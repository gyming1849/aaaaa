// 离线估算器：未配置 AI 时使用的关键词匹配营养估算（精度有限，仅保证网站可用）。
// 同时用于演示数据与自动化测试。数据为 USDA FoodData Central 常见条目的近似值（每 100 g）。

import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, emptyVector, sanitizeVector, scaleVector } from "../standards/nutrients.ts";
import { ACTIVITIES, ACTIVITY_MAP } from "../standards/met.ts";

interface MockFood {
  kw: string[];
  name: string;
  serving: number;
  unit?: string;
  nova: 1 | 2 | 3 | 4;
  cat: string;
  cook?: string;
  n: Record<string, number>;
  g?: Record<string, number>;
  hz?: Record<string, number>;
}

// n 中未列出的营养素视为 0
export const MOCK_FOODS: MockFood[] = [
  { kw: ["糙米"], name: "糙米饭", serving: 200, unit: "碗", nova: 1, cat: "staple", cook: "蒸", n: { energy_kcal: 123, protein_g: 2.7, carb_g: 25.6, fat_g: 1, fiber_g: 1.6, magnesium_mg: 39, potassium_mg: 86, phosphorus_mg: 103, thiamin_mg: 0.18, niacin_mg: 2.6, vit_b6_mg: 0.12, selenium_ug: 5.8, manganese_mg: 1.0, zinc_mg: 0.7, water_g: 70 }, g: { grains_whole_oz: 1.07 } },
  { kw: ["米饭", "白饭", "大米饭"], name: "米饭", serving: 200, unit: "碗", nova: 1, cat: "staple", cook: "蒸", n: { energy_kcal: 130, protein_g: 2.7, carb_g: 28.2, fat_g: 0.3, fiber_g: 0.4, sodium_mg: 1, potassium_mg: 35, magnesium_mg: 12, phosphorus_mg: 43, iron_mg: 0.2, zinc_mg: 0.5, selenium_ug: 7.5, manganese_mg: 0.47, thiamin_mg: 0.02, niacin_mg: 0.4, water_g: 68 }, g: { grains_refined_oz: 1.07 } },
  { kw: ["炒饭"], name: "炒饭", serving: 300, unit: "盘", nova: 3, cat: "dish", cook: "炒", n: { energy_kcal: 190, protein_g: 5, carb_g: 28, fat_g: 6.5, sat_fat_g: 1.2, mufa_g: 2.5, pufa_g: 2.3, linoleic_g: 2, ala_g: 0.1, fiber_g: 0.8, sodium_mg: 450, potassium_mg: 90, cholesterol_mg: 40, choline_mg: 25, water_g: 58 }, g: { grains_refined_oz: 1.0, protein_total_oz: 0.3, veg_total_cup: 0.08 } },
  { kw: ["螺蛳粉", "螺狮粉"], name: "螺蛳粉（袋装）", serving: 335, unit: "包", nova: 4, cat: "fast_food", cook: "煮", n: { energy_kcal: 290, protein_g: 5, carb_g: 45, fat_g: 10, sat_fat_g: 3, mufa_g: 3.5, pufa_g: 3, linoleic_g: 2.6, fiber_g: 2, sugars_g: 2, added_sugars_g: 1.5, sodium_mg: 1200, potassium_mg: 120, water_g: 35 }, g: { grains_refined_oz: 2.5, veg_total_cup: 0.1, plant_protein_oz: 0.3 }, hz: { pickled_vegetables: 15 } },
  { kw: ["方便面", "泡面", "拉面"], name: "方便面", serving: 100, unit: "包", nova: 4, cat: "fast_food", cook: "冲泡", n: { energy_kcal: 450, protein_g: 9, carb_g: 60, fat_g: 20, sat_fat_g: 9, mufa_g: 7, pufa_g: 3, trans_fat_g: 0.1, fiber_g: 2.5, sodium_mg: 1800, potassium_mg: 150, iron_mg: 4, thiamin_mg: 0.6, water_g: 5 }, g: { grains_refined_oz: 3.5 } },
  { kw: ["米粉", "河粉", "米线"], name: "米粉", serving: 250, unit: "碗", nova: 2, cat: "staple", cook: "煮", n: { energy_kcal: 110, protein_g: 1.8, carb_g: 25, fat_g: 0.2, fiber_g: 1, sodium_mg: 20, water_g: 73 }, g: { grains_refined_oz: 1 } },
  { kw: ["面条", "挂面", "面"], name: "面条", serving: 250, unit: "碗", nova: 2, cat: "staple", cook: "煮", n: { energy_kcal: 138, protein_g: 4.5, carb_g: 25, fat_g: 2.1, fiber_g: 1.2, sodium_mg: 5, potassium_mg: 44, iron_mg: 1.3, thiamin_mg: 0.2, folate_ug: 60, selenium_ug: 26, water_g: 66 }, g: { grains_refined_oz: 1.4 } },
  { kw: ["饺子", "水饺"], name: "猪肉饺子", serving: 200, unit: "份(10个)", nova: 3, cat: "dish", cook: "煮", n: { energy_kcal: 220, protein_g: 9, carb_g: 25, fat_g: 9, sat_fat_g: 3, mufa_g: 3.8, pufa_g: 1.6, fiber_g: 1.2, sodium_mg: 500, potassium_mg: 150, iron_mg: 1.5, zinc_mg: 1.2, thiamin_mg: 0.25, cholesterol_mg: 25, water_g: 55 }, g: { grains_refined_oz: 1.5, red_meat_g: 15, protein_total_oz: 0.5, veg_total_cup: 0.1 } },
  { kw: ["包子"], name: "肉包子", serving: 100, unit: "个", nova: 3, cat: "dish", cook: "蒸", n: { energy_kcal: 230, protein_g: 8, carb_g: 32, fat_g: 7.5, sat_fat_g: 2.6, mufa_g: 3, pufa_g: 1.3, fiber_g: 1.3, sodium_mg: 420, potassium_mg: 130, water_g: 50 }, g: { grains_refined_oz: 2, red_meat_g: 15, protein_total_oz: 0.5 } },
  { kw: ["馒头"], name: "馒头", serving: 100, unit: "个", nova: 3, cat: "staple", cook: "蒸", n: { energy_kcal: 223, protein_g: 7, carb_g: 47, fat_g: 1.1, fiber_g: 1.3, sodium_mg: 165, potassium_mg: 138, iron_mg: 1.8, thiamin_mg: 0.04, water_g: 44 }, g: { grains_refined_oz: 3 } },
  { kw: ["全麦面包"], name: "全麦面包", serving: 60, unit: "2片", nova: 4, cat: "staple", n: { energy_kcal: 250, protein_g: 12.5, carb_g: 43, fat_g: 3.5, sat_fat_g: 0.7, fiber_g: 6, sugars_g: 4.4, added_sugars_g: 3.5, sodium_mg: 450, potassium_mg: 250, magnesium_mg: 75, iron_mg: 2.5, thiamin_mg: 0.4, niacin_mg: 4.4, selenium_ug: 25, manganese_mg: 2, water_g: 38 }, g: { grains_whole_oz: 3.5 } },
  { kw: ["面包", "吐司"], name: "白吐司", serving: 60, unit: "2片", nova: 4, cat: "staple", n: { energy_kcal: 265, protein_g: 9, carb_g: 49, fat_g: 3.2, sat_fat_g: 0.7, fiber_g: 2.7, sugars_g: 5.7, added_sugars_g: 4.5, sodium_mg: 490, potassium_mg: 115, calcium_mg: 150, iron_mg: 3.6, thiamin_mg: 0.5, riboflavin_mg: 0.3, niacin_mg: 4.4, folate_ug: 170, selenium_ug: 22, water_g: 36 }, g: { grains_refined_oz: 3.5 } },
  { kw: ["燕麦"], name: "燕麦粥", serving: 250, unit: "碗", nova: 1, cat: "staple", cook: "煮", n: { energy_kcal: 71, protein_g: 2.5, carb_g: 12, fat_g: 1.5, sat_fat_g: 0.3, fiber_g: 1.7, magnesium_mg: 27, phosphorus_mg: 77, iron_mg: 0.9, zinc_mg: 1, manganese_mg: 1, thiamin_mg: 0.08, water_g: 84 }, g: { grains_whole_oz: 0.85 } },
  { kw: ["油条"], name: "油条", serving: 80, unit: "根", nova: 3, cat: "staple", cook: "炸", n: { energy_kcal: 388, protein_g: 7, carb_g: 51, fat_g: 17.6, sat_fat_g: 3.5, mufa_g: 6, pufa_g: 7, trans_fat_g: 0.2, fiber_g: 1, sodium_mg: 585, potassium_mg: 110, water_g: 22 }, g: { grains_refined_oz: 3 }, hz: { acrylamide: 100 } },
  { kw: ["鸡蛋", "煮蛋", "荷包蛋", "蛋"], name: "鸡蛋", serving: 50, unit: "个", nova: 1, cat: "egg", cook: "煮", n: { energy_kcal: 155, protein_g: 12.6, carb_g: 1.1, fat_g: 10.6, sat_fat_g: 3.3, mufa_g: 4.1, pufa_g: 1.4, linoleic_g: 1.2, ala_g: 0.04, epa_dha_g: 0.04, cholesterol_mg: 373, sodium_mg: 124, potassium_mg: 126, calcium_mg: 50, iron_mg: 1.2, phosphorus_mg: 172, zinc_mg: 1.1, selenium_ug: 30.8, iodine_ug: 26, vit_a_ug: 149, vit_d_ug: 2.2, vit_e_mg: 1, riboflavin_mg: 0.51, vit_b12_ug: 1.1, folate_ug: 44, pantothenic_mg: 1.4, biotin_ug: 20, choline_mg: 294, water_g: 75 }, g: { protein_total_oz: 2 } },
  { kw: ["牛奶", "纯奶"], name: "牛奶", serving: 250, unit: "杯", nova: 1, cat: "dairy", n: { energy_kcal: 61, protein_g: 3.2, carb_g: 4.8, fat_g: 3.3, sat_fat_g: 1.9, mufa_g: 0.8, pufa_g: 0.2, sugars_g: 5, cholesterol_mg: 10, sodium_mg: 43, potassium_mg: 132, calcium_mg: 113, phosphorus_mg: 84, magnesium_mg: 10, zinc_mg: 0.4, iodine_ug: 56, vit_a_ug: 46, vit_d_ug: 1.1, riboflavin_mg: 0.17, vit_b12_ug: 0.45, pantothenic_mg: 0.37, choline_mg: 14, water_g: 88 }, g: { dairy_cup: 0.41 } },
  { kw: ["酸奶"], name: "酸奶（加糖）", serving: 200, unit: "杯", nova: 4, cat: "dairy", n: { energy_kcal: 95, protein_g: 3.5, carb_g: 15, fat_g: 2.7, sat_fat_g: 1.7, sugars_g: 14, added_sugars_g: 8, sodium_mg: 50, potassium_mg: 150, calcium_mg: 120, phosphorus_mg: 95, riboflavin_mg: 0.18, vit_b12_ug: 0.4, water_g: 78 }, g: { dairy_cup: 0.41 } },
  { kw: ["豆浆"], name: "豆浆（无糖）", serving: 250, unit: "杯", nova: 1, cat: "soy_legume", n: { energy_kcal: 33, protein_g: 3, carb_g: 1.5, fat_g: 1.6, sat_fat_g: 0.2, pufa_g: 0.9, linoleic_g: 0.8, ala_g: 0.1, fiber_g: 0.3, potassium_mg: 120, calcium_mg: 10, magnesium_mg: 15, iron_mg: 0.5, water_g: 93 }, g: { plant_protein_oz: 0.25 } },
  { kw: ["豆腐", "豆干"], name: "豆腐", serving: 150, unit: "份", nova: 1, cat: "soy_legume", n: { energy_kcal: 76, protein_g: 8, carb_g: 1.9, fat_g: 4.8, sat_fat_g: 0.7, mufa_g: 1.1, pufa_g: 2.7, linoleic_g: 2.4, ala_g: 0.3, fiber_g: 0.3, sodium_mg: 7, potassium_mg: 121, calcium_mg: 350, iron_mg: 5.4, magnesium_mg: 30, phosphorus_mg: 97, zinc_mg: 0.8, selenium_ug: 9, manganese_mg: 0.6, water_g: 85 }, g: { plant_protein_oz: 1.6 } },
  { kw: ["鸡胸"], name: "鸡胸肉", serving: 150, unit: "份", nova: 1, cat: "poultry", cook: "煎", n: { energy_kcal: 165, protein_g: 31, fat_g: 3.6, sat_fat_g: 1, mufa_g: 1.2, pufa_g: 0.8, cholesterol_mg: 85, sodium_mg: 74, potassium_mg: 256, phosphorus_mg: 228, magnesium_mg: 29, zinc_mg: 1, selenium_ug: 27.6, niacin_mg: 13.7, vit_b6_mg: 0.6, vit_b12_ug: 0.3, pantothenic_mg: 1, choline_mg: 85, water_g: 65 }, g: { poultry_g: 100, protein_total_oz: 3.5 } },
  { kw: ["炸鸡", "鸡块", "鸡翅"], name: "炸鸡", serving: 200, unit: "份", nova: 4, cat: "fast_food", cook: "炸", n: { energy_kcal: 290, protein_g: 20, carb_g: 12, fat_g: 18, sat_fat_g: 4.5, mufa_g: 7.5, pufa_g: 4.5, trans_fat_g: 0.1, cholesterol_mg: 90, sodium_mg: 700, potassium_mg: 230, niacin_mg: 7, selenium_ug: 20, water_g: 48 }, g: { poultry_g: 70, protein_total_oz: 2.5, grains_refined_oz: 0.4 } },
  { kw: ["鸡", "鸭"], name: "鸡肉", serving: 150, unit: "份", nova: 1, cat: "poultry", cook: "炒", n: { energy_kcal: 200, protein_g: 26, fat_g: 10, sat_fat_g: 2.8, mufa_g: 4, pufa_g: 2.2, cholesterol_mg: 90, sodium_mg: 90, potassium_mg: 230, zinc_mg: 2, selenium_ug: 24, niacin_mg: 8, vit_b6_mg: 0.4, choline_mg: 70, water_g: 62 }, g: { poultry_g: 100, protein_total_oz: 3.5 } },
  { kw: ["培根"], name: "培根", serving: 30, unit: "2片", nova: 4, cat: "meat", cook: "煎", n: { energy_kcal: 541, protein_g: 37, carb_g: 1.4, fat_g: 42, sat_fat_g: 14, mufa_g: 18.5, pufa_g: 4.5, cholesterol_mg: 110, sodium_mg: 1717, potassium_mg: 565, zinc_mg: 3.5, selenium_ug: 62, thiamin_mg: 0.4, niacin_mg: 11, vit_b12_ug: 1.2, choline_mg: 120, water_g: 12 }, g: { processed_meat_g: 100, protein_total_oz: 3.5 } },
  { kw: ["腊肉", "腊肠", "香肠", "火腿", "午餐肉"], name: "腊肉/香肠", serving: 50, unit: "份", nova: 4, cat: "meat", cook: "蒸", n: { energy_kcal: 450, protein_g: 18, carb_g: 8, fat_g: 38, sat_fat_g: 14, mufa_g: 17, pufa_g: 5, sugars_g: 8, added_sugars_g: 7, cholesterol_mg: 90, sodium_mg: 1400, potassium_mg: 300, zinc_mg: 2.5, thiamin_mg: 0.5, water_g: 30 }, g: { processed_meat_g: 100, protein_total_oz: 3.5 }, hz: { smoked_food: 60 } },
  { kw: ["红烧肉", "五花肉"], name: "红烧肉", serving: 150, unit: "份", nova: 3, cat: "meat", cook: "炖", n: { energy_kcal: 480, protein_g: 12, carb_g: 8, fat_g: 45, sat_fat_g: 16, mufa_g: 20, pufa_g: 5, sugars_g: 6, added_sugars_g: 6, cholesterol_mg: 80, sodium_mg: 700, potassium_mg: 200, thiamin_mg: 0.4, zinc_mg: 1.5, water_g: 30 }, g: { red_meat_g: 100, protein_total_oz: 3.5 } },
  { kw: ["烤串", "烧烤", "羊肉串", "烤肉"], name: "烤肉串", serving: 30, unit: "串", nova: 3, cat: "meat", cook: "炭烤", n: { energy_kcal: 250, protein_g: 25, fat_g: 16, sat_fat_g: 7, mufa_g: 6.5, pufa_g: 1, cholesterol_mg: 90, sodium_mg: 700, potassium_mg: 310, iron_mg: 2.3, zinc_mg: 4.5, vit_b12_ug: 2.5, niacin_mg: 6, selenium_ug: 26, water_g: 55 }, g: { red_meat_g: 100, protein_total_oz: 3.5 }, hz: { high_temp_meat: 100 } },
  { kw: ["牛肉", "牛排"], name: "牛肉", serving: 150, unit: "份", nova: 1, cat: "meat", cook: "炒", n: { energy_kcal: 250, protein_g: 26, fat_g: 15, sat_fat_g: 6, mufa_g: 6.5, pufa_g: 0.5, cholesterol_mg: 90, sodium_mg: 72, potassium_mg: 318, iron_mg: 2.6, zinc_mg: 6.3, phosphorus_mg: 200, selenium_ug: 21, niacin_mg: 5.4, vit_b6_mg: 0.4, vit_b12_ug: 2.6, choline_mg: 90, water_g: 58 }, g: { red_meat_g: 100, protein_total_oz: 3.5 } },
  { kw: ["羊肉"], name: "羊肉", serving: 150, unit: "份", nova: 1, cat: "meat", cook: "炖", n: { energy_kcal: 258, protein_g: 25.6, fat_g: 16.5, sat_fat_g: 7, mufa_g: 7, pufa_g: 1.2, cholesterol_mg: 97, sodium_mg: 72, potassium_mg: 310, iron_mg: 1.9, zinc_mg: 4.5, vit_b12_ug: 2.6, niacin_mg: 6.7, water_g: 57 }, g: { red_meat_g: 100, protein_total_oz: 3.5 } },
  { kw: ["猪肉", "肉丝", "排骨", "猪"], name: "猪肉", serving: 150, unit: "份", nova: 1, cat: "meat", cook: "炒", n: { energy_kcal: 250, protein_g: 26, fat_g: 16, sat_fat_g: 5.5, mufa_g: 7, pufa_g: 1.6, cholesterol_mg: 85, sodium_mg: 60, potassium_mg: 360, iron_mg: 1, zinc_mg: 3, phosphorus_mg: 230, selenium_ug: 40, thiamin_mg: 0.8, niacin_mg: 7, vit_b6_mg: 0.5, vit_b12_ug: 0.7, choline_mg: 80, water_g: 58 }, g: { red_meat_g: 100, protein_total_oz: 3.5 } },
  { kw: ["咸鱼"], name: "咸鱼", serving: 30, unit: "份", nova: 3, cat: "seafood", cook: "蒸", n: { energy_kcal: 250, protein_g: 40, fat_g: 8, sat_fat_g: 2, sodium_mg: 5000, potassium_mg: 300, calcium_mg: 120, selenium_ug: 50, vit_b12_ug: 3, water_g: 40 }, g: { seafood_oz: 3.5 }, hz: { salted_fish_cantonese: 100 } },
  { kw: ["三文鱼", "鲑鱼"], name: "三文鱼", serving: 120, unit: "份", nova: 1, cat: "seafood", cook: "煎", n: { energy_kcal: 206, protein_g: 22, fat_g: 12, sat_fat_g: 2.5, mufa_g: 4.3, pufa_g: 4.4, epa_dha_g: 2.2, ala_g: 0.1, linoleic_g: 0.2, cholesterol_mg: 63, sodium_mg: 61, potassium_mg: 384, phosphorus_mg: 252, selenium_ug: 41, vit_d_ug: 11, vit_b12_ug: 3, vit_b6_mg: 0.6, niacin_mg: 8.5, choline_mg: 90, water_g: 62 }, g: { seafood_oz: 3.5 } },
  { kw: ["虾"], name: "虾", serving: 100, unit: "份", nova: 1, cat: "seafood", cook: "煮", n: { energy_kcal: 99, protein_g: 24, fat_g: 0.3, epa_dha_g: 0.3, cholesterol_mg: 189, sodium_mg: 111, potassium_mg: 259, calcium_mg: 70, zinc_mg: 1.6, copper_mg: 0.3, selenium_ug: 38, iodine_ug: 35, vit_b12_ug: 1.1, choline_mg: 80, water_g: 75 }, g: { seafood_oz: 3.5 } },
  { kw: ["鱼"], name: "清蒸鱼", serving: 150, unit: "份", nova: 1, cat: "seafood", cook: "蒸", n: { energy_kcal: 110, protein_g: 20, fat_g: 3, sat_fat_g: 0.7, mufa_g: 1, pufa_g: 0.9, epa_dha_g: 0.3, cholesterol_mg: 60, sodium_mg: 250, potassium_mg: 350, phosphorus_mg: 210, selenium_ug: 36, iodine_ug: 20, vit_d_ug: 2, vit_b12_ug: 1.5, water_g: 75 }, g: { seafood_oz: 3.5 } },
  { kw: ["西兰花", "西蓝花"], name: "西兰花", serving: 150, unit: "份", nova: 1, cat: "vegetable", cook: "炒", n: { energy_kcal: 35, protein_g: 2.4, carb_g: 7, fat_g: 0.4, fiber_g: 3.3, sugars_g: 1.4, sodium_mg: 41, potassium_mg: 293, calcium_mg: 40, iron_mg: 0.7, magnesium_mg: 21, vit_c_mg: 65, vit_k_ug: 141, vit_a_ug: 77, folate_ug: 108, vit_e_mg: 1.5, water_g: 89 }, g: { fruit_veg_g: 100, veg_total_cup: 0.64, veg_dark_green_cup: 0.64 } },
  { kw: ["菠菜", "青菜", "油菜", "小白菜", "空心菜", "生菜", "油麦菜", "菜心"], name: "绿叶蔬菜", serving: 150, unit: "份", nova: 1, cat: "vegetable", cook: "炒", n: { energy_kcal: 23, protein_g: 2.5, carb_g: 3.6, fat_g: 0.3, fiber_g: 2.4, sodium_mg: 70, potassium_mg: 450, calcium_mg: 130, iron_mg: 2.5, magnesium_mg: 80, vit_a_ug: 300, vit_c_mg: 20, vit_k_ug: 300, folate_ug: 150, vit_e_mg: 2, water_g: 91 }, g: { fruit_veg_g: 100, veg_total_cup: 0.56, veg_dark_green_cup: 0.56 } },
  { kw: ["番茄", "西红柿"], name: "番茄", serving: 150, unit: "个", nova: 1, cat: "vegetable", n: { energy_kcal: 18, protein_g: 0.9, carb_g: 3.9, fiber_g: 1.2, sugars_g: 2.6, potassium_mg: 237, vit_c_mg: 14, vit_a_ug: 42, vit_k_ug: 8, folate_ug: 15, water_g: 94 }, g: { fruit_veg_g: 100, veg_total_cup: 0.56 } },
  { kw: ["黄瓜"], name: "黄瓜", serving: 150, unit: "根", nova: 1, cat: "vegetable", n: { energy_kcal: 15, protein_g: 0.7, carb_g: 3.6, fiber_g: 0.5, potassium_mg: 147, vit_k_ug: 16, water_g: 95 }, g: { fruit_veg_g: 100, veg_total_cup: 0.96 } },
  { kw: ["薯条"], name: "薯条", serving: 117, unit: "中份", nova: 4, cat: "fast_food", cook: "炸", n: { energy_kcal: 312, protein_g: 3.4, carb_g: 41, fat_g: 15, sat_fat_g: 2.3, mufa_g: 8, pufa_g: 4, fiber_g: 3.8, sodium_mg: 210, potassium_mg: 579, vit_c_mg: 5, vit_b6_mg: 0.4, water_g: 38 }, g: { veg_total_cup: 0.3 }, hz: { acrylamide: 100 } },
  { kw: ["薯片"], name: "薯片", serving: 40, unit: "小包", nova: 4, cat: "snack", cook: "炸", n: { energy_kcal: 536, protein_g: 7, carb_g: 53, fat_g: 35, sat_fat_g: 3.1, mufa_g: 10, pufa_g: 19, fiber_g: 4.4, sodium_mg: 525, potassium_mg: 1275, vit_c_mg: 20, vit_e_mg: 5, water_g: 2 }, g: { veg_total_cup: 0.4 }, hz: { acrylamide: 100 } },
  { kw: ["土豆", "马铃薯"], name: "土豆", serving: 150, unit: "份", nova: 1, cat: "vegetable", cook: "炒", n: { energy_kcal: 87, protein_g: 1.9, carb_g: 20, fiber_g: 1.8, potassium_mg: 379, vit_c_mg: 13, vit_b6_mg: 0.3, magnesium_mg: 22, water_g: 77 }, g: { veg_total_cup: 0.64 } },
  { kw: ["苹果"], name: "苹果", serving: 180, unit: "个", nova: 1, cat: "fruit", n: { energy_kcal: 52, protein_g: 0.3, carb_g: 14, fiber_g: 2.4, sugars_g: 10, potassium_mg: 107, vit_c_mg: 4.6, vit_k_ug: 2.2, water_g: 86 }, g: { fruit_veg_g: 100, fruit_total_cup: 0.8, fruit_whole_cup: 0.8 } },
  { kw: ["香蕉"], name: "香蕉", serving: 120, unit: "根", nova: 1, cat: "fruit", n: { energy_kcal: 89, protein_g: 1.1, carb_g: 23, fiber_g: 2.6, sugars_g: 12, potassium_mg: 358, magnesium_mg: 27, vit_b6_mg: 0.37, vit_c_mg: 8.7, manganese_mg: 0.27, water_g: 75 }, g: { fruit_veg_g: 100, fruit_total_cup: 0.67, fruit_whole_cup: 0.67 } },
  { kw: ["橙", "橘"], name: "橙子", serving: 150, unit: "个", nova: 1, cat: "fruit", n: { energy_kcal: 47, protein_g: 0.9, carb_g: 12, fiber_g: 2.4, sugars_g: 9.4, potassium_mg: 181, calcium_mg: 40, vit_c_mg: 53, folate_ug: 30, thiamin_mg: 0.09, water_g: 87 }, g: { fruit_veg_g: 100, fruit_total_cup: 0.55, fruit_whole_cup: 0.55 } },
  { kw: ["坚果", "花生", "核桃", "杏仁", "腰果"], name: "坚果", serving: 30, unit: "小把", nova: 1, cat: "nut_seed", n: { energy_kcal: 600, protein_g: 20, carb_g: 20, fat_g: 52, sat_fat_g: 7, mufa_g: 28, pufa_g: 13, linoleic_g: 12, ala_g: 0.5, fiber_g: 8, magnesium_mg: 200, potassium_mg: 600, phosphorus_mg: 450, zinc_mg: 3, copper_mg: 1.2, manganese_mg: 2, vit_e_mg: 10, niacin_mg: 5, folate_ug: 60, water_g: 3 }, g: { nuts_g: 100, plant_protein_oz: 7 } },
  { kw: ["零度", "无糖可乐", "健怡"], name: "无糖可乐", serving: 330, unit: "罐", nova: 4, cat: "beverage", n: { energy_kcal: 0.4, sodium_mg: 12, caffeine_mg: 9.6, water_g: 99 }, hz: { aspartame: 40 } },
  { kw: ["可乐", "雪碧", "汽水", "饮料"], name: "含糖汽水", serving: 330, unit: "罐", nova: 4, cat: "beverage", n: { energy_kcal: 42, carb_g: 10.6, sugars_g: 10.6, added_sugars_g: 10.6, sodium_mg: 4, caffeine_mg: 9.6, water_g: 89 }, g: { ssb_ml: 100 } },
  { kw: ["奶茶"], name: "奶茶", serving: 500, unit: "杯", nova: 4, cat: "beverage", n: { energy_kcal: 80, protein_g: 0.8, carb_g: 13, fat_g: 3, sat_fat_g: 2, trans_fat_g: 0.05, sugars_g: 11, added_sugars_g: 10, sodium_mg: 20, calcium_mg: 25, caffeine_mg: 10, water_g: 83 }, g: { ssb_ml: 100 } },
  { kw: ["拿铁"], name: "拿铁", serving: 350, unit: "杯", nova: 3, cat: "beverage", n: { energy_kcal: 55, protein_g: 3, carb_g: 5, fat_g: 2.7, sat_fat_g: 1.6, sugars_g: 5, calcium_mg: 110, potassium_mg: 150, riboflavin_mg: 0.15, vit_b12_ug: 0.35, caffeine_mg: 30, water_g: 88 }, g: { dairy_cup: 0.3 } },
  { kw: ["咖啡", "美式"], name: "黑咖啡", serving: 240, unit: "杯", nova: 1, cat: "beverage", n: { energy_kcal: 1, potassium_mg: 49, magnesium_mg: 3, niacin_mg: 0.2, caffeine_mg: 40, water_g: 99 } },
  { kw: ["茶"], name: "茶", serving: 300, unit: "杯", nova: 1, cat: "beverage", n: { energy_kcal: 1, potassium_mg: 37, manganese_mg: 0.2, caffeine_mg: 20, water_g: 99.7 } },
  { kw: ["啤酒"], name: "啤酒", serving: 500, unit: "瓶", nova: 3, cat: "alcohol", n: { energy_kcal: 43, protein_g: 0.5, carb_g: 3.6, potassium_mg: 27, niacin_mg: 0.5, alcohol_g: 3.9, water_g: 92 } },
  { kw: ["白酒"], name: "白酒 (52%)", serving: 50, unit: "两", nova: 3, cat: "alcohol", n: { energy_kcal: 290, alcohol_g: 41, water_g: 58 } },
  { kw: ["红酒", "葡萄酒"], name: "红酒", serving: 150, unit: "杯", nova: 3, cat: "alcohol", n: { energy_kcal: 85, carb_g: 2.6, potassium_mg: 127, alcohol_g: 10.6, water_g: 86 } },
  { kw: ["汉堡"], name: "牛肉汉堡", serving: 200, unit: "个", nova: 4, cat: "fast_food", n: { energy_kcal: 250, protein_g: 13, carb_g: 25, fat_g: 11, sat_fat_g: 4, mufa_g: 4.5, pufa_g: 1.2, trans_fat_g: 0.3, fiber_g: 1.5, sugars_g: 5, added_sugars_g: 4, cholesterol_mg: 35, sodium_mg: 500, potassium_mg: 220, calcium_mg: 80, iron_mg: 2.4, zinc_mg: 2.2, vit_b12_ug: 1, water_g: 48 }, g: { grains_refined_oz: 1.5, red_meat_g: 25, protein_total_oz: 1, veg_total_cup: 0.05 } },
  { kw: ["披萨", "比萨"], name: "披萨", serving: 200, unit: "2块", nova: 4, cat: "fast_food", cook: "烤", n: { energy_kcal: 266, protein_g: 11, carb_g: 33, fat_g: 10, sat_fat_g: 4.5, mufa_g: 2.8, pufa_g: 1.7, fiber_g: 2.3, sugars_g: 3.6, added_sugars_g: 2, cholesterol_mg: 17, sodium_mg: 600, potassium_mg: 172, calcium_mg: 190, water_g: 46 }, g: { grains_refined_oz: 2, dairy_cup: 0.2, veg_total_cup: 0.1 } },
  { kw: ["蛋糕", "甜点", "饼干", "面包圈", "甜甜圈"], name: "蛋糕/甜点", serving: 80, unit: "块", nova: 4, cat: "dessert", cook: "烤", n: { energy_kcal: 380, protein_g: 5, carb_g: 50, fat_g: 18, sat_fat_g: 8, mufa_g: 6, pufa_g: 2.5, trans_fat_g: 0.2, sugars_g: 35, added_sugars_g: 32, cholesterol_mg: 60, sodium_mg: 300, water_g: 25 }, g: { sweets_serv: 1.25, grains_refined_oz: 1.5 } },
  { kw: ["泡菜", "酸菜", "咸菜", "榨菜", "梅干菜"], name: "腌菜", serving: 30, unit: "份", nova: 3, cat: "vegetable", n: { energy_kcal: 20, protein_g: 1.2, carb_g: 3.5, fiber_g: 2, sodium_mg: 1500, potassium_mg: 150, vit_c_mg: 5, water_g: 88 }, g: { fruit_veg_g: 100, veg_total_cup: 0.5 }, hz: { pickled_vegetables: 100 } },
  { kw: ["槟榔"], name: "槟榔", serving: 10, unit: "颗", nova: 1, cat: "other", n: { energy_kcal: 200, carb_g: 40, fiber_g: 10, water_g: 40 }, hz: { areca_nut: 100 } },
  { kw: ["沙拉"], name: "蔬菜沙拉", serving: 200, unit: "份", nova: 1, cat: "vegetable", n: { energy_kcal: 20, protein_g: 1.4, carb_g: 3.5, fiber_g: 1.8, potassium_mg: 250, calcium_mg: 35, vit_a_ug: 250, vit_c_mg: 15, vit_k_ug: 100, folate_ug: 60, water_g: 94 }, g: { fruit_veg_g: 100, veg_total_cup: 1.2, veg_dark_green_cup: 0.5 } },
];

const CN_NUM: Record<string, number> = { 半: 0.5, 一: 1, 两: 2, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10 };

function parseQuantity(chunk: string, food: MockFood): { grams: number; desc: string } {
  const g = chunk.match(/(\d+(?:\.\d+)?)\s*(g|克|ml|毫升)/i);
  if (g) return { grams: Number(g[1]), desc: `${g[1]}${g[2]}` };
  const kg = chunk.match(/(\d+(?:\.\d+)?)\s*(kg|公斤|斤)/i);
  if (kg) {
    const v = Number(kg[1]) * (kg[2] === "斤" ? 500 : 1000);
    return { grams: v, desc: `${kg[1]}${kg[2]}` };
  }
  const n = chunk.match(/(\d+(?:\.\d+)?)\s*(个|碗|杯|份|包|瓶|罐|片|根|块|盘|串|两|把|颗)?/);
  if (n) {
    const count = Number(n[1]);
    return { grams: count * food.serving, desc: `${count}${n[2] ?? food.unit ?? "份"}` };
  }
  const c = chunk.match(/([半一两二三四五六七八九十])\s*(个|碗|杯|份|包|瓶|罐|片|根|块|盘|串|两|把|颗)/);
  if (c) {
    const count = CN_NUM[c[1]];
    return { grams: count * food.serving, desc: `${c[1]}${c[2]}` };
  }
  return { grams: food.serving, desc: `1${food.unit ?? "份"}（默认份量）` };
}

export interface MockItem {
  name: string;
  matched_food_id: number | null;
  amount_g: number;
  amount_desc: string;
  category: string;
  cooking_method: string;
  nova_group: number;
  confidence: string;
  nutrients: Record<string, number>;
  food_groups: Record<string, number>;
  hazards: { key: string; amount: number; note: string }[];
  notes: string;
}

export function mockAnalyzeMeal(text: string): { items: MockItem[]; summary: string; assumptions: string[]; questions: string[]; sources: { title: string; url: string }[] } {
  const chunks = text.split(/[，,、;；+\n。]|和|还有|加上|配/).map((s) => s.trim()).filter(Boolean);
  const items: MockItem[] = [];
  const unmatched: string[] = [];
  for (const chunk of chunks) {
    // 在一段描述中找出所有食物关键词（长词优先、互不重叠），如“西兰花炒牛肉”→ 西兰花 + 牛肉
    const cands: { food: MockFood; kw: string; idx: number }[] = [];
    for (const f of MOCK_FOODS) for (const k of f.kw) {
      const idx = chunk.indexOf(k);
      if (idx >= 0) cands.push({ food: f, kw: k, idx });
    }
    cands.sort((a, b) => b.kw.length - a.kw.length);
    const taken: [number, number][] = [];
    const found: MockFood[] = [];
    for (const c of cands) {
      const s = c.idx, e = c.idx + c.kw.length;
      if (taken.some(([a, b]) => s < b && e > a) || found.includes(c.food)) continue;
      taken.push([s, e]);
      found.push(c.food);
    }
    if (!found.length) {
      unmatched.push(chunk);
      continue;
    }
    for (const food of found) {
      const share = found.length > 1 ? 0.6 : 1;
      const q = parseQuantity(chunk, food);
      const grams = q.grams * share;
      const desc = share < 1 ? `${q.desc}（菜品中的一部分）` : q.desc;
      const factor = grams / 100;
      const nutrients = scaleVector(sanitizeVector(food.n, NUTRIENT_KEYS), factor);
      const stirFried = /炒|煎/.test(chunk) || food.cook === "炒";
      if (stirFried && (food.cat === "vegetable" || food.cat === "meat" || food.cat === "poultry")) {
        // 烹调油 10 g
        const oil = { energy_kcal: 88, fat_g: 10, sat_fat_g: 1.5, mufa_g: 5.5, pufa_g: 2.5, linoleic_g: 2.2, ala_g: 0.3, vit_e_mg: 1.5, vit_k_ug: 7 };
        for (const [k, v] of Object.entries(oil)) nutrients[k] = (nutrients[k] ?? 0) + v;
        nutrients.sodium_mg += 400;
      }
      items.push({
        name: food.name,
        matched_food_id: null,
        amount_g: Math.round(grams),
        amount_desc: desc,
        category: food.cat,
        cooking_method: food.cook ?? "",
        nova_group: food.nova,
        confidence: "low",
        nutrients,
        food_groups: scaleVector(sanitizeVector(food.g ?? {}, FOOD_GROUP_KEYS), factor),
        hazards: Object.entries(food.hz ?? {}).map(([key, per100]) => ({ key, amount: per100 * factor, note: "" })),
        notes: "离线关键词估算（未配置 AI），数值为同类食物平均值",
      });
    }
  }
  if (!items.length) {
    const kcal = 500;
    items.push({
      name: text.slice(0, 20) || "未识别食物",
      matched_food_id: null,
      amount_g: 300,
      amount_desc: "按一份普通餐估算",
      category: "dish",
      cooking_method: "",
      nova_group: 3,
      confidence: "low",
      nutrients: { ...emptyVector(NUTRIENT_KEYS), energy_kcal: kcal, protein_g: 20, carb_g: 60, fat_g: 18, sat_fat_g: 5, sodium_mg: 900, fiber_g: 4, water_g: 150 },
      food_groups: { ...emptyVector(FOOD_GROUP_KEYS), grains_refined_oz: 2, protein_total_oz: 2, veg_total_cup: 0.5 },
      hazards: [],
      notes: "离线模式无法识别，按普通一餐粗略估算",
    });
  }
  return {
    items,
    summary: `离线估算：识别出 ${items.length} 种食物`,
    assumptions: ["当前未配置 AI（Claude），使用内置关键词表粗略估算；配置后可获得精确分解与联网查询"],
    questions: unmatched.length ? [`以下内容未识别：${unmatched.join("、")}`] : [],
    sources: [],
  };
}

export function mockParseExercise(text: string): { items: { description: string; activity_key: string; met: number; duration_min: number; distance_km: number; notes: string }[]; assumptions: string[] } {
  const rules: [RegExp, string][] = [
    [/蝶泳/, "swim_butterfly"], [/蛙泳/, "swim_breaststroke"], [/仰泳/, "swim_backstroke"], [/游泳|自由泳/, "swim_freestyle_medium"],
    [/慢跑/, "jogging"], [/跑/, "run_10kmh"], [/快走|健走/, "walk_brisk"], [/散步|走路|步行/, "walk_moderate"],
    [/骑|单车/, "cycle_moderate"], [/爬山|徒步/, "hiking"], [/楼梯/, "stairs"], [/跳绳/, "jump_rope"],
    [/篮球/, "basketball"], [/足球/, "soccer"], [/羽毛球/, "badminton"], [/网球/, "tennis_singles"], [/乒乓/, "table_tennis"],
    [/瑜伽/, "yoga"], [/普拉提/, "pilates"], [/力量|举铁|撸铁|健身/, "strength_moderate"], [/hiit|HIIT|间歇/, "hiit"],
    [/椭圆/, "elliptical"], [/划船/, "rowing_machine"], [/跳舞|舞/, "dance_social"], [/家务|打扫/, "housework"],
  ];
  const chunks = text.split(/[，,、;；+\n。]|和|然后/).map((s) => s.trim()).filter(Boolean);
  const items = [];
  for (const c of chunks) {
    const rule = rules.find(([re]) => re.test(c));
    const act = ACTIVITY_MAP[rule ? rule[1] : "other_moderate"];
    const km = c.match(/(\d+(?:\.\d+)?)\s*(km|公里|千米)/i);
    const m = c.match(/(\d+(?:\.\d+)?)\s*(m|米)(?!in)/i);
    const hours = c.match(/(\d+(?:\.\d+)?)\s*(小时|h)/i);
    const mins = c.match(/(\d+(?:\.\d+)?)\s*(分钟|min)/i);
    let distance = km ? Number(km[1]) : m ? Number(m[1]) / 1000 : 0;
    let duration = (hours ? Number(hours[1]) * 60 : 0) + (mins ? Number(mins[1]) : 0);
    if (/半小时/.test(c)) duration += 30;
    if (!duration && distance && act.speedKmh) duration = (distance / act.speedKmh) * 60;
    if (!duration) duration = 30;
    items.push({ description: c, activity_key: act.key, met: act.met, duration_min: Math.round(duration), distance_km: distance, notes: "离线规则估算" });
  }
  return { items, assumptions: ["离线规则估算（未配置 AI）"] };
}

export { ACTIVITIES };

/** 离线解析身体与活动描述（无法识别截图） */
export function mockParseActivity(text: string) {
  const n = (re: RegExp, i = 1) => {
    const m = text.match(re);
    return m ? Number(m[i].replace(/,/g, "")) : null;
  };
  let sleep = n(/睡了?\s*(\d+(?:\.\d+)?)\s*个?\s*半?\s*小时/);
  if (sleep != null && /睡了?\s*\d+(?:\.\d+)?\s*个?\s*半\s*小时/.test(text)) sleep += 0.5;
  let weight = n(/体重\s*(\d+(?:\.\d+)?)/);
  if (weight != null && /体重\s*\d+(?:\.\d+)?\s*斤/.test(text)) weight /= 2;
  const bp = text.match(/血压\s*(\d{2,3})\s*[/／]\s*(\d{2,3})/);
  const exerciseChunks = text
    .split(/[，,、;；\n。]/)
    .map((s) => s.trim())
    .filter((s) => s && !/步(?!行)|睡|体重|血压|体脂|活动能量|消耗/.test(s));
  const ex = exerciseChunks.length ? mockParseExercise(exerciseChunks.join("，")) : { items: [] };
  return {
    date: null,
    steps: n(/(\d[\d,]*)\s*步(?!行)/),
    distance_km: null,
    active_kcal: n(/(?:活动能量|动态消耗|活动消耗|消耗)\s*(\d+)/),
    resting_kcal: n(/静息(?:能量)?\s*(\d+)/),
    exercise_min: n(/锻炼\s*(\d+)\s*分钟/),
    stand_hours: null,
    sleep_hours: sleep,
    weight_kg: weight,
    body_fat_pct: n(/体脂(?:率)?\s*(\d+(?:\.\d+)?)/),
    sbp: bp ? Number(bp[1]) : null,
    dbp: bp ? Number(bp[2]) : null,
    workouts: ex.items.filter((w) => w.activity_key !== "other_moderate" || /运动|锻炼|训练/.test(w.description))
      .map((w) => ({ ...w, avg_hr: null, device_kcal: null, from_device: false })),
    notes: "离线规则解析（未配置 AI），无法识别截图",
  };
}
