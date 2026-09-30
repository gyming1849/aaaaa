import { test } from "node:test";
import assert from "node:assert/strict";
import { computeTargets, type Profile } from "../src/standards/targets.ts";
import { scoreDay, limitCurve, MAR_NUTRIENTS } from "../src/scoring/daily.ts";
import { computeLE8, paPoints, bpPoints, sleepPoints, bmiPoints, lipidPoints, glucosePoints, nicotinePoints, mepaPoints } from "../src/scoring/le8.ts";
import { computeWcrf } from "../src/scoring/wcrf.ts";
import { computeMepa } from "../src/scoring/mepa.ts";
import { computeIndices } from "../src/scoring/indices.ts";
import { weightTrend, scorePeriod } from "../src/scoring/period.ts";
import { computeHei } from "../src/standards/hei.ts";
import { eer, bmrMifflin } from "../src/standards/energy.ts";
import { lifeStageFor } from "../src/standards/dri.ts";
import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, emptyVector } from "../src/standards/nutrients.ts";
import type { DayData, ItemRecord } from "../src/scoring/types.ts";
import { rangeDays } from "../src/lib/dates.ts";

const profile: Profile = {
  sex: "male", birth_date: "1994-05-01", height_cm: 175, weight_kg: 75, activity_level: "low_active",
  goal: "maintain", goal_rate_kg_week: 0.5, target_weight_kg: null, physiology: "none", sodium_mode: "cdrr",
  conditions: [], timezone: "Asia/Shanghai",
};

function item(name: string, n: Record<string, number>, g: Record<string, number> = {}, extra: Partial<ItemRecord> = {}): ItemRecord {
  return {
    name, amount_g: 100,
    nutrients: { ...emptyVector(NUTRIENT_KEYS), ...n },
    groups: { ...emptyVector(FOOD_GROUP_KEYS), ...g },
    hazards: [], nova_group: 1, ...extra,
  };
}

function day(items: ItemRecord[][], date = "2026-09-01"): DayData {
  return {
    date,
    meals: items.map((its, i) => ({ id: i + 1, meal_type: "lunch", time: `${8 + i * 4}:00`.padStart(5, "0"), items: its })),
    weightKg: 75, weighedToday: null, activity: null, exercises: [],
  };
}

test("EER matches NASEM 2023 worked example (woman 22y, 165cm, 63kg, low active ≈ 2275)", () => {
  const r = eer("female", "low_active", 63, 165, 22);
  assert.ok(Math.abs(r.kcal - 2275) < 3, `got ${r.kcal}`);
});

test("Mifflin-St Jeor BMR", () => {
  assert.equal(Math.round(bmrMifflin("male", 75, 175, 32)), 1689); // 750 + 1093.75 − 160 + 5
});

test("life stage mapping", () => {
  assert.equal(lifeStageFor(32, "male"), "m31_50");
  assert.equal(lifeStageFor(28, "female", "pregnant"), "p19_30");
  assert.equal(lifeStageFor(72, "female"), "f71");
  assert.equal(lifeStageFor(6, "male"), "c4_8");
});

test("targets are personalised by weight/age/sex", () => {
  const t = computeTargets(profile, "2026-09-01");
  assert.equal(t.age, 32);
  assert.equal(t.intake.iron_mg.value, 8);
  assert.equal(t.intake.potassium_mg.value, 3400);
  assert.equal(Math.round(t.protein.rdaG), 60); // 0.8 × 75
  assert.equal(t.limits.sodium_mg.limit, 2300);
  assert.equal(t.limits.alcohol_g.limit, 28);
  const f = computeTargets({ ...profile, sex: "female", physiology: "pregnant", conditions: ["hypertension"] }, "2026-09-01");
  assert.equal(f.intake.iron_mg.value, 27);
  assert.equal(f.limits.alcohol_g.limit, 0);
  assert.equal(f.limits.caffeine_mg.limit, 200);
  assert.equal(f.limits.sodium_mg.limit, 1500);
  assert.equal(f.goal, "maintain");
});

test("limit curve", () => {
  assert.deepEqual(limitCurve(1000, 1500, 2300), { score: 1, status: "good" });
  assert.equal(limitCurve(2300, 1500, 2300).score, 0.7);
  assert.equal(limitCurve(4600, 1500, 2300).score, 0);
  assert.equal(limitCurve(3450, 1500, 2300).status, "bad");
});

test("HEI-2020 perfect-ish diet scores high, junk diet scores low", () => {
  const good = computeHei(
    { ...emptyVector(NUTRIENT_KEYS), energy_kcal: 2000, sodium_mg: 2000, added_sugars_g: 20, sat_fat_g: 15, pufa_g: 25, mufa_g: 30 },
    { ...emptyVector(FOOD_GROUP_KEYS), fruit_total_cup: 2, fruit_whole_cup: 1.5, veg_total_cup: 3, veg_dark_green_cup: 0.6, grains_whole_oz: 4, grains_refined_oz: 2, dairy_cup: 3, protein_total_oz: 6, seafood_oz: 2 },
  )!;
  assert.ok(good.total > 90, `good ${good.total}`);
  const bad = computeHei(
    { ...emptyVector(NUTRIENT_KEYS), energy_kcal: 2000, sodium_mg: 5000, added_sugars_g: 150, sat_fat_g: 40, pufa_g: 10, mufa_g: 20 },
    { ...emptyVector(FOOD_GROUP_KEYS), grains_refined_oz: 10, protein_total_oz: 3 },
  )!;
  assert.ok(bad.total < 20, `bad ${bad.total}`);
});

test("daily score is the HEI-2020 total and salt deductions follow the HEI formula", () => {
  const t = computeTargets(profile, "2026-09-01");
  const clean = scoreDay(day([[item("米饭", { energy_kcal: 700, carb_g: 150, protein_g: 15, sodium_mg: 700 }, { grains_refined_oz: 4 })]]), profile, t);
  const salty = scoreDay(day([[item("米饭", { energy_kcal: 700, carb_g: 150, protein_g: 15, sodium_mg: 3000 }, { grains_refined_oz: 4 })]]), profile, t);
  assert.equal(clean.score, clean.hei!.total);
  const na = salty.items.find((i) => i.key === "hei_sodium")!;
  assert.equal(na.points, 0); // 3000 mg / 700 kcal = 4.3 g/1000 kcal ≥ 2.0 → 0/10
  assert.ok(na.message.includes("扣 10"));
  assert.ok(salty.score! < clean.score!);
  const cdrr = salty.items.find((i) => i.key === "sodium_mg")!;
  assert.equal(cdrr.status, "bad");
  assert.equal(cdrr.maxPoints, 0); // 限量项只标状态，不另设权重
  assert.ok(salty.top.issues.length > 0);
});

test("MAR uses the 11 FAO micronutrients with equal weights and NAR capped at 1", () => {
  const t = computeTargets(profile, "2026-09-01");
  const full = Object.fromEntries(MAR_NUTRIENTS.map((k) => [k, t.intake[k].value * 3]));
  const s1 = scoreDay(day([[item("全面", { energy_kcal: 2000, ...full })]]), profile, t);
  assert.equal(Math.round(s1.mar!.value), 100);
  const half = Object.fromEntries(MAR_NUTRIENTS.map((k) => [k, t.intake[k].value * 0.5]));
  const s2 = scoreDay(day([[item("一半", { energy_kcal: 2000, ...half })]]), profile, t);
  assert.equal(Math.round(s2.mar!.value), 50);
  assert.equal(s2.mar!.nutrients.length, 11);
});

test("IARC hazards are warnings only and never change the score", () => {
  const t = computeTargets(profile, "2026-09-01");
  const base = { energy_kcal: 800, protein_g: 40, sodium_mg: 600 };
  const plain = scoreDay(day([[item("烤肉", base, { red_meat_g: 150, protein_total_oz: 5 })]]), profile, t);
  const charred = scoreDay(day([[item("烤肉", base, { red_meat_g: 150, protein_total_oz: 5 }, { hazards: [{ key: "high_temp_meat", amount: 150 }] })]]), profile, t);
  assert.equal(plain.score, charred.score);
  assert.ok(charred.hazards.some((h) => h.key === "high_temp_meat" && h.iarc === "2A"));
  assert.ok(charred.top.issues.some((x) => x.includes("IARC")));
});

test("aspartame is judged against body-weight ADI", () => {
  const t = computeTargets(profile, "2026-09-01");
  const ok = scoreDay(day([[item("零度可乐", { energy_kcal: 1 }, {}, { hazards: [{ key: "aspartame", amount: 200 }] })]]), profile, t);
  assert.ok(ok.hazards[0].message.includes("ADI 以内"));
  const over = scoreDay(day([[item("无糖饮料 x20", { energy_kcal: 1 }, {}, { hazards: [{ key: "aspartame", amount: 4000 }] })]]), profile, t);
  assert.ok(over.hazards[0].message.includes("已超过 ADI"));
});

test("LE8 point tables match the AHA supplement worked examples", () => {
  assert.equal(paPoints(90), 80);
  assert.equal(paPoints(150), 100);
  assert.equal(paPoints(0), 0);
  assert.equal(bpPoints(135, 76, true), 30);
  assert.equal(bpPoints(118, 78, false), 100);
  assert.equal(sleepPoints(7.5), 100);
  assert.equal(sleepPoints(6.5), 70);
  assert.equal(bmiPoints(27), 70);
  assert.equal(lipidPoints(150, true), 40);
  assert.equal(glucosePoints(105, null, false), 60);
  assert.equal(glucosePoints(null, 7.5, true), 30);
  assert.equal(nicotinePoints("never", true), 80);
  assert.equal(mepaPoints(13), 80);
  const r = computeLE8({
    mepa: { score: 13, days: 7, items: [] }, paMinutesPerWeek: 90, nicotine: "never", secondhandSmoke: false, sleepHours: null,
    bmi: 27, nonHdl: null, lipidTreated: false, fastingGlucose: null, hba1c: null, diabetes: false, sbp: 135, dbp: 76, bpTreated: true,
  });
  // (80 + 80 + 100 + 70 + 30) / 5 —— 缺失项不计入分母
  assert.equal(r.available, 5);
  assert.equal(r.score, 72);
  assert.equal(r.category?.key, "moderate");
});

test("WCRF/AICR standardized score follows Shams-White 2019 cut-points", () => {
  const r = computeWcrf({
    sex: "male", bmi: 23, waistCm: null, mvpaMinutesPerWeek: 100, fruitVegGPerDay: 450, fiberGPerDay: 20, upfPct: 40,
    redMeatGPerWeek: 400, processedMeatGPerWeek: 50, ssbMlPerDay: 330, alcoholGPerDay: 0,
  });
  const pts = Object.fromEntries(r.components.map((c) => [c.key, c.points]));
  assert.equal(pts.weight, 1); // 只有 BMI：0.5 × 2
  assert.equal(pts.activity, 0.5);
  assert.equal(pts.plants, 0.75);
  assert.equal(pts.upf, null); // 无绝对切点，不计分
  assert.equal(pts.meat, 0.5);
  assert.equal(pts.ssb, 0);
  assert.equal(pts.alcohol, 1);
  assert.equal(r.max, 6);
  assert.equal(r.score, 3.75);
});

test("MEPA derives weekly servings from logged food groups", () => {
  const groups = { ...emptyVector(FOOD_GROUP_KEYS), veg_dark_green_cup: 7 * 0.6, veg_total_cup: 7 * 2, fruit_total_cup: 7, red_meat_g: 170, seafood_oz: 6, nuts_g: 150, legumes_cup: 2 };
  const m = computeMepa({ groups, alcoholG: 0, fastFoodMeals: 0, days: 7, sex: "female" })!;
  const met = Object.fromEntries(m.items.map((i) => [i.key, i.met]));
  assert.equal(met.leafy, true); // 8.4 份/周 > 7
  assert.equal(met.meat, true); // 2 份/周 < 3
  assert.equal(met.fish, true);
  assert.equal(met.nuts, true); // 5 份/周 > 4
  assert.equal(met.beans, true); // 4 份/周 > 3
  assert.equal(met.alcohol, false);
  assert.equal(computeMepa({ groups, alcoholG: 0, fastFoodMeals: 0, days: 2, sex: "female" }), null);
});

test("energy uses device active energy when present", () => {
  const t = computeTargets(profile, "2026-09-01");
  const d = day([[item("饭", { energy_kcal: 2500 })]]);
  d.activity = { steps: 12000, active_kcal: 600, resting_kcal: 1700, distance_km: 9, exercise_min: 40, source: "apple" };
  d.exercises = [{ description: "游泳 5km", activity_key: "swim_freestyle_medium", met: 8, duration_min: 110, kcal: 963, in_device: false }];
  const s = scoreDay(d, profile, t);
  assert.equal(s.energy.activeSource, "device");
  assert.equal(Math.round(s.energy.tdee), Math.round((1700 + 600 + 963) / 0.9));
});

test("empty day has no score", () => {
  const t = computeTargets(profile, "2026-09-01");
  const s = scoreDay(day([]), profile, t);
  assert.equal(s.score, null);
  assert.equal(s.hasData, false);
});

test("weight trend smooths noise and period computes empirical TDEE", () => {
  const dates = rangeDays("2026-08-01", "2026-08-28");
  const weights = dates.map((d, i) => ({ date: d, weight_kg: 80 - i * 0.07 + (i % 2 ? 0.4 : -0.4) }));
  const trend = weightTrend(weights, dates);
  assert.ok(trend[27].trend! < 80 && trend[27].trend! > 78);
  const t = computeTargets(profile, "2026-08-28");
  const days = dates.map((date) => scoreDay({ ...day([[item("x", { energy_kcal: 1100 })], [item("y", { energy_kcal: 1100 })]], date) }, profile, t));
  const indices = computeIndices({ days, exercises: [], activity: [], profile, weightKg: 78, waistCm: null, bp: null, lab: null });
  const p = scorePeriod({ start: dates[0], end: dates[27], days, exercises: new Map(), activity: new Map(), trend, profile, targets: t, indices });
  assert.equal(p.daysLogged, 28);
  assert.ok(p.energy.actualChangeKg! < 0);
  assert.ok(p.energy.empiricalTdee! > 2200, `emp ${p.energy.empiricalTdee}`);
  assert.ok(p.checks.find((c) => c.key === "activity_week"));
  assert.equal(p.score, p.indices.le8.score); // 周期总分 = LE8
  assert.ok(p.indices.le8.components.find((c) => c.key === "bmi")!.points != null);
});
