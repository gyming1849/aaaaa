import type { NutrientVector } from "../standards/nutrients.ts";
import type { CompositeScore } from "./composite.ts";

export interface HazardEntry {
  key: string;
  /** 与该风险相关的食物量（单位见 hazard 定义） */
  amount: number;
  note?: string;
}

export interface ItemRecord {
  id?: number;
  meal_id?: number;
  name: string;
  amount_g: number;
  nutrients: NutrientVector;
  groups: NutrientVector;
  hazards: HazardEntry[];
  nova_group: number | null;
  category?: string | null;
}

export interface MealRecord {
  id: number;
  meal_type: string;
  time: string;
  items: ItemRecord[];
}

export interface ActivityRecord {
  steps: number | null;
  active_kcal: number | null;
  resting_kcal: number | null;
  distance_km: number | null;
  exercise_min: number | null;
  sleep_hours?: number | null;
  stand_hours?: number | null;
  source: string;
}

export interface ExerciseRecord {
  id?: number;
  description: string;
  activity_key: string | null;
  met: number;
  duration_min: number;
  kcal: number;
  in_device: boolean;
}

export interface DayData {
  date: string;
  meals: MealRecord[];
  /** 当天或之前最近一次称重，用于计算 */
  weightKg: number;
  /** 当天是否有称重记录 */
  weighedToday: number | null;
  activity: ActivityRecord | null;
  exercises: ExerciseRecord[];
}

export type Status = "good" | "ok" | "warn" | "bad" | "info";

export interface ScoreItem {
  key: string;
  /** hei = HEI-2020 组分（有官方分值）；mar = MAR 计分营养素；adequacy / moderation / energy = 只标状态的检查项 */
  category: "hei" | "mar" | "adequacy" | "moderation" | "energy";
  zh: string;
  value: number;
  unit: string;
  /** 展示用的目标描述，如 "≥ 38 g" 或 "≤ 2300 mg（理想 ≤ 1500）" */
  targetText: string;
  target?: number;
  ideal?: number;
  limit?: number;
  status: Status;
  /** 0–1 */
  score: number;
  /** 仅 HEI-2020 组分有：官方分值 */
  points: number;
  maxPoints: number;
  message: string;
  sources: string[];
}

export interface HazardResult {
  key: string;
  zh: string;
  iarc: string;
  dose: number;
  unit: string;
  foods: string[];
  message: string;
  sources: string[];
}

export interface EnergyResult {
  intake: number;
  resting: number;
  restingSource: "device" | "bmr";
  active: number;
  activeSource: "device" | "steps" | "exercise" | "none";
  exerciseKcal: number;
  tef: number;
  tdee: number;
  method: "measured" | "eer";
  target: number;
  balance: number;
}

export interface CategoryResult {
  key: "hei" | "mar";
  zh: string;
  /** 0–100 */
  score: number;
  source: string;
  note: string;
}

export interface MarResult {
  /** 0–100 */
  value: number;
  nutrients: { key: string; zh: string; intake: number; target: number; nar: number }[];
}

export interface DailyScore {
  date: string;
  hasData: boolean;
  /** 当日膳食质量 = HEI-2020 总分（0–100） */
  score: number | null;
  /** 综合总分（本站自定权重，见 composite.ts） */
  total: CompositeScore;
  categories: CategoryResult[];
  items: ScoreItem[];
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  mar: MarResult | null;
  hazards: HazardResult[];
  energy: EnergyResult;
  totals: NutrientVector;
  groups: NutrientVector;
  macroPct: { protein: number; carb: number; fat: number; satFat: number; addedSugar: number; alcohol: number };
  upfPct: number;
  mealCount: number;
  itemCount: number;
  fastFoodMeals: number;
  completeness: { level: "none" | "partial" | "likely"; note: string };
  top: { issues: string[]; wins: string[] };
  weightKg: number;
  weighedToday: number | null;
  version: number;
}
