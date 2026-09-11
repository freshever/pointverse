import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import {
  appendMessage,
  createPoint,
  listPoints,
  openDatabase,
} from "../src/db.mjs";

const root = resolve(process.cwd());
const port = Number(process.env.PORT || 4173);
const host = process.env.HOST || "127.0.0.1";
const db = openDatabase(join(root, "data", "pointverse.sqlite"));

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
};

const server = createServer(async (request, response) => {
  const pathname = decodeURIComponent(
    new URL(request.url, `http://${request.headers.host}`).pathname,
  );

  if (pathname.startsWith("/api/")) {
    await handleApi(request, response, pathname);
    return;
  }

  const relativePath =
    pathname === "/"
      ? "index.html"
      : normalize(pathname).replace(/^[/\\]+/, "");
  const filePath = join(root, relativePath);

  if (
    !filePath.startsWith(`${root}/`) ||
    !existsSync(filePath) ||
    !statSync(filePath).isFile()
  ) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("404 Not Found");
    return;
  }

  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type":
      mimeTypes[extname(filePath).toLowerCase()] || "application/octet-stream",
  });
  createReadStream(filePath).pipe(response);
});

server.listen(port, host, () => {
  console.log(`PointVerse H5 is running at http://${host}:${port}`);
  console.log(`SQLite database: ${join(root, "data", "pointverse.sqlite")}`);
});

async function handleApi(request, response, pathname) {
  try {
    if (request.method === "GET" && pathname === "/api/points") {
      return json(response, 200, { points: listPoints(db) });
    }

    if (request.method === "POST" && pathname === "/api/points") {
      return json(response, 201, {
        point: createPoint(db, await readJson(request)),
      });
    }

    const messageRoute = pathname.match(/^\/api\/points\/([^/]+)\/messages$/);
    if (request.method === "POST" && messageRoute) {
      const point = appendMessage(
        db,
        decodeURIComponent(messageRoute[1]),
        await readJson(request),
      );
      return point
        ? json(response, 200, { point })
        : json(response, 404, { error: "Point 不存在" });
    }

    json(response, 404, { error: "API 不存在" });
  } catch (error) {
    json(response, 400, { error: error.message || "请求处理失败" });
  }
}

function json(response, status, payload) {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
  });
  response.end(JSON.stringify(payload));
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 1_000_000) throw new Error("请求内容过大");
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}
