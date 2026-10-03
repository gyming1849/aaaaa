// Healthy Eating Index-2020（HEI-2020，适用于 2 岁及以上）。
// 满分 100，13 个组分；均按每 1000 kcal 的密度计分，最低与最高标准之间线性插值。
// 豆类同时计入蔬菜类与蛋白质类组分（HEI-2015 起的做法）。

import type { NutrientVector } from "./nutrients.ts";

export interface HeiComponentDef {
  key: string;
  zh: string;
  en: string;
  max: number;
  kind: "adequacy" | "moderation";
  /** 满分标准 */
  best: number;
  /** 零分标准 */
  worst: number;
  unit: string;
  hint: string;
}

export const HEI_COMPONENTS: HeiComponentDef[] = [
  { key: "total_fruits", zh: "水果总量", en: "Total Fruits", max: 5, kind: "adequacy", best: 0.8, worst: 0, unit: "杯当量/1000kcal", hint: "每天吃水果（含果汁）" },
  { key: "whole_fruits", zh: "完整水果", en: "Whole Fruits", max: 5, kind: "adequacy", best: 0.4, worst: 0, unit: "杯当量/1000kcal", hint: "优先吃整个水果而不是果汁" },
  { key: "total_vegetables", zh: "蔬菜总量", en: "Total Vegetables", max: 5, kind: "adequacy", best: 1.1, worst: 0, unit: "杯当量/1000kcal", hint: "每餐都有蔬菜" },
  { key: "greens_beans", zh: "深绿色蔬菜与豆类", en: "Greens and Beans", max: 5, kind: "adequacy", best: 0.2, worst: 0, unit: "杯当量/1000kcal", hint: "菠菜、西兰花、豆类" },
  { key: "whole_grains", zh: "全谷物", en: "Whole Grains", max: 10, kind: "adequacy", best: 1.5, worst: 0, unit: "盎司当量/1000kcal", hint: "糙米、燕麦、全麦替代部分白米白面" },
  { key: "dairy", zh: "奶制品", en: "Dairy", max: 10, kind: "adequacy", best: 1.3, worst: 0, unit: "杯当量/1000kcal", hint: "牛奶、酸奶、奶酪或强化豆奶" },
  { key: "total_protein", zh: "蛋白质食物", en: "Total Protein Foods", max: 5, kind: "adequacy", best: 2.5, worst: 0, unit: "盎司当量/1000kcal", hint: "肉蛋鱼禽豆坚果" },
  { key: "seafood_plant_protein", zh: "海产与植物蛋白", en: "Seafood and Plant Proteins", max: 5, kind: "adequacy", best: 0.8, worst: 0, unit: "盎司当量/1000kcal", hint: "鱼虾、豆腐、坚果" },
  { key: "fatty_acids", zh: "脂肪酸比例", en: "Fatty Acids", max: 10, kind: "adequacy", best: 2.5, worst: 1.2, unit: "(PUFA+MUFA)/SFA", hint: "植物油、坚果、鱼替代动物脂肪" },
  { key: "refined_grains", zh: "精制谷物", en: "Refined Grains", max: 10, kind: "moderation", best: 1.8, worst: 4.3, unit: "盎司当量/1000kcal", hint: "减少白米白面" },
  { key: "sodium", zh: "钠", en: "Sodium", max: 10, kind: "moderation", best: 1.1, worst: 2.0, unit: "g/1000kcal", hint: "少盐少酱油" },
  { key: "added_sugars", zh: "添加糖", en: "Added Sugars", max: 10, kind: "moderation", best: 6.5, worst: 26, unit: "% 能量", hint: "少喝含糖饮料、少吃甜点" },
  { key: "saturated_fats", zh: "饱和脂肪", en: "Saturated Fats", max: 10, kind: "moderation", best: 8, worst: 16, unit: "% 能量", hint: "少肥肉、黄油、椰子油、奶油" },
];

export interface HeiComponentResult {
  key: string;
  zh: string;
  max: number;
  score: number;
  value: number;
  best: number;
  worst: number;
  unit: string;
  hint: string;
}

export interface HeiResult {
  total: number;
  components: HeiComponentResult[];
}

function interp(value: number, best: number, worst: number, max: number): number {
  if (best > worst) {
    // 越多越好
    if (value >= best) return max;
    if (value <= worst) return 0;
    return (max * (value - worst)) / (best - worst);
  }
  // 越少越好
  if (value <= best) return max;
  if (value >= worst) return 0;
  return (max * (worst - value)) / (worst - best);
}

export function computeHei(n: NutrientVector, g: NutrientVector): HeiResult | null {
  const kcal = n.energy_kcal ?? 0;
  if (kcal < 200) return null;
  const per1000 = (v: number) => (v / kcal) * 1000;
  const legumesOz = (g.legumes_cup ?? 0) * 4; // 1 杯豆类 = 4 盎司当量蛋白质
  const sfa = n.sat_fat_g ?? 0;
  const fattyRatio = sfa > 0 ? ((n.pufa_g ?? 0) + (n.mufa_g ?? 0)) / sfa : 2.5;

  const values: Record<string, number> = {
    total_fruits: per1000(g.fruit_total_cup ?? 0),
    whole_fruits: per1000(g.fruit_whole_cup ?? 0),
    total_vegetables: per1000((g.veg_total_cup ?? 0) + (g.legumes_cup ?? 0)),
    greens_beans: per1000((g.veg_dark_green_cup ?? 0) + (g.legumes_cup ?? 0)),
    whole_grains: per1000(g.grains_whole_oz ?? 0),
    dairy: per1000(g.dairy_cup ?? 0),
    total_protein: per1000((g.protein_total_oz ?? 0) + legumesOz),
    seafood_plant_protein: per1000((g.seafood_oz ?? 0) + (g.plant_protein_oz ?? 0) + legumesOz),
    fatty_acids: fattyRatio,
    refined_grains: per1000(g.grains_refined_oz ?? 0),
    sodium: per1000((n.sodium_mg ?? 0) / 1000),
    added_sugars: (((n.added_sugars_g ?? 0) * 4) / kcal) * 100,
    saturated_fats: ((sfa * 9) / kcal) * 100,
  };

  const components = HEI_COMPONENTS.map((c) => {
    const value = values[c.key];
    return {
      key: c.key,
      zh: c.zh,
      max: c.max,
      score: interp(value, c.best, c.worst, c.max),
      value,
      best: c.best,
      worst: c.worst,
      unit: c.unit,
      hint: c.hint,
    };
  });
  const total = components.reduce((s, c) => s + c.score, 0);
  return { total, components };
}
