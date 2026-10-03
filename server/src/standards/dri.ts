// 美国膳食营养素参考摄入量（DRI，NASEM）。
// 数值取自 NASEM DRI 汇总表（NIH ODS 转载）；钠/钾为 2019 年修订版。
// 每个数组按 LIFE_STAGES 的顺序排列（20 个人群组）。

export type LifeStageId =
  | "c1_3" | "c4_8"
  | "m9_13" | "m14_18" | "m19_30" | "m31_50" | "m51_70" | "m71"
  | "f9_13" | "f14_18" | "f19_30" | "f31_50" | "f51_70" | "f71"
  | "p14_18" | "p19_30" | "p31_50"
  | "l14_18" | "l19_30" | "l31_50";

export interface LifeStage {
  id: LifeStageId;
  zh: string;
}

export const LIFE_STAGES: LifeStage[] = [
  { id: "c1_3", zh: "儿童 1–3 岁" },
  { id: "c4_8", zh: "儿童 4–8 岁" },
  { id: "m9_13", zh: "男 9–13 岁" },
  { id: "m14_18", zh: "男 14–18 岁" },
  { id: "m19_30", zh: "男 19–30 岁" },
  { id: "m31_50", zh: "男 31–50 岁" },
  { id: "m51_70", zh: "男 51–70 岁" },
  { id: "m71", zh: "男 >70 岁" },
  { id: "f9_13", zh: "女 9–13 岁" },
  { id: "f14_18", zh: "女 14–18 岁" },
  { id: "f19_30", zh: "女 19–30 岁" },
  { id: "f31_50", zh: "女 31–50 岁" },
  { id: "f51_70", zh: "女 51–70 岁" },
  { id: "f71", zh: "女 >70 岁" },
  { id: "p14_18", zh: "孕期 ≤18 岁" },
  { id: "p19_30", zh: "孕期 19–30 岁" },
  { id: "p31_50", zh: "孕期 31–50 岁" },
  { id: "l14_18", zh: "哺乳期 ≤18 岁" },
  { id: "l19_30", zh: "哺乳期 19–30 岁" },
  { id: "l31_50", zh: "哺乳期 31–50 岁" },
];

const IDX: Record<LifeStageId, number> = Object.fromEntries(
  LIFE_STAGES.map((s, i) => [s.id, i]),
) as Record<LifeStageId, number>;

type Row = (number | null)[];

export type IntakeKind = "RDA" | "AI";

export interface IntakeRow {
  kind: IntakeKind;
  values: Row;
}

/** 推荐摄入量：RDA（推荐膳食供给量）或 AI（适宜摄入量） */
export const INTAKE: Record<string, IntakeRow> = {
  //                          c1-3  c4-8  m9-13 m14-18 m19-30 m31-50 m51-70 m71  f9-13 f14-18 f19-30 f31-50 f51-70 f71  p≤18 p19-30 p31-50 l≤18 l19-30 l31-50
  protein_g:      { kind: "RDA", values: [13, 19, 34, 52, 56, 56, 56, 56, 34, 46, 46, 46, 46, 46, 71, 71, 71, 71, 71, 71] },
  carb_g:         { kind: "RDA", values: [130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 175, 175, 175, 210, 210, 210] },
  fiber_g:        { kind: "AI", values: [19, 25, 31, 38, 38, 38, 30, 30, 26, 26, 25, 25, 21, 21, 28, 28, 28, 29, 29, 29] },
  linoleic_g:     { kind: "AI", values: [7, 10, 12, 16, 17, 17, 14, 14, 10, 11, 12, 12, 11, 11, 13, 13, 13, 13, 13, 13] },
  ala_g:          { kind: "AI", values: [0.7, 0.9, 1.2, 1.6, 1.6, 1.6, 1.6, 1.6, 1.0, 1.1, 1.1, 1.1, 1.1, 1.1, 1.4, 1.4, 1.4, 1.3, 1.3, 1.3] },
  // 总水 AI 单位为 L，这里换算为 g（1 L ≈ 1000 g）
  water_g:        { kind: "AI", values: [1300, 1700, 2400, 3300, 3700, 3700, 3700, 3700, 2100, 2300, 2700, 2700, 2700, 2700, 3000, 3000, 3000, 3800, 3800, 3800] },

  vit_a_ug:       { kind: "RDA", values: [300, 400, 600, 900, 900, 900, 900, 900, 600, 700, 700, 700, 700, 700, 750, 770, 770, 1200, 1300, 1300] },
  vit_c_mg:       { kind: "RDA", values: [15, 25, 45, 75, 90, 90, 90, 90, 45, 65, 75, 75, 75, 75, 80, 85, 85, 115, 120, 120] },
  vit_d_ug:       { kind: "RDA", values: [15, 15, 15, 15, 15, 15, 15, 20, 15, 15, 15, 15, 15, 20, 15, 15, 15, 15, 15, 15] },
  vit_e_mg:       { kind: "RDA", values: [6, 7, 11, 15, 15, 15, 15, 15, 11, 15, 15, 15, 15, 15, 15, 15, 15, 19, 19, 19] },
  vit_k_ug:       { kind: "AI", values: [30, 55, 60, 75, 120, 120, 120, 120, 60, 75, 90, 90, 90, 90, 75, 90, 90, 75, 90, 90] },
  thiamin_mg:     { kind: "RDA", values: [0.5, 0.6, 0.9, 1.2, 1.2, 1.2, 1.2, 1.2, 0.9, 1.0, 1.1, 1.1, 1.1, 1.1, 1.4, 1.4, 1.4, 1.4, 1.4, 1.4] },
  riboflavin_mg:  { kind: "RDA", values: [0.5, 0.6, 0.9, 1.3, 1.3, 1.3, 1.3, 1.3, 0.9, 1.0, 1.1, 1.1, 1.1, 1.1, 1.4, 1.4, 1.4, 1.6, 1.6, 1.6] },
  niacin_mg:      { kind: "RDA", values: [6, 8, 12, 16, 16, 16, 16, 16, 12, 14, 14, 14, 14, 14, 18, 18, 18, 17, 17, 17] },
  vit_b6_mg:      { kind: "RDA", values: [0.5, 0.6, 1.0, 1.3, 1.3, 1.3, 1.7, 1.7, 1.0, 1.2, 1.3, 1.3, 1.5, 1.5, 1.9, 1.9, 1.9, 2.0, 2.0, 2.0] },
  folate_ug:      { kind: "RDA", values: [150, 200, 300, 400, 400, 400, 400, 400, 300, 400, 400, 400, 400, 400, 600, 600, 600, 500, 500, 500] },
  vit_b12_ug:     { kind: "RDA", values: [0.9, 1.2, 1.8, 2.4, 2.4, 2.4, 2.4, 2.4, 1.8, 2.4, 2.4, 2.4, 2.4, 2.4, 2.6, 2.6, 2.6, 2.8, 2.8, 2.8] },
  pantothenic_mg: { kind: "AI", values: [2, 3, 4, 5, 5, 5, 5, 5, 4, 5, 5, 5, 5, 5, 6, 6, 6, 7, 7, 7] },
  biotin_ug:      { kind: "AI", values: [8, 12, 20, 25, 30, 30, 30, 30, 20, 25, 30, 30, 30, 30, 30, 30, 30, 35, 35, 35] },
  choline_mg:     { kind: "AI", values: [200, 250, 375, 550, 550, 550, 550, 550, 375, 400, 425, 425, 425, 425, 450, 450, 450, 550, 550, 550] },

  calcium_mg:     { kind: "RDA", values: [700, 1000, 1300, 1300, 1000, 1000, 1000, 1200, 1300, 1300, 1000, 1000, 1200, 1200, 1300, 1000, 1000, 1300, 1000, 1000] },
  copper_mg:      { kind: "RDA", values: [0.34, 0.44, 0.7, 0.89, 0.9, 0.9, 0.9, 0.9, 0.7, 0.89, 0.9, 0.9, 0.9, 0.9, 1.0, 1.0, 1.0, 1.3, 1.3, 1.3] },
  iodine_ug:      { kind: "RDA", values: [90, 90, 120, 150, 150, 150, 150, 150, 120, 150, 150, 150, 150, 150, 220, 220, 220, 290, 290, 290] },
  iron_mg:        { kind: "RDA", values: [7, 10, 8, 11, 8, 8, 8, 8, 8, 15, 18, 18, 8, 8, 27, 27, 27, 10, 9, 9] },
  magnesium_mg:   { kind: "RDA", values: [80, 130, 240, 410, 400, 420, 420, 420, 240, 360, 310, 320, 320, 320, 400, 350, 360, 360, 310, 320] },
  manganese_mg:   { kind: "AI", values: [1.2, 1.5, 1.9, 2.2, 2.3, 2.3, 2.3, 2.3, 1.6, 1.6, 1.8, 1.8, 1.8, 1.8, 2.0, 2.0, 2.0, 2.6, 2.6, 2.6] },
  phosphorus_mg:  { kind: "RDA", values: [460, 500, 1250, 1250, 700, 700, 700, 700, 1250, 1250, 700, 700, 700, 700, 1250, 700, 700, 1250, 700, 700] },
  selenium_ug:    { kind: "RDA", values: [20, 30, 40, 55, 55, 55, 55, 55, 40, 55, 55, 55, 55, 55, 60, 60, 60, 70, 70, 70] },
  zinc_mg:        { kind: "RDA", values: [3, 5, 8, 11, 11, 11, 11, 11, 8, 9, 8, 8, 8, 8, 12, 11, 11, 13, 12, 12] },
  potassium_mg:   { kind: "AI", values: [2000, 2300, 2500, 3000, 3400, 3400, 3400, 3400, 2300, 2300, 2600, 2600, 2600, 2600, 2600, 2900, 2900, 2500, 2800, 2800] },
  sodium_mg:      { kind: "AI", values: [800, 1000, 1200, 1500, 1500, 1500, 1500, 1500, 1200, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500, 1500] },
};

/** 蛋白质 RDA 按体重（g/kg/天） */
export const PROTEIN_G_PER_KG: Row = [1.05, 0.95, 0.95, 0.85, 0.8, 0.8, 0.8, 0.8, 0.95, 0.85, 0.8, 0.8, 0.8, 0.8, 1.1, 1.1, 1.1, 1.3, 1.3, 1.3];

/** 可耐受最高摄入量 UL。null = 未设定。 */
export interface UpperRow {
  values: Row;
  /** 为 false 时 UL 只针对补充剂/强化剂或特定形式，食物总量不参与评分 */
  appliesToTotal: boolean;
  note?: string;
}

export const UPPER: Record<string, UpperRow> = {
  vit_a_ug:      { appliesToTotal: false, note: "UL 仅针对预制维生素 A（视黄醇），不含 β-胡萝卜素", values: [600, 900, 1700, 2800, 3000, 3000, 3000, 3000, 1700, 2800, 3000, 3000, 3000, 3000, 2800, 3000, 3000, 2800, 3000, 3000] },
  vit_c_mg:      { appliesToTotal: true, values: [400, 650, 1200, 1800, 2000, 2000, 2000, 2000, 1200, 1800, 2000, 2000, 2000, 2000, 1800, 2000, 2000, 1800, 2000, 2000] },
  vit_d_ug:      { appliesToTotal: true, values: [63, 75, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100] },
  vit_e_mg:      { appliesToTotal: false, note: "UL 仅针对补充剂/强化食品中的 α-生育酚", values: [200, 300, 600, 800, 1000, 1000, 1000, 1000, 600, 800, 1000, 1000, 1000, 1000, 800, 1000, 1000, 800, 1000, 1000] },
  niacin_mg:     { appliesToTotal: false, note: "UL 仅针对补充剂/强化食品", values: [10, 15, 20, 30, 35, 35, 35, 35, 20, 30, 35, 35, 35, 35, 30, 35, 35, 30, 35, 35] },
  vit_b6_mg:     { appliesToTotal: true, values: [30, 40, 60, 80, 100, 100, 100, 100, 60, 80, 100, 100, 100, 100, 80, 100, 100, 80, 100, 100] },
  folate_ug:     { appliesToTotal: false, note: "UL 仅针对合成叶酸（补充剂/强化食品）", values: [300, 400, 600, 800, 1000, 1000, 1000, 1000, 600, 800, 1000, 1000, 1000, 1000, 800, 1000, 1000, 800, 1000, 1000] },
  choline_mg:    { appliesToTotal: true, values: [1000, 1000, 2000, 3000, 3500, 3500, 3500, 3500, 2000, 3000, 3500, 3500, 3500, 3500, 3000, 3500, 3500, 3000, 3500, 3500] },
  calcium_mg:    { appliesToTotal: true, values: [2500, 2500, 3000, 3000, 2500, 2500, 2000, 2000, 3000, 3000, 2500, 2500, 2000, 2000, 3000, 2500, 2500, 3000, 2500, 2500] },
  copper_mg:     { appliesToTotal: true, values: [1, 3, 5, 8, 10, 10, 10, 10, 5, 8, 10, 10, 10, 10, 8, 10, 10, 8, 10, 10] },
  iodine_ug:     { appliesToTotal: true, values: [200, 300, 600, 900, 1100, 1100, 1100, 1100, 600, 900, 1100, 1100, 1100, 1100, 900, 1100, 1100, 900, 1100, 1100] },
  iron_mg:       { appliesToTotal: true, values: [40, 40, 40, 45, 45, 45, 45, 45, 40, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45] },
  magnesium_mg:  { appliesToTotal: false, note: "UL 仅针对补充剂/药物中的镁", values: [65, 110, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350, 350] },
  manganese_mg:  { appliesToTotal: true, values: [2, 3, 6, 9, 11, 11, 11, 11, 6, 9, 11, 11, 11, 11, 9, 11, 11, 9, 11, 11] },
  phosphorus_mg: { appliesToTotal: true, values: [3000, 3000, 4000, 4000, 4000, 4000, 4000, 3000, 4000, 4000, 4000, 4000, 4000, 3000, 3500, 3500, 3500, 4000, 4000, 4000] },
  selenium_ug:   { appliesToTotal: true, values: [90, 150, 280, 400, 400, 400, 400, 400, 280, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400] },
  zinc_mg:       { appliesToTotal: true, values: [7, 12, 23, 34, 40, 40, 40, 40, 23, 34, 40, 40, 40, 40, 34, 40, 40, 34, 40, 40] },
};

/** 钠：降低慢性病风险摄入量（CDRR，2019）。超过即应减少。 */
export const SODIUM_CDRR: Row = [1200, 1500, 1800, 2300, 2300, 2300, 2300, 2300, 1800, 2300, 2300, 2300, 2300, 2300, 2300, 2300, 2300, 2300, 2300, 2300];

/** 宏量营养素可接受范围 AMDR（占总能量 %） */
export interface Amdr { protein: [number, number]; carb: [number, number]; fat: [number, number]; n6: [number, number]; n3: [number, number] }

export function amdrFor(ageYears: number): Amdr {
  if (ageYears < 4) return { protein: [5, 20], carb: [45, 65], fat: [30, 40], n6: [5, 10], n3: [0.6, 1.2] };
  if (ageYears < 19) return { protein: [10, 30], carb: [45, 65], fat: [25, 35], n6: [5, 10], n3: [0.6, 1.2] };
  return { protein: [10, 35], carb: [45, 65], fat: [20, 35], n6: [5, 10], n3: [0.6, 1.2] };
}

export type Sex = "male" | "female";
export type Physiology = "none" | "pregnant" | "lactating";

export function lifeStageFor(ageYears: number, sex: Sex, physiology: Physiology = "none"): LifeStageId {
  if (ageYears < 4) return "c1_3";
  if (ageYears < 9) return "c4_8";
  if (sex === "female" && physiology !== "none" && ageYears >= 14) {
    const p = physiology === "pregnant" ? "p" : "l";
    if (ageYears < 19) return `${p}14_18` as LifeStageId;
    if (ageYears < 31) return `${p}19_30` as LifeStageId;
    return `${p}31_50` as LifeStageId;
  }
  const s = sex === "male" ? "m" : "f";
  if (ageYears < 14) return `${s}9_13` as LifeStageId;
  if (ageYears < 19) return `${s}14_18` as LifeStageId;
  if (ageYears < 31) return `${s}19_30` as LifeStageId;
  if (ageYears < 51) return `${s}31_50` as LifeStageId;
  if (ageYears < 71) return `${s}51_70` as LifeStageId;
  return `${s}71` as LifeStageId;
}

export function valueAt(row: Row, stage: LifeStageId): number | null {
  return row[IDX[stage]] ?? null;
}

export function lifeStageIndex(stage: LifeStageId): number {
  return IDX[stage];
}
