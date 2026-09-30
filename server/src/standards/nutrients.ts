// 营养素字典：系统中所有营养素的唯一定义来源。
// AI 输出、食物库、评分引擎和前端展示都使用这里的 key。

export type NutrientGroup =
  | "energy"
  | "macro"
  | "carb"
  | "fat"
  | "mineral"
  | "vitamin"
  | "other";

export interface NutrientDef {
  key: string;
  zh: string;
  en: string;
  unit: string;
  group: NutrientGroup;
  decimals: number;
  /** FDA 营养标签每日参考值（Daily Value，成人及 4 岁以上儿童，2016 新规） */
  dv?: number;
  /** 简短说明，前端悬浮提示用 */
  note?: string;
}

export const NUTRIENTS: NutrientDef[] = [
  { key: "energy_kcal", zh: "能量", en: "Energy", unit: "kcal", group: "energy", decimals: 0 },

  { key: "protein_g", zh: "蛋白质", en: "Protein", unit: "g", group: "macro", decimals: 1, dv: 50 },
  { key: "carb_g", zh: "碳水化合物", en: "Carbohydrate", unit: "g", group: "macro", decimals: 1, dv: 275 },
  { key: "fat_g", zh: "总脂肪", en: "Total fat", unit: "g", group: "macro", decimals: 1, dv: 78 },
  { key: "water_g", zh: "水分(食物+饮品)", en: "Total water", unit: "g", group: "macro", decimals: 0, note: "包含食物本身水分与饮品" },

  { key: "fiber_g", zh: "膳食纤维", en: "Dietary fiber", unit: "g", group: "carb", decimals: 1, dv: 28 },
  { key: "sugars_g", zh: "总糖", en: "Total sugars", unit: "g", group: "carb", decimals: 1 },
  { key: "added_sugars_g", zh: "添加糖", en: "Added sugars", unit: "g", group: "carb", decimals: 1, dv: 50, note: "加工/烹饪时额外加入的糖、糖浆、蜂蜜、浓缩果汁中的糖" },

  { key: "sat_fat_g", zh: "饱和脂肪", en: "Saturated fat", unit: "g", group: "fat", decimals: 1, dv: 20 },
  { key: "trans_fat_g", zh: "反式脂肪", en: "Trans fat", unit: "g", group: "fat", decimals: 2 },
  { key: "mufa_g", zh: "单不饱和脂肪", en: "MUFA", unit: "g", group: "fat", decimals: 1 },
  { key: "pufa_g", zh: "多不饱和脂肪", en: "PUFA", unit: "g", group: "fat", decimals: 1 },
  { key: "linoleic_g", zh: "亚油酸 (ω-6)", en: "Linoleic acid", unit: "g", group: "fat", decimals: 1 },
  { key: "ala_g", zh: "α-亚麻酸 (ω-3)", en: "α-Linolenic acid", unit: "g", group: "fat", decimals: 2 },
  { key: "epa_dha_g", zh: "EPA+DHA (ω-3)", en: "EPA+DHA", unit: "g", group: "fat", decimals: 2, note: "主要来自鱼类海产" },
  { key: "cholesterol_mg", zh: "胆固醇", en: "Cholesterol", unit: "mg", group: "fat", decimals: 0, dv: 300 },

  { key: "sodium_mg", zh: "钠", en: "Sodium", unit: "mg", group: "mineral", decimals: 0, dv: 2300, note: "1 g 食盐 ≈ 393 mg 钠" },
  { key: "potassium_mg", zh: "钾", en: "Potassium", unit: "mg", group: "mineral", decimals: 0, dv: 4700 },
  { key: "calcium_mg", zh: "钙", en: "Calcium", unit: "mg", group: "mineral", decimals: 0, dv: 1300 },
  { key: "iron_mg", zh: "铁", en: "Iron", unit: "mg", group: "mineral", decimals: 1, dv: 18 },
  { key: "magnesium_mg", zh: "镁", en: "Magnesium", unit: "mg", group: "mineral", decimals: 0, dv: 420 },
  { key: "phosphorus_mg", zh: "磷", en: "Phosphorus", unit: "mg", group: "mineral", decimals: 0, dv: 1250 },
  { key: "zinc_mg", zh: "锌", en: "Zinc", unit: "mg", group: "mineral", decimals: 1, dv: 11 },
  { key: "copper_mg", zh: "铜", en: "Copper", unit: "mg", group: "mineral", decimals: 2, dv: 0.9 },
  { key: "manganese_mg", zh: "锰", en: "Manganese", unit: "mg", group: "mineral", decimals: 2, dv: 2.3 },
  { key: "selenium_ug", zh: "硒", en: "Selenium", unit: "µg", group: "mineral", decimals: 0, dv: 55 },
  { key: "iodine_ug", zh: "碘", en: "Iodine", unit: "µg", group: "mineral", decimals: 0, dv: 150 },

  { key: "vit_a_ug", zh: "维生素 A", en: "Vitamin A (RAE)", unit: "µg RAE", group: "vitamin", decimals: 0, dv: 900 },
  { key: "vit_c_mg", zh: "维生素 C", en: "Vitamin C", unit: "mg", group: "vitamin", decimals: 0, dv: 90 },
  { key: "vit_d_ug", zh: "维生素 D", en: "Vitamin D", unit: "µg", group: "vitamin", decimals: 1, dv: 20, note: "1 µg = 40 IU；日晒合成不计入" },
  { key: "vit_e_mg", zh: "维生素 E", en: "Vitamin E (α-tocopherol)", unit: "mg", group: "vitamin", decimals: 1, dv: 15 },
  { key: "vit_k_ug", zh: "维生素 K", en: "Vitamin K", unit: "µg", group: "vitamin", decimals: 0, dv: 120 },
  { key: "thiamin_mg", zh: "维生素 B1 (硫胺素)", en: "Thiamin", unit: "mg", group: "vitamin", decimals: 2, dv: 1.2 },
  { key: "riboflavin_mg", zh: "维生素 B2 (核黄素)", en: "Riboflavin", unit: "mg", group: "vitamin", decimals: 2, dv: 1.3 },
  { key: "niacin_mg", zh: "烟酸 (B3)", en: "Niacin (NE)", unit: "mg", group: "vitamin", decimals: 1, dv: 16 },
  { key: "pantothenic_mg", zh: "泛酸 (B5)", en: "Pantothenic acid", unit: "mg", group: "vitamin", decimals: 1, dv: 5 },
  { key: "vit_b6_mg", zh: "维生素 B6", en: "Vitamin B6", unit: "mg", group: "vitamin", decimals: 2, dv: 1.7 },
  { key: "biotin_ug", zh: "生物素 (B7)", en: "Biotin", unit: "µg", group: "vitamin", decimals: 0, dv: 30 },
  { key: "folate_ug", zh: "叶酸 (B9)", en: "Folate (DFE)", unit: "µg DFE", group: "vitamin", decimals: 0, dv: 400 },
  { key: "vit_b12_ug", zh: "维生素 B12", en: "Vitamin B12", unit: "µg", group: "vitamin", decimals: 2, dv: 2.4 },
  { key: "choline_mg", zh: "胆碱", en: "Choline", unit: "mg", group: "vitamin", decimals: 0, dv: 550 },

  { key: "caffeine_mg", zh: "咖啡因", en: "Caffeine", unit: "mg", group: "other", decimals: 0 },
  { key: "alcohol_g", zh: "酒精", en: "Alcohol", unit: "g", group: "other", decimals: 1, note: "1 标准杯 = 14 g 纯酒精" },
];

export const NUTRIENT_KEYS = NUTRIENTS.map((n) => n.key);
export const NUTRIENT_MAP: Record<string, NutrientDef> = Object.fromEntries(
  NUTRIENTS.map((n) => [n.key, n]),
);

// 食物组当量：用于 HEI-2020 膳食质量指数以及肉类/海产等周度评估。
// 单位遵循 USDA FPED（Food Patterns Equivalents Database）。
export interface FoodGroupDef {
  key: string;
  zh: string;
  unit: string;
  note: string;
}

export const FOOD_GROUPS: FoodGroupDef[] = [
  { key: "fruit_total_cup", zh: "水果总量", unit: "杯当量", note: "1 杯当量 ≈ 1 杯切块水果 / ½ 杯果干 / 1 杯 100% 果汁" },
  { key: "fruit_whole_cup", zh: "完整水果", unit: "杯当量", note: "不含果汁的水果部分" },
  { key: "veg_total_cup", zh: "蔬菜总量", unit: "杯当量", note: "1 杯当量 ≈ 1 杯生/熟蔬菜 或 2 杯生绿叶菜；不含豆类（豆类单独计）" },
  { key: "veg_dark_green_cup", zh: "深绿色蔬菜", unit: "杯当量", note: "菠菜、西兰花、油菜、空心菜等（是蔬菜总量的一部分）" },
  { key: "legumes_cup", zh: "豆类(干豆/豌豆/扁豆)", unit: "杯当量", note: "煮熟的干豆类；豆腐等大豆制品计入植物蛋白" },
  { key: "grains_whole_oz", zh: "全谷物", unit: "盎司当量", note: "1 盎司当量 ≈ 1 片面包 / ½ 杯熟米饭或面条 (~28g 干重)" },
  { key: "grains_refined_oz", zh: "精制谷物", unit: "盎司当量", note: "白米、白面、米粉、面条等" },
  { key: "dairy_cup", zh: "奶及奶制品", unit: "杯当量", note: "1 杯牛奶/酸奶 或 1.5 盎司奶酪；含强化豆奶" },
  { key: "protein_total_oz", zh: "蛋白质食物总量", unit: "盎司当量", note: "1 盎司肉鱼禽 / 1 个蛋 / ½ 盎司坚果 / ¼ 杯豆类" },
  { key: "seafood_oz", zh: "海产品", unit: "盎司当量", note: "鱼、虾、贝类等" },
  { key: "plant_protein_oz", zh: "植物蛋白(坚果/种子/大豆/豆类)", unit: "盎司当量", note: "坚果、种子、豆腐、豆干、豆类" },
  { key: "red_meat_g", zh: "红肉(熟重)", unit: "g", note: "猪、牛、羊等哺乳动物肌肉，不含加工肉" },
  { key: "processed_meat_g", zh: "加工肉", unit: "g", note: "培根、火腿、香肠、腊肉、午餐肉、肉干等腌/熏/发酵肉" },
  { key: "poultry_g", zh: "禽肉", unit: "g", note: "鸡、鸭、鹅等" },
];

export const FOOD_GROUP_KEYS = FOOD_GROUPS.map((g) => g.key);

export type NutrientVector = Record<string, number>;

export function emptyVector(keys: string[]): NutrientVector {
  return Object.fromEntries(keys.map((k) => [k, 0]));
}

/** 把任意输入清洗为只包含已知 key 的非负数值向量 */
export function sanitizeVector(input: unknown, keys: string[]): NutrientVector {
  const out = emptyVector(keys);
  if (input && typeof input === "object") {
    for (const k of keys) {
      const v = Number((input as Record<string, unknown>)[k]);
      out[k] = Number.isFinite(v) && v > 0 ? v : 0;
    }
  }
  return out;
}

export function addVectors(a: NutrientVector, b: NutrientVector, factor = 1): NutrientVector {
  const out: NutrientVector = { ...a };
  for (const [k, v] of Object.entries(b)) out[k] = (out[k] ?? 0) + v * factor;
  return out;
}

export function scaleVector(a: NutrientVector, factor: number): NutrientVector {
  return Object.fromEntries(Object.entries(a).map(([k, v]) => [k, v * factor]));
}
