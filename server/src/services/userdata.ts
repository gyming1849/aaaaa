// 从数据库装载用户数据、计算并缓存评分。

import { db, parseJson, all, get } from "../db/index.ts";
import { computeIndices, type HealthIndices, type IndicesInput } from "../scoring/indices.ts";
import { sanitizeVector, NUTRIENT_KEYS, FOOD_GROUP_KEYS } from "../standards/nutrients.ts";
import { computeTargets, type Profile, type Targets } from "../standards/targets.ts";
import { scoreDay, SCORING_VERSION } from "../scoring/daily.ts";
import { scorePeriod, weightTrend, type WeightPoint, type PeriodScore } from "../scoring/period.ts";
import type { DayData, DailyScore, MealRecord, ItemRecord, ActivityRecord, ExerciseRecord, HazardEntry } from "../scoring/types.ts";
import { rangeDays, addDays } from "../lib/dates.ts";

interface ProfileRow {
  sex: string; birth_date: string; height_cm: number; weight_kg: number; activity_level: string; goal: string;
  goal_rate_kg_week: number; target_weight_kg: number | null; physiology: string; sodium_mode: string; conditions: string; timezone: string;
  nicotine: string; secondhand_smoke: number;
}

export function getProfile(userId: number): Profile | null {
  const r = db.prepare("SELECT * FROM profiles WHERE user_id = ?").get(userId) as ProfileRow | undefined;
  if (!r) return null;
  return {
    sex: r.sex as Profile["sex"],
    birth_date: r.birth_date,
    height_cm: r.height_cm,
    weight_kg: r.weight_kg,
    activity_level: r.activity_level as Profile["activity_level"],
    goal: r.goal as Profile["goal"],
    goal_rate_kg_week: r.goal_rate_kg_week,
    target_weight_kg: r.target_weight_kg,
    physiology: r.physiology as Profile["physiology"],
    sodium_mode: r.sodium_mode as Profile["sodium_mode"],
    conditions: parseJson<string[]>(r.conditions, []),
    timezone: r.timezone,
    nicotine: (r.nicotine ?? "unknown") as Profile["nicotine"],
    secondhand_smoke: !!r.secondhand_smoke,
  };
}

export function getWeights(userId: number, end: string): WeightPoint[] {
  return db
    .prepare(
      `SELECT date, weight_kg FROM body_metrics WHERE user_id = ? AND date <= ? AND weight_kg IS NOT NULL ORDER BY date, time, id`,
    )
    .all(userId, end) as unknown as WeightPoint[];
}

/** 某日使用的体重：当天或之前最近一次称重，否则用建档体重 */
export function weightOn(weights: WeightPoint[], date: string, fallback: number): number {
  let w = fallback;
  for (const p of weights) {
    if (p.date > date) break;
    w = p.weight_kg;
  }
  return w;
}

interface ItemRow {
  id: number; meal_id: number; date: string; name: string; amount_g: number; nutrients: string; groups: string; hazards: string; nova_group: number | null;
  category?: string | null;
}

export function itemFromRow(r: ItemRow): ItemRecord {
  return {
    id: r.id,
    meal_id: r.meal_id,
    name: r.name,
    amount_g: r.amount_g,
    nutrients: sanitizeVector(parseJson(r.nutrients, {}), NUTRIENT_KEYS),
    groups: sanitizeVector(parseJson(r.groups, {}), FOOD_GROUP_KEYS),
    hazards: parseJson<HazardEntry[]>(r.hazards, []),
    nova_group: r.nova_group,
    category: r.category ?? null,
  };
}

export function loadDays(userId: number, start: string, end: string, profile: Profile): DayData[] {
  const meals = db
    .prepare("SELECT id, date, time, meal_type FROM meals WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date, time, id")
    .all(userId, start, end) as { id: number; date: string; time: string; meal_type: string }[];
  const items = db
    .prepare("SELECT id, meal_id, date, name, amount_g, nutrients, groups, hazards, nova_group, category FROM meal_items WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as unknown as ItemRow[];
  const acts = db
    .prepare("SELECT * FROM activity_days WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as unknown as (ActivityRecord & { date: string })[];
  const exs = db
    .prepare("SELECT * FROM exercises WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date, time")
    .all(userId, start, end) as unknown as (ExerciseRecord & { date: string; in_device: number | boolean })[];
  const weights = getWeights(userId, end);

  const itemsByMeal = new Map<number, ItemRecord[]>();
  for (const r of items) {
    const list = itemsByMeal.get(r.meal_id) ?? [];
    list.push(itemFromRow(r));
    itemsByMeal.set(r.meal_id, list);
  }
  const mealsByDate = new Map<string, MealRecord[]>();
  for (const m of meals) {
    const list = mealsByDate.get(m.date) ?? [];
    list.push({ id: m.id, meal_type: m.meal_type, time: m.time, items: itemsByMeal.get(m.id) ?? [] });
    mealsByDate.set(m.date, list);
  }
  const actByDate = new Map(acts.map((a) => [a.date, a]));
  const exByDate = new Map<string, ExerciseRecord[]>();
  for (const e of exs) {
    const list = exByDate.get(e.date) ?? [];
    list.push({ ...e, in_device: Boolean(e.in_device) });
    exByDate.set(e.date, list);
  }
  const todayWeights = new Map<string, number>();
  for (const w of weights) todayWeights.set(w.date, w.weight_kg);

  return rangeDays(start, end).map((date) => ({
    date,
    meals: mealsByDate.get(date) ?? [],
    weightKg: weightOn(weights, date, profile.weight_kg),
    weighedToday: todayWeights.get(date) ?? null,
    activity: actByDate.get(date) ?? null,
    exercises: exByDate.get(date) ?? [],
  }));
}

export function targetsFor(profile: Profile, date: string, weightKg?: number): Targets {
  return computeTargets(profile, date, weightKg ?? profile.weight_kg);
}

export function getDailyScores(userId: number, start: string, end: string, profile?: Profile | null): DailyScore[] {
  const p = profile ?? getProfile(userId);
  if (!p) return [];
  const cached = db
    .prepare("SELECT date, detail FROM daily_scores WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as { date: string; detail: string }[];
  const cache = new Map<string, DailyScore>();
  for (const c of cached) {
    const d = parseJson<DailyScore | null>(c.detail, null);
    if (d && d.version === SCORING_VERSION) cache.set(c.date, d);
  }
  const dates = rangeDays(start, end);
  const missing = dates.filter((d) => !cache.has(d));
  if (missing.length) {
    const days = loadDays(userId, missing[0], missing[missing.length - 1], p);
    const upsert = db.prepare(
      `INSERT INTO daily_scores (user_id, date, score, detail, computed_at) VALUES (?, ?, ?, ?, datetime('now'))
       ON CONFLICT(user_id, date) DO UPDATE SET score = excluded.score, detail = excluded.detail, computed_at = excluded.computed_at`,
    );
    const missingSet = new Set(missing);
    for (const day of days) {
      if (!missingSet.has(day.date)) continue;
      const t = computeTargets(p, day.date, day.weightKg);
      const s = scoreDay(day, p, t);
      cache.set(day.date, s);
      upsert.run(userId, day.date, s.score, JSON.stringify(s));
    }
  }
  return dates.map((d) => cache.get(d)!);
}

export function invalidateFrom(userId: number, date: string) {
  db.prepare("DELETE FROM daily_scores WHERE user_id = ? AND date >= ?").run(userId, date);
  db.prepare("DELETE FROM reports WHERE user_id = ? AND end_date >= ? AND ai_summary IS NULL").run(userId, date);
}

export function invalidateDay(userId: number, date: string) {
  db.prepare("DELETE FROM daily_scores WHERE user_id = ? AND date = ?").run(userId, date);
}

export function invalidateAll(userId: number) {
  db.prepare("DELETE FROM daily_scores WHERE user_id = ?").run(userId);
}

/** 计算窗口 [start, end] 的 LE8 / MEPA / WCRF（身体指标取截至 end 的最近记录） */
type BpRow = { sbp: number; dbp: number; bp_treated: number };

/** 血压：最近 3 次读数取平均 */
function avgBp(bps: BpRow[]): IndicesInput["bp"] {
  if (!bps.length) return null;
  return { sbp: bps.reduce((a, b) => a + b.sbp, 0) / bps.length, dbp: bps.reduce((a, b) => a + b.dbp, 0) / bps.length, treated: bps.some((b) => b.bp_treated), n: bps.length };
}

export function getIndices(userId: number, start: string, end: string, p: Profile, days?: DailyScore[]): HealthIndices {
  return computeIndices(loadIndicesInput(userId, start, end, p, days).input);
}

function loadIndicesInput(userId: number, start: string, end: string, p: Profile, days?: DailyScore[]): { input: IndicesInput; bps: BpRow[] } {
  const scores = days ?? getDailyScores(userId, start, end, p);
  const exercises = db
    .prepare("SELECT * FROM exercises WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as unknown as (ExerciseRecord & { date: string })[];
  const activity = db
    .prepare("SELECT * FROM activity_days WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as unknown as (ActivityRecord & { date: string })[];
  const weights = getWeights(userId, end);
  const waist = get<{ waist_cm: number }>(
    "SELECT waist_cm FROM body_metrics WHERE user_id = ? AND date <= ? AND date >= ? AND waist_cm IS NOT NULL ORDER BY date DESC, time DESC LIMIT 1",
    userId, end, addDays(end, -180),
  );
  // 血压：截至 end 的 90 天内最近 3 次读数取平均
  const bps = all<BpRow>(
    "SELECT sbp, dbp, bp_treated FROM body_metrics WHERE user_id = ? AND date <= ? AND date >= ? AND sbp IS NOT NULL AND dbp IS NOT NULL ORDER BY date DESC, time DESC LIMIT 3",
    userId, end, addDays(end, -90),
  );
  const lab = get<{ date: string; non_hdl: number | null; lipid_treated: number; fasting_glucose: number | null; hba1c: number | null; diabetes: number }>(
    "SELECT date, non_hdl, lipid_treated, fasting_glucose, hba1c, diabetes FROM lab_results WHERE user_id = ? AND date <= ? ORDER BY date DESC, id DESC LIMIT 1",
    userId, end,
  );
  const input: IndicesInput = {
    days: scores,
    exercises,
    activity,
    profile: p,
    weightKg: weightOn(weights, end, p.weight_kg),
    waistCm: waist?.waist_cm ?? null,
    bp: avgBp(bps),
    lab: lab ? { ...lab, lipid_treated: !!lab.lipid_treated, diabetes: !!lab.diabetes } : null,
  };
  return { input, bps };
}

export function getPeriod(userId: number, start: string, end: string): PeriodScore | null {
  const p = getProfile(userId);
  if (!p) return null;
  const days = getDailyScores(userId, start, end, p);
  const exs = db
    .prepare("SELECT * FROM exercises WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as unknown as (ExerciseRecord & { date: string })[];
  const acts = db
    .prepare("SELECT * FROM activity_days WHERE user_id = ? AND date BETWEEN ? AND ?")
    .all(userId, start, end) as unknown as (ActivityRecord & { date: string })[];
  const exercises = new Map<string, ExerciseRecord[]>();
  for (const e of exs) exercises.set(e.date, [...(exercises.get(e.date) ?? []), e]);
  const activity = new Map(acts.map((a) => [a.date, a]));
  // 预热 60 天的体重历史，使趋势线稳定
  const weights = getWeights(userId, end).filter((w) => w.date >= addDays(start, -60));
  const trend = weightTrend(weights, rangeDays(start, end));
  const targets = computeTargets(p, end, weightOn(weights, end, p.weight_kg));
  const indices = getIndices(userId, start, end, p, days);
  return scorePeriod({ start, end, days, exercises, activity, trend, profile: p, targets, indices });
}

// ---------------------------------------------------------------- 合并预览（不写库）

export interface DayPatch {
  /** 新增一餐；若带 replace_meal_id 则替换该餐（编辑） */
  meal?: { meal_type: string; time: string; items: ItemRecord[]; replace_meal_id?: number | null };
  /** 覆盖当天活动数据中给出的字段 */
  activity?: Partial<ActivityRecord>;
  /** 新增称重 */
  weight_kg?: number | null;
  /** 新增运动 */
  workouts?: ExerciseRecord[];
  /** 新增血压读数 */
  bp?: { sbp: number; dbp: number; treated: boolean } | null;
}

export interface DayPreview {
  before: DailyScore;
  after: DailyScore;
  /** 近 7 天（含当天）的 LE8 / WCRF：合并前后 */
  indices: { before: HealthIndices; after: HealthIndices };
}

export function previewDay(userId: number, date: string, patch: DayPatch): DayPreview | null {
  const p = getProfile(userId);
  if (!p) return null;
  const [day] = loadDays(userId, date, date, p);
  const before = scoreDay(day, p, computeTargets(p, date, day.weightKg));
  const next: DayData = structuredClone(day);
  if (patch.meal) {
    if (patch.meal.replace_meal_id) next.meals = next.meals.filter((m) => m.id !== patch.meal!.replace_meal_id);
    next.meals.push({ id: -1, meal_type: patch.meal.meal_type, time: patch.meal.time, items: patch.meal.items });
  }
  if (patch.activity) {
    const base: ActivityRecord = next.activity ?? { steps: null, active_kcal: null, resting_kcal: null, distance_km: null, exercise_min: null, source: "preview" };
    for (const [k, v] of Object.entries(patch.activity)) if (v !== null && v !== undefined) (base as unknown as Record<string, unknown>)[k] = v;
    next.activity = base;
  }
  if (patch.weight_kg) {
    next.weightKg = patch.weight_kg;
    next.weighedToday = patch.weight_kg;
  }
  if (patch.workouts?.length) next.exercises.push(...patch.workouts);
  const after = scoreDay(next, p, computeTargets(p, date, next.weightKg));

  // 近 7 天滚动的 LE8 / WCRF：把同样的修改套到窗口数据上重算
  const { input, bps } = loadIndicesInput(userId, addDays(date, -6), date, p);
  const patched: IndicesInput = {
    ...input,
    days: input.days.map((d) => (d.date === date ? after : d)),
    exercises: [...input.exercises, ...(patch.workouts ?? []).map((w) => ({ ...w, date }))],
    activity: patch.activity
      ? [...input.activity.filter((a) => a.date !== date), { ...(next.activity as ActivityRecord), date }]
      : input.activity,
    weightKg: patch.weight_kg ?? input.weightKg,
    bp: patch.bp ? avgBp([{ sbp: patch.bp.sbp, dbp: patch.bp.dbp, bp_treated: patch.bp.treated ? 1 : 0 }, ...bps].slice(0, 3)) : input.bp,
  };
  return { before, after, indices: { before: computeIndices(input), after: computeIndices(patched) } };
}
