import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { config } from "../config.ts";

fs.mkdirSync(path.dirname(config.dbPath), { recursive: true });

export const db = new DatabaseSync(config.dbPath);
db.exec("PRAGMA journal_mode = WAL;");
db.exec("PRAGMA foreign_keys = ON;");
db.exec("PRAGMA busy_timeout = 5000;");

const MIGRATIONS: string[] = [
  `
  CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    display_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    avatar_color TEXT NOT NULL DEFAULT '#2f7d5b',
    share_mode TEXT NOT NULL DEFAULT 'private',     -- private | public | selected
    share_detail TEXT NOT NULL DEFAULT 'summary',   -- summary | full
    api_token_hash TEXT,
    api_token_hint TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TEXT NOT NULL
  );

  CREATE TABLE profiles (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    sex TEXT NOT NULL,                      -- male | female
    birth_date TEXT NOT NULL,               -- YYYY-MM-DD
    height_cm REAL NOT NULL,
    weight_kg REAL NOT NULL,                -- 建档时体重
    activity_level TEXT NOT NULL DEFAULT 'low_active', -- inactive | low_active | active | very_active
    goal TEXT NOT NULL DEFAULT 'maintain',  -- lose | maintain | gain
    goal_rate_kg_week REAL NOT NULL DEFAULT 0.5,
    target_weight_kg REAL,
    physiology TEXT NOT NULL DEFAULT 'none',-- none | pregnant | lactating
    sodium_mode TEXT NOT NULL DEFAULT 'cdrr', -- cdrr (2300) | aha (1500)
    conditions TEXT NOT NULL DEFAULT '[]',  -- JSON: ["hypertension","diabetes","high_ldl",...]
    timezone TEXT NOT NULL DEFAULT 'Asia/Shanghai',
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE share_grants (
    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    viewer_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (owner_id, viewer_id)
  );

  CREATE TABLE meals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    time TEXT NOT NULL,
    meal_type TEXT NOT NULL DEFAULT 'other',
    description TEXT NOT NULL DEFAULT '',
    photos TEXT NOT NULL DEFAULT '[]',
    ai_summary TEXT,
    ai_model TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX idx_meals_user_date ON meals(user_id, date);

  CREATE TABLE meal_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    meal_id INTEGER NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    name TEXT NOT NULL,
    amount_g REAL NOT NULL,
    amount_desc TEXT,
    food_id INTEGER REFERENCES foods(id) ON DELETE SET NULL,
    category TEXT,
    cooking_method TEXT,
    nova_group INTEGER,
    confidence TEXT,
    nutrients TEXT NOT NULL,       -- JSON NutrientVector（该份量的总量）
    groups TEXT NOT NULL,          -- JSON 食物组当量（该份量）
    hazards TEXT NOT NULL DEFAULT '[]', -- JSON [{key, amount, unit, note}]
    notes TEXT
  );
  CREATE INDEX idx_items_user_date ON meal_items(user_id, date);

  CREATE TABLE foods (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    visibility TEXT NOT NULL DEFAULT 'private', -- private | public
    name TEXT NOT NULL,
    brand TEXT,
    aliases TEXT NOT NULL DEFAULT '',
    category TEXT,
    serving_g REAL,
    serving_desc TEXT,
    per100 TEXT NOT NULL,          -- JSON 每 100 g 营养素
    groups100 TEXT NOT NULL,       -- JSON 每 100 g 食物组当量
    hazards100 TEXT NOT NULL DEFAULT '[]', -- JSON [{key, fraction, note}]
    nova_group INTEGER,
    ingredients TEXT,
    label_fields TEXT NOT NULL DEFAULT '[]',
    source TEXT NOT NULL DEFAULT 'manual', -- label | ai_search | ai_estimate | manual
    source_urls TEXT NOT NULL DEFAULT '[]',
    notes TEXT,
    use_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX idx_foods_owner ON foods(owner_id);

  CREATE TABLE body_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    time TEXT NOT NULL DEFAULT '22:00',
    weight_kg REAL,
    body_fat_pct REAL,
    waist_cm REAL,
    note TEXT,
    source TEXT NOT NULL DEFAULT 'manual',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX idx_body_user_date ON body_metrics(user_id, date);

  CREATE TABLE activity_days (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    steps INTEGER,
    active_kcal REAL,
    resting_kcal REAL,
    distance_km REAL,
    exercise_min REAL,
    source TEXT NOT NULL DEFAULT 'manual',
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, date)
  );

  CREATE TABLE exercises (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    time TEXT NOT NULL DEFAULT '12:00',
    description TEXT NOT NULL,
    activity_key TEXT,
    met REAL NOT NULL,
    duration_min REAL NOT NULL,
    distance_km REAL,
    kcal REAL NOT NULL,            -- 净消耗（已扣除静息代谢）
    in_device INTEGER NOT NULL DEFAULT 0, -- 1 = 已包含在手表/手机的活动能量中，避免重复计算
    source TEXT NOT NULL DEFAULT 'manual',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX idx_ex_user_date ON exercises(user_id, date);

  CREATE TABLE ai_jobs (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued', -- queued | running | done | error
    input TEXT NOT NULL,
    result TEXT,
    error TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    finished_at TEXT
  );

  CREATE TABLE daily_scores (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    score REAL,
    detail TEXT NOT NULL,
    computed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, date)
  );

  CREATE TABLE reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    period TEXT NOT NULL,          -- week | month
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    score REAL,
    detail TEXT NOT NULL,
    ai_summary TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (user_id, period, start_date)
  );
  `,
];

function migrate() {
  db.exec("CREATE TABLE IF NOT EXISTS _migrations (version INTEGER PRIMARY KEY)");
  const row = db.prepare("SELECT MAX(version) AS v FROM _migrations").get() as { v: number | null };
  const current = row.v ?? 0;
  for (let i = current; i < MIGRATIONS.length; i++) {
    db.exec("BEGIN");
    try {
      db.exec(MIGRATIONS[i]);
      db.prepare("INSERT INTO _migrations (version) VALUES (?)").run(i + 1);
      db.exec("COMMIT");
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  }
}

migrate();

export function tx<T>(fn: () => T): T {
  db.exec("BEGIN");
  try {
    const r = fn();
    db.exec("COMMIT");
    return r;
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

export function parseJson<T>(s: string | null | undefined, fallback: T): T {
  if (!s) return fallback;
  try {
    return JSON.parse(s) as T;
  } catch {
    return fallback;
  }
}

type Param = string | number | bigint | null | Uint8Array;

/** 带类型的查询辅助函数 */
export function all<T>(sql: string, ...params: Param[]): T[] {
  return db.prepare(sql).all(...params) as unknown as T[];
}

export function get<T>(sql: string, ...params: Param[]): T | undefined {
  return db.prepare(sql).get(...params) as unknown as T | undefined;
}

export function run(sql: string, ...params: Param[]) {
  return db.prepare(sql).run(...params);
}
