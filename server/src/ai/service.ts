// AI 业务层：把模型输出清洗、校验、与食物库对齐后交给前端确认。

import path from "node:path";
import fs from "node:fs";
import { all, get } from "../db/index.ts";
import { parseJson } from "../db/index.ts";
import { config } from "../config.ts";
import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, sanitizeVector, scaleVector, type NutrientVector } from "../standards/nutrients.ts";
import { HAZARD_MAP } from "../standards/hazards.ts";
import { ACTIVITY_MAP, netKcal } from "../standards/met.ts";
import { MEAL_SYSTEM, FOOD_SYSTEM, EXERCISE_SYSTEM, WEEKLY_SYSTEM, ACTIVITY_SYSTEM } from "./prompts.ts";
import { mealAnalysisSchema, foodProfileSchema, exerciseSchema, weeklySummarySchema, activitySchema, FOOD_CATEGORIES } from "./schema.ts";
import { runAi, activeProvider, type AiImage } from "./providers.ts";
import { mockAnalyzeMeal, mockParseExercise, mockParseActivity } from "./mock.ts";
import type { HazardEntry } from "../scoring/types.ts";
import type { PeriodScore } from "../scoring/period.ts";
import type { Profile } from "../standards/targets.ts";
import { ageOn } from "../lib/dates.ts";

export interface DraftItem {
  name: string;
  amount_g: number;
  amount_desc: string;
  food_id: number | null;
  category: string;
  cooking_method: string;
  nova_group: number | null;
  confidence: string;
  nutrients: NutrientVector;
  groups: NutrientVector;
  hazards: HazardEntry[];
  notes: string;
  per100: { nutrients: NutrientVector; groups: NutrientVector; hazards: { key: string; amount_per_100g: number }[] };
  save_suggested: boolean;
}

export interface MealDraft {
  items: DraftItem[];
  summary: string;
  assumptions: string[];
  questions: string[];
  sources: { title: string; url: string }[];
  provider: string;
  model: string;
}

export interface FoodRow {
  id: number;
  owner_id: number;
  visibility: string;
  name: string;
  brand: string | null;
  aliases: string;
  category: string | null;
  serving_g: number | null;
  serving_desc: string | null;
  per100: string;
  groups100: string;
  hazards100: string;
  nova_group: number | null;
}

// ---------- 图片 ----------

const MEDIA: Record<string, string> = { ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp", ".gif": "image/gif" };

export function resolvePhotos(userId: number, ids: unknown): AiImage[] {
  if (!Array.isArray(ids)) return [];
  const out: AiImage[] = [];
  for (const id of ids.slice(0, 6)) {
    if (typeof id !== "string" || !/^[\w.-]+$/.test(id)) continue;
    const p = path.join(config.uploadDir, String(userId), id);
    const mediaType = MEDIA[path.extname(p).toLowerCase()];
    if (mediaType && fs.existsSync(p)) out.push({ path: p, mediaType });
  }
  return out;
}

// ---------- 清洗 ----------

function fixConsistency(n: NutrientVector, g: NutrientVector) {
  const macroKcal = n.protein_g * 4 + n.carb_g * 4 + n.fat_g * 9 + n.alcohol_g * 7;
  if (n.energy_kcal <= 0 && macroKcal > 0) n.energy_kcal = macroKcal;
  if (n.sat_fat_g > n.fat_g) n.fat_g = n.sat_fat_g + n.mufa_g + n.pufa_g + n.trans_fat_g;
  if (n.added_sugars_g > n.sugars_g) n.sugars_g = n.added_sugars_g;
  if (n.sugars_g > n.carb_g && n.carb_g > 0) n.carb_g = n.sugars_g + n.fiber_g;
  if (g.fruit_whole_cup > g.fruit_total_cup) g.fruit_total_cup = g.fruit_whole_cup;
  if (g.veg_dark_green_cup > g.veg_total_cup) g.veg_total_cup = g.veg_dark_green_cup;
}

function cleanHazards(input: unknown, amountKey: "amount" | "amount_per_100g"): { key: string; amount: number; note: string }[] {
  if (!Array.isArray(input)) return [];
  const out: { key: string; amount: number; note: string }[] = [];
  for (const h of input) {
    if (!h || typeof h !== "object") continue;
    const key = String((h as Record<string, unknown>).key ?? "");
    if (!HAZARD_MAP[key] || !HAZARD_MAP[key].aiFlag) continue;
    const amount = Number((h as Record<string, unknown>)[amountKey]);
    out.push({ key, amount: Number.isFinite(amount) && amount > 0 ? amount : 0, note: String((h as Record<string, unknown>).note ?? "") });
  }
  return out;
}

const cleanSources = (s: unknown) =>
  Array.isArray(s)
    ? s.filter((x) => x && typeof x === "object" && typeof x.url === "string").slice(0, 10).map((x) => ({ title: String(x.title ?? x.url), url: String(x.url) }))
    : [];
const cleanStrings = (s: unknown) => (Array.isArray(s) ? s.filter((x) => typeof x === "string").slice(0, 12) : []);

export function accessibleFoods(userId: number): FoodRow[] {
  return all<FoodRow>(
    `SELECT id, owner_id, visibility, name, brand, aliases, category, serving_g, serving_desc, per100, groups100, hazards100, nova_group
     FROM foods WHERE owner_id = ? OR visibility = 'public'`,
    userId,
  );
}

export function foodForUser(userId: number, id: number): FoodRow | undefined {
  return get<FoodRow>(
    `SELECT id, owner_id, visibility, name, brand, aliases, category, serving_g, serving_desc, per100, groups100, hazards100, nova_group
     FROM foods WHERE id = ? AND (owner_id = ? OR visibility = 'public')`,
    id,
    userId,
  );
}

/** 根据食物库条目与克数生成记录项 */
export function itemFromFood(food: FoodRow, grams: number, extra: Partial<DraftItem> = {}): DraftItem {
  const per100 = sanitizeVector(parseJson(food.per100, {}), NUTRIENT_KEYS);
  const groups100 = sanitizeVector(parseJson(food.groups100, {}), FOOD_GROUP_KEYS);
  const hz100 = parseJson<{ key: string; amount_per_100g: number }[]>(food.hazards100, []);
  const f = grams / 100;
  return {
    name: food.brand && !food.name.includes(food.brand) ? `${food.name}（${food.brand}）` : food.name,
    amount_g: grams,
    amount_desc: food.serving_g && Math.abs(grams - food.serving_g) < 0.5 ? food.serving_desc || `1 份 ${food.serving_g} g` : `${Math.round(grams)} g`,
    food_id: food.id,
    category: food.category ?? "other",
    cooking_method: "",
    nova_group: food.nova_group,
    confidence: "high",
    nutrients: scaleVector(per100, f),
    groups: scaleVector(groups100, f),
    hazards: hz100.filter((h) => HAZARD_MAP[h.key]).map((h) => ({ key: h.key, amount: h.amount_per_100g * f })),
    notes: "来自食物库",
    per100: { nutrients: per100, groups: groups100, hazards: hz100 },
    save_suggested: false,
    ...extra,
  };
}

function libraryCandidates(userId: number, text: string): FoodRow[] {
  const t = text.toLowerCase();
  return accessibleFoods(userId)
    .filter((f) => {
      const names = [f.name, f.brand ?? "", ...f.aliases.split(/[,，、\s]+/)].map((s) => s.trim().toLowerCase()).filter((s) => s.length >= 2);
      return names.some((n) => t.includes(n));
    })
    .slice(0, 15);
}

const SAVE_CATEGORIES = new Set(["snack", "dessert", "beverage", "fast_food", "dairy", "supplement", "alcohol"]);

function draftFromRaw(userId: number, raw: Record<string, unknown>, allowFoodIds: Set<number>): DraftItem {
  const amount = Math.max(1, Number(raw.amount_g) || 100);
  const matched = Number(raw.matched_food_id);
  if (Number.isInteger(matched) && allowFoodIds.has(matched)) {
    const food = foodForUser(userId, matched);
    if (food) return itemFromFood(food, amount, { amount_desc: String(raw.amount_desc ?? `${amount} g`), notes: String(raw.notes ?? "来自食物库") });
  }
  const nutrients = sanitizeVector(raw.nutrients, NUTRIENT_KEYS);
  const groups = sanitizeVector(raw.food_groups, FOOD_GROUP_KEYS);
  fixConsistency(nutrients, groups);
  const hazards = cleanHazards(raw.hazards, "amount");
  const category = FOOD_CATEGORIES.includes(raw.category as (typeof FOOD_CATEGORIES)[number]) ? String(raw.category) : "other";
  const nova = [1, 2, 3, 4].includes(Number(raw.nova_group)) ? Number(raw.nova_group) : null;
  const f = 100 / amount;
  return {
    name: String(raw.name ?? "未命名食物").slice(0, 80),
    amount_g: amount,
    amount_desc: String(raw.amount_desc ?? `${amount} g`).slice(0, 80),
    food_id: null,
    category,
    cooking_method: String(raw.cooking_method ?? "").slice(0, 30),
    nova_group: nova,
    confidence: ["high", "medium", "low"].includes(String(raw.confidence)) ? String(raw.confidence) : "medium",
    nutrients,
    groups,
    hazards: hazards.map((h) => ({ key: h.key, amount: h.amount, note: h.note })),
    notes: String(raw.notes ?? "").slice(0, 300),
    per100: {
      nutrients: scaleVector(nutrients, f),
      groups: scaleVector(groups, f),
      hazards: hazards.map((h) => ({ key: h.key, amount_per_100g: h.amount * f })),
    },
    save_suggested: SAVE_CATEGORIES.has(category) || nova === 4,
  };
}

// ---------- 分析一餐 ----------

export async function analyzeMeal(
  userId: number,
  input: { text: string; date: string; time: string; meal_type: string; photos: unknown },
  profile: Profile | null,
): Promise<MealDraft> {
  const text = input.text.trim();
  const images = resolvePhotos(userId, input.photos);
  const candidates = libraryCandidates(userId, text);
  const allow = new Set(candidates.map((c) => c.id));

  if (activeProvider() === "mock") {
    const r = mockAnalyzeMeal(text);
    const items: DraftItem[] = [];
    // 离线模式下，优先使用食物库命中项
    for (const c of candidates) items.push(itemFromFood(c, c.serving_g ?? 100));
    // 去掉括号里的说明再比较（“螺蛳粉（袋装）”与“柳州螺蛳粉”视为同一种），别名也参与比较
    const core = (s: string) => s.replace(/[（(][^）)]*[）)]/g, "").trim().toLowerCase();
    const libNames = candidates.flatMap((c) => [c.name, ...c.aliases.split(/[,，、\s]+/)].map(core).filter((s) => s.length >= 2));
    for (const it of r.items) {
      const n = core(it.name);
      if (n.length >= 2 && libNames.some((ln) => n.includes(ln) || ln.includes(n))) continue;
      items.push(draftFromRaw(userId, it as unknown as Record<string, unknown>, allow));
    }
    return { items, summary: r.summary, assumptions: r.assumptions, questions: r.questions, sources: [], provider: "mock", model: "offline" };
  }

  const lib = candidates.length
    ? candidates
        .map((c) => {
          const n = parseJson<Record<string, number>>(c.per100, {});
          return `- id ${c.id}: ${c.name}${c.brand ? `（${c.brand}）` : ""}；一份 ${c.serving_g ?? "?"} g ${c.serving_desc ?? ""}；每 100 g：${Math.round(n.energy_kcal ?? 0)} kcal，蛋白质 ${n.protein_g ?? 0} g，钠 ${Math.round(n.sodium_mg ?? 0)} mg`;
        })
        .join("\n")
    : "（无匹配）";
  const who = profile ? `${profile.sex === "male" ? "男" : "女"}，${ageOn(profile.birth_date, input.date)} 岁，${profile.weight_kg} kg` : "未知";
  const prompt = `记录时间：${input.date} ${input.time}（${mealTypeZh(input.meal_type)}）
用户：${who}（仅用于判断份量习惯）

用户描述：
${text || "（无文字，请根据图片判断）"}

用户食物库中可能匹配的条目：
${lib}
${images.length ? `\n附带 ${images.length} 张图片（可能是食物照片、包装、配料表或营养成分表）。` : ""}`;

  const res = await runAi({ kind: "meal", system: MEAL_SYSTEM, prompt, images, schema: mealAnalysisSchema, webSearch: true });
  const data = res.data as Record<string, unknown>;
  const rawItems = Array.isArray(data.items) ? (data.items as Record<string, unknown>[]) : [];
  return {
    items: rawItems.map((r) => draftFromRaw(userId, r, allow)),
    summary: String(data.summary ?? ""),
    assumptions: cleanStrings(data.assumptions),
    questions: cleanStrings(data.questions),
    sources: cleanSources(data.sources),
    provider: res.provider,
    model: res.model,
  };
}

export function mealTypeZh(t: string) {
  return ({ breakfast: "早餐", lunch: "午餐", dinner: "晚餐", snack: "加餐/零食", drink: "饮品", other: "其他" } as Record<string, string>)[t] ?? t;
}

// ---------- 食物库：AI 查询 / 识别标签 ----------

export interface FoodDraft {
  name: string;
  brand: string;
  aliases: string[];
  category: string;
  serving_g: number;
  serving_desc: string;
  per100: NutrientVector;
  groups100: NutrientVector;
  hazards100: { key: string; amount_per_100g: number; note: string }[];
  nova_group: number | null;
  ingredients: string;
  label_fields: string[];
  confidence: string;
  sources: { title: string; url: string }[];
  notes: string;
  source: "label" | "ai_search" | "ai_estimate";
  provider: string;
}

export async function lookupFood(userId: number, input: { name: string; brand?: string; photos: unknown; note?: string }): Promise<FoodDraft> {
  const images = resolvePhotos(userId, input.photos);
  if (activeProvider() === "mock") {
    const r = mockAnalyzeMeal(input.name);
    const it = r.items[0];
    const f = 100 / it.amount_g;
    return {
      name: input.name || it.name, brand: input.brand ?? "", aliases: [], category: it.category, serving_g: it.amount_g, serving_desc: it.amount_desc,
      per100: scaleVector(sanitizeVector(it.nutrients, NUTRIENT_KEYS), f), groups100: scaleVector(sanitizeVector(it.food_groups, FOOD_GROUP_KEYS), f),
      hazards100: it.hazards.map((h) => ({ key: h.key, amount_per_100g: h.amount * f, note: "" })), nova_group: it.nova_group, ingredients: "", label_fields: [],
      confidence: "low", sources: [], notes: "离线估算（未配置 AI），请手动核对标签数值", source: "ai_estimate", provider: "mock",
    };
  }
  const prompt = `请为我的食物库建立营养档案。
名称：${input.name || "（见图片）"}
品牌：${input.brand || "（未提供）"}
${input.note ? `补充说明：${input.note}\n` : ""}${images.length ? `附带 ${images.length} 张图片（包装/配料表/营养成分表），请以图片中的标签数值为准。` : "没有图片，请联网查找该产品的官方营养成分表；找不到时基于配料与同类产品估算并注明。"}`;
  const res = await runAi({ kind: "food", system: FOOD_SYSTEM, prompt, images, schema: foodProfileSchema, webSearch: true });
  const d = res.data as Record<string, unknown>;
  const per100 = sanitizeVector(d.per100g, NUTRIENT_KEYS);
  const groups100 = sanitizeVector(d.groups100g, FOOD_GROUP_KEYS);
  fixConsistency(per100, groups100);
  const labelFields = cleanStrings(d.label_fields).filter((k) => NUTRIENT_KEYS.includes(k));
  const sources = cleanSources(d.sources);
  return {
    name: String(d.name ?? input.name).slice(0, 80),
    brand: String(d.brand ?? input.brand ?? "").slice(0, 60),
    aliases: cleanStrings(d.aliases).map((s) => s.slice(0, 40)),
    category: FOOD_CATEGORIES.includes(d.category as (typeof FOOD_CATEGORIES)[number]) ? String(d.category) : "other",
    serving_g: Math.max(1, Number(d.serving_g) || 100),
    serving_desc: String(d.serving_desc ?? "").slice(0, 60),
    per100,
    groups100,
    hazards100: cleanHazards(d.hazards, "amount_per_100g").map((h) => ({ key: h.key, amount_per_100g: h.amount, note: h.note })),
    nova_group: [1, 2, 3, 4].includes(Number(d.nova_group)) ? Number(d.nova_group) : null,
    ingredients: String(d.ingredients ?? "").slice(0, 2000),
    label_fields: labelFields,
    confidence: String(d.confidence ?? "medium"),
    sources,
    notes: String(d.notes ?? "").slice(0, 600),
    source: images.length || labelFields.length ? "label" : sources.length ? "ai_search" : "ai_estimate",
    provider: res.provider,
  };
}

// ---------- 运动解析 ----------

export interface ExerciseDraft {
  description: string;
  activity_key: string;
  met: number;
  duration_min: number;
  distance_km: number;
  kcal: number;
  notes: string;
}

export async function parseExercise(text: string, weightKg: number): Promise<{ items: ExerciseDraft[]; provider: string }> {
  let raw: { items: Record<string, unknown>[] };
  let provider = "mock";
  if (activeProvider() === "mock") {
    raw = mockParseExercise(text) as unknown as { items: Record<string, unknown>[] };
  } else {
    const res = await runAi({ kind: "exercise", system: EXERCISE_SYSTEM, prompt: `体重 ${weightKg} kg。运动记录：${text}`, images: [], schema: exerciseSchema, webSearch: false });
    raw = res.data as { items: Record<string, unknown>[] };
    provider = res.provider;
  }
  const items = (raw.items ?? []).map((r) => {
    const act = ACTIVITY_MAP[String(r.activity_key)] ?? ACTIVITY_MAP.other_moderate;
    const met = Math.min(20, Math.max(1, Number(r.met) || act.met));
    const duration = Math.min(1440, Math.max(1, Number(r.duration_min) || 30));
    return {
      description: String(r.description ?? text).slice(0, 80),
      activity_key: act.key,
      met,
      duration_min: Math.round(duration),
      distance_km: Math.max(0, Number(r.distance_km) || 0),
      kcal: Math.round(netKcal(met, weightKg, duration)),
      notes: String(r.notes ?? "").slice(0, 200),
    };
  });
  return { items, provider };
}

// ---------- 身体与活动识别（文字 + 截图） ----------

export interface WorkoutDraft extends ExerciseDraft {
  avg_hr: number | null;
  device_kcal: number | null;
  in_device: boolean;
}

export interface ActivityDraft {
  date: string;
  date_from_image: boolean;
  activity: { steps: number | null; distance_km: number | null; active_kcal: number | null; resting_kcal: number | null; exercise_min: number | null; stand_hours: number | null; sleep_hours: number | null };
  body: { weight_kg: number | null; body_fat_pct: number | null; sbp: number | null; dbp: number | null };
  workouts: WorkoutDraft[];
  notes: string;
  provider: string;
  model: string;
}

const numOrNull = (v: unknown, min: number, max: number): number | null => {
  const x = Number(v);
  return v === null || v === undefined || v === "" || !Number.isFinite(x) || x < min || x > max ? null : x;
};

export async function recognizeActivity(
  userId: number,
  input: { date: string; today: string; text: string; photos: unknown },
  weightKg: number,
): Promise<ActivityDraft> {
  const images = resolvePhotos(userId, input.photos);
  let raw: Record<string, unknown>;
  let provider = "mock";
  let model = "offline";
  if (activeProvider() === "mock") {
    raw = mockParseActivity(input.text) as unknown as Record<string, unknown>;
  } else {
    const prompt = `记录日期：${input.date}（今天是 ${input.today}）
用户体重约 ${weightKg} kg。
${input.text ? `用户描述：\n${input.text}` : "（没有文字，请从截图中读取）"}
${images.length ? `\n附带 ${images.length} 张截图（健康 App / 手表 / 体脂秤 / 血压计等）。` : ""}`;
    const res = await runAi({ kind: "activity", system: ACTIVITY_SYSTEM, prompt, images, schema: activitySchema, webSearch: false });
    raw = res.data as Record<string, unknown>;
    provider = res.provider;
    model = res.model;
  }
  const aiDate = typeof raw.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(raw.date) && raw.date <= input.today ? raw.date : null;
  const workouts = (Array.isArray(raw.workouts) ? (raw.workouts as Record<string, unknown>[]) : []).map((w) => {
    const act = ACTIVITY_MAP[String(w.activity_key)] ?? ACTIVITY_MAP.other_moderate;
    const met = Math.min(20, Math.max(1, Number(w.met) || act.met));
    const duration = Math.min(1440, Math.max(1, Number(w.duration_min) || 30));
    return {
      description: String(w.description ?? act.zh).slice(0, 80),
      activity_key: act.key,
      met,
      duration_min: Math.round(duration),
      distance_km: Math.max(0, Number(w.distance_km) || 0),
      kcal: Math.round(netKcal(met, weightKg, duration)),
      notes: String(w.notes ?? "").slice(0, 200),
      avg_hr: numOrNull(w.avg_hr, 30, 230),
      device_kcal: numOrNull(w.device_kcal, 1, 10000),
      in_device: Boolean(w.from_device),
    };
  });
  return {
    date: aiDate ?? input.date,
    date_from_image: !!aiDate && aiDate !== input.date,
    activity: {
      steps: numOrNull(raw.steps, 0, 200000),
      distance_km: numOrNull(raw.distance_km, 0, 500),
      active_kcal: numOrNull(raw.active_kcal, 0, 10000),
      resting_kcal: numOrNull(raw.resting_kcal, 300, 5000),
      exercise_min: numOrNull(raw.exercise_min, 0, 1440),
      stand_hours: numOrNull(raw.stand_hours, 0, 24),
      sleep_hours: numOrNull(raw.sleep_hours, 0, 24),
    },
    body: {
      weight_kg: numOrNull(raw.weight_kg, 20, 350),
      body_fat_pct: numOrNull(raw.body_fat_pct, 2, 70),
      sbp: numOrNull(raw.sbp, 60, 260),
      dbp: numOrNull(raw.dbp, 30, 160),
    },
    workouts,
    notes: String(raw.notes ?? "").slice(0, 600),
    provider,
    model,
  };
}

// ---------- 每周 AI 点评 ----------

export interface WeeklySummary {
  headline: string;
  summary: string;
  wins: string[];
  issues: string[];
  actions: string[];
}

export async function weeklySummary(p: PeriodScore, topFoods: { name: string; count: number }[]): Promise<WeeklySummary | null> {
  if (activeProvider() === "mock" || p.daysLogged === 0) return null;
  const round = (v: number | null, d = 0) => (v == null ? null : Math.round(v * 10 ** d) / 10 ** d);
  const payload = {
    period: `${p.start} ~ ${p.end}`,
    days_logged: `${p.daysLogged}/${p.days}`,
    aha_life_essential_8: {
      score: round(p.score),
      category: p.category?.zh ?? null,
      components: p.indices.le8.components.map((c) => ({ metric: c.zh, points: c.points, value: c.value })),
    },
    wcrf_aicr_cancer_prevention: {
      score: `${round(p.indices.wcrf.score, 2)}/${p.indices.wcrf.max}`,
      components: p.indices.wcrf.components.map((c) => ({ recommendation: c.zh, points: c.points, detail: c.detail })),
    },
    mepa_diet_screener: p.indices.mepa ? { score: `${p.indices.mepa.score}/16`, unmet: p.indices.mepa.items.filter((i) => !i.met).map((i) => `${i.zh}：${round(i.value, 1)} ${i.unit}，标准 ${i.criterion}`) } : null,
    avg_daily_hei_2020: round(p.avgHei),
    avg_daily_mar: round(p.avgMar),
    hei_2020_on_period_totals: p.hei ? round(p.hei.total) : null,
    hei_components: p.hei?.components.map((c) => ({ component: c.zh, score: `${round(c.score, 1)}/${c.max}` })),
    daily_item_stats: p.itemStats.map((s) => ({ item: s.zh, good: s.good + s.ok, warn: s.warn, bad: s.bad })),
    weekly_checks: p.checks.map((c) => ({ item: c.zh, status: c.status, message: c.message, target: c.targetText })),
    iarc_hazard_exposures: p.hazards.map((h) => ({ hazard: h.zh, iarc: h.iarc, total: `${round(h.dose)} ${h.unit}`, days: h.days })),
    avg_daily_intake: {
      kcal: round(p.avgTotals.energy_kcal), protein_g: round(p.avgTotals.protein_g), fiber_g: round(p.avgTotals.fiber_g),
      sodium_mg: round(p.avgTotals.sodium_mg), added_sugars_g: round(p.avgTotals.added_sugars_g), sat_fat_g: round(p.avgTotals.sat_fat_g),
      calcium_mg: round(p.avgTotals.calcium_mg), potassium_mg: round(p.avgTotals.potassium_mg), vit_d_ug: round(p.avgTotals.vit_d_ug, 1),
    },
    energy: {
      avg_intake: round(p.energy.avgIntake), avg_expenditure: round(p.energy.avgTdee),
      weight_trend_change_kg: round(p.energy.actualChangeKg, 2), predicted_change_from_balance_kg: round(p.energy.predictedChangeKg, 2),
    },
    most_eaten_foods: topFoods.slice(0, 15),
  };
  const res = await runAi({
    kind: "weekly",
    system: WEEKLY_SYSTEM,
    prompt: `以下是本周期的评估数据（JSON）：\n${JSON.stringify(payload, null, 1)}`,
    images: [],
    schema: weeklySummarySchema,
    webSearch: false,
  });
  const d = res.data as Record<string, unknown>;
  return {
    headline: String(d.headline ?? ""),
    summary: String(d.summary ?? ""),
    wins: cleanStrings(d.wins),
    issues: cleanStrings(d.issues),
    actions: cleanStrings(d.actions),
  };
}
