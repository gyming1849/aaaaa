// AI 结构化输出的 JSON Schema（同时用于 Claude API 的 output_config.format 与 `claude -p --json-schema`）。
// 结构化输出要求：所有对象 additionalProperties:false，且不支持数值范围约束。

import { NUTRIENTS, FOOD_GROUPS } from "../standards/nutrients.ts";
import { AI_HAZARD_KEYS, HAZARD_MAP } from "../standards/hazards.ts";
import { ACTIVITIES } from "../standards/met.ts";

type Schema = Record<string, unknown>;

const obj = (properties: Record<string, Schema>, description?: string): Schema => ({
  type: "object",
  ...(description ? { description } : {}),
  properties,
  required: Object.keys(properties),
  additionalProperties: false,
});
const str = (description?: string): Schema => ({ type: "string", ...(description ? { description } : {}) });
const num = (description?: string): Schema => ({ type: "number", ...(description ? { description } : {}) });
const arr = (items: Schema, description?: string): Schema => ({ type: "array", items, ...(description ? { description } : {}) });

export const FOOD_CATEGORIES = [
  "staple", "vegetable", "fruit", "meat", "poultry", "seafood", "egg", "dairy", "soy_legume", "nut_seed",
  "snack", "dessert", "beverage", "alcohol", "condiment", "fast_food", "dish", "supplement", "other",
] as const;

export const nutrientsSchema = (desc: string) =>
  obj(Object.fromEntries(NUTRIENTS.map((n) => [n.key, num(`${n.en} (${n.unit})`)])), desc);

export const groupsSchema = (desc: string) =>
  obj(Object.fromEntries(FOOD_GROUPS.map((g) => [g.key, num(`${g.zh}，单位 ${g.unit}`)])), desc);

const hazardKeySchema: Schema = { type: "string", enum: AI_HAZARD_KEYS };

const sourceSchema = obj({ title: str(), url: str() });

export const mealAnalysisSchema: Schema = obj({
  items: arr(
    obj({
      name: str("食物名称（中文）"),
      matched_food_id: { anyOf: [{ type: "integer" }, { type: "null" }], description: "若使用了用户食物库中的条目，填其 id，否则 null" },
      amount_g: num("可食部分重量（g）；饮品按 ml≈g"),
      amount_desc: str("份量描述，如 1 碗 (200 g)"),
      category: { type: "string", enum: [...FOOD_CATEGORIES] },
      cooking_method: str("烹饪方式，如 生/蒸/煮/炒/炸/烤/烟熏/腌制/冲泡"),
      nova_group: { type: "integer", enum: [1, 2, 3, 4], description: "NOVA 加工程度分类" },
      confidence: { type: "string", enum: ["high", "medium", "low"] },
      nutrients: nutrientsSchema("该份量的营养素总量（不是每 100 g）"),
      food_groups: groupsSchema("该份量的 USDA 食物组当量"),
      hazards: arr(
        obj({
          key: hazardKeySchema,
          amount: num("与该风险相关的量：多数为 g；aspartame 为 mg；very_hot_beverage 为 ml"),
          note: str(),
        }),
      ),
      notes: str("估算依据/说明（中文，简短）"),
    }),
  ),
  summary: str("一句话总结这餐（中文）"),
  assumptions: arr(str(), "做出的关键假设，如份量、用油量"),
  questions: arr(str(), "如信息不足，希望用户补充的问题（可为空）"),
  sources: arr(sourceSchema, "联网查询时参考的来源"),
});

export const foodProfileSchema: Schema = obj({
  name: str("食物/产品名称（中文）"),
  brand: str("品牌，没有则空字符串"),
  aliases: arr(str(), "常见别名、英文名、口味变体，便于搜索"),
  category: { type: "string", enum: [...FOOD_CATEGORIES] },
  serving_g: num("一份（一包/一个）的重量 g"),
  serving_desc: str("份量描述，如 1 包 335 g"),
  per100g: nutrientsSchema("每 100 g（或 100 ml）的营养素"),
  groups100g: groupsSchema("每 100 g 的 USDA 食物组当量"),
  hazards: arr(
    obj({
      key: hazardKeySchema,
      amount_per_100g: num("每 100 g 食物中与该风险相关的量（g；aspartame 为 mg；very_hot_beverage 为 ml）"),
      note: str(),
    }),
  ),
  nova_group: { type: "integer", enum: [1, 2, 3, 4] },
  ingredients: str("配料表原文或概要"),
  label_fields: arr(str(), "直接从营养标签读取（而非估算）的营养素 key 列表"),
  confidence: { type: "string", enum: ["high", "medium", "low"] },
  sources: arr(sourceSchema),
  notes: str("说明：哪些数值来自标签/官网，哪些为估算"),
});

export const exerciseSchema: Schema = obj({
  items: arr(
    obj({
      description: str("活动描述（中文）"),
      activity_key: { type: "string", enum: ACTIVITIES.map((a) => a.key) },
      met: num("MET（参考 2024 Compendium）"),
      duration_min: num("持续时间（分钟）；只给距离时按合理速度推算"),
      distance_km: num("距离 km，未知填 0"),
      notes: str("推算依据"),
    }),
  ),
  assumptions: arr(str()),
});

const nullableNum = (description: string): Schema => ({ anyOf: [{ type: "number" }, { type: "null" }], description });

/** 身体与活动识别：文字（“今天走了 8000 步、游泳 5km、睡了 7 小时”）或苹果健康/手表/体脂秤截图 */
export const activitySchema: Schema = obj({
  date: { anyOf: [{ type: "string", format: "date" }, { type: "null" }], description: "截图或文字中明确显示的日期 YYYY-MM-DD；看不出来填 null" },
  steps: nullableNum("当天总步数"),
  distance_km: nullableNum("步行+跑步距离 km（英里需换算）"),
  active_kcal: nullableNum("活动能量 / 动态消耗 kcal（kJ 需换算：kcal = kJ ÷ 4.184）"),
  resting_kcal: nullableNum("静息能量 kcal；若只给“总消耗”，静息 = 总消耗 − 活动能量"),
  exercise_min: nullableNum("锻炼分钟（Apple 绿色圆环）"),
  stand_hours: nullableNum("站立小时"),
  sleep_hours: nullableNum("前一晚睡眠时长（小时，含小数）"),
  weight_kg: nullableNum("体重 kg（斤需 ÷2，磅需 ×0.4536）"),
  body_fat_pct: nullableNum("体脂率 %"),
  sbp: nullableNum("收缩压 mmHg"),
  dbp: nullableNum("舒张压 mmHg"),
  workouts: arr(
    obj({
      description: str("活动描述（中文）"),
      activity_key: { type: "string", enum: ACTIVITIES.map((a) => a.key) },
      met: num("MET（参考 2024 Compendium，可按配速/心率调整强度）"),
      duration_min: num("持续时间（分钟）；只给距离时按合理速度推算"),
      distance_km: num("距离 km，未知填 0"),
      avg_hr: nullableNum("平均心率（截图中有才填）"),
      device_kcal: nullableNum("设备显示的该次运动“活动千卡”（截图中有才填）"),
      from_device: { type: "boolean", description: "该运动是否由手表/手机记录（截图来源为 true；用户口述为 false）" },
      notes: str("识别/推算依据，不要写卡路里数字"),
    }),
  ),
  notes: str("整体说明：从哪里读到了哪些数；哪些无法识别"),
});

export const weeklySummarySchema: Schema = obj({
  headline: str("一句话标题"),
  summary: str("2–4 句总体点评"),
  wins: arr(str(), "做得好的地方"),
  issues: arr(str(), "主要问题（引用具体数据）"),
  actions: arr(str(), "下周可执行的 3–5 条具体建议"),
});

export const HAZARD_BRIEF = AI_HAZARD_KEYS.map((k) => {
  const h = HAZARD_MAP[k];
  return `- ${k}: ${h.zh}（IARC ${h.iarc}）— 判定：${h.detect}；例：${h.examples}`;
}).join("\n");
