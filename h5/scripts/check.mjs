import { readFile } from "node:fs/promises";

const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
const requiredMarkers = [
  "<!doctype html>",
  "点界",
  'id="s01"',
  'id="s03"',
  'id="graphCanvas"',
  'src="/src/main.js"',
];

const missing = requiredMarkers.filter(
  (marker) => !html.toLowerCase().includes(marker.toLowerCase()),
);

if (missing.length) {
  console.error(`H5 入口缺少必要标记：${missing.join(", ")}`);
  process.exit(1);
}

console.log("H5 入口检查通过");
