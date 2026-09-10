import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";

const samplePoints = [
  ["雨后的窗户", "看到雨后的窗户，想起小时候放学。", -85, -35, 60],
  ["底片显影", "学习像底片显影，旧经验在新条件下显现。", 65, 50, 10],
  ["故事的开头", "从一个声音开始讲述故事。", -60, 85, -40],
  ["跨领域的共鸣", "不同背景的人怎样产生新的理解？", 105, -65, -55],
  ["日常的灵感", "记录一闪而过的瞬间。", 10, -100, 15],
  ["多个美的终态", "魔方不同的颜色排布也可以是美。", -110, 20, -80],
  ["不可言传", "先留下感受，不强迫解释。", 40, 10, 115],
];

export function openDatabase(filePath) {
  mkdirSync(dirname(filePath), { recursive: true });
  const db = new DatabaseSync(filePath);
  db.exec("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;");
  migrate(db);
  seed(db);
  return db;
}

function migrate(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    );
  `);

  const current = db
    .prepare(
      "SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations",
    )
    .get().version;
  if (current < 1) {
    db.exec(`
      BEGIN;
      CREATE TABLE points (
        id TEXT PRIMARY KEY,
        title TEXT,
        original_text TEXT NOT NULL DEFAULT '',
        version INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'active',
        x REAL NOT NULL DEFAULT 0,
        y REAL NOT NULL DEFAULT 0,
        z REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        point_id TEXT NOT NULL REFERENCES points(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
        content TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(point_id, sequence)
      );
      CREATE INDEX idx_messages_point_sequence ON messages(point_id, sequence);
      CREATE INDEX idx_points_updated_at ON points(updated_at DESC);
      INSERT INTO schema_migrations(version, applied_at) VALUES (1, datetime('now'));
      COMMIT;
    `);
  }
}

function seed(db) {
  const count = db.prepare("SELECT COUNT(*) AS count FROM points").get().count;
  if (count > 0) return;

  const insertPoint = db.prepare(`
    INSERT INTO points(id, title, original_text, x, y, z, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const insertMessage = db.prepare(`
    INSERT INTO messages(id, point_id, role, content, sequence, created_at)
    VALUES (?, ?, 'user', ?, 0, ?)
  `);
  const now = new Date().toISOString();

  db.exec("BEGIN");
  try {
    for (const [title, text, x, y, z] of samplePoints) {
      const id = randomUUID();
      insertPoint.run(id, title, text, x, y, z, now, now);
      insertMessage.run(randomUUID(), id, text, now);
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export function listPoints(db) {
  const points = db
    .prepare(
      `
    SELECT id, title, original_text AS text, version, status, x, y, z, created_at, updated_at
    FROM points WHERE status = 'active' ORDER BY created_at ASC
  `,
    )
    .all();
  const messages = db
    .prepare(
      `
    SELECT id, point_id, role, content, sequence, created_at
    FROM messages ORDER BY point_id, sequence
  `,
    )
    .all();
  const grouped = Map.groupBy(messages, (message) => message.point_id);
  return points.map((point) => ({
    ...point,
    messages: grouped.get(point.id) || [],
  }));
}

export function createPoint(db, input) {
  const id = randomUUID();
  const now = new Date().toISOString();
  const text = String(input.text || "").trim();
  const title = String(input.title || text.slice(0, 14) || "未命名点子").trim();
  const x = finiteNumber(input.x);
  const y = finiteNumber(input.y);
  const z = finiteNumber(input.z);

  db.exec("BEGIN");
  try {
    db.prepare(
      `
      INSERT INTO points(id, title, original_text, x, y, z, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `,
    ).run(id, title, text, x, y, z, now, now);
    if (text) {
      db.prepare(
        `
        INSERT INTO messages(id, point_id, role, content, sequence, created_at)
        VALUES (?, ?, 'user', ?, 0, ?)
      `,
      ).run(randomUUID(), id, text, now);
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return getPoint(db, id);
}

export function appendMessage(db, pointId, input) {
  const content = String(input.content || "").trim();
  if (!content) throw new Error("消息内容不能为空");
  const point = db
    .prepare("SELECT id FROM points WHERE id = ? AND status = 'active'")
    .get(pointId);
  if (!point) return null;

  const now = new Date().toISOString();
  const sequence = db
    .prepare(
      "SELECT COALESCE(MAX(sequence), -1) + 1 AS sequence FROM messages WHERE point_id = ?",
    )
    .get(pointId).sequence;
  db.exec("BEGIN");
  try {
    db.prepare(
      `
      INSERT INTO messages(id, point_id, role, content, sequence, created_at)
      VALUES (?, ?, 'user', ?, ?, ?)
    `,
    ).run(randomUUID(), pointId, content, sequence, now);
    db.prepare(
      `
      UPDATE points SET original_text = CASE WHEN original_text = '' THEN ? ELSE original_text || char(10) || ? END,
        version = version + 1, updated_at = ? WHERE id = ?
    `,
    ).run(content, content, now, pointId);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return getPoint(db, pointId);
}

function getPoint(db, id) {
  return listPoints(db).find((point) => point.id === id) || null;
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}
