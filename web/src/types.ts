export type Vec = Record<string, number>;
export type Status = "good" | "ok" | "warn" | "bad" | "info";

export interface User {
  id: number;
  username: string;
  display_name: string;
  avatar_color: string;
  share_mode: "private" | "public" | "selected";
  share_detail: "summary" | "full";
  api_token_hint: string | null;
  share_with: number[];
}

export interface Profile {
  sex: "male" | "female";
  birth_date: string;
  height_cm: number;
  weight_kg: number;
  activity_level: "inactive" | "low_active" | "active" | "very_active";
  goal: "lose" | "maintain" | "gain";
  goal_rate_kg_week: number;
  target_weight_kg: number | null;
  physiology: "none" | "pregnant" | "lactating";
  sodium_mode: "cdrr" | "aha";
  conditions: string[];
  timezone: string;
}

export interface Me {
  user: User;
  profile: Profile | null;
  today: string;
  ai: { provider: "cli" | "api" | "mock"; model: string };
  conditions: { key: string; zh: string; effect: string }[];
}

export interface NutrientDef { key: string; zh: string; en: string; unit: string; group: string; decimals: number; dv?: number; note?: string }
export interface FoodGroupDef { key: string; zh: string; unit: string; note: string }
export interface HazardDef {
  key: string; zh: string; en: string; iarc: string; category: string; risk: string; detect: string; examples: string;
  refAmount: number; penaltyPerRef: number; cap: number; freeAmount?: number; sensitiveMultiplier?: number; sources: string[]; advice: string;
  dose: { from: string; unit: string; key?: string };
}
export interface Source { id: string; org: string; title: string; year: string; url: string }
export interface Activity { key: string; zh: string; met: number; speedKmh?: number; intensity: string; code?: string }

export interface Meta {
  version: number;
  nutrients: NutrientDef[];
  foodGroups: FoodGroupDef[];
  hazards: HazardDef[];
  hazardsInfoOnly: { zh: string; iarc: string; examples: string; why: string }[];
  hazardTotalCap: number;
  hei: { key: string; zh: string; en: string; max: number; kind: string; best: number; worst: number; unit: string; hint: string }[];
  activities: Activity[];
  activityLevels: { key: string; zh: string; pal: number; desc: string }[];
  sources: Source[];
  lifeStages: { id: string; zh: string }[];
  categoryWeights: Record<string, { zh: string; weight: number }>;
  adequacyWeights: Record<string, number>;
  conditions: { key: string; zh: string; effect: string }[];
}

export interface ScoreItem {
  key: string; category: string; zh: string; value: number; unit: string; targetText: string;
  target?: number; ideal?: number; limit?: number; status: Status; score: number; points: number; maxPoints: number; message: string; sources: string[];
}

export interface HazardResult { key: string; zh: string; iarc: string; dose: number; unit: string; penalty: number; foods: string[]; message: string; sources: string[] }

export interface Energy {
  intake: number; resting: number; restingSource: string; active: number; activeSource: string; exerciseKcal: number;
  tef: number; tdee: number; method: string; target: number; balance: number;
}

export interface DailyScore {
  date: string;
  hasData: boolean;
  score: number | null;
  grade: { key: string; zh: string } | null;
  categories: { key: string; zh: string; weight: number; score: number; points: number; maxPoints: number }[];
  items: ScoreItem[];
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  hazards: HazardResult[];
  hazardPenalty: number;
  energy: Energy;
  totals: Vec;
  groups: Vec;
  macroPct: { protein: number; carb: number; fat: number; satFat: number; addedSugar: number; alcohol: number };
  upfPct: number;
  mealCount: number;
  itemCount: number;
  completeness: { level: string; note: string };
  top: { issues: string[]; wins: string[] };
  weightKg: number;
  weighedToday: number | null;
}

export interface Targets {
  date: string; age: number; sex: string; lifeStage: string; lifeStageZh: string; physiology: string; sensitive: boolean;
  weightKg: number; heightCm: number; bmi: number; bmiCategory: { key: string; zh: string }; referenceWeightKg: number;
  bmr: number; eer: number; eerMethod: string; goal: string; goalDeltaKcal: number; energyTarget: number; energyFloor: number;
  protein: { rdaG: number; idealLowG: number; idealHighG: number; perKgRda: number };
  intake: Record<string, { key: string; value: number; kind: string; source: string; note?: string }>;
  upper: Record<string, { value: number; appliesToTotal: boolean; note?: string }>;
  limits: Record<string, { key: string; zh: string; unit: string; ideal: number; limit: number; idealSource: string; limitSource: string; note?: string }>;
  amdr: { protein: [number, number]; carb: [number, number]; fat: [number, number] };
  addedSugarPerMealG: number;
  aspartameAdiMg: number;
}

export interface HazardEntry { key: string; amount: number; note?: string }

export interface MealItem {
  id?: number;
  name: string;
  amount_g: number;
  amount_desc?: string;
  food_id?: number | null;
  category?: string;
  cooking_method?: string;
  nova_group: number | null;
  confidence?: string;
  nutrients: Vec;
  groups: Vec;
  hazards: HazardEntry[];
  notes?: string;
}

export interface DraftItem extends MealItem {
  per100: { nutrients: Vec; groups: Vec; hazards: { key: string; amount_per_100g: number }[] };
  save_suggested: boolean;
  saved_food_id?: number;
}

export interface Meal {
  id: number; date: string; time: string; meal_type: string; description: string; photos: string[]; ai_summary: string | null; items: MealItem[];
}

export interface MealDraft {
  items: DraftItem[]; summary: string; assumptions: string[]; questions: string[]; sources: { title: string; url: string }[]; provider: string; model: string;
}

export interface ActivityDay { date: string; steps: number | null; active_kcal: number | null; resting_kcal: number | null; distance_km: number | null; exercise_min: number | null; source: string }
export interface Exercise { id: number; date: string; time: string; description: string; activity_key: string | null; met: number; duration_min: number; distance_km: number | null; kcal: number; in_device: number; source: string }
export interface BodyMetric { id: number; date: string; time: string; weight_kg: number | null; body_fat_pct: number | null; waist_cm: number | null; note: string | null; source: string }

export interface DayResponse {
  date: string; score: DailyScore; targets: Targets; meals: Meal[]; activity: ActivityDay | null; exercises: Exercise[]; body: BodyMetric[]; weightTrend: number | null; full: boolean;
}

export interface TrendDay {
  date: string; hasData: boolean; score: number | null; grade: string | null; categories: Record<string, number>; hazardPenalty: number; hei: number | null;
  intake: number; tdee: number; target: number; exerciseKcal: number; energyMethod: string; weight: number | null; trend: number | null;
  steps: number | null; activeKcal: number | null; completeness: string; totals: Vec; groups: Vec; macroPct: Record<string, number>; upfPct: number;
  statuses: Record<string, Status>;
}

export interface PeriodCheck { key: string; zh: string; value: number; unit: string; targetText: string; status: Status; score: number; weight: number; message: string; sources: string[] }

export interface PeriodScore {
  start: string; end: string; days: number; daysLogged: number; avgScore: number | null; lifestyleScore: number; score: number | null;
  grade: { key: string; zh: string } | null;
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  avgTotals: Vec; avgGroups: Vec;
  itemStats: { key: string; zh: string; category: string; good: number; ok: number; warn: number; bad: number; days: number }[];
  checks: PeriodCheck[];
  hazards: { key: string; zh: string; iarc: string; dose: number; unit: string; penalty: number; days: number }[];
  energy: { avgIntake: number | null; avgTdee: number; totalBalance: number; predictedChangeKg: number; trendStart: number | null; trendEnd: number | null; actualChangeKg: number | null; empiricalTdee: number | null; ratePerWeek: number | null };
  series: { date: string; score: number | null; intake: number; tdee: number; weight: number | null; trend: number | null }[];
  aiSummary: { headline: string; summary: string; wins: string[]; issues: string[]; actions: string[] } | null;
  full: boolean;
}

export interface Food {
  id: number; owner_id: number; owner_name: string; visibility: "private" | "public"; name: string; brand: string | null; aliases: string;
  category: string | null; serving_g: number | null; serving_desc: string | null; per100: Vec; groups100: Vec;
  hazards100: { key: string; amount_per_100g: number; note?: string }[]; nova_group: number | null; ingredients: string | null;
  label_fields: string[]; source: string; source_urls: { title: string; url: string }[]; notes: string | null; use_count: number; mine: boolean; updated_at: string;
}

export interface FoodDraft {
  name: string; brand: string; aliases: string[]; category: string; serving_g: number; serving_desc: string; per100: Vec; groups100: Vec;
  hazards100: { key: string; amount_per_100g: number; note: string }[]; nova_group: number | null; ingredients: string; label_fields: string[];
  confidence: string; sources: { title: string; url: string }[]; notes: string; source: string; provider: string;
}

export interface CommunityUser {
  id: number; username: string; display_name: string; avatar_color: string; is_me: boolean; shared_with_me: boolean;
  share_detail: "full" | "summary" | "none"; last_log_date: string | null; streak: number; recent: { date: string; score: number | null }[];
}
