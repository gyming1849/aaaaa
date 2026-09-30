// 从数据库装载用户数据、计算并缓存评分。

import { db, parseJson } from "../db/index.ts";
import { sanitizeVector, NUTRIENT_KEYS, FOOD_GROUP_KEYS } from "../standards/nutrients.ts";
import { computeTargets, type Profile, type Targets } from "../standards/targets.ts";
import { scoreDay, SCORING_VERSION } from "../scoring/daily.ts";
import { scorePeriod, weightTrend, type WeightPoint, type PeriodScore } from "../scoring/period.ts";
import type { DayData, DailyScore, MealRecord, ItemRecord, ActivityRecord, ExerciseRecord, HazardEntry } from "../scoring/types.ts";
import { rangeDays, addDays } from "../lib/dates.ts";

interface ProfileRow {
  sex: string; birth_date: string; height_cm: number; weight_kg: number; activity_level: string; goal: string;
  goal_rate_kg_week: number; target_weight_kg: number | null; physiology: string; sodium_mode: string; conditions: string; timezone: string;
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
  };
}

export function loadDays(userId: number, start: string, end: string, profile: Profile): DayData[] {
  const meals = db
    .prepare("SELECT id, date, time, meal_type FROM meals WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date, time, id")
    .all(userId, start, end) as { id: number; date: string; time: string; meal_type: string }[];
  const items = db
    .prepare("SELECT id, meal_id, date, name, amount_g, nutrients, groups, hazards, nova_group FROM meal_items WHERE user_id = ? AND date BETWEEN ? AND ?")
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
  return scorePeriod({ start, end, days, exercises, activity, trend, profile: p, targets });
}
