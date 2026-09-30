// 每日离线评分引擎（评分规则 v1）。
//
// 综合分（0–100）=
//   膳食质量 HEI-2020 × 35%
// + 营养素充足度（对照 RDA/AI）× 25%
// + 限量控制（钠、添加糖、饱和脂肪、反式脂肪、酒精、咖啡因、超加工、UL、AMDR）× 25%
// + 能量平衡（摄入 vs 当日消耗 + 目标调整）× 15%
// − 致癌/风险物扣分（封顶 30 分）
//
// 规则详细说明见 docs/scoring.md，前端“标准库”页面也会完整展示。

import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, NUTRIENT_MAP, emptyVector, addVectors, type NutrientVector } from "../standards/nutrients.ts";
import { computeHei, HEI_COMPONENTS } from "../standards/hei.ts";
import { HAZARDS, HAZARD_TOTAL_CAP } from "../standards/hazards.ts";
import { eer, stepsNetKcal } from "../standards/energy.ts";
import type { Profile, Targets } from "../standards/targets.ts";
import type {
  DayData, DailyScore, ScoreItem, HazardResult, EnergyResult, CategoryResult, Status,
} from "./types.ts";

export const SCORING_VERSION = 1;

export const CATEGORY_WEIGHTS = {
  hei: { zh: "膳食质量 (HEI-2020)", weight: 35 },
  adequacy: { zh: "营养素充足", weight: 25 },
  moderation: { zh: "限量控制", weight: 25 },
  energy: { zh: "能量平衡", weight: 15 },
} as const;

/** 充足度评估的营养素及权重（DGA 列出的“公共健康关注营养素”权重更高） */
export const ADEQUACY_WEIGHTS: Record<string, number> = {
  protein_g: 2, fiber_g: 2, potassium_mg: 2, calcium_mg: 2, vit_d_ug: 2,
  iron_mg: 1, magnesium_mg: 1, zinc_mg: 1, vit_a_ug: 1, vit_c_mg: 1, vit_e_mg: 1, vit_k_ug: 1,
  folate_ug: 1, vit_b12_ug: 1, water_g: 1,
  thiamin_mg: 0.5, riboflavin_mg: 0.5, niacin_mg: 0.5, vit_b6_mg: 0.5, choline_mg: 0.5,
  selenium_ug: 0.5, iodine_ug: 0.5, phosphorus_mg: 0.5, copper_mg: 0.5, manganese_mg: 0.5,
  linoleic_g: 0.5, ala_g: 0.5, pantothenic_mg: 0.25, biotin_ug: 0.25,
};

export function gradeOf(score: number): { key: string; zh: string } {
  if (score >= 85) return { key: "A", zh: "优秀" };
  if (score >= 70) return { key: "B", zh: "良好" };
  if (score >= 55) return { key: "C", zh: "一般" };
  if (score >= 40) return { key: "D", zh: "较差" };
  return { key: "E", zh: "很差" };
}

/** 限量型项目的得分曲线：≤理想 满分；理想→上限 线性降到 0.7；超过上限后到 2×上限 降到 0 */
export function limitCurve(value: number, ideal: number, limit: number): { score: number; status: Status } {
  if (limit <= 0) return value <= 0 ? { score: 1, status: "good" } : { score: 0, status: "bad" };
  if (value <= ideal) return { score: 1, status: "good" };
  if (value <= limit) {
    const span = limit - ideal;
    return { score: span > 0 ? 1 - (0.3 * (value - ideal)) / span : 1, status: "ok" };
  }
  return { score: Math.max(0, 0.7 * (1 - (value - limit) / limit)), status: "bad" };
}

function adequacyStatus(ratio: number): Status {
  if (ratio >= 1) return "good";
  if (ratio >= 0.7) return "warn";
  return "bad";
}

const fmtNum = (v: number, d = 0) => {
  const f = Math.pow(10, d);
  return (Math.round(v * f) / f).toLocaleString("en-US", { maximumFractionDigits: d });
};

export interface DayTotals {
  totals: NutrientVector;
  groups: NutrientVector;
  upfKcal: number;
  mealSugars: { meal_type: string; time: string; added_sugars_g: number }[];
  itemCount: number;
  mealCount: number;
}

export function sumDay(day: DayData): DayTotals {
  let totals = emptyVector(NUTRIENT_KEYS);
  let groups = emptyVector(FOOD_GROUP_KEYS);
  let upfKcal = 0;
  let itemCount = 0;
  const mealSugars: DayTotals["mealSugars"] = [];
  let mealCount = 0;
  for (const meal of day.meals) {
    let sugar = 0;
    let kcal = 0;
    for (const it of meal.items) {
      totals = addVectors(totals, it.nutrients);
      groups = addVectors(groups, it.groups);
      if (it.nova_group === 4) upfKcal += it.nutrients.energy_kcal ?? 0;
      sugar += it.nutrients.added_sugars_g ?? 0;
      kcal += it.nutrients.energy_kcal ?? 0;
      itemCount++;
    }
    // 只喝水/黑咖啡等几乎无能量的记录不算作“一餐”
    if (kcal >= 5) {
      mealCount++;
      mealSugars.push({ meal_type: meal.meal_type, time: meal.time, added_sugars_g: sugar });
    }
  }
  return { totals, groups, upfKcal, mealSugars, itemCount, mealCount };
}

export function computeEnergy(day: DayData, profile: Profile, t: Targets, intakeKcal: number): EnergyResult {
  const a = day.activity;
  const hasDeviceActive = a?.active_kcal != null && a.active_kcal > 0;
  const hasSteps = a?.steps != null && a.steps > 0;
  const deviceResting = a?.resting_kcal != null && a.resting_kcal > 500 ? a.resting_kcal : null;
  const resting = deviceResting ?? t.bmr;
  const extraExercise = day.exercises.filter((e) => !e.in_device).reduce((s, e) => s + e.kcal, 0);
  const allExercise = day.exercises.reduce((s, e) => s + e.kcal, 0);

  let active = 0;
  let activeSource: EnergyResult["activeSource"] = "none";
  let tdee: number;
  let method: EnergyResult["method"] = "measured";
  let tef: number;

  if (hasDeviceActive) {
    active = a!.active_kcal! + extraExercise;
    activeSource = "device";
    tdee = (resting + active) / 0.9;
    tef = tdee * 0.1;
  } else if (hasSteps) {
    active = stepsNetKcal(a!.steps!, t.heightCm, day.weightKg) + extraExercise;
    activeSource = "steps";
    tdee = (resting + active) / 0.9;
    tef = tdee * 0.1;
  } else if (allExercise > 0) {
    // 只有手动记录的运动：以“久坐”EER 为基线（已含日常活动与食物热效应）再加运动净消耗
    const base = eer(profile.sex, "inactive", day.weightKg, t.heightCm, t.age, t.physiology).kcal;
    active = allExercise;
    activeSource = "exercise";
    tdee = base + allExercise;
    tef = base * 0.1;
  } else {
    tdee = t.eer;
    method = "eer";
    tef = tdee * 0.1;
  }
  const target = Math.max(t.energyFloor, tdee + t.goalDeltaKcal);
  return {
    intake: intakeKcal,
    resting,
    restingSource: deviceResting ? "device" : "bmr",
    active,
    activeSource,
    exerciseKcal: allExercise,
    tef,
    tdee,
    method,
    target,
    balance: intakeKcal - tdee,
  };
}

export function scoreHazards(day: DayData, sums: DayTotals, t: Targets): { list: HazardResult[]; penalty: number } {
  const list: HazardResult[] = [];
  const items = day.meals.flatMap((m) => m.items);
  for (const h of HAZARDS) {
    let dose = 0;
    const foods = new Set<string>();
    if (h.dose.from === "group") {
      const key = h.dose.key;
      dose = sums.groups[key] ?? 0;
      for (const it of items) if ((it.groups[key] ?? 0) > 0) foods.add(it.name);
    } else if (h.dose.from === "nutrient") {
      const key = h.dose.key;
      dose = sums.totals[key] ?? 0;
      for (const it of items) if ((it.nutrients[key] ?? 0) > 0.5) foods.add(it.name);
    } else {
      for (const it of items) {
        for (const e of it.hazards) {
          if (e.key !== h.key) continue;
          dose += e.amount > 0 ? e.amount : h.refAmount;
          foods.add(it.name);
        }
      }
    }
    if (dose <= 0.01) continue;

    let penalty = 0;
    let message = "";
    const unit = h.dose.unit;
    if (h.key === "aspartame") {
      const pct = (dose / t.aspartameAdiMg) * 100;
      penalty = dose > t.aspartameAdiMg ? h.cap : 0;
      message = `约 ${fmtNum(dose)} mg，为你体重对应 ADI（${fmtNum(t.aspartameAdiMg)} mg）的 ${fmtNum(pct)}%` + (penalty ? "，已超过 ADI" : "，在安全范围内");
    } else {
      const over = Math.max(0, dose - (h.freeAmount ?? 0));
      const mult = t.sensitive && h.sensitiveMultiplier ? h.sensitiveMultiplier : 1;
      penalty = Math.min(h.cap, (over / h.refAmount) * h.penaltyPerRef * mult);
      if (h.key === "processed_meat") {
        message = `加工肉约 ${fmtNum(dose)} g（每天每 50 g 结直肠癌风险约 +18%）`;
      } else if (h.key === "red_meat") {
        message = over > 0
          ? `红肉约 ${fmtNum(dose)} g，超过日均建议（约 ${h.freeAmount} g）${fmtNum(over)} g`
          : `红肉约 ${fmtNum(dose)} g，在日均建议（约 ${h.freeAmount} g）以内`;
      } else if (h.key === "alcohol") {
        message = `纯酒精约 ${fmtNum(dose, 1)} g ≈ ${fmtNum(dose / 14, 1)} 标准杯` + (mult > 1 ? "（敏感人群加倍扣分）" : "");
      } else {
        message = `相关食物约 ${fmtNum(dose)} ${unit}`;
      }
    }
    list.push({
      key: h.key,
      zh: h.zh,
      iarc: h.iarc,
      dose,
      unit,
      penalty,
      foods: [...foods],
      message,
      sources: h.sources,
    });
  }
  list.sort((a, b) => b.penalty - a.penalty);
  const penalty = Math.min(HAZARD_TOTAL_CAP, list.reduce((s, h) => s + h.penalty, 0));
  return { list, penalty };
}

export function scoreDay(day: DayData, profile: Profile, t: Targets): DailyScore {
  const sums = sumDay(day);
  const { totals, groups } = sums;
  const kcal = totals.energy_kcal ?? 0;
  const energy = computeEnergy(day, profile, t, kcal);
  const hasData = sums.itemCount > 0 && kcal > 0;
  const pctOf = (g: number, kcalPerG: number) => (kcal > 0 ? ((g * kcalPerG) / kcal) * 100 : 0);
  const macroPct = {
    protein: pctOf(totals.protein_g, 4),
    carb: pctOf(totals.carb_g, 4),
    fat: pctOf(totals.fat_g, 9),
    satFat: pctOf(totals.sat_fat_g, 9),
    addedSugar: pctOf(totals.added_sugars_g, 4),
    alcohol: pctOf(totals.alcohol_g, 7),
  };
  const upfPct = kcal > 0 ? (sums.upfKcal / kcal) * 100 : 0;
  const mealCount = sums.mealCount;

  const base: Omit<DailyScore, "score" | "grade" | "categories" | "items" | "hei" | "hazards" | "hazardPenalty" | "top"> = {
    date: day.date,
    hasData,
    energy,
    totals,
    groups,
    macroPct,
    upfPct,
    mealCount,
    itemCount: sums.itemCount,
    completeness: completenessOf(kcal, mealCount, t),
    weightKg: day.weightKg,
    weighedToday: day.weighedToday,
    version: SCORING_VERSION,
  };

  if (!hasData) {
    return {
      ...base,
      score: null,
      grade: null,
      categories: [],
      items: [],
      hei: null,
      hazards: [],
      hazardPenalty: 0,
      top: { issues: [], wins: [] },
    };
  }

  const items: ScoreItem[] = [];

  // ---------- A. 膳食质量 HEI-2020 ----------
  const hei = computeHei(totals, groups);
  const heiW = CATEGORY_WEIGHTS.hei.weight;
  if (hei) {
    for (const c of hei.components) {
      const def = HEI_COMPONENTS.find((d) => d.key === c.key)!;
      const ratio = c.score / c.max;
      const maxPoints = (heiW * c.max) / 100;
      const targetText = def.kind === "adequacy"
        ? (def.key === "fatty_acids" ? `≥ ${def.best}（≤ ${def.worst} 得 0 分）` : `≥ ${def.best} ${def.unit}`)
        : `≤ ${def.best} ${def.unit}（≥ ${def.worst} 得 0 分）`;
      items.push({
        key: `hei_${c.key}`,
        category: "hei",
        zh: c.zh,
        value: c.value,
        unit: c.unit,
        targetText,
        status: ratio >= 0.999 ? "good" : ratio >= 0.6 ? "warn" : "bad",
        score: ratio,
        points: maxPoints * ratio,
        maxPoints,
        message: `${c.zh} ${fmtNum(c.value, 2)} ${c.unit}，得 ${fmtNum(c.score, 1)}/${c.max}` + (ratio < 0.999 ? `。建议：${c.hint}` : ""),
        sources: ["hei_2020"],
      });
    }
  }
  const heiScore = hei ? hei.total : 0;

  // ---------- B. 营养素充足 ----------
  const adqW = CATEGORY_WEIGHTS.adequacy.weight;
  const adqKeys = Object.keys(ADEQUACY_WEIGHTS).filter((k) => t.intake[k]);
  const weightFor = (k: string) => {
    let w = ADEQUACY_WEIGHTS[k];
    if (k === "iron_mg" && (t.lifeStage.startsWith("f19") || t.lifeStage.startsWith("f31") || t.lifeStage.startsWith("p"))) w = 2;
    if (k === "folate_ug" && t.physiology === "pregnant") w = 2;
    return w;
  };
  const adqWeightSum = adqKeys.reduce((s, k) => s + weightFor(k), 0);
  let adqScoreSum = 0;
  for (const k of adqKeys) {
    const target = t.intake[k].value;
    const v = totals[k] ?? 0;
    const ratio = target > 0 ? v / target : 1;
    const s = Math.min(1, ratio);
    const w = weightFor(k);
    adqScoreSum += s * w;
    const def = NUTRIENT_MAP[k];
    const maxPoints = (adqW * w) / adqWeightSum;
    let message = `${def.zh} ${fmtNum(v, def.decimals)} ${def.unit}，达到${t.intake[k].kind} 的 ${fmtNum(ratio * 100)}%`;
    if (k === "protein_g") {
      const perKg = v / t.referenceWeightKg;
      message += `（${fmtNum(perKg, 2)} g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg）`;
    }
    items.push({
      key: k,
      category: "adequacy",
      zh: def.zh,
      value: v,
      unit: def.unit,
      targetText: `≥ ${fmtNum(target, def.decimals)} ${def.unit}（${t.intake[k].kind}）`,
      target,
      status: k === "protein_g" && ratio >= 1 && v / t.referenceWeightKg < 1.2 ? "ok" : adequacyStatus(ratio),
      score: s,
      points: maxPoints * s,
      maxPoints,
      message,
      sources: [t.intake[k].source, ...(k === "protein_g" ? ["dga_2025"] : [])],
    });
  }
  const adequacyScore = adqWeightSum ? (adqScoreSum / adqWeightSum) * 100 : 0;

  // ---------- C. 限量控制 ----------
  const modW = CATEGORY_WEIGHTS.moderation.weight;
  interface ModItem { item: Omit<ScoreItem, "points" | "maxPoints">; w: number }
  const mods: ModItem[] = [];
  const addLimit = (key: string, zh: string, value: number, unit: string, ideal: number, limit: number, w: number, sources: string[], extra = "", decimals = 0) => {
    const { score, status } = limitCurve(value, ideal, limit);
    const over = value - limit;
    let message = `${zh} ${fmtNum(value, decimals)} ${unit}`;
    if (status === "bad") {
      message += unit === "%"
        ? `，超出上限 ${fmtNum(over, decimals)} 个百分点`
        : `，超出上限 ${fmtNum(over, decimals)} ${unit}` + (limit > 0 ? `（${fmtNum((over / limit) * 100)}%）` : "");
    }
    else if (status === "ok") message += `，在上限内但高于理想值 ${fmtNum(ideal, decimals)} ${unit}`;
    else message += "，达到理想水平";
    mods.push({
      w,
      item: {
        key, category: "moderation", zh, value, unit,
        targetText: ideal === limit ? `≤ ${fmtNum(limit, decimals)} ${unit}` : `≤ ${fmtNum(limit, decimals)} ${unit}（理想 ≤ ${fmtNum(ideal, decimals)}）`,
        ideal, limit, status, score, message: message + extra, sources,
      },
    });
  };

  const L = t.limits;
  addLimit("sodium_mg", "钠", totals.sodium_mg, "mg", L.sodium_mg.ideal, L.sodium_mg.limit, 3,
    [L.sodium_mg.limitSource, L.sodium_mg.idealSource, "dga_2025"], `（约合食盐 ${fmtNum(totals.sodium_mg / 393, 1)} g）`);
  addLimit("added_sugars_g", "添加糖", totals.added_sugars_g, "g", L.added_sugars_g.ideal, L.added_sugars_g.limit, 3,
    [L.added_sugars_g.limitSource, L.added_sugars_g.idealSource, "dga_2025"], "", 1);
  addLimit("sat_fat_pct", "饱和脂肪供能比", macroPct.satFat, "%", L.sat_fat_pct.ideal, L.sat_fat_pct.limit, 3,
    [L.sat_fat_pct.limitSource, L.sat_fat_pct.idealSource], `（${fmtNum(totals.sat_fat_g, 1)} g）`, 1);
  addLimit("trans_fat_g", "反式脂肪", totals.trans_fat_g, "g", 0.3, Math.max(0.5, L.trans_fat_g.limit), 1, ["who_trans", "dga_2020"], "", 2);
  addLimit("alcohol_g", "酒精", totals.alcohol_g, "g", 0, L.alcohol_g.limit, 2, ["dga_2020", "dga_2025", "niaaa_drink"],
    totals.alcohol_g > 0 ? `（≈ ${fmtNum(totals.alcohol_g / 14, 1)} 标准杯）` : "", 1);
  addLimit("caffeine_mg", "咖啡因", totals.caffeine_mg, "mg", L.caffeine_mg.ideal, L.caffeine_mg.limit, 1, [L.caffeine_mg.limitSource]);
  addLimit("upf_pct", "超加工食品供能比", upfPct, "%", L.upf_pct.ideal, L.upf_pct.limit, 1, ["dga_2025", "nova", "system"]);

  // 每餐添加糖 ≤ 10 g（DGA 2025–2030）
  if (sums.mealSugars.length) {
    const okMeals = sums.mealSugars.filter((m) => m.added_sugars_g <= t.addedSugarPerMealG + 0.05).length;
    const ratio = okMeals / sums.mealSugars.length;
    const worst = sums.mealSugars.reduce((a, b) => (b.added_sugars_g > a.added_sugars_g ? b : a));
    mods.push({
      w: 1,
      item: {
        key: "added_sugars_per_meal", category: "moderation", zh: "每餐添加糖 ≤ 10 g", value: okMeals, unit: `/${sums.mealSugars.length} 餐`,
        targetText: "每餐 ≤ 10 g（DGA 2025–2030）", status: ratio >= 1 ? "good" : ratio >= 0.5 ? "warn" : "bad", score: ratio,
        message: ratio >= 1 ? "每餐添加糖都在 10 g 以内" : `${sums.mealSugars.length - okMeals} 餐超过 10 g，最高一餐 ${fmtNum(worst.added_sugars_g, 1)} g（${worst.time}）`,
        sources: ["dga_2025"],
      },
    });
  }

  // 宏量营养素供能比（AMDR）
  if (kcal >= 600) {
    const amdrItems: [string, string, number, [number, number]][] = [
      ["amdr_protein", "蛋白质供能比", macroPct.protein, t.amdr.protein],
      ["amdr_carb", "碳水供能比", macroPct.carb, t.amdr.carb],
      ["amdr_fat", "脂肪供能比", macroPct.fat, t.amdr.fat],
    ];
    for (const [key, zh, v, [lo, hi]] of amdrItems) {
      const dist = v < lo ? lo - v : v > hi ? v - hi : 0;
      const s = Math.max(0, 1 - dist / 15);
      mods.push({
        w: 0.5,
        item: {
          key, category: "moderation", zh, value: v, unit: "%", targetText: `${lo}–${hi}%（AMDR）`,
          status: dist === 0 ? "good" : dist <= 5 ? "warn" : "bad", score: s,
          message: `${zh} ${fmtNum(v)}%` + (dist === 0 ? "，在可接受范围内" : v < lo ? `，低于下限 ${lo}%` : `，高于上限 ${hi}%`),
          sources: ["nasem_dri"],
        },
      });
    }
  }

  // 可耐受最高摄入量 UL（仅对适用于总摄入的营养素）
  for (const [k, u] of Object.entries(t.upper)) {
    if (!u.appliesToTotal) continue;
    const v = totals[k] ?? 0;
    if (v <= u.value) continue;
    const def = NUTRIENT_MAP[k];
    mods.push({
      w: 1,
      item: {
        key: `ul_${k}`, category: "moderation", zh: `${def.zh} 超过 UL`, value: v, unit: def.unit,
        targetText: `≤ ${fmtNum(u.value, def.decimals)} ${def.unit}（UL）`, limit: u.value, status: "bad", score: 0,
        message: `${def.zh} ${fmtNum(v, def.decimals)} ${def.unit}，超过可耐受最高摄入量 ${fmtNum(u.value, def.decimals)} ${def.unit}，检查补充剂或强化食品`,
        sources: ["nasem_dri"],
      },
    });
  }

  const modWeightSum = mods.reduce((s, m) => s + m.w, 0);
  const moderationScore = modWeightSum ? (mods.reduce((s, m) => s + m.item.score * m.w, 0) / modWeightSum) * 100 : 100;
  for (const m of mods) {
    const maxPoints = (modW * m.w) / modWeightSum;
    items.push({ ...m.item, maxPoints, points: maxPoints * m.item.score });
  }

  // 胆固醇：仅提示
  items.push({
    key: "cholesterol_mg", category: "moderation", zh: "膳食胆固醇（仅提示）", value: totals.cholesterol_mg, unit: "mg",
    targetText: "尽量低（旧标准 300 mg）", status: "info", score: 1, points: 0, maxPoints: 0,
    message: `胆固醇 ${fmtNum(totals.cholesterol_mg)} mg。现行 DGA 不设数值上限，只建议在健康膳食模式内尽量低`,
    sources: ["nasem_dri", "fda_dv"],
  });

  // ---------- D. 能量平衡 ----------
  const enW = CATEGORY_WEIGHTS.energy.weight;
  const ratio = energy.target > 0 ? kcal / energy.target : 1;
  const dev = Math.abs(ratio - 1);
  const energyScore = dev <= 0.1 ? 100 : Math.max(0, 100 * (1 - (dev - 0.1) / 0.4));
  items.push({
    key: "energy_balance", category: "energy", zh: "能量摄入 vs 目标", value: kcal, unit: "kcal",
    targetText: `${fmtNum(energy.target)} kcal ±10%`, target: energy.target,
    status: dev <= 0.1 ? "good" : dev <= 0.25 ? "warn" : "bad",
    score: energyScore / 100, points: (enW * energyScore) / 100, maxPoints: enW,
    message: `摄入 ${fmtNum(kcal)} kcal，今日目标 ${fmtNum(energy.target)} kcal（消耗 ${fmtNum(energy.tdee)}${t.goalDeltaKcal ? ` ${t.goalDeltaKcal > 0 ? "+" : "−"} ${fmtNum(Math.abs(t.goalDeltaKcal))} 目标调整` : ""}），` +
      (ratio > 1 ? `多 ${fmtNum(kcal - energy.target)} kcal` : `少 ${fmtNum(energy.target - kcal)} kcal`),
    sources: energy.method === "eer" ? ["nasem_energy", "mifflin"] : ["mifflin", "compendium_2024"],
  });

  // ---------- 风险物 ----------
  const hz = scoreHazards(day, sums, t);

  const categories: CategoryResult[] = [
    { key: "hei", zh: CATEGORY_WEIGHTS.hei.zh, weight: heiW, score: heiScore, points: (heiW * heiScore) / 100, maxPoints: heiW },
    { key: "adequacy", zh: CATEGORY_WEIGHTS.adequacy.zh, weight: adqW, score: adequacyScore, points: (adqW * adequacyScore) / 100, maxPoints: adqW },
    { key: "moderation", zh: CATEGORY_WEIGHTS.moderation.zh, weight: modW, score: moderationScore, points: (modW * moderationScore) / 100, maxPoints: modW },
    { key: "energy", zh: CATEGORY_WEIGHTS.energy.zh, weight: enW, score: energyScore, points: (enW * energyScore) / 100, maxPoints: enW },
  ];
  const raw = categories.reduce((s, c) => s + c.points, 0) - hz.penalty;
  const score = Math.max(0, Math.min(100, raw));

  // 摘要：扣分最多的问题与做得好的地方
  const scored = items.filter((i) => i.maxPoints > 0);
  const issues = [
    ...hz.list.filter((h) => h.penalty > 0).map((h) => ({ lost: h.penalty, text: `${h.zh}：${h.message}，扣 ${fmtNum(h.penalty, 1)} 分` })),
    ...scored.filter((i) => i.maxPoints - i.points > 0.3).map((i) => ({ lost: i.maxPoints - i.points, text: `${i.message}，少得 ${fmtNum(i.maxPoints - i.points, 1)} 分` })),
  ].sort((a, b) => b.lost - a.lost).slice(0, 5).map((x) => x.text);
  const wins = scored
    .filter((i) => i.status === "good" && i.maxPoints >= 1)
    .sort((a, b) => b.maxPoints - a.maxPoints)
    .slice(0, 4)
    .map((i) => i.message);

  return {
    ...base,
    score,
    grade: gradeOf(score),
    categories,
    items,
    hei: hei ? { total: hei.total, components: hei.components.map((c) => ({ key: c.key, zh: c.zh, score: c.score, max: c.max, value: c.value, unit: c.unit, hint: c.hint })) } : null,
    hazards: hz.list,
    hazardPenalty: hz.penalty,
    top: { issues, wins },
  };
}

function completenessOf(kcal: number, meals: number, t: Targets): DailyScore["completeness"] {
  if (meals === 0) return { level: "none", note: "今天还没有记录" };
  if (kcal < t.bmr * 0.6 || meals < 2) return { level: "partial", note: "记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考" };
  return { level: "likely", note: "记录较完整" };
}
