// 根据个人档案（性别、年龄、身高、体重、生理阶段、目标、健康状况）计算个性化目标值。

import {
  INTAKE, UPPER, SODIUM_CDRR, PROTEIN_G_PER_KG, LIFE_STAGES,
  amdrFor, lifeStageFor, valueAt, type LifeStageId, type Sex, type Physiology, type Amdr,
} from "./dri.ts";
import { bmrMifflin, eer, bmiOf, bmiCategory, KCAL_PER_KG, type ActivityLevel } from "./energy.ts";
import { ASPARTAME_ADI_MG_PER_KG } from "./hazards.ts";
import { ageOn } from "../lib/dates.ts";

export type Goal = "lose" | "maintain" | "gain";

export interface Profile {
  sex: Sex;
  birth_date: string;
  height_cm: number;
  weight_kg: number;
  activity_level: ActivityLevel;
  goal: Goal;
  goal_rate_kg_week: number;
  target_weight_kg: number | null;
  physiology: Physiology;
  sodium_mode: "cdrr" | "aha";
  conditions: string[];
  timezone: string;
  /** 吸烟 / 尼古丁暴露（AHA Life's Essential 8） */
  nicotine?: "unknown" | "never" | "former_5y" | "former_1_5y" | "former_lt1y" | "ecig" | "current";
  secondhand_smoke?: boolean;
}

export const CONDITIONS = [
  { key: "hypertension", zh: "高血压", effect: "钠上限收紧到 1500 mg（AHA）" },
  { key: "high_ldl", zh: "高胆固醇 / 高 LDL", effect: "饱和脂肪理想值收紧到 6% 能量（AHA）" },
  { key: "diabetes", zh: "糖尿病 / 糖尿病前期", effect: "添加糖上限收紧到 AHA 建议值" },
  { key: "kidney", zh: "慢性肾病", effect: "仅提示：蛋白质、钾、磷目标请遵医嘱，本系统不据此加分" },
  { key: "gout", zh: "痛风 / 高尿酸", effect: "仅提示：注意红肉、海鲜、酒精与含糖饮料" },
];

export interface IntakeTarget {
  key: string;
  value: number;
  kind: "RDA" | "AI";
  source: string;
  note?: string;
}

export interface LimitTarget {
  key: string;
  zh: string;
  unit: string;
  ideal: number;
  limit: number;
  idealSource: string;
  limitSource: string;
  note?: string;
}

export interface Targets {
  date: string;
  age: number;
  sex: Sex;
  lifeStage: LifeStageId;
  lifeStageZh: string;
  physiology: Physiology;
  sensitive: boolean;
  weightKg: number;
  heightCm: number;
  bmi: number;
  bmiCategory: { key: string; zh: string };
  referenceWeightKg: number;
  bmr: number;
  eer: number;
  eerMethod: string;
  goal: Goal;
  goalDeltaKcal: number;
  energyTarget: number;
  energyFloor: number;
  protein: { rdaG: number; idealLowG: number; idealHighG: number; perKgRda: number };
  intake: Record<string, IntakeTarget>;
  upper: Record<string, { value: number; appliesToTotal: boolean; note?: string }>;
  limits: Record<string, LimitTarget>;
  amdr: Amdr;
  addedSugarPerMealG: number;
  aspartameAdiMg: number;
}

export function computeTargets(p: Profile, date: string, weightKg: number = p.weight_kg): Targets {
  const age = Math.max(1, ageOn(p.birth_date, date));
  const physiology: Physiology = p.sex === "female" ? p.physiology : "none";
  const stage = lifeStageFor(age, p.sex, physiology);
  const stageZh = LIFE_STAGES.find((s) => s.id === stage)!.zh;
  const sensitive = physiology !== "none" || age < 18;
  const bmi = bmiOf(weightKg, p.height_cm);

  // 肥胖者按“校正体重”计算按体重的目标，避免高估
  const h = p.height_cm / 100;
  const idealW = 22.5 * h * h;
  const referenceWeightKg = bmi >= 30 ? idealW + 0.4 * (weightKg - idealW) : weightKg;

  const bmr = bmrMifflin(p.sex, weightKg, p.height_cm, age);
  const e = eer(p.sex, p.activity_level, weightKg, p.height_cm, age, physiology);

  // 目标：若已达到目标体重则按维持处理
  let goal = p.goal;
  if (p.target_weight_kg) {
    if (goal === "lose" && weightKg <= p.target_weight_kg) goal = "maintain";
    if (goal === "gain" && weightKg >= p.target_weight_kg) goal = "maintain";
  }
  if (physiology !== "none" && goal === "lose") goal = "maintain"; // 孕期/哺乳期不建议主动减重
  const rate = Math.min(Math.max(p.goal_rate_kg_week || 0.5, 0.1), 1);
  let goalDeltaKcal = 0;
  if (goal === "lose") goalDeltaKcal = -(rate * KCAL_PER_KG) / 7;
  if (goal === "gain") goalDeltaKcal = Math.min((rate * KCAL_PER_KG) / 7, 500);
  const energyFloor = Math.max(p.sex === "male" ? 1500 : 1200, Math.round(bmr));
  const energyTarget = Math.max(energyFloor, Math.round(e.kcal + goalDeltaKcal));

  // 推荐摄入量
  const intake: Record<string, IntakeTarget> = {};
  for (const [key, row] of Object.entries(INTAKE)) {
    const v = valueAt(row.values, stage);
    if (v == null) continue;
    intake[key] = { key, value: v, kind: row.kind, source: key === "sodium_mg" || key === "potassium_mg" ? "nasem_na_k" : "nasem_dri" };
  }
  // 蛋白质：RDA 按体重，DGA 2025–2030 建议 1.2–1.6 g/kg
  const perKgRda = valueAt(PROTEIN_G_PER_KG, stage) ?? 0.8;
  const rdaG = Math.max(valueAt(INTAKE.protein_g.values, stage) ?? 0, perKgRda * referenceWeightKg);
  intake.protein_g = {
    key: "protein_g",
    value: rdaG,
    kind: "RDA",
    source: "nasem_dri",
    note: `RDA ${perKgRda} g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg`,
  };
  // 膳食纤维：AI = 14 g / 1000 kcal（按个人能量目标）
  intake.fiber_g = {
    key: "fiber_g",
    value: Math.round((14 * energyTarget) / 1000),
    kind: "AI",
    source: "nasem_dri",
    note: "14 g / 1000 kcal × 你的能量目标",
  };

  const upper: Targets["upper"] = {};
  for (const [key, row] of Object.entries(UPPER)) {
    const v = valueAt(row.values, stage);
    if (v != null) upper[key] = { value: v, appliesToTotal: row.appliesToTotal, note: row.note };
  }

  const cond = new Set(p.conditions ?? []);
  const adult = age >= 19;
  const limits: Record<string, LimitTarget> = {};

  const cdrr = valueAt(SODIUM_CDRR, stage) ?? 2300;
  const sodiumStrict = adult && (p.sodium_mode === "aha" || cond.has("hypertension"));
  limits.sodium_mg = {
    key: "sodium_mg", zh: "钠", unit: "mg",
    ideal: adult ? 1500 : intake.sodium_mg?.value ?? 1500,
    limit: sodiumStrict ? 1500 : cdrr,
    idealSource: adult ? "aha_sodium" : "nasem_na_k",
    limitSource: sodiumStrict ? "aha_sodium" : "nasem_na_k",
    note: sodiumStrict ? "已按高血压/AHA 模式收紧" : "上限为 CDRR，与 DGA 一致",
  };

  const ahaSugar = p.sex === "male" && age >= 19 ? 36 : 25;
  const dgaSugar = Math.round((energyTarget * 0.1) / 4);
  const sugarLimit = age < 4 ? 5 : cond.has("diabetes") ? ahaSugar : Math.max(dgaSugar, ahaSugar);
  limits.added_sugars_g = {
    key: "added_sugars_g", zh: "添加糖", unit: "g",
    ideal: age < 4 ? 0 : ahaSugar,
    limit: sugarLimit,
    idealSource: "aha_sugar",
    limitSource: cond.has("diabetes") ? "aha_sugar" : "dga_2020",
    note: "DGA 2025–2030：不推荐任何添加糖，每餐不超过 10 g",
  };

  limits.sat_fat_pct = {
    key: "sat_fat_pct", zh: "饱和脂肪供能比", unit: "% 能量",
    ideal: cond.has("high_ldl") ? 6 : 8,
    limit: 10,
    idealSource: cond.has("high_ldl") ? "aha_satfat" : "hei_2020",
    limitSource: "dga_2025",
  };

  limits.trans_fat_g = {
    key: "trans_fat_g", zh: "反式脂肪", unit: "g",
    ideal: 0,
    limit: Math.round(((energyTarget * 0.01) / 9) * 10) / 10,
    idealSource: "dga_2020",
    limitSource: "who_trans",
    note: "WHO：< 1% 总能量",
  };

  const noAlcohol = physiology !== "none" || age < 21;
  limits.alcohol_g = {
    key: "alcohol_g", zh: "酒精", unit: "g",
    ideal: 0,
    limit: noAlcohol ? 0 : p.sex === "male" ? 28 : 14,
    idealSource: "iarc_list",
    limitSource: "dga_2020",
    note: noAlcohol ? "孕期/哺乳期/未满 21 岁应完全避免" : "DGA 2020–2025：男 ≤2 杯、女 ≤1 杯；DGA 2025–2030：越少越好",
  };

  const caffeineLimit = physiology !== "none" ? 200 : age < 18 ? Math.round(2.5 * weightKg) : 400;
  limits.caffeine_mg = {
    key: "caffeine_mg", zh: "咖啡因", unit: "mg",
    ideal: caffeineLimit,
    limit: caffeineLimit,
    idealSource: physiology !== "none" ? "acog_caffeine" : age < 18 ? "hc_caffeine" : "fda_caffeine",
    limitSource: physiology !== "none" ? "acog_caffeine" : age < 18 ? "hc_caffeine" : "fda_caffeine",
    note: age < 18 ? "未成年人按 2.5 mg/kg 体重" : undefined,
  };

  limits.upf_pct = {
    key: "upf_pct", zh: "超加工食品供能比", unit: "% 能量",
    ideal: 20,
    limit: 50,
    idealSource: "dga_2025",
    limitSource: "system",
    note: "DGA 2025–2030 要求限制高度加工食品但未给数值；按 NOVA 4 类估算，阈值为本系统设定",
  };

  return {
    date,
    age,
    sex: p.sex,
    lifeStage: stage,
    lifeStageZh: stageZh,
    physiology,
    sensitive,
    weightKg,
    heightCm: p.height_cm,
    bmi,
    bmiCategory: bmiCategory(bmi),
    referenceWeightKg,
    bmr,
    eer: e.kcal,
    eerMethod: e.method,
    goal,
    goalDeltaKcal,
    energyTarget,
    energyFloor,
    protein: {
      rdaG,
      idealLowG: 1.2 * referenceWeightKg,
      idealHighG: 1.6 * referenceWeightKg,
      perKgRda,
    },
    intake,
    upper,
    limits,
    amdr: amdrFor(age),
    addedSugarPerMealG: 10,
    aspartameAdiMg: ASPARTAME_ADI_MG_PER_KG * weightKg,
  };
}
