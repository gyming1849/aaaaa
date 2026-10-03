// 饮食记录、图片上传、AI 任务、食物库

import { Router } from "express";
import multer from "multer";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { all, get, run, tx, parseJson } from "../db/index.ts";
import { requireAuth } from "../auth.ts";
import { config } from "../config.ts";
import { ah, bad, notFound, forbidden, num, str, oneOf } from "../lib/http.ts";
import { isDate, TIME_RE, todayIn, nowTimeIn } from "../lib/dates.ts";
import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, sanitizeVector } from "../standards/nutrients.ts";
import { HAZARD_MAP } from "../standards/hazards.ts";
import { getProfile, invalidateDay, itemFromRow, getWeights, weightOn } from "../services/userdata.ts";
import { enqueue, getJob } from "../ai/jobs.ts";
import { analyzeMeal, lookupFood, parseExercise, itemFromFood, foodForUser, type DraftItem } from "../ai/service.ts";
import { activeProvider } from "../ai/providers.ts";
import { FOOD_CATEGORIES } from "../ai/schema.ts";

export const logRouter = Router();
logRouter.use(requireAuth);

const MEAL_TYPES = ["breakfast", "lunch", "dinner", "snack", "drink", "other"] as const;

// ---------------------------------------------------------------- 上传

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, _file, cb) => {
      const dir = path.join(config.uploadDir, String(req.user!.id));
      fs.mkdirSync(dir, { recursive: true });
      cb(null, dir);
    },
    filename: (_req, file, cb) => {
      const ext = (path.extname(file.originalname).toLowerCase().match(/^\.(jpe?g|png|webp|gif)$/) ?? [".jpg"])[0];
      cb(null, crypto.randomBytes(12).toString("hex") + ext);
    },
  }),
  limits: { fileSize: 12 * 1024 * 1024, files: 6 },
  fileFilter: (_req, file, cb) => cb(null, /^image\/(jpeg|png|webp|gif)$/.test(file.mimetype)),
});

logRouter.post(
  "/uploads",
  upload.array("photos", 6),
  ah((req) => {
    const files = (req.files as Express.Multer.File[]) ?? [];
    if (!files.length) throw bad("请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）");
    return { photos: files.map((f) => ({ id: f.filename, url: `/api/uploads/${f.filename}` })) };
  }),
);

logRouter.get(
  "/uploads/:id",
  ah((req, res) => {
    const id = String(req.params.id);
    if (!/^[\w.-]+$/.test(id)) throw notFound();
    const p = path.join(config.uploadDir, String(req.user!.id), id);
    if (!fs.existsSync(p)) throw notFound();
    res.sendFile(p);
  }),
);

// ---------------------------------------------------------------- AI 任务

logRouter.get("/ai/status", ah(() => ({ provider: activeProvider(), model: activeProvider() === "mock" ? "offline" : config.ai.model, web_search: config.ai.webSearch })));

logRouter.post(
  "/ai/meal",
  ah((req) => {
    const uid = req.user!.id;
    const profile = getProfile(uid);
    const text = str(req.body.text, { optional: true, max: 2000 });
    const photos = Array.isArray(req.body.photos) ? req.body.photos : [];
    if (!text && !photos.length) throw bad("请描述吃了什么，或上传照片");
    const date = isDate(req.body.date) ? req.body.date : todayIn(profile?.timezone ?? "Asia/Shanghai");
    const time = TIME_RE.test(req.body.time) ? req.body.time : "12:00";
    const meal_type = oneOf(req.body.meal_type, MEAL_TYPES, "other");
    const input = { text, date, time, meal_type, photos };
    const id = enqueue(uid, "meal", input, () => analyzeMeal(uid, input, profile));
    return { job_id: id };
  }),
);

logRouter.post(
  "/ai/food",
  ah((req) => {
    const uid = req.user!.id;
    const name = str(req.body.name, { optional: true, max: 80 });
    const photos = Array.isArray(req.body.photos) ? req.body.photos : [];
    if (!name && !photos.length) throw bad("请输入食物名称或上传包装/营养成分表照片");
    const input = { name, brand: str(req.body.brand, { optional: true, max: 60 }), note: str(req.body.note, { optional: true, max: 500 }), photos };
    const id = enqueue(uid, "food", input, () => lookupFood(uid, input));
    return { job_id: id };
  }),
);

logRouter.post(
  "/ai/exercise",
  ah((req) => {
    const uid = req.user!.id;
    const profile = getProfile(uid);
    if (!profile) throw bad("请先完善个人档案");
    const text = str(req.body.text, { max: 500, name: "运动描述" });
    const date = isDate(req.body.date) ? req.body.date : todayIn(profile.timezone);
    const weight = weightOn(getWeights(uid, date), date, profile.weight_kg);
    const id = enqueue(uid, "exercise", { text, date }, () => parseExercise(text, weight));
    return { job_id: id };
  }),
);

logRouter.get(
  "/ai/jobs/:id",
  ah((req) => {
    const job = getJob(req.user!.id, String(req.params.id));
    if (!job) throw notFound("任务不存在");
    return { id: job.id, kind: job.kind, status: job.status, error: job.error, result: job.result ? JSON.parse(job.result) : null };
  }),
);

// ---------------------------------------------------------------- 餐食

function cleanItem(raw: Record<string, unknown>, uid: number) {
  const amount = num(raw.amount_g, { min: 0.1, max: 20000, name: "重量" })!;
  const foodId = Number(raw.food_id);
  const food = Number.isInteger(foodId) && foodId > 0 ? foodForUser(uid, foodId) : undefined;
  let nutrients = sanitizeVector(raw.nutrients, NUTRIENT_KEYS);
  let groups = sanitizeVector(raw.groups, FOOD_GROUP_KEYS);
  let hazards = (Array.isArray(raw.hazards) ? raw.hazards : [])
    .filter((h: Record<string, unknown>) => h && HAZARD_MAP[String(h.key)])
    .map((h: Record<string, unknown>) => ({ key: String(h.key), amount: Math.max(0, Number(h.amount) || 0), note: String(h.note ?? "").slice(0, 200) }));
  if (food) {
    // 库中食物：以库数值为准重新计算，防止客户端篡改
    const it = itemFromFood(food, amount);
    nutrients = it.nutrients;
    groups = it.groups;
    hazards = it.hazards.map((h) => ({ key: h.key, amount: h.amount, note: "" }));
  }
  return {
    name: str(raw.name, { max: 80, name: "食物名称" }),
    amount_g: amount,
    amount_desc: str(raw.amount_desc, { optional: true, max: 80 }),
    food_id: food ? food.id : null,
    category: FOOD_CATEGORIES.includes(raw.category as (typeof FOOD_CATEGORIES)[number]) ? String(raw.category) : "other",
    cooking_method: str(raw.cooking_method, { optional: true, max: 30 }),
    nova_group: [1, 2, 3, 4].includes(Number(raw.nova_group)) ? Number(raw.nova_group) : null,
    confidence: str(raw.confidence, { optional: true, max: 10 }),
    nutrients,
    groups,
    hazards,
    notes: str(raw.notes, { optional: true, max: 300 }),
  };
}

function insertItems(mealId: number, uid: number, date: string, items: ReturnType<typeof cleanItem>[]) {
  for (const it of items) {
    run(
      `INSERT INTO meal_items (meal_id, user_id, date, name, amount_g, amount_desc, food_id, category, cooking_method, nova_group, confidence, nutrients, groups, hazards, notes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      mealId, uid, date, it.name, it.amount_g, it.amount_desc, it.food_id, it.category, it.cooking_method, it.nova_group, it.confidence,
      JSON.stringify(it.nutrients), JSON.stringify(it.groups), JSON.stringify(it.hazards), it.notes,
    );
    if (it.food_id) run("UPDATE foods SET use_count = use_count + 1 WHERE id = ?", it.food_id);
  }
}

function mealBody(req: { body: Record<string, unknown> }, uid: number) {
  const b = req.body;
  if (!isDate(b.date)) throw bad("日期格式不正确");
  if (!TIME_RE.test(String(b.time))) throw bad("时间格式不正确");
  const items = Array.isArray(b.items) ? b.items.map((i: Record<string, unknown>) => cleanItem(i, uid)) : [];
  if (!items.length) throw bad("至少需要一种食物");
  const photos = Array.isArray(b.photos) ? b.photos.filter((p: unknown) => typeof p === "string" && /^[\w.-]+$/.test(p)).slice(0, 6) : [];
  return {
    date: b.date as string,
    time: String(b.time),
    meal_type: oneOf(b.meal_type, MEAL_TYPES, "other"),
    description: str(b.description, { optional: true, max: 2000 }),
    photos,
    ai_summary: str(b.ai_summary, { optional: true, max: 500 }),
    ai_model: str(b.ai_model, { optional: true, max: 60 }),
    items,
  };
}

logRouter.post(
  "/meals",
  ah((req) => {
    const uid = req.user!.id;
    const m = mealBody(req, uid);
    const id = tx(() => {
      const r = run(
        "INSERT INTO meals (user_id, date, time, meal_type, description, photos, ai_summary, ai_model) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        uid, m.date, m.time, m.meal_type, m.description, JSON.stringify(m.photos), m.ai_summary, m.ai_model,
      );
      const mealId = Number(r.lastInsertRowid);
      insertItems(mealId, uid, m.date, m.items);
      invalidateDay(uid, m.date);
      return mealId;
    });
    return { id };
  }),
);

logRouter.put(
  "/meals/:id",
  ah((req) => {
    const uid = req.user!.id;
    const id = Number(req.params.id);
    const old = get<{ date: string }>("SELECT date FROM meals WHERE id = ? AND user_id = ?", id, uid);
    if (!old) throw notFound("餐食不存在");
    const m = mealBody(req, uid);
    tx(() => {
      run("UPDATE meals SET date = ?, time = ?, meal_type = ?, description = ? WHERE id = ?", m.date, m.time, m.meal_type, m.description, id);
      run("DELETE FROM meal_items WHERE meal_id = ?", id);
      insertItems(id, uid, m.date, m.items);
      invalidateDay(uid, old.date);
      invalidateDay(uid, m.date);
    });
    return { ok: true };
  }),
);

logRouter.delete(
  "/meals/:id",
  ah((req) => {
    const uid = req.user!.id;
    const old = get<{ date: string }>("SELECT date FROM meals WHERE id = ? AND user_id = ?", Number(req.params.id), uid);
    if (!old) throw notFound("餐食不存在");
    tx(() => {
      run("DELETE FROM meals WHERE id = ?", Number(req.params.id));
      invalidateDay(uid, old.date);
    });
    return { ok: true };
  }),
);

export function mealsForDay(uid: number, date: string) {
  const meals = all<{ id: number; date: string; time: string; meal_type: string; description: string; photos: string; ai_summary: string | null }>(
    "SELECT id, date, time, meal_type, description, photos, ai_summary FROM meals WHERE user_id = ? AND date = ? ORDER BY time, id",
    uid,
    date,
  );
  const items = all<Parameters<typeof itemFromRow>[0] & { amount_desc: string; food_id: number | null; category: string; cooking_method: string; confidence: string; notes: string }>(
    "SELECT * FROM meal_items WHERE user_id = ? AND date = ? ORDER BY id",
    uid,
    date,
  );
  return meals.map((m) => ({
    ...m,
    photos: parseJson<string[]>(m.photos, []),
    items: items
      .filter((i) => i.meal_id === m.id)
      .map((i) => ({
        ...itemFromRow(i),
        amount_desc: i.amount_desc,
        food_id: i.food_id,
        category: i.category,
        cooking_method: i.cooking_method,
        confidence: i.confidence,
        notes: i.notes,
      })),
  }));
}

/** 快速记录饮水：同一天累加到一条“饮水”记录里 */
logRouter.post(
  "/water",
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    const date = isDate(req.body.date) ? req.body.date : todayIn(p?.timezone ?? "Asia/Shanghai");
    const ml = num(req.body.ml, { min: -2000, max: 3000, name: "饮水量" })!;
    const existing = get<{ id: number; item_id: number; amount_g: number }>(
      `SELECT m.id, i.id AS item_id, i.amount_g FROM meals m JOIN meal_items i ON i.meal_id = m.id
       WHERE m.user_id = ? AND m.date = ? AND m.description = '饮水' LIMIT 1`,
      uid, date,
    );
    const total = Math.max(0, (existing?.amount_g ?? 0) + ml);
    const nutrients = JSON.stringify({ ...sanitizeVector({}, NUTRIENT_KEYS), water_g: total });
    tx(() => {
      if (existing && total <= 0) run("DELETE FROM meals WHERE id = ?", existing.id);
      else if (existing) run("UPDATE meal_items SET amount_g = ?, amount_desc = ?, nutrients = ? WHERE id = ?", total, `${total} ml`, nutrients, existing.item_id);
      else if (total > 0) {
        const mealId = Number(run("INSERT INTO meals (user_id, date, time, meal_type, description) VALUES (?, ?, ?, 'drink', '饮水')", uid, date, nowTimeIn(p?.timezone ?? "Asia/Shanghai")).lastInsertRowid);
        run(
          `INSERT INTO meal_items (meal_id, user_id, date, name, amount_g, amount_desc, category, nova_group, confidence, nutrients, groups, hazards)
           VALUES (?, ?, ?, '饮用水', ?, ?, 'beverage', 1, 'high', ?, ?, '[]')`,
          mealId, uid, date, total, `${total} ml`, nutrients, JSON.stringify(sanitizeVector({}, FOOD_GROUP_KEYS)),
        );
      }
      invalidateDay(uid, date);
    });
    return { ok: true, total_ml: total };
  }),
);

/** 最近常吃的食物（用于快速添加） */
logRouter.get(
  "/meals/recent-items",
  ah((req) => {
    return all<{ name: string; food_id: number | null; amount_g: number; n: number; last: string }>(
      `SELECT name, food_id, amount_g, COUNT(*) AS n, MAX(date) AS last FROM meal_items WHERE user_id = ? AND date >= date('now', '-60 days')
       GROUP BY name ORDER BY n DESC, last DESC LIMIT 20`,
      req.user!.id,
    );
  }),
);

// ---------------------------------------------------------------- 食物库

interface FoodFull {
  id: number; owner_id: number; visibility: string; name: string; brand: string | null; aliases: string; category: string | null;
  serving_g: number | null; serving_desc: string | null; per100: string; groups100: string; hazards100: string; nova_group: number | null;
  ingredients: string | null; label_fields: string; source: string; source_urls: string; notes: string | null; use_count: number;
  created_at: string; updated_at: string; owner_name?: string;
}

function foodOut(f: FoodFull, uid: number) {
  return {
    ...f,
    per100: sanitizeVector(parseJson(f.per100, {}), NUTRIENT_KEYS),
    groups100: sanitizeVector(parseJson(f.groups100, {}), FOOD_GROUP_KEYS),
    hazards100: parseJson(f.hazards100, []),
    label_fields: parseJson(f.label_fields, []),
    source_urls: parseJson(f.source_urls, []),
    mine: f.owner_id === uid,
  };
}

logRouter.get(
  "/foods",
  ah((req) => {
    const uid = req.user!.id;
    const q = str(req.query.q, { optional: true, max: 60 });
    const scope = req.query.scope === "mine" ? "mine" : "all";
    const where = scope === "mine" ? "f.owner_id = ?" : "(f.owner_id = ? OR f.visibility = 'public')";
    const like = `%${q}%`;
    const rows = all<FoodFull>(
      `SELECT f.*, u.display_name AS owner_name FROM foods f JOIN users u ON u.id = f.owner_id
       WHERE ${where} ${q ? "AND (f.name LIKE ? OR f.brand LIKE ? OR f.aliases LIKE ?)" : ""}
       ORDER BY (f.owner_id = ?) DESC, f.use_count DESC, f.updated_at DESC LIMIT 200`,
      ...(q ? [uid, like, like, like, uid] : [uid, uid]),
    );
    return rows.map((f) => foodOut(f, uid));
  }),
);

logRouter.get(
  "/foods/:id",
  ah((req) => {
    const uid = req.user!.id;
    const f = get<FoodFull>(
      "SELECT f.*, u.display_name AS owner_name FROM foods f JOIN users u ON u.id = f.owner_id WHERE f.id = ? AND (f.owner_id = ? OR f.visibility = 'public')",
      Number(req.params.id),
      uid,
    );
    if (!f) throw notFound("食物不存在");
    return foodOut(f, uid);
  }),
);

function foodBody(b: Record<string, unknown>) {
  const hazards = (Array.isArray(b.hazards100) ? b.hazards100 : [])
    .filter((h: Record<string, unknown>) => h && HAZARD_MAP[String(h.key)])
    .map((h: Record<string, unknown>) => ({ key: String(h.key), amount_per_100g: Math.max(0, Number(h.amount_per_100g) || 0), note: String(h.note ?? "").slice(0, 200) }));
  const aliases = Array.isArray(b.aliases) ? b.aliases.map(String).join(",") : str(b.aliases, { optional: true, max: 300 });
  const sources = Array.isArray(b.source_urls) ? b.source_urls.filter((s: Record<string, unknown>) => s && typeof s.url === "string").slice(0, 10) : [];
  return {
    name: str(b.name, { max: 80, name: "名称" }),
    brand: str(b.brand, { optional: true, max: 60 }) || null,
    aliases: aliases.slice(0, 300),
    category: FOOD_CATEGORIES.includes(b.category as (typeof FOOD_CATEGORIES)[number]) ? String(b.category) : "other",
    serving_g: num(b.serving_g, { min: 0.1, max: 10000, optional: true, name: "每份重量" }),
    serving_desc: str(b.serving_desc, { optional: true, max: 60 }),
    per100: JSON.stringify(sanitizeVector(b.per100, NUTRIENT_KEYS)),
    groups100: JSON.stringify(sanitizeVector(b.groups100, FOOD_GROUP_KEYS)),
    hazards100: JSON.stringify(hazards),
    nova_group: [1, 2, 3, 4].includes(Number(b.nova_group)) ? Number(b.nova_group) : null,
    ingredients: str(b.ingredients, { optional: true, max: 2000 }),
    label_fields: JSON.stringify(Array.isArray(b.label_fields) ? b.label_fields.filter((k: unknown) => NUTRIENT_KEYS.includes(String(k))) : []),
    source: oneOf(b.source, ["label", "ai_search", "ai_estimate", "manual"] as const, "manual"),
    source_urls: JSON.stringify(sources),
    notes: str(b.notes, { optional: true, max: 600 }),
    visibility: oneOf(b.visibility, ["private", "public"] as const, "private"),
  };
}

logRouter.post(
  "/foods",
  ah((req) => {
    const f = foodBody(req.body ?? {});
    const r = run(
      `INSERT INTO foods (owner_id, visibility, name, brand, aliases, category, serving_g, serving_desc, per100, groups100, hazards100, nova_group, ingredients, label_fields, source, source_urls, notes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      req.user!.id, f.visibility, f.name, f.brand, f.aliases, f.category, f.serving_g, f.serving_desc, f.per100, f.groups100, f.hazards100,
      f.nova_group, f.ingredients, f.label_fields, f.source, f.source_urls, f.notes,
    );
    return { id: Number(r.lastInsertRowid) };
  }),
);

/** 把 AI 分析出的一项直接存为食物库条目 */
logRouter.post(
  "/foods/from-item",
  ah((req) => {
    const item = req.body.item as DraftItem | undefined;
    if (!item || !item.per100) throw bad("缺少食物数据");
    const f = foodBody({
      name: req.body.name ?? item.name,
      brand: req.body.brand ?? "",
      aliases: req.body.aliases ?? [],
      category: item.category,
      serving_g: req.body.serving_g ?? item.amount_g,
      serving_desc: req.body.serving_desc ?? item.amount_desc,
      per100: item.per100.nutrients,
      groups100: item.per100.groups,
      hazards100: item.per100.hazards,
      nova_group: item.nova_group,
      notes: item.notes,
      source: "ai_estimate",
      source_urls: req.body.source_urls ?? [],
      visibility: req.body.visibility,
    });
    const r = run(
      `INSERT INTO foods (owner_id, visibility, name, brand, aliases, category, serving_g, serving_desc, per100, groups100, hazards100, nova_group, ingredients, label_fields, source, source_urls, notes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      req.user!.id, f.visibility, f.name, f.brand, f.aliases, f.category, f.serving_g, f.serving_desc, f.per100, f.groups100, f.hazards100,
      f.nova_group, f.ingredients, f.label_fields, f.source, f.source_urls, f.notes,
    );
    return { id: Number(r.lastInsertRowid) };
  }),
);

logRouter.put(
  "/foods/:id",
  ah((req) => {
    const id = Number(req.params.id);
    const own = get<{ owner_id: number }>("SELECT owner_id FROM foods WHERE id = ?", id);
    if (!own) throw notFound("食物不存在");
    if (own.owner_id !== req.user!.id) throw forbidden("只能修改自己创建的食物");
    const f = foodBody(req.body ?? {});
    run(
      `UPDATE foods SET visibility=?, name=?, brand=?, aliases=?, category=?, serving_g=?, serving_desc=?, per100=?, groups100=?, hazards100=?, nova_group=?,
       ingredients=?, label_fields=?, source=?, source_urls=?, notes=?, updated_at=datetime('now') WHERE id = ?`,
      f.visibility, f.name, f.brand, f.aliases, f.category, f.serving_g, f.serving_desc, f.per100, f.groups100, f.hazards100, f.nova_group,
      f.ingredients, f.label_fields, f.source, f.source_urls, f.notes, id,
    );
    return { ok: true };
  }),
);

logRouter.delete(
  "/foods/:id",
  ah((req) => {
    const id = Number(req.params.id);
    const own = get<{ owner_id: number }>("SELECT owner_id FROM foods WHERE id = ?", id);
    if (!own) throw notFound("食物不存在");
    if (own.owner_id !== req.user!.id) throw forbidden("只能删除自己创建的食物");
    run("DELETE FROM foods WHERE id = ?", id);
    return { ok: true };
  }),
);

/** 选择食物库条目 + 克数 → 生成可直接保存的记录项（无需 AI） */
logRouter.post(
  "/foods/:id/item",
  ah((req) => {
    const food = foodForUser(req.user!.id, Number(req.params.id));
    if (!food) throw notFound("食物不存在");
    const grams = num(req.body.grams, { min: 0.1, max: 20000, optional: true, name: "克数" }) ?? food.serving_g ?? 100;
    return itemFromFood(food, grams);
  }),
);
