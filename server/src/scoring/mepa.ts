// MEPA（Mediterranean Eating Pattern for Americans）16 题饮食问卷：
// AHA Life's Essential 8 规定的个人饮食评分工具（Cerwinske LA et al., J Hum Nutr Diet 2017;30:596–603；
// LE8 补充材料 Table C）。每题满足得 1 分，共 0–16 分。
// 本系统用饮食记录自动推算每周/每天份数（份量按 Rush 大学 MEPA 问卷的定义）。

import type { NutrientVector } from "../standards/nutrients.ts";

export interface MepaItem {
  key: string;
  zh: string;
  criterion: string;
  value: number;
  unit: string;
  met: boolean;
}

export interface MepaResult {
  score: number;
  days: number;
  items: MepaItem[];
}

export interface MepaInput {
  /** 统计期内的食物组总量 */
  groups: NutrientVector;
  /** 统计期内的酒精总克数 */
  alcoholG: number;
  /** 统计期内的快餐餐数（含 fast_food 类食物的餐次） */
  fastFoodMeals: number;
  /** 有饮食记录的天数 */
  days: number;
  sex: "male" | "female";
}

export function computeMepa(x: MepaInput): MepaResult | null {
  if (x.days < 3) return null;
  const g = x.groups;
  const perWeek = (total: number) => (total / x.days) * 7;
  const perDay = (total: number) => total / x.days;
  const leafyServ = (g.veg_dark_green_cup ?? 0) / 0.5; // 1 份 = 1 杯生 / ½ 杯熟 ≈ 0.5 杯当量
  const otherVegServ = Math.max(0, (g.veg_total_cup ?? 0) - (g.veg_dark_green_cup ?? 0)) / 0.5; // 1 份 = ½ 杯
  const berryServ = (g.berries_cup ?? 0) / 0.5;
  const otherFruitServ = Math.max(0, (g.fruit_total_cup ?? 0) - (g.berries_cup ?? 0)) / 0.5;
  const meatServ = ((g.red_meat_g ?? 0) + (g.processed_meat_g ?? 0)) / 85; // 1 份 = 3 盎司 ≈ 85 g
  const fishServ = (g.seafood_oz ?? 0) / 3;
  const chickenServ = (g.poultry_g ?? 0) / 85;
  const cheeseServ = (g.cheese_g ?? 0) / 28;
  const butterServ = (g.butter_cream_g ?? 0) / 14;
  const beanServ = (g.legumes_cup ?? 0) / 0.5;
  const wholeGrainServ = g.grains_whole_oz ?? 0;
  const sweetsServ = g.sweets_serv ?? 0;
  const nutsServ = (g.nuts_g ?? 0) / 30; // ¼ 杯 ≈ 30 g
  const oliveServ = (g.olive_oil_g ?? 0) / 13.5;
  const drinksPerDay = perDay(x.alcoholG) / 14;
  const alcoholLimit = x.sex === "male" ? 2 : 1;

  const items: MepaItem[] = [
    { key: "olive_oil", zh: "橄榄油", criterion: "> 2 份/天（1 份 = 1 汤匙）", value: perDay(oliveServ), unit: "份/天", met: perDay(oliveServ) > 2 },
    { key: "leafy", zh: "绿叶蔬菜", criterion: "> 7 份/周（1 份 = 1 杯生 / ½ 杯熟）", value: perWeek(leafyServ), unit: "份/周", met: perWeek(leafyServ) > 7 },
    { key: "other_veg", zh: "其他蔬菜", criterion: "> 2 份/天（1 份 = ½ 杯）", value: perDay(otherVegServ), unit: "份/天", met: perDay(otherVegServ) > 2 },
    { key: "berries", zh: "浆果", criterion: "> 2 份/周（1 份 = ½ 杯）", value: perWeek(berryServ), unit: "份/周", met: perWeek(berryServ) > 2 },
    { key: "other_fruit", zh: "其他水果", criterion: "> 1 份/天（1 份 = ½ 杯）", value: perDay(otherFruitServ), unit: "份/天", met: perDay(otherFruitServ) > 1 },
    { key: "meat", zh: "红肉、汉堡、培根、香肠", criterion: "< 3 份/周（1 份 = 3 盎司）", value: perWeek(meatServ), unit: "份/周", met: perWeek(meatServ) < 3 },
    { key: "fish", zh: "鱼和贝类", criterion: "> 1 份/周（1 份 = 3 盎司）", value: perWeek(fishServ), unit: "份/周", met: perWeek(fishServ) > 1 },
    { key: "chicken", zh: "鸡肉", criterion: "< 5 份/周（1 份 = 3 盎司）", value: perWeek(chickenServ), unit: "份/周", met: perWeek(chickenServ) < 5 },
    { key: "cheese", zh: "全脂奶酪 / 奶油奶酪", criterion: "< 4 份/周（1 份 = 1 盎司）", value: perWeek(cheeseServ), unit: "份/周", met: perWeek(cheeseServ) < 4 },
    { key: "butter", zh: "黄油 / 奶油", criterion: "< 5 份/周（1 份 = 1 汤匙）", value: perWeek(butterServ), unit: "份/周", met: perWeek(butterServ) < 5 },
    { key: "beans", zh: "豆类", criterion: "> 3 份/周（1 份 = ½ 杯）", value: perWeek(beanServ), unit: "份/周", met: perWeek(beanServ) > 3 },
    { key: "whole_grains", zh: "全谷物", criterion: "> 3 份/天（1 份 = 1 片面包 / ¾ 杯）", value: perDay(wholeGrainServ), unit: "份/天", met: perDay(wholeGrainServ) > 3 },
    { key: "sweets", zh: "商业甜点、糖果、糕点", criterion: "< 4 份/周", value: perWeek(sweetsServ), unit: "份/周", met: perWeek(sweetsServ) < 4 },
    { key: "nuts", zh: "坚果", criterion: "> 4 份/周（1 份 = ¼ 杯）", value: perWeek(nutsServ), unit: "份/周", met: perWeek(nutsServ) > 4 },
    { key: "fast_food", zh: "快餐", criterion: "< 1 次/周", value: perWeek(x.fastFoodMeals), unit: "次/周", met: perWeek(x.fastFoodMeals) < 1 },
    {
      key: "alcohol", zh: "酒精",
      criterion: `> 0 且 < ${alcoholLimit} 杯/天（问卷原文；与 IARC“无安全剂量”的观点不同，防癌评分中以不饮酒为最佳）`,
      value: drinksPerDay, unit: "杯/天", met: drinksPerDay > 0 && drinksPerDay < alcoholLimit,
    },
  ];
  return { score: items.filter((i) => i.met).length, days: x.days, items };
}
