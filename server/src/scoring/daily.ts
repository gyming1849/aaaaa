// 每日离线评分引擎（评分规则 v2：全部采用已发表的评分体系，不自定权重）
//
// - 当日膳食质量 = HEI-2020 总分（USDA / NCI，13 个组分的官方分值，满分 100）
// - 营养素充足 = MAR 平均充足比（FAO 等采用的 11 种微量营养素，NAR = min(摄入/RDA, 1)，等权平均）
// - 其他营养素、限量（钠、添加糖、饱和脂肪、酒精、咖啡因、UL…）、能量平衡：只标“达标 / 不达标”，不另设权重
// - 致癌物与风险物：按 IARC 分级给出警示，不另设扣分；加工肉、红肉、酒精、含糖饮料在 WCRF/AICR 防癌评分中计分
// - 周期与近 7 天的综合健康分：AHA Life's Essential 8（见 le8.ts）、WCRF/AICR（见 wcrf.ts）
// - 另有综合总分（本站自定权重，见 composite.ts），与上面的分数并列展示
//
// 规则详细说明见 docs/scoring.md，前端“标准库”页面也会完整展示。

import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, NUTRIENT_MAP, emptyVector, addVectors, type NutrientVector } from "../standards/nutrients.ts";
import { computeHei, HEI_COMPONENTS } from "../standards/hei.ts";
import { HAZARDS, HAZARD_MAP } from "../standards/hazards.ts";
import { eer, stepsNetKcal } from "../standards/energy.ts";
import type { Profile, Targets } from "../standards/targets.ts";
import { dailyComposite } from "./composite.ts";
import type {
  DayData, DailyScore, ScoreItem, HazardResult, EnergyResult, CategoryResult, Status, MarResult,
} from "./types.ts";

export const SCORING_VERSION = 3;

/** HEI-2020 美国人平均分（USDA，NHANES 2017–2018，2 岁及以上） */
export const HEI_US_MEAN = 58;

/** MAR 计分的 11 种微量营养素（Arimond et al. 2010；FAO MDD-W 指南） */
export const MAR_NUTRIENTS = [
  "vit_a_ug", "thiamin_mg", "riboflavin_mg", "niacin_mg", "vit_b6_mg", "folate_ug", "vit_b12_ug", "vit_c_mg", "calcium_mg", "iron_mg", "zinc_mg",
];

/** 限量型项目的状态：≤理想 达标；≤上限 达标（高于理想）；超过上限 不达标 */
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
  fastFoodMeals: number;
}

export function sumDay(day: DayData): DayTotals {
  let totals = emptyVector(NUTRIENT_KEYS);
  let groups = emptyVector(FOOD_GROUP_KEYS);
  let upfKcal = 0;
  let itemCount = 0;
  const mealSugars: DayTotals["mealSugars"] = [];
  let mealCount = 0;
  let fastFoodMeals = 0;
  for (const meal of day.meals) {
    if (meal.items.some((it) => it.category === "fast_food")) fastFoodMeals++;
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
  return { totals, groups, upfKcal, mealSugars, itemCount, mealCount, fastFoodMeals };
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

/** 风险物警示（IARC 分级 + 剂量说明），不扣分 */
export function scoreHazards(day: DayData, sums: DayTotals, t: Targets): HazardResult[] {
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
    let message: string;
    if (h.key === "aspartame") {
      message = `约 ${fmtNum(dose)} mg，为你体重对应 ADI（${fmtNum(t.aspartameAdiMg)} mg）的 ${fmtNum((dose / t.aspartameAdiMg) * 100)}%` + (dose > t.aspartameAdiMg ? "，已超过 ADI" : "，在 ADI 以内");
    } else if (h.key === "processed_meat") {
      message = `加工肉约 ${fmtNum(dose)} g（WHO：每天每 50 g 结直肠癌风险约 +18%；WCRF：<21 g/周）`;
    } else if (h.key === "red_meat") {
      message = `红肉约 ${fmtNum(dose)} g（WCRF：每周 ≤500 g 熟重）`;
    } else if (h.key === "alcohol") {
      message = `纯酒精约 ${fmtNum(dose, 1)} g ≈ ${fmtNum(dose / 14, 1)} 标准杯（IARC：无安全剂量）`;
    } else {
      message = `相关食物约 ${fmtNum(dose)} ${h.dose.unit}`;
    }
    list.push({ key: h.key, zh: h.zh, iarc: h.iarc, dose, unit: h.dose.unit, foods: [...foods], message, sources: h.sources });
  }
  const rank = (g: string) => ({ "1": 0, "2A": 1, "—": 2, "2B": 3 })[g] ?? 4;
  return list.sort((a, b) => rank(a.iarc) - rank(b.iarc));
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

  const base = {
    date: day.date,
    hasData,
    energy,
    totals,
    groups,
    macroPct,
    upfPct,
    mealCount,
    itemCount: sums.itemCount,
    fastFoodMeals: sums.fastFoodMeals,
    completeness: completenessOf(kcal, mealCount, t),
    weightKg: day.weightKg,
    weighedToday: day.weighedToday,
    version: SCORING_VERSION,
  };

  if (!hasData) {
    const total = dailyComposite({ hasData, hei: null, mar: null, energy, day });
    return { ...base, score: null, total, categories: [], items: [], hei: null, mar: null, hazards: [], top: { issues: [], wins: [] } };
  }

  const items: ScoreItem[] = [];

  // ---------- HEI-2020：官方组分分值 ----------
  const hei = computeHei(totals, groups);
  if (hei) {
    for (const c of hei.components) {
      const def = HEI_COMPONENTS.find((d) => d.key === c.key)!;
      const ratio = c.score / c.max;
      const lost = c.max - c.score;
      const targetText = def.kind === "adequacy"
        ? (def.key === "fatty_acids" ? `≥ ${def.best} 得满分，≤ ${def.worst} 得 0` : `≥ ${def.best} ${def.unit} 得满分`)
        : `≤ ${def.best} 得满分，≥ ${def.worst} 得 0（${def.unit}）`;
      items.push({
        key: `hei_${c.key}`,
        category: "hei",
        zh: c.zh,
        value: c.value,
        unit: c.unit,
        targetText,
        status: ratio >= 0.999 ? "good" : ratio >= 0.6 ? "warn" : "bad",
        score: ratio,
        points: c.score,
        maxPoints: c.max,
        message: `${c.zh} ${fmtNum(c.value, 2)} ${c.unit}：得 ${fmtNum(c.score, 1)}/${c.max}` + (lost > 0.05 ? `，扣 ${fmtNum(lost, 1)} 分。建议：${c.hint}` : "，满分"),
        sources: ["hei_2020"],
      });
    }
  }

  // ---------- MAR：11 种微量营养素，等权 ----------
  const marList: MarResult["nutrients"] = [];
  for (const k of MAR_NUTRIENTS) {
    const tgt = t.intake[k];
    if (!tgt) continue;
    const v = totals[k] ?? 0;
    const nar = Math.min(1, v / tgt.value);
    marList.push({ key: k, zh: NUTRIENT_MAP[k].zh, intake: v, target: tgt.value, nar });
  }
  const mar: MarResult | null = marList.length ? { value: (marList.reduce((s, n) => s + n.nar, 0) / marList.length) * 100, nutrients: marList } : null;

  // ---------- 各营养素是否达到 RDA/AI（MAR 的 11 种计分，其余只标状态） ----------
  const skip = new Set(["sodium_mg", "carb_g", "water_g"]);
  for (const k of Object.keys(t.intake)) {
    if (skip.has(k)) continue;
    const def = NUTRIENT_MAP[k];
    if (!def) continue;
    const target = t.intake[k].value;
    const v = totals[k] ?? 0;
    const ratio = target > 0 ? v / target : 1;
    const inMar = MAR_NUTRIENTS.includes(k);
    let message = `${def.zh} ${fmtNum(v, def.decimals)} ${def.unit}，达到${t.intake[k].kind} 的 ${fmtNum(ratio * 100)}%`;
    if (k === "protein_g") message += `（${fmtNum(v / t.referenceWeightKg, 2)} g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg）`;
    if (inMar) message += `（NAR ${fmtNum(Math.min(1, ratio), 2)}）`;
    items.push({
      key: k,
      category: inMar ? "mar" : "adequacy",
      zh: def.zh,
      value: v,
      unit: def.unit,
      targetText: `≥ ${fmtNum(target, def.decimals)} ${def.unit}（${t.intake[k].kind}）`,
      target,
      status: k === "protein_g" && ratio >= 1 && v / t.referenceWeightKg < 1.2 ? "ok" : ratio >= 1 ? "good" : ratio >= 0.7 ? "warn" : "bad",
      score: Math.min(1, ratio),
      points: 0,
      maxPoints: 0,
      message,
      sources: [t.intake[k].source, ...(k === "protein_g" ? ["dga_2025"] : [])],
    });
  }
  // 水分单独提示（饮水常被漏记）
  if (t.intake.water_g) {
    const v = totals.water_g ?? 0;
    const r = v / t.intake.water_g.value;
    items.push({
      key: "water_g", category: "adequacy", zh: "总水分", value: v, unit: "g", targetText: `≥ ${fmtNum(t.intake.water_g.value)} g（AI，含食物水分）`,
      target: t.intake.water_g.value, status: r >= 1 ? "good" : r >= 0.7 ? "warn" : "bad", score: Math.min(1, r), points: 0, maxPoints: 0,
      message: `总水分 ${fmtNum(v)} g，达到 AI 的 ${fmtNum(r * 100)}%（记得用“+250 ml”记录饮水）`, sources: ["nasem_dri"],
    });
  }

  // ---------- 限量与其他标准：只标状态 ----------
  const addLimit = (key: string, zh: string, value: number, unit: string, ideal: number, limit: number, sources: string[], extra = "", decimals = 0) => {
    const { score, status } = limitCurve(value, ideal, limit);
    const over = value - limit;
    let message = `${zh} ${fmtNum(value, decimals)} ${unit}`;
    if (status === "bad") {
      message += unit === "%"
        ? `，超出上限 ${fmtNum(over, decimals)} 个百分点`
        : `，超出上限 ${fmtNum(over, decimals)} ${unit}` + (limit > 0 ? `（${fmtNum((over / limit) * 100)}%）` : "");
    } else if (status === "ok") message += `，在上限内但高于理想值 ${fmtNum(ideal, decimals)} ${unit}`;
    else message += "，达到理想水平";
    items.push({
      key, category: "moderation", zh, value, unit,
      targetText: ideal === limit ? `≤ ${fmtNum(limit, decimals)} ${unit}` : `≤ ${fmtNum(limit, decimals)} ${unit}（理想 ≤ ${fmtNum(ideal, decimals)}）`,
      ideal, limit, status, score, points: 0, maxPoints: 0, message: message + extra, sources,
    });
  };
  const L = t.limits;
  addLimit("sodium_mg", "钠", totals.sodium_mg, "mg", L.sodium_mg.ideal, L.sodium_mg.limit,
    [L.sodium_mg.limitSource, L.sodium_mg.idealSource, "dga_2025"], `（约合食盐 ${fmtNum(totals.sodium_mg / 393, 1)} g）`);
  addLimit("added_sugars_g", "添加糖", totals.added_sugars_g, "g", L.added_sugars_g.ideal, L.added_sugars_g.limit,
    [L.added_sugars_g.limitSource, L.added_sugars_g.idealSource, "dga_2025"], "", 1);
  addLimit("sat_fat_pct", "饱和脂肪供能比", macroPct.satFat, "%", L.sat_fat_pct.ideal, L.sat_fat_pct.limit,
    [L.sat_fat_pct.limitSource, L.sat_fat_pct.idealSource], `（${fmtNum(totals.sat_fat_g, 1)} g）`, 1);
  addLimit("trans_fat_g", "反式脂肪", totals.trans_fat_g, "g", 0.3, Math.max(0.5, L.trans_fat_g.limit), ["who_trans", "dga_2020"], "", 2);
  addLimit("alcohol_g", "酒精", totals.alcohol_g, "g", 0, L.alcohol_g.limit, ["dga_2020", "dga_2025", "niaaa_drink"],
    totals.alcohol_g > 0 ? `（≈ ${fmtNum(totals.alcohol_g / 14, 1)} 标准杯）` : "", 1);
  addLimit("caffeine_mg", "咖啡因", totals.caffeine_mg, "mg", L.caffeine_mg.ideal, L.caffeine_mg.limit, [L.caffeine_mg.limitSource]);
  addLimit("upf_pct", "超加工食品供能比", upfPct, "%", L.upf_pct.ideal, L.upf_pct.limit, ["dga_2025", "nova"]);
  if (sums.mealSugars.length) {
    const okMeals = sums.mealSugars.filter((m) => m.added_sugars_g <= t.addedSugarPerMealG + 0.05).length;
    const ratio = okMeals / sums.mealSugars.length;
    const worst = sums.mealSugars.reduce((a, b) => (b.added_sugars_g > a.added_sugars_g ? b : a));
    items.push({
      key: "added_sugars_per_meal", category: "moderation", zh: "每餐添加糖 ≤ 10 g", value: okMeals, unit: `/${sums.mealSugars.length} 餐`,
      targetText: "每餐 ≤ 10 g（DGA 2025–2030）", status: ratio >= 1 ? "good" : "bad", score: ratio, points: 0, maxPoints: 0,
      message: ratio >= 1 ? "每餐添加糖都在 10 g 以内" : `${sums.mealSugars.length - okMeals} 餐超过 10 g，最高一餐 ${fmtNum(worst.added_sugars_g, 1)} g（${worst.time}）`,
      sources: ["dga_2025"],
    });
  }
  if (kcal >= 600) {
    const amdrItems: [string, string, number, [number, number]][] = [
      ["amdr_protein", "蛋白质供能比", macroPct.protein, t.amdr.protein],
      ["amdr_carb", "碳水供能比", macroPct.carb, t.amdr.carb],
      ["amdr_fat", "脂肪供能比", macroPct.fat, t.amdr.fat],
    ];
    for (const [key, zh, v, [lo, hi]] of amdrItems) {
      const inRange = v >= lo && v <= hi;
      items.push({
        key, category: "moderation", zh, value: v, unit: "%", targetText: `${lo}–${hi}%（AMDR）`,
        status: inRange ? "good" : "bad", score: inRange ? 1 : 0, points: 0, maxPoints: 0,
        message: `${zh} ${fmtNum(v)}%` + (inRange ? "，在可接受范围内" : v < lo ? `，低于下限 ${lo}%` : `，高于上限 ${hi}%`),
        sources: ["nasem_dri"],
      });
    }
  }
  for (const [k, u] of Object.entries(t.upper)) {
    if (!u.appliesToTotal) continue;
    const v = totals[k] ?? 0;
    if (v <= u.value) continue;
    const def = NUTRIENT_MAP[k];
    items.push({
      key: `ul_${k}`, category: "moderation", zh: `${def.zh} 超过 UL`, value: v, unit: def.unit,
      targetText: `≤ ${fmtNum(u.value, def.decimals)} ${def.unit}（UL）`, limit: u.value, status: "bad", score: 0, points: 0, maxPoints: 0,
      message: `${def.zh} ${fmtNum(v, def.decimals)} ${def.unit}，超过可耐受最高摄入量 ${fmtNum(u.value, def.decimals)} ${def.unit}，检查补充剂或强化食品`,
      sources: ["nasem_dri"],
    });
  }
  items.push({
    key: "cholesterol_mg", category: "moderation", zh: "膳食胆固醇（仅提示）", value: totals.cholesterol_mg, unit: "mg",
    targetText: "尽量低（现行 DGA 无数值上限）", status: "info", score: 1, points: 0, maxPoints: 0,
    message: `胆固醇 ${fmtNum(totals.cholesterol_mg)} mg。现行 DGA 不设数值上限，只建议在健康膳食模式内尽量低`,
    sources: ["nasem_dri", "fda_dv"],
  });

  // ---------- 能量平衡：只标状态 ----------
  const ratio = energy.target > 0 ? kcal / energy.target : 1;
  const dev = Math.abs(ratio - 1);
  items.push({
    key: "energy_balance", category: "energy", zh: "能量摄入 vs 目标", value: kcal, unit: "kcal",
    targetText: `${fmtNum(energy.target)} kcal ±10%`, target: energy.target,
    status: dev <= 0.1 ? "good" : dev <= 0.25 ? "warn" : "bad",
    score: Math.max(0, 1 - dev), points: 0, maxPoints: 0,
    message: `摄入 ${fmtNum(kcal)} kcal，今日目标 ${fmtNum(energy.target)} kcal（消耗 ${fmtNum(energy.tdee)}${t.goalDeltaKcal ? ` ${t.goalDeltaKcal > 0 ? "+" : "−"} ${fmtNum(Math.abs(t.goalDeltaKcal))} 目标调整` : ""}），` +
      (ratio > 1 ? `多 ${fmtNum(kcal - energy.target)} kcal` : `少 ${fmtNum(energy.target - kcal)} kcal`),
    sources: energy.method === "eer" ? ["nasem_energy", "mifflin"] : ["mifflin", "compendium_2024"],
  });

  const hazards = scoreHazards(day, sums, t);

  const categories: CategoryResult[] = [];
  if (hei) categories.push({ key: "hei", zh: "膳食质量 HEI-2020", score: hei.total, source: "hei_2020", note: `美国人平均 ${HEI_US_MEAN} 分` });
  if (mar) categories.push({ key: "mar", zh: "微量营养素充足 MAR", score: mar.value, source: "mar", note: "11 种微量营养素的平均充足比" });

  // 摘要：HEI 扣分最多的组分、超标项、风险物、明显不足的营养素
  const cand: { w: number; text: string }[] = [];
  for (const i of items) {
    if (i.category === "hei" && i.maxPoints - i.points >= 1.5) cand.push({ w: i.maxPoints - i.points, text: `HEI「${i.zh}」扣 ${fmtNum(i.maxPoints - i.points, 1)} 分：${fmtNum(i.value, 2)} ${i.unit}` });
    if (i.category === "moderation" && i.status === "bad") cand.push({ w: 8, text: i.message });
    if ((i.category === "mar" || i.key === "fiber_g" || i.key === "potassium_mg" || i.key === "vit_d_ug") && i.score < 0.5) cand.push({ w: 3, text: i.message });
  }
  for (const h of hazards) {
    const def = HAZARD_MAP[h.key];
    if (h.key === "red_meat" && h.dose < 72) continue; // 日均低于 WCRF 周上限（500 g ÷ 7）不提示
    if (h.key === "aspartame" && h.dose <= t.aspartameAdiMg) continue;
    // 风险物警示总是排在最前面（1 类 > 2A > 其他）
    cand.push({ w: h.iarc === "1" ? 30 : h.iarc === "2A" ? 20 : 15, text: `${h.zh}（IARC ${def.iarc}）：${h.message}` });
  }
  const issues = cand.sort((a, b) => b.w - a.w).slice(0, 7).map((c) => c.text);
  const wins = items
    .filter((i) => (i.category === "hei" && i.maxPoints >= 5 && i.points >= i.maxPoints - 0.01) || (i.category === "moderation" && i.status === "good" && ["sodium_mg", "added_sugars_g", "sat_fat_pct"].includes(i.key)))
    .slice(0, 4)
    .map((i) => i.message);

  return {
    ...base,
    score: hei ? hei.total : null,
    total: dailyComposite({ hasData, hei: hei ? hei.total : null, mar: mar ? mar.value : null, energy, day }),
    categories,
    items,
    hei: hei ? { total: hei.total, components: hei.components.map((c) => ({ key: c.key, zh: c.zh, score: c.score, max: c.max, value: c.value, unit: c.unit, hint: c.hint })) } : null,
    mar,
    hazards,
    top: { issues, wins },
  };
}

function completenessOf(kcal: number, meals: number, t: Targets): DailyScore["completeness"] {
  if (meals === 0) return { level: "none", note: "今天还没有记录" };
  if (kcal < t.bmr * 0.6 || meals < 2) return { level: "partial", note: "记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考" };
  return { level: "likely", note: "记录较完整" };
}
