import type { NutrientVector } from "../standards/nutrients.ts";

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
  category: "hei" | "adequacy" | "moderation" | "energy";
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
  penalty: number;
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
  key: "hei" | "adequacy" | "moderation" | "energy";
  zh: string;
  weight: number;
  /** 0–100 */
  score: number;
  points: number;
  maxPoints: number;
}

export interface DailyScore {
  date: string;
  hasData: boolean;
  score: number | null;
  grade: { key: string; zh: string } | null;
  categories: CategoryResult[];
  items: ScoreItem[];
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  hazards: HazardResult[];
  hazardPenalty: number;
  energy: EnergyResult;
  totals: NutrientVector;
  groups: NutrientVector;
  macroPct: { protein: number; carb: number; fat: number; satFat: number; addedSugar: number; alcohol: number };
  upfPct: number;
  mealCount: number;
  itemCount: number;
  completeness: { level: "none" | "partial" | "likely"; note: string };
  top: { issues: string[]; wins: string[] };
  weightKg: number;
  weighedToday: number | null;
  version: number;
}
