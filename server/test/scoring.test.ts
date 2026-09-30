import { test } from "node:test";
import assert from "node:assert/strict";
import { computeTargets, type Profile } from "../src/standards/targets.ts";
import { scoreDay, limitCurve } from "../src/scoring/daily.ts";
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

test("processed meat and salt are penalised with explicit deductions", () => {
  const t = computeTargets(profile, "2026-09-01");
  const clean = scoreDay(day([[item("米饭", { energy_kcal: 700, carb_g: 150, protein_g: 15, sodium_mg: 800 }, { grains_refined_oz: 4 })]]), profile, t);
  const bacon = scoreDay(day([[
    item("米饭", { energy_kcal: 700, carb_g: 150, protein_g: 15, sodium_mg: 800 }, { grains_refined_oz: 4 }),
    item("培根", { energy_kcal: 500, fat_g: 40, sat_fat_g: 14, sodium_mg: 2800 }, { processed_meat_g: 100, protein_total_oz: 3 }),
  ]]), profile, t);
  const pm = bacon.hazards.find((h) => h.key === "processed_meat")!;
  assert.equal(Math.round(pm.penalty), 12); // 100 g → 2 × 6 分
  const sodium = bacon.items.find((i) => i.key === "sodium_mg")!;
  assert.equal(sodium.status, "bad");
  assert.ok(sodium.message.includes("超出上限"));
  assert.ok(bacon.score! < clean.score!);
  assert.ok(bacon.top.issues.length > 0);
});

test("flag hazards use reference amounts and caps", () => {
  const t = computeTargets(profile, "2026-09-01");
  const d = day([[item("烤串", { energy_kcal: 600, protein_g: 40 }, { red_meat_g: 200 }, { hazards: [{ key: "high_temp_meat", amount: 500 }] })]]);
  const s = scoreDay(d, profile, t);
  const h = s.hazards.find((x) => x.key === "high_temp_meat")!;
  assert.equal(h.penalty, 9); // 封顶
  const rm = s.hazards.find((x) => x.key === "red_meat")!;
  assert.ok(Math.abs(rm.penalty - 3.9) < 0.01); // (200−70)/100 × 3
});

test("aspartame is judged against body-weight ADI", () => {
  const t = computeTargets(profile, "2026-09-01");
  const ok = scoreDay(day([[item("零度可乐", { energy_kcal: 1 }, {}, { hazards: [{ key: "aspartame", amount: 200 }] })]]), profile, t);
  assert.equal(ok.hazards[0].penalty, 0);
  const over = scoreDay(day([[item("无糖饮料 x20", { energy_kcal: 1 }, {}, { hazards: [{ key: "aspartame", amount: 4000 }] })]]), profile, t);
  assert.equal(over.hazards[0].penalty, 5);
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
  const p = scorePeriod({ start: dates[0], end: dates[27], days, exercises: new Map(), activity: new Map(), trend, profile, targets: t });
  assert.equal(p.daysLogged, 28);
  assert.ok(p.energy.actualChangeKg! < 0);
  assert.ok(p.energy.empiricalTdee! > 2200, `emp ${p.energy.empiricalTdee}`);
  assert.ok(p.checks.find((c) => c.key === "activity_week"));
});
