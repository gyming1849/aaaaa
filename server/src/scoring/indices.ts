// 按时间窗口（近 7 天或报告周期）计算 AHA Life's Essential 8、MEPA 与 WCRF/AICR 评分

import { FOOD_GROUP_KEYS, emptyVector, addVectors } from "../standards/nutrients.ts";
import { bmiOf } from "../standards/energy.ts";
import type { Profile } from "../standards/targets.ts";
import type { DailyScore, ExerciseRecord, ActivityRecord } from "./types.ts";
import { computeMepa, type MepaResult } from "./mepa.ts";
import { computeLE8, type Le8Result } from "./le8.ts";
import { computeWcrf, type WcrfResult } from "./wcrf.ts";

export interface LabInfo {
  non_hdl: number | null;
  lipid_treated: boolean;
  fasting_glucose: number | null;
  hba1c: number | null;
  diabetes: boolean;
  date: string;
}

export interface IndicesInput {
  days: DailyScore[];
  exercises: (ExerciseRecord & { date: string })[];
  activity: (ActivityRecord & { date: string })[];
  profile: Profile;
  weightKg: number;
  waistCm: number | null;
  bp: { sbp: number; dbp: number; treated: boolean; n: number } | null;
  lab: LabInfo | null;
}

export interface HealthIndices {
  windowDays: number;
  loggedDays: number;
  mepa: MepaResult | null;
  le8: Le8Result;
  wcrf: WcrfResult;
  pa: { le8MinPerWeek: number | null; mvpaMinPerWeek: number | null; strengthDays: number };
  sleepHours: number | null;
}

export function computeIndices(x: IndicesInput): HealthIndices {
  const n = x.days.length;
  const logged = x.days.filter((d) => d.hasData);
  const ld = logged.length;

  let groups = emptyVector(FOOD_GROUP_KEYS);
  let alcohol = 0;
  let fiber = 0;
  let upfSum = 0;
  let fastFood = 0;
  for (const d of logged) {
    groups = addVectors(groups, d.groups);
    alcohol += d.totals.alcohol_g ?? 0;
    fiber += d.totals.fiber_g ?? 0;
    upfSum += d.upfPct;
    fastFood += d.fastFoodMeals ?? 0;
  }

  // 身体活动：LE8 高强度按 2 倍计；WCRF 原文未规定加倍，按实际分钟
  const byDate = new Map<string, { le8: number; plain: number; strength: boolean }>();
  for (const e of x.exercises) {
    const r = byDate.get(e.date) ?? { le8: 0, plain: 0, strength: false };
    if (e.met >= 6) {
      r.le8 += 2 * e.duration_min;
      r.plain += e.duration_min;
    } else if (e.met >= 3) {
      r.le8 += e.duration_min;
      r.plain += e.duration_min;
    }
    if (e.activity_key && /strength|circuit|hiit/.test(e.activity_key)) r.strength = true;
    byDate.set(e.date, r);
  }
  let le8Min = 0;
  let plainMin = 0;
  let hasPa = x.exercises.length > 0;
  for (const a of x.activity) {
    if (a.exercise_min != null) hasPa = true;
  }
  const dates = new Set([...byDate.keys(), ...x.activity.map((a) => a.date)]);
  let strengthDays = 0;
  for (const dt of dates) {
    const r = byDate.get(dt) ?? { le8: 0, plain: 0, strength: false };
    const dev = x.activity.find((a) => a.date === dt)?.exercise_min ?? 0;
    le8Min += Math.max(r.le8, dev);
    plainMin += Math.max(r.plain, dev);
    if (r.strength) strengthDays++;
  }
  const perWeek = (v: number) => (n ? (v / n) * 7 : 0);
  const le8MinPerWeek = hasPa ? perWeek(le8Min) : null;
  const mvpaMinPerWeek = hasPa ? perWeek(plainMin) : null;

  const sleeps = x.activity.map((a) => a.sleep_hours).filter((v): v is number => v != null && v > 0);
  const sleepHours = sleeps.length ? sleeps.reduce((a, b) => a + b, 0) / sleeps.length : null;
  const bmi = bmiOf(x.weightKg, x.profile.height_cm);

  const mepa = computeMepa({ groups, alcoholG: alcohol, fastFoodMeals: fastFood, days: ld, sex: x.profile.sex });
  const le8 = computeLE8({
    mepa,
    paMinutesPerWeek: le8MinPerWeek,
    nicotine: x.profile.nicotine && x.profile.nicotine !== "unknown" ? x.profile.nicotine : undefined,
    secondhandSmoke: x.profile.secondhand_smoke,
    sleepHours,
    bmi,
    nonHdl: x.lab?.non_hdl ?? null,
    lipidTreated: !!x.lab?.lipid_treated,
    fastingGlucose: x.lab?.fasting_glucose ?? null,
    hba1c: x.lab?.hba1c ?? null,
    diabetes: !!x.lab?.diabetes || x.profile.conditions.includes("diabetes"),
    sbp: x.bp?.sbp ?? null,
    dbp: x.bp?.dbp ?? null,
    bpTreated: !!x.bp?.treated,
  });
  const enough = ld >= 3;
  const wcrf = computeWcrf({
    sex: x.profile.sex,
    bmi,
    waistCm: x.waistCm,
    mvpaMinutesPerWeek: mvpaMinPerWeek,
    fruitVegGPerDay: enough ? groups.fruit_veg_g / ld : null,
    fiberGPerDay: enough ? fiber / ld : null,
    upfPct: enough ? upfSum / ld : null,
    redMeatGPerWeek: enough ? (groups.red_meat_g / ld) * 7 : null,
    processedMeatGPerWeek: enough ? (groups.processed_meat_g / ld) * 7 : null,
    ssbMlPerDay: enough ? groups.ssb_ml / ld : null,
    alcoholGPerDay: enough ? alcohol / ld : null,
  });
  return { windowDays: n, loggedDays: ld, mepa, le8, wcrf, pa: { le8MinPerWeek, mvpaMinPerWeek, strengthDays }, sleepHours };
}
