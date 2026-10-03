// 能量需求与消耗模型。
// - BMR：Mifflin-St Jeor (1990)
// - EER：NASEM 2023 DRI for Energy（成人 19 岁以上，按体力活动水平分 4 档）
// - 1 kg 体重变化 ≈ 7700 kcal（经验值，用于趋势对照）

import type { Sex } from "./dri.ts";

export type ActivityLevel = "inactive" | "low_active" | "active" | "very_active";

export const ACTIVITY_LEVELS: { key: ActivityLevel; zh: string; pal: number; desc: string }[] = [
  { key: "inactive", zh: "久坐", pal: 1.4, desc: "办公室工作，几乎不运动（PAL 1.0–1.53）" },
  { key: "low_active", zh: "轻度活动", pal: 1.6, desc: "每天步行约 30–60 分钟或少量运动（PAL 1.53–1.68）" },
  { key: "active", zh: "活跃", pal: 1.75, desc: "每天中等强度运动约 1 小时（PAL 1.68–1.85）" },
  { key: "very_active", zh: "非常活跃", pal: 2.05, desc: "体力劳动或每天高强度训练（PAL 1.85–2.5）" },
];

export const KCAL_PER_KG = 7700;

export function bmrMifflin(sex: Sex, weightKg: number, heightCm: number, age: number): number {
  return 10 * weightKg + 6.25 * heightCm - 5 * age + (sex === "male" ? 5 : -161);
}

// NASEM 2023 成人 EER 系数：[截距, 年龄, 身高 cm, 体重 kg]
const EER_COEF: Record<Sex, Record<ActivityLevel, [number, number, number, number]>> = {
  male: {
    inactive: [753.07, -10.83, 6.5, 14.1],
    low_active: [581.47, -10.83, 8.3, 14.94],
    active: [1004.82, -10.83, 6.52, 15.91],
    very_active: [-517.88, -10.83, 15.61, 19.11],
  },
  female: {
    inactive: [584.9, -7.01, 5.72, 11.71],
    low_active: [575.77, -7.01, 6.6, 12.14],
    active: [710.25, -7.01, 6.54, 12.34],
    very_active: [511.83, -7.01, 9.07, 12.56],
  },
};

export function eer(
  sex: Sex,
  level: ActivityLevel,
  weightKg: number,
  heightCm: number,
  age: number,
  physiology: "none" | "pregnant" | "lactating" = "none",
): { kcal: number; method: string } {
  let kcal: number;
  let method: string;
  if (age >= 19) {
    const [a, b, c, d] = EER_COEF[sex][level];
    kcal = a + b * age + c * heightCm + d * weightKg;
    method = "NASEM 2023 EER";
  } else {
    // 未成年人：用 Mifflin × PAL 近似（NASEM 儿童方程含生长能量，此处简化）
    const pal = ACTIVITY_LEVELS.find((l) => l.key === level)!.pal;
    kcal = bmrMifflin(sex, weightKg, heightCm, age) * pal;
    method = "Mifflin-St Jeor × PAL（未成年人近似）";
  }
  if (physiology === "pregnant") {
    kcal += 340; // 孕中期典型增量；孕早期几乎不需增加、孕晚期约 +450
    method += " + 孕期增量";
  } else if (physiology === "lactating") {
    kcal += 330;
    method += " + 哺乳期增量";
  }
  return { kcal, method };
}

/** 步数 → 净活动消耗（无手机活动能量时使用）。步长 ≈ 身高 × 0.414；步行净能耗 ≈ 0.5 kcal/kg/km */
export function stepsNetKcal(steps: number, heightCm: number, weightKg: number): number {
  const km = (steps * heightCm * 0.414) / 100_000;
  return km * weightKg * 0.5;
}

export function bmiOf(weightKg: number, heightCm: number): number {
  const m = heightCm / 100;
  return weightKg / (m * m);
}

export function bmiCategory(bmi: number): { key: string; zh: string } {
  if (bmi < 18.5) return { key: "under", zh: "偏瘦" };
  if (bmi < 25) return { key: "normal", zh: "正常" };
  if (bmi < 30) return { key: "over", zh: "超重" };
  return { key: "obese", zh: "肥胖" };
}
