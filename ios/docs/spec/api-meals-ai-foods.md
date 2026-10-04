# NutriLog API spec: meals, photo uploads, AI jobs, food library, preview

Audience: an iOS (SwiftUI) engineer who will not read the server's TypeScript. Everything here was derived by reading the server source in `aaaaa/server/src` (mainly `routes/log.ts`, `routes/body.ts` for `/preview`, `routes/reports.ts` for `/day/{date}`, `ai/jobs.ts`, `ai/schema.ts`, `ai/service.ts`, `ai/providers.ts`, `standards/nutrients.ts`, `standards/hazards.ts`, `services/userdata.ts`, `lib/http.ts`, `auth.ts`, `index.ts`) and the web client (`web/src/pages/LogMeal.tsx`, `web/src/components/ItemEditor.tsx`, `web/src/pages/Foods.tsx`, `web/src/pages/Today.tsx`, `web/src/lib/format.ts`, `web/src/api.ts`). Field names are verbatim from code. Where the web client has client-side logic, such as gram scaling, section 4 describes it exactly so the app can behave the same way.

Server stack facts that matter for a client: Express **5**, multer **2**, SQLite. The JSON body limit is 2 MB. JSON responses carry weak ETags.

---

## 0. Conventions (read first)

### 0.1 Base URL and prefixes
- Production: `http://45.63.23.52:8787`. This is **plain HTTP to an IP literal**, which has two consequences:
  - iOS ATS blocks it unless `NSAppTransportSecurity > NSAllowsArbitraryLoads = YES`. `NSExceptionDomains` does not work for IP literals.
  - The bearer token travels in cleartext. Put HTTPS and a domain in front of the server before release.
- Every endpoint in this document is mounted under **both** `/api/v1/...` and `/api/...`. The app should use `/api/v1`.
- `GET /api/v1/health` takes no auth and returns `{"ok":true,"version":"1"}`.

### 0.2 Auth
- Every endpoint in this document requires auth. Send `Authorization: Bearer nla_...`, a token from `POST /api/v1/auth/token`. That flow is covered in another spec.
- **Cookie precedence gotcha:** the server reads the cookie `nl_session` **before** the bearer header (`token = cookie ?? bearer`). If `URLSession` has ever stored a stale `nl_session` cookie, which happens after calling `/auth/login`, or `/auth/register` without `device_name`, that cookie wins and every request returns 401 even though the bearer token is valid. Set `URLSessionConfiguration.httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never`, or use an ephemeral configuration.
- A bearer value that starts with `nl_` (a personal token, not `nla_`) is **ignored** by these endpoints. Personal tokens only work for `/health/ingest`.
- Missing or invalid auth returns `401 {"error":"未登录或令牌已失效"}`.
- Unauthenticated requests to **unknown** paths under the prefix also return **401, not 404**, because a router-level auth middleware runs first. With valid auth, an unknown path returns `404 {"error":"接口不存在"}`.

### 0.3 Request format
- JSON bodies: send `Content-Type: application/json`. **Always send a JSON object body on POST and PUT, even if it is just `{}`.** Express 5 leaves `req.body` *undefined* when no JSON is parsed, and several handlers read `req.body.x` directly: `/ai/meal`, `/ai/food`, `/ai/exercise`, `/water`, `/meals` (POST and PUT), `/foods/from-item`, `/foods/{id}/item`. Without a body those crash with `500 {"error":"服务器内部错误"}`. The web client always sends `{}` as a minimum.
- A top-level JSON value that is not an object or array, or JSON that does not parse, returns `400 {"error":"请求格式不正确"}`.
- Dates are `"YYYY-MM-DD"` and times are `"HH:MM"` (24-hour, zero-padded).
  - The server checks dates with `/^\d{4}-\d{2}-\d{2}$/` plus `Date.parse` validity.
  - Times are checked with `/^\d{2}:\d{2}$/` **only**, so `"99:99"` passes. Validate on the client.
  - On iOS, format with `Locale(identifier: "en_US_POSIX")` and the Gregorian calendar.
- The date fields in this document are the user's *local* calendar date. The server's notion of "today" uses `profile.timezone`, defaulting to `Asia/Shanghai`. `GET /auth/me` returns `today` as computed by the server, so use it for defaults.

### 0.4 Error shape
Every error body has the same shape:
```json
{ "error": "<human-readable Chinese message>" }
```
| Status | When |
|---|---|
| 400 | Validation (`bad(...)`). Messages are listed in section 5. |
| 401 | Auth missing or invalid |
| 403 | Not the owner (food library PUT and DELETE) |
| 404 | Not found, including other users' resources (the server returns 404 rather than 403 for meals and jobs) |
| 413 | Upload file > 12 MB: `{"error":"文件太大"}` |
| 500 | `{"error":"服务器内部错误"}`. Unexpected errors, including some multer errors (see 2.1). |

Show the `error` string to the user as-is. The web client does this, with fallback text `请求失败（{status}）` when there is no body.

### 0.5 Number handling
- All numbers are JSON numbers (IEEE double). Integer-valued doubles, such as `100`, may arrive with or without a decimal part. Decode as `Double` except for IDs and enums.
- The server coerces numeric strings with `Number(x)` in most places. The app should still send real numbers.
- **Never send `NaN` or `Infinity`.** Swift's `JSONEncoder` throws on them; sanitize to 0.
- Nutrient and food-group vectors are **dictionaries keyed by string**. The server always returns **every** known key, and missing or invalid inputs become `0`. Decode them as `[String: Double]` and look keys up with a default of `0`, not as a fixed struct, so a newly added nutrient key does not break decoding.

---

## 1. Shared data definitions

### 1.1 NutrientVector: 43 keys (`NUTRIENTS` in `standards/nutrients.ts`)

All amounts are for the stated portion. They are per-portion totals in meal items and per 100 g (or 100 ml) in food-library `per100`. Key order is the server's canonical display order.

- `decimals` is the number of decimals the web uses for display.
- `DV` is the FDA label Daily Value, used for the "占标签 DV" column.
- `group` values: `energy | macro | carb | fat | mineral | vitamin | other`.

| # | key | 中文 (zh) | en | unit | group | decimals | DV (FDA) | note |
|---|---|---|---|---|---|---|---|---|
| 1 | `energy_kcal` | 能量 | Energy | kcal | energy | 0 |  |  |
| 2 | `protein_g` | 蛋白质 | Protein | g | macro | 1 | 50 |  |
| 3 | `carb_g` | 碳水化合物 | Carbohydrate | g | macro | 1 | 275 |  |
| 4 | `fat_g` | 总脂肪 | Total fat | g | macro | 1 | 78 |  |
| 5 | `water_g` | 水分(食物+饮品) | Total water | g | macro | 0 |  | 包含食物本身水分与饮品 |
| 6 | `fiber_g` | 膳食纤维 | Dietary fiber | g | carb | 1 | 28 |  |
| 7 | `sugars_g` | 总糖 | Total sugars | g | carb | 1 |  |  |
| 8 | `added_sugars_g` | 添加糖 | Added sugars | g | carb | 1 | 50 | 加工/烹饪时额外加入的糖、糖浆、蜂蜜、浓缩果汁中的糖 |
| 9 | `sat_fat_g` | 饱和脂肪 | Saturated fat | g | fat | 1 | 20 |  |
| 10 | `trans_fat_g` | 反式脂肪 | Trans fat | g | fat | 2 |  |  |
| 11 | `mufa_g` | 单不饱和脂肪 | MUFA | g | fat | 1 |  |  |
| 12 | `pufa_g` | 多不饱和脂肪 | PUFA | g | fat | 1 |  |  |
| 13 | `linoleic_g` | 亚油酸 (ω-6) | Linoleic acid | g | fat | 1 |  |  |
| 14 | `ala_g` | α-亚麻酸 (ω-3) | α-Linolenic acid | g | fat | 2 |  |  |
| 15 | `epa_dha_g` | EPA+DHA (ω-3) | EPA+DHA | g | fat | 2 |  | 主要来自鱼类海产 |
| 16 | `cholesterol_mg` | 胆固醇 | Cholesterol | mg | fat | 0 | 300 |  |
| 17 | `sodium_mg` | 钠 | Sodium | mg | mineral | 0 | 2300 | 1 g 食盐 ≈ 393 mg 钠 |
| 18 | `potassium_mg` | 钾 | Potassium | mg | mineral | 0 | 4700 |  |
| 19 | `calcium_mg` | 钙 | Calcium | mg | mineral | 0 | 1300 |  |
| 20 | `iron_mg` | 铁 | Iron | mg | mineral | 1 | 18 |  |
| 21 | `magnesium_mg` | 镁 | Magnesium | mg | mineral | 0 | 420 |  |
| 22 | `phosphorus_mg` | 磷 | Phosphorus | mg | mineral | 0 | 1250 |  |
| 23 | `zinc_mg` | 锌 | Zinc | mg | mineral | 1 | 11 |  |
| 24 | `copper_mg` | 铜 | Copper | mg | mineral | 2 | 0.9 |  |
| 25 | `manganese_mg` | 锰 | Manganese | mg | mineral | 2 | 2.3 |  |
| 26 | `selenium_ug` | 硒 | Selenium | µg | mineral | 0 | 55 |  |
| 27 | `iodine_ug` | 碘 | Iodine | µg | mineral | 0 | 150 |  |
| 28 | `vit_a_ug` | 维生素 A | Vitamin A (RAE) | µg RAE | vitamin | 0 | 900 |  |
| 29 | `vit_c_mg` | 维生素 C | Vitamin C | mg | vitamin | 0 | 90 |  |
| 30 | `vit_d_ug` | 维生素 D | Vitamin D | µg | vitamin | 1 | 20 | 1 µg = 40 IU；日晒合成不计入 |
| 31 | `vit_e_mg` | 维生素 E | Vitamin E (α-tocopherol) | mg | vitamin | 1 | 15 |  |
| 32 | `vit_k_ug` | 维生素 K | Vitamin K | µg | vitamin | 0 | 120 |  |
| 33 | `thiamin_mg` | 维生素 B1 (硫胺素) | Thiamin | mg | vitamin | 2 | 1.2 |  |
| 34 | `riboflavin_mg` | 维生素 B2 (核黄素) | Riboflavin | mg | vitamin | 2 | 1.3 |  |
| 35 | `niacin_mg` | 烟酸 (B3) | Niacin (NE) | mg | vitamin | 1 | 16 |  |
| 36 | `pantothenic_mg` | 泛酸 (B5) | Pantothenic acid | mg | vitamin | 1 | 5 |  |
| 37 | `vit_b6_mg` | 维生素 B6 | Vitamin B6 | mg | vitamin | 2 | 1.7 |  |
| 38 | `biotin_ug` | 生物素 (B7) | Biotin | µg | vitamin | 0 | 30 |  |
| 39 | `folate_ug` | 叶酸 (B9) | Folate (DFE) | µg DFE | vitamin | 0 | 400 |  |
| 40 | `vit_b12_ug` | 维生素 B12 | Vitamin B12 | µg | vitamin | 2 | 2.4 |  |
| 41 | `choline_mg` | 胆碱 | Choline | mg | vitamin | 0 | 550 |  |
| 42 | `caffeine_mg` | 咖啡因 | Caffeine | mg | other | 0 |  |  |
| 43 | `alcohol_g` | 酒精 | Alcohol | g | other | 1 |  | 1 标准杯 = 14 g 纯酒精 |

Sanitization rule (`sanitizeVector`), applied everywhere server-side:
- The output has exactly these 43 keys.
- For each key, `v = Number(input[key])`. If `v` is finite and `> 0` it is kept; otherwise it becomes `0`, so negative values become `0`.
- Unknown keys are dropped.

The web's **item editor** shows this short list by default, with a "显示全部 43 项" toggle:
`energy_kcal, protein_g, carb_g, fat_g, sat_fat_g, trans_fat_g, sugars_g, added_sugars_g, fiber_g, sodium_mg, cholesterol_mg, caffeine_mg, alcohol_g`.

The web's **food-library editor** shows this per-100 g list by default:
`energy_kcal, protein_g, fat_g, sat_fat_g, trans_fat_g, carb_g, sugars_g, added_sugars_g, fiber_g, sodium_mg`.

### 1.2 FoodGroupVector: 22 keys (`FOOD_GROUPS`), USDA FPED-style equivalents

The same sanitization rule applies. Units: `杯当量` = cup-eq, `盎司当量` = oz-eq, `g`, `ml`, `份` = servings.

| # | key | 中文 (zh) | unit | note |
|---|---|---|---|---|
| 1 | `fruit_total_cup` | 水果总量 | 杯当量 | 1 杯当量 ≈ 1 杯切块水果 / ½ 杯果干 / 1 杯 100% 果汁 |
| 2 | `fruit_whole_cup` | 完整水果 | 杯当量 | 不含果汁的水果部分 |
| 3 | `veg_total_cup` | 蔬菜总量 | 杯当量 | 1 杯当量 ≈ 1 杯生/熟蔬菜 或 2 杯生绿叶菜；不含豆类（豆类单独计） |
| 4 | `veg_dark_green_cup` | 深绿色蔬菜 | 杯当量 | 菠菜、西兰花、油菜、空心菜等（是蔬菜总量的一部分） |
| 5 | `legumes_cup` | 豆类(干豆/豌豆/扁豆) | 杯当量 | 煮熟的干豆类；豆腐等大豆制品计入植物蛋白 |
| 6 | `grains_whole_oz` | 全谷物 | 盎司当量 | 1 盎司当量 ≈ 1 片面包 / ½ 杯熟米饭或面条 (~28g 干重) |
| 7 | `grains_refined_oz` | 精制谷物 | 盎司当量 | 白米、白面、米粉、面条等 |
| 8 | `dairy_cup` | 奶及奶制品 | 杯当量 | 1 杯牛奶/酸奶 或 1.5 盎司奶酪；含强化豆奶 |
| 9 | `protein_total_oz` | 蛋白质食物总量 | 盎司当量 | 1 盎司肉鱼禽 / 1 个蛋 / ½ 盎司坚果 / ¼ 杯豆类 |
| 10 | `seafood_oz` | 海产品 | 盎司当量 | 鱼、虾、贝类等 |
| 11 | `plant_protein_oz` | 植物蛋白(坚果/种子/大豆/豆类) | 盎司当量 | 坚果、种子、豆腐、豆干、豆类 |
| 12 | `red_meat_g` | 红肉(熟重) | g | 猪、牛、羊等哺乳动物肌肉，不含加工肉 |
| 13 | `processed_meat_g` | 加工肉 | g | 培根、火腿、香肠、腊肉、午餐肉、肉干等腌/熏/发酵肉 |
| 14 | `poultry_g` | 禽肉 | g | 鸡、鸭、鹅等 |
| 15 | `fruit_veg_g` | 水果+非淀粉类蔬菜 | g | WCRF：每天 ≥400 g；不含土豆等淀粉类根茎、豆类和果汁 |
| 16 | `berries_cup` | 浆果 | 杯当量 | 草莓、蓝莓、树莓、桑葚等（是水果总量的一部分） |
| 17 | `olive_oil_g` | 橄榄油 | g | 1 汤匙 ≈ 13.5 g |
| 18 | `butter_cream_g` | 黄油/奶油 | g | 黄油、奶油、淡奶油；1 汤匙 ≈ 14 g |
| 19 | `cheese_g` | 全脂奶酪/奶油奶酪 | g | 1 盎司 ≈ 28 g |
| 20 | `nuts_g` | 坚果种子 | g | 花生、核桃、杏仁、瓜子等；¼ 杯 ≈ 30 g |
| 21 | `sweets_serv` | 商业甜点/糖果/糕点 | 份 | 蛋糕、饼干、糖果、甜甜圈、冰淇淋等，按常见一份计 |
| 22 | `ssb_ml` | 含糖饮料 | ml | 含添加糖/蜂蜜/糖浆的饮料，含加糖果汁、奶茶；不含无糖饮料 |

Web item editor unit affix: `unit === "g" ? "g" : first character of unit`, which gives 杯, 盎, 份, or `m` for `ml`. The web section header is `食物组（影响 HEI-2020 与红肉/加工肉判断）`. Each label's tooltip is the group's `note`.

### 1.3 Food category: `category` enum (`FOOD_CATEGORIES`)

Any value outside the list is coerced to `"other"` on write. Chinese labels come from web `CATEGORY_ZH`.

| key | zh |
|---|---|
| `staple` | 主食 |
| `vegetable` | 蔬菜 |
| `fruit` | 水果 |
| `meat` | 肉类 |
| `poultry` | 禽肉 |
| `seafood` | 水产 |
| `egg` | 蛋类 |
| `dairy` | 奶制品 |
| `soy_legume` | 豆制品/豆类 |
| `nut_seed` | 坚果种子 |
| `snack` | 零食 |
| `dessert` | 甜点 |
| `beverage` | 饮品 |
| `alcohol` | 酒类 |
| `condiment` | 调味品 |
| `fast_food` | 速食/快餐 |
| `dish` | 菜肴 |
| `supplement` | 补充剂 |
| `other` | 其他 |

`fast_food` matters for scoring: a meal containing any `fast_food` item counts toward `fastFoodMeals` (MEPA/WCRF).

### 1.4 NOVA processing group: `nova_group`

Values are the integers `1 | 2 | 3 | 4`, or `null` for unknown. Anything else is coerced to `null` on write. Web `NOVA_ZH`: `1: 未加工`, `2: 烹饪原料`, `3: 加工食品`, `4: 超加工`. The web dropdown has an extra empty option `未知` that maps to `null`. Chip text is `NOVA {n} · {zh}`. Items with `nova_group == 4` contribute to `upfPct` (ultra-processed % of kcal).

### 1.5 Confidence: `confidence`

AI output is `"high" | "medium" | "low"`. On meal-item write the server accepts any string up to 10 characters without validating it. The web shows a chip `置信度低` when the value is `"low"`. Library-derived items are always `"high"`.

### 1.6 Meal type: `meal_type`

| key | web label (`MEAL_TYPES`) | web default time (unused by the log page) |
|---|---|---|
| `breakfast` | 早餐 | 08:00 |
| `lunch` | 午餐 | 12:30 |
| `dinner` | 晚餐 | 18:30 |
| `snack` | 加餐 | 15:30 |
| `drink` | 饮品 | 10:00 |
| `other` | 其他 | 12:00 |

Any other value is coerced to `"other"` on write. The AI prompt uses `加餐/零食` for snack, but the UI uses `加餐`.

The web guesses the default meal type from the current time (`guessMealType`):
| hour | meal type |
|---|---|
| < 10 | breakfast |
| < 14 | lunch |
| < 17 | snack |
| < 21 | dinner |
| otherwise | snack |

### 1.7 Hazard / risk tags (`HAZARDS` in `standards/hazards.ts`)

There are 15 hazard keys.
- `dose source` says where the day's dose comes from:
  - `group <key>`: summed from the food-group vector.
  - `nutrient <key>`: summed from the nutrient vector.
  - `flag`: summed from explicit hazard entries on items. For these, an entry with `amount == 0` counts as `refAmount`.
- Only `aiFlag = true` keys are ever produced by the AI. Only `flag` keys are offered in the web's "补充风险标记" picker.
- Entries with keys `processed_meat`, `red_meat` or `alcohol` inside `hazards[]` are accepted and stored but **ignored by scoring**, because those doses come from `groups` and `nutrients`.

| # | key | 中文 (zh) | en | IARC | category | dose source | unit | refAmount | aiFlag |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `processed_meat` | 加工肉 | Processed meat | 1 | carcinogen | group `processed_meat_g` | g | 50 | false |
| 2 | `red_meat` | 红肉 | Red meat | 2A | carcinogen | group `red_meat_g` | g | 100 | false |
| 3 | `alcohol` | 酒精饮料 | Alcoholic beverages | 1 | carcinogen | nutrient `alcohol_g` | g | 14 | false |
| 4 | `salted_fish_cantonese` | 中式咸鱼 | Chinese-style salted fish | 1 | carcinogen | flag | g | 50 | true |
| 5 | `areca_nut` | 槟榔 | Areca nut / betel quid | 1 | carcinogen | flag | g | 10 | true |
| 6 | `aflatoxin_risk` | 黄曲霉毒素风险 | Aflatoxins | 1 | carcinogen | flag | g | 30 | true |
| 7 | `high_temp_meat` | 高温烧烤/焦糊肉类 | Meat cooked at high temperature (HCAs/PAHs) | 2A | carcinogen | flag | g | 100 | true |
| 8 | `smoked_food` | 烟熏食品 | Smoked foods (PAHs) | 2A | carcinogen | flag | g | 100 | true |
| 9 | `acrylamide` | 丙烯酰胺(高温油炸/烘烤淀粉) | Acrylamide | 2A | carcinogen | flag | g | 100 | true |
| 10 | `pickled_vegetables` | 传统腌菜 | Pickled vegetables (traditional Asian) | 2B | carcinogen | flag | g | 50 | true |
| 11 | `very_hot_beverage` | 过烫饮品(>65°C) | Very hot beverages | 2A | carcinogen | flag | ml | 250 | true |
| 12 | `bracken_fern` | 蕨菜 | Bracken fern | 2B | carcinogen | flag | g | 100 | true |
| 13 | `high_mercury_fish` | 高汞鱼类 | High-mercury fish | — | toxicant | flag | g | 100 | true |
| 14 | `hijiki` | 羊栖菜(无机砷) | Hijiki seaweed (inorganic arsenic) | 1 | carcinogen | flag | g | 50 | true |
| 15 | `aspartame` | 阿斯巴甜(超过 ADI 时警示) | Aspartame | 2B | carcinogen | flag | mg | 1 | true |

Details shown to users (also returned by `GET /standards/meta` → `hazards[]`, together with `sources: string[]` IDs):

| key | risk 风险 | detect 判定 | examples 例 | advice 建议 |
|---|---|---|---|---|
| `processed_meat` | 结直肠癌（每天 50 g 风险约增加 18%），胃癌 | 经腌制、烟熏、发酵、添加亚硝酸盐等方式加工的肉 | 培根、火腿、香肠、腊肉、腊肠、午餐肉、热狗、肉松、牛肉干、咸肉 | 尽量少吃，WCRF 建议“很少或不吃”。可用新鲜禽肉、鱼、豆制品代替。 |
| `red_meat` | 结直肠癌（很可能），胰腺癌、前列腺癌（有限证据） | 猪牛羊等哺乳动物的新鲜肌肉肉 | 猪肉、牛肉、羊肉、牛排、红烧肉 | 每周红肉熟重控制在 350–500 g 以内，日均不超过约 70 g。 |
| `alcohol` | 口腔、咽、喉、食管、肝、结直肠、乳腺等多种癌症；无安全阈值 | 按纯酒精克数计 | 啤酒、白酒、红酒、黄酒、鸡尾酒 | 越少越好。孕期、未成年人应完全避免。 |
| `salted_fish_cantonese` | 鼻咽癌 | 传统盐腌、晾晒发酵的咸鱼（腌制过程产生亚硝胺） | 咸鱼、梅香咸鱼、咸鱼茄子煲、咸鱼炒饭中的咸鱼 | 尽量避免，尤其不要从小经常食用。 |
| `areca_nut` | 口腔癌、咽癌、食管癌 | 嚼食槟榔（无论是否含烟草） | 槟榔、槟榔果、含槟榔的嚼块 | 不要嚼槟榔。 |
| `aflatoxin_risk` | 肝癌 | 食用明显发霉/变味的花生、玉米、坚果、谷物，或未经精炼的土榨花生油 | 发霉花生、哈喇味坚果、发霉玉米、自榨花生油 | 发霉或有哈喇味的坚果谷物一律丢弃；选择精炼食用油。 |
| `high_temp_meat` | 杂环胺 (HCAs) 与多环芳烃 (PAHs，苯并[a]芘为 1 类) —— 结直肠、胰腺、前列腺癌风险 | 明火烧烤、炭烤、铁板高温煎至焦黑的肉/鱼 | 烤串、炭烤肉、韩式烤肉、烤鸭皮焦黑部分、煎到焦黑的牛排 | 避免焦黑部分，多翻面、先预煮、降低火候，搭配蔬菜。 |
| `smoked_food` | 多环芳烃 (PAHs) 暴露 | 烟熏工艺制作的肉、鱼、豆制品等 | 烟熏三文鱼、烟熏香肠、熏肉、熏鱼、烟熏豆干 | 减少烟熏食品频率。 |
| `acrylamide` | 动物实验致癌，人类很可能致癌 | 淀粉类食物经 120°C 以上油炸/烘烤，颜色金黄至焦褐 | 薯条、薯片、油条、炸糕、深烤吐司、焦饼干 | 烤至金黄即可，避免焦褐；少吃油炸淀粉类。 |
| `pickled_vegetables` | 食管癌、胃癌（可能）；同时高盐 | 传统盐腌/发酵蔬菜（非现做醋泡） | 酸菜、泡菜、咸菜、榨菜、梅干菜、雪菜、腌萝卜 | 少量佐餐即可，同时注意钠摄入。 |
| `very_hot_beverage` | 食管鳞癌 | 用户明确提到很烫/滚烫时饮用的茶、咖啡、汤等 | 滚烫的茶、刚出锅的热汤一口闷 | 稍放凉（< 60°C）再喝。 |
| `bracken_fern` | 含原蕨苷 (ptaquiloside)，动物实验致胃癌、膀胱癌 | 食用蕨菜（龙须菜不算） | 凉拌蕨菜、蕨根粉（淀粉制品风险较低） | 偶尔吃无妨，避免经常大量食用；充分焯水可降低含量。 |
| `high_mercury_fish` | 甲基汞神经毒性（孕妇、哺乳期、儿童尤其敏感） | FDA/EPA 列为“应避免”的高汞鱼 | 大耳马鲛/王鲭、枪鱼(马林鱼)、橙棘鲷、鲨鱼、剑鱼、方头鱼(墨西哥湾)、大眼金枪鱼 | 选择三文鱼、鳕鱼、虾、罗非鱼等低汞海产。 |
| `hijiki` | 无机砷为 1 类致癌物（肺、膀胱、皮肤） | 食用羊栖菜（鹿尾菜/ひじき） | 羊栖菜沙拉、日式煮羊栖菜 | 海带、紫菜、裙带菜等不受影响，避免羊栖菜即可。 |
| `aspartame` | IARC 2B；JECFA 认为在 ADI（40 mg/kg 体重）以内可接受 | 含阿斯巴甜的无糖饮料/食品，按阿斯巴甜毫克数（一罐 355 ml 无糖可乐约 180–200 mg） | 健怡/零度可乐（部分配方）、无糖口香糖、代糖 | 偶尔饮用在安全范围内；按体重计算，不要长期大量饮用。 |

IARC chip text and colors on the web:
| `iarc` | chip text | web style |
|---|---|---|
| `"1"` | `IARC 1 类` | critical (red) |
| `"2A"` | `IARC 2A 类` | serious (orange) |
| `"2B"` | `IARC 2B 类` | warning (yellow) |
| `"—"` | `非致癌` | default chip |

In the item editor, hazard chips show the hazard `zh` with a shield icon.

The web shows extra chips derived from groups, not from `hazards[]`:
- If `groups.processed_meat_g > 0`: `加工肉 {fmt(g)} g`, with IARC 1 styling.
- If `groups.red_meat_g > 0`: `红肉 {fmt(g)} g`, with IARC 2A styling.

#### Hazard entry shapes (three variants; note the field-name differences)
| Context | Shape |
|---|---|
| Meal item `hazards[]` (per-portion) | `{ "key": string, "amount": number, "note"?: string }` |
| Draft item `per100.hazards[]` | `{ "key": string, "amount_per_100g": number, "note"?: string }` (`note` usually absent) |
| Food library `hazards100[]` / FoodDraft `hazards100[]` | `{ "key": string, "amount_per_100g": number, "note": string }` |

- `amount` units: `g` for most keys, `mg` for `aspartame`, `ml` for `very_hot_beverage`. It is the quantity of the related food, not of the toxin. For aspartame it is mg of aspartame.
- Sanitization on write: an entry is kept only if `key` is one of the 15 keys. `amount` (or `amount_per_100g`) becomes `max(0, Number(x) || 0)`. `note` is cut to 200 characters.
- Decode leniently. Legacy rows may lack `note`, and the DB comment even mentions an old `fraction` field.

### 1.8 Meal item: what the app **sends** in `POST/PUT /meals` `items[]` and `POST /preview` `meal.items[]`

| Field | Type | Required | Server rule (`cleanItem`) |
|---|---|---|---|
| `name` | string | **yes** | Trimmed. Empty → 400 `食物名称不能为空`. Cut to 80 characters. |
| `amount_g` | number | **yes** | 0.1 ≤ x ≤ 20000, otherwise 400 (`重量不能为空` / `重量格式不正确` / `重量不能小于 0.1` / `重量不能大于 20000`). Grams of edible portion; for drinks ml ≈ g. |
| `amount_desc` | string | no | Portion text such as `1 碗 (200 g)`. Max 80. Missing → `""`. |
| `food_id` | int or null | no | See the **library override** below. |
| `category` | string | no | Enum 1.3, else `"other"`. |
| `cooking_method` | string | no | Max 30. Missing → `""`. Free text such as 生/蒸/煮/炒/炸/烤/烟熏/腌制/冲泡. |
| `nova_group` | int or null | no | 1–4, else `null`. |
| `confidence` | string | no | Max 10. Missing → `""`. |
| `nutrients` | NutrientVector | no* | Sanitized; missing means all zeros. *Effectively required.* |
| `groups` | FoodGroupVector | no* | Sanitized. |
| `hazards` | `[{key, amount, note}]` | no | Sanitized as in 1.7. |
| `notes` | string | no | Max 300. Missing → `""`. |
| *anything else* | | | **Ignored.** For example `per100`, `save_suggested`, `saved_food_id`, `id`, `meal_id`. The web sends whole DraftItems as-is. |

**Library override.** If `food_id` is a positive integer referring to a food the user can access (own or public), the server **discards** the client's `nutrients`, `groups` and `hazards`. It recomputes them as `library per-100 values × amount_g / 100`, with hazard notes set to `""`, and stores `food_id`. The client's `name`, `category`, `nova_group`, `amount_desc` and other fields are still kept.

If `food_id` refers to a food that is missing or inaccessible, the server silently stores `food_id = null` and **uses the client's numbers**.

Practical consequence: if the user edits any nutrient, group or hazard value on an item, the app **must send `food_id: null`**, which is what the web does (section 4.3). Otherwise the server silently reverts the edits.

Each saved item with a valid `food_id` increments that food's `use_count` by 1. This happens on every POST **and** every PUT of the meal.

### 1.9 Meal item: what the server **returns** inside a meal (`GET /day/{date}` → `meals[].items[]`)

Keys appear in this order:
```json
{
  "id": 812,                 // int, meal_items.id (new IDs after every PUT of the meal)
  "meal_id": 301,            // int
  "name": "牛肉面",
  "amount_g": 450,           // number
  "nutrients": { /* all 43 keys */ },
  "groups":    { /* all 22 keys */ },
  "hazards":   [ { "key": "acrylamide", "amount": 80, "note": "" } ],
  "nova_group": 3,           // int | null
  "category": "dish",        // string | null
  "amount_desc": "1 大碗 (450 g)", // string | null   (often "" rather than null)
  "food_id": null,           // int | null  (becomes null if the library food is later deleted: FK ON DELETE SET NULL)
  "cooking_method": "煮",    // string | null
  "confidence": "medium",    // string | null
  "notes": "按餐馆份量估算"   // string | null
}
```
- No `date` or `user_id` fields are returned.
- Optional strings may be `""` (written through the API) or `null` (water rows, legacy rows). Treat both as empty.

### 1.10 DraftItem: an item produced by the server for review before saving

`DraftItem` is returned by AI meal analysis (`MealDraft.items[]`) and by `POST /foods/{id}/item`.

```json
{
  "name": "string",
  "amount_g": 0,                 // number ≥ 1 from AI; exactly the requested grams from /foods/{id}/item
  "amount_desc": "string",
  "food_id": 12,                 // int | null
  "category": "string",          // enum 1.3 (or library value; may be "other")
  "cooking_method": "string",    // "" for library items
  "nova_group": 4,               // int | null
  "confidence": "high",          // "high" | "medium" | "low"
  "nutrients": { /* 43 keys, per portion */ },
  "groups":    { /* 22 keys, per portion */ },
  "hazards":   [ { "key": "...", "amount": 0, "note": "..." } ],   // note absent on library items
  "notes": "string",
  "per100": {
    "nutrients": { /* 43 keys, per 100 g */ },
    "groups":    { /* 22 keys, per 100 g */ },
    "hazards":   [ { "key": "...", "amount_per_100g": 0 } ]     // library items: raw library entries, may include "note"
  },
  "save_suggested": true          // bool: UI hint "存入食物库（推荐）"
}
```

The web adds one **client-only** field, `saved_food_id?: int`. It is set after the user saves the item to the library and only controls the UI: it hides the save button and shows the chip `已存入食物库`. The web does **not** set `food_id` when saving to the library.

How the server builds DraftItems:
- **AI item, not from the library** (`draftFromRaw`):
  - `amount_g = max(1, Number(ai.amount_g) || 100)`.
  - `name` defaults to `未命名食物`.
  - `confidence` defaults to `medium`.
  - `per100.* = portion values × 100 / amount_g`.
  - `save_suggested = category ∈ {snack, dessert, beverage, fast_food, dairy, supplement, alcohol} OR nova_group == 4`.
  - The server also applies consistency fixes:
    - If `energy_kcal ≤ 0`, it becomes `4·protein + 4·carb + 9·fat + 7·alcohol`.
    - If `sat_fat > fat`, then `fat = sat + mufa + pufa + trans`.
    - If `added_sugars > sugars`, then `sugars = added_sugars`.
    - If `sugars > carb > 0`, then `carb = sugars + fiber`.
    - If `fruit_whole > fruit_total`, then `fruit_total = fruit_whole`.
    - If `veg_dark_green > veg_total`, then `veg_total = veg_dark_green`.
  - Only hazards with `aiFlag` keys are kept.
- **AI item matched to the library**: built by `itemFromFood` using the AI's `amount_g`. `amount_desc` and `notes` come from the AI; `notes` defaults to `来自食物库`.
- **Library item** (`itemFromFood(food, grams)`):
  - `name`: the food name, or `name（brand）` with full-width parentheses when the brand is not already in the name.
  - `amount_g = grams`.
  - `amount_desc`: if `serving_g` is set and `|grams − serving_g| < 0.5`, use `serving_desc` or else `1 份 {serving_g} g`. Otherwise use `{Math.round(grams)} g`.
  - `food_id = food.id`.
  - `category = food.category ?? "other"`.
  - `cooking_method = ""`.
  - `confidence = "high"`.
  - `nutrients/groups = per100 × grams / 100`.
  - `hazards = [{key, amount: amount_per_100g × grams/100}]`, with no note.
  - `notes = "来自食物库"`.
  - `per100 = {nutrients: per100, groups: groups100, hazards: hazards100 raw}`.
  - `save_suggested = false`.

### 1.11 Meal: returned by `GET /day/{date}` → `meals[]`

```json
{
  "id": 301,                       // int
  "date": "2026-10-03",
  "time": "12:30",
  "meal_type": "lunch",
  "description": "中午一碗牛肉面加一个卤蛋",   // string ("" if none)
  "photos": ["3f9a...c1.jpg"],     // string[]: upload IDs (filenames), NOT URLs; build URL per 2.2
  "ai_summary": "一碗牛肉面…",      // string | null  ("" if saved without one)
  "items": [ /* 1.9 */ ]
}
```
- There is **no `ai_model` field** in the response, even though it is stored.
- Meals are sorted by `time`, then `id`. Items are sorted by item `id`.
- **The water pseudo-meal.** `POST /water` maintains one meal per day with `description == "饮水"`, `meal_type "drink"`, and a single item `饮用水`. The web **hides** it from the meal list (`filter(m => m.description !== "饮水")`) and reads the water amount from `items[0].amount_g`. Do the same, and never offer edit or delete for it.
  - Caveat: a normal meal whose description is exactly `饮水` is indistinguishable from it.

### 1.12 Food: the library entry (`GET /foods`, `GET /foods/{id}`)

```json
{
  "id": 12,                        // int
  "owner_id": 3,                   // int
  "visibility": "private",         // "private" | "public"
  "name": "螺蛳粉",
  "brand": "李子柒",               // string | null  (empty → null)
  "aliases": "螺狮粉,luosifen",    // STRING, comma-joined (NOT an array) — split on [,，、] for display
  "category": "fast_food",         // string | null
  "serving_g": 335,                // number | null
  "serving_desc": "1 包 335 g",    // string | null (often "")
  "per100":   { /* 43 nutrient keys, per 100 g */ },
  "groups100":{ /* 22 group keys, per 100 g */ },
  "hazards100": [ { "key": "pickled_vegetables", "amount_per_100g": 4.5, "note": "" } ],
  "nova_group": 4,                 // int | null
  "ingredients": "…",              // string | null (often "")
  "label_fields": ["energy_kcal","protein_g"],  // nutrient keys read from a real label (UI chip "标签")
  "source": "label",               // "label" | "ai_search" | "ai_estimate" | "manual"
  "source_urls": [ { "title": "…", "url": "https://…" } ],   // title may be missing; extra props possible
  "notes": "…",                    // string | null (often "")
  "use_count": 5,                  // int
  "created_at": "2026-09-30 08:12:44",   // SQLite datetime('now'), UTC, "YYYY-MM-DD HH:MM:SS" (no T/Z)
  "updated_at": "2026-10-01 10:00:02",
  "owner_name": "小王",            // owner's display_name
  "mine": true                     // bool: owner_id == current user
}
```
`source` labels (web `SOURCE_ZH`):
| key | zh |
|---|---|
| `label` | 营养标签 |
| `ai_search` | AI 联网查询 |
| `ai_estimate` | AI 估算 |
| `manual` | 手动录入 |

### 1.13 MealDraft: result of AI job kind `"meal"`

```json
{
  "items": [ /* DraftItem 1.10 */ ],
  "summary": "string",            // one-line Chinese summary ("" possible)
  "assumptions": ["string"],      // ≤ 12 strings
  "questions": ["string"],        // ≤ 12 strings; follow-up questions for the user
  "sources": [ { "title": "string", "url": "string" } ],   // ≤ 10
  "provider": "api",              // "cli" | "api" | "mock"
  "model": "claude-opus-5-5"      // model id string; "offline" for mock
}
```
`items` may be empty in theory. The offline mock always returns at least one item. The draft does **not** echo back the date, time or meal type; the app keeps those itself.

### 1.14 FoodDraft: result of AI job kind `"food"`

```json
{
  "name": "string",               // ≤ 80
  "brand": "string",              // ≤ 60, "" if none
  "aliases": ["string"],          // ARRAY here (≤ 12, each ≤ 40) — unlike Food.aliases
  "category": "string",           // enum 1.3
  "serving_g": 100,               // number ≥ 1 (default 100)
  "serving_desc": "string",       // ≤ 60
  "per100": { /* 43 */ },
  "groups100": { /* 22 */ },
  "hazards100": [ { "key": "...", "amount_per_100g": 0, "note": "..." } ],   // aiFlag keys only
  "nova_group": 3,                // int | null
  "ingredients": "string",        // ≤ 2000
  "label_fields": ["energy_kcal"],// valid nutrient keys only
  "confidence": "string",         // usually high|medium|low but NOT validated (default "medium")
  "sources": [ { "title": "string", "url": "string" } ],   // ≤ 10
  "notes": "string",              // ≤ 600
  "source": "label",              // "label" if photos were sent or label_fields non-empty; else "ai_search" if sources non-empty; else "ai_estimate"
  "provider": "api"               // "cli" | "api" | "mock"   (no "model" field here)
}
```
The mock provider returns `confidence "low"`, `notes "离线估算（未配置 AI），请手动核对标签数值"`, `source "ai_estimate"` and `provider "mock"`.

### 1.15 Other job results (same jobs endpoint)
- Kind `"exercise"` (`POST /ai/exercise`) returns `{ "items": ExerciseDraft[], "provider": string }`. Each `ExerciseDraft` is:
  ```json
  { "description": "string(≤80)", "activity_key": "string", "met": 1-20, "duration_min": int 1-1440,
    "distance_km": number ≥0, "kcal": int (net kcal, server-computed), "notes": "string(≤200)" }
  ```
- Kind `"activity"` (`POST /ai/activity`, covered by the body/activity spec) returns an `ActivityDraft`:
  ```json
  { "date": "YYYY-MM-DD", "date_from_image": bool,
    "activity": { "steps": n|null, "distance_km": n|null, "active_kcal": n|null, "resting_kcal": n|null,
                  "exercise_min": n|null, "stand_hours": n|null, "sleep_hours": n|null },
    "body": { "weight_kg": n|null, "body_fat_pct": n|null, "sbp": n|null, "dbp": n|null },
    "workouts": [ ExerciseDraft + { "avg_hr": n|null, "device_kcal": n|null, "in_device": bool } ],
    "notes": "string", "provider": "string", "model": "string" }
  ```
- Kind `"summary"` (`POST /period/summary`, covered by the reports spec) returns `{ "headline": string, "summary": string, "wins": string[], "issues": string[], "actions": string[] }`, **or `null`**. It is `null` in mock mode and when nothing was logged.

### 1.16 Scoring shapes returned by `POST /preview`

These are reproduced from `server/src/scoring/*.ts` and `web/src/types.ts`; the full meaning is in the reports spec.

```
DailyScore {
  date: string
  hasData: bool                       // items>0 and kcal>0
  score: number|null                  // HEI-2020 total 0–100
  total: CompositeScore
  categories: [ { key: "hei"|"mar", zh: string, score: number /*0-100*/, source: string, note: string } ]
  items: ScoreItem[]
  hei: { total: number, components: [ { key, zh, score: number, max: number, value: number, unit: string, hint: string } ] } | null
  mar: { value: number /*0-100*/, nutrients: [ { key, zh, intake: number, target: number, nar: number } ] } | null
  hazards: HazardResult[]
  energy: { intake, resting: number, restingSource: "device"|"bmr", active: number, activeSource: "device"|"steps"|"exercise"|"none",
            exerciseKcal, tef, tdee, method: "measured"|"eer", target, balance: number }
  totals: NutrientVector              // day totals
  groups: FoodGroupVector
  macroPct: { protein, carb, fat, satFat, addedSugar, alcohol: number }   // % of kcal
  upfPct: number
  mealCount: int                      // meals with ≥ 5 kcal (water pseudo-meal not counted)
  itemCount: int
  fastFoodMeals: int
  completeness: { level: "none"|"partial"|"likely", note: string }
  top: { issues: string[], wins: string[] }
  weightKg: number
  weighedToday: number|null
  version: int                        // scoring version (server field; web type omits it)
}
CompositeScore { score: number|null, parts: [ { key, zh, weight: number, score: number|null, points: number|null, note } ], missing: string[] }
ScoreItem { key, category: "hei"|"mar"|"adequacy"|"moderation"|"energy", zh, value: number, unit, targetText,
            target?: number, ideal?: number, limit?: number, status: "good"|"ok"|"warn"|"bad"|"info",
            score: number /*0-1*/, points: number, maxPoints: number, message: string, sources: string[] }
HazardResult { key, zh, iarc: string, dose: number, unit: string, foods: string[], message: string, sources: string[] }
HealthIndices {
  windowDays: int, loggedDays: int,
  mepa: { score: number, days: int, items: [ { key, zh, criterion: string, value: number, unit, met: bool } ] } | null,
  le8: { score: number|null, category: { key: "high"|"moderate"|"low", zh } | null, available: int,
         components: [ { key, zh, points: number|null, value: string, rule: string, missing: string } ] },
  wcrf: { score: number, max: number, components: [ { key, zh, points: number|null, max: number, detail: string, rule: string } ] },
  pa: { le8MinPerWeek: number|null, mvpaMinPerWeek: number|null, strengthDays: number },
  sleepHours: number|null
}
```
When `hasData == false`, these fields are empty or null: `score`, `categories`, `items`, `hei`, `mar`, `hazards`, `top`. `totals`, `energy` and the rest are still present.

---

## 2. Endpoints

All paths below are relative to `/api/v1` and all require Bearer auth.

### 2.1 `POST /uploads`: upload photos (multipart)

Used for food photos, packaging, ingredient lists, nutrition labels and health screenshots. The returned IDs are what the AI endpoints and meals reference.

**Request**: `multipart/form-data`.
- File field name is exactly **`photos`**. Repeat the field once per file.
- At most **6 files** per request, each **≤ 12 MB** (12 × 1024 × 1024 bytes).
- **Accepted MIME types** (the part's `Content-Type`): `image/jpeg`, `image/png`, `image/webp`, `image/gif`, matched by `/^image\/(jpeg|png|webp|gif)$/`.
  - **HEIC/HEIF is NOT accepted.** Convert to JPEG on device. iPhone photos are HEIC by default.
  - Files of other types are **silently skipped**, not errors.
- **Filename extension matters.** The stored extension comes from the part's *filename*: if it matches `.jpg/.jpeg/.png/.webp/.gif` (case-insensitive) that is used, otherwise `.jpg`. The AI later infers the media type from that extension.
  - Always send a filename whose extension matches the bytes, such as `photo1.jpg` with `Content-Type: image/jpeg`.
  - A PNG sent as `x.heic` would be stored as `.jpg` and declared `image/jpeg` to the model, which may fail.
- Recommended client preprocessing:
  - JPEG, quality ≈ 0.8, long edge ≈ 1568–2048 px.
  - The model API rejects very large images, around 5 MB per image after base64, even though the server accepts 12 MB uploads. Such a failure only appears later as an AI job error.
- Other multipart text fields are ignored.

**Response 200**:
```json
{ "photos": [ { "id": "a1b2c3d4e5f6a7b8c9d0e1f2.jpg", "url": "/api/uploads/a1b2c3d4e5f6a7b8c9d0e1f2.jpg" } ] }
```
- `id` is 24 lowercase hex characters plus the extension. It matches `^[\w.-]+$` and is the value used in `photos` arrays elsewhere.
- `url` is a **relative path under `/api` (not `/api/v1`)** and **requires auth** to fetch (2.2).
- Files are stored per user at `data/uploads/{userId}/{id}`. There is **no delete endpoint**. Removing a photo in the UI only drops its ID from the client list.

**Errors**:
| Status | Body | Cause |
|---|---|---|
| 400 | `请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）` | No accepted file in the request: all were skipped, it was not multipart, or the field name was wrong *and* there were no files |
| 413 | `文件太大` | Any file > 12 MB. The whole request fails; multer normally deletes files already written for that request, so retry all of them. |
| 500 | `服务器内部错误` | More than 6 files, or a file part with a field name other than `photos` (multer `LIMIT_FILE_COUNT` / `LIMIT_UNEXPECTED_FILE` are not mapped to 4xx). Enforce both rules on the client. |

The web uploads files as soon as they are picked and caps the total per meal at 6 (`slice(0, 6 - photos.length)`).

### 2.2 `GET /uploads/{id}`: fetch an uploaded photo
- `GET /api/v1/uploads/{id}` and `GET /api/uploads/{id}` behave identically.
- **Requires `Authorization: Bearer`.** The web relies on its cookie, so `<img src>` works there. In SwiftUI, `AsyncImage` cannot add headers: use a custom loader (`URLRequest` with the header, then `UIImage(data:)`, plus an image cache).
- Only the **owner** can fetch, because files are looked up in the requesting user's own folder. Another user's photo ID returns 404, so photos from shared or community views are not viewable.
- `id` must match `^[\w.-]+$`, otherwise the response is 404.
- Response: raw bytes, `Content-Type` from the extension. Express `sendFile` adds ETag, Last-Modified and `Cache-Control: public, max-age=0`.
- 404 `{"error":"不存在"}` if the ID is invalid or missing.

### 2.3 `GET /ai/status`
```json
{ "provider": "cli" | "api" | "mock", "model": "claude-opus-5-5" /* or "offline" when mock */, "web_search": true }
```
`GET /auth/me` also returns `ai: {provider, model}`, which is what the web uses.

Web hint text next to the analyze button:
- Mock: `当前为离线估算模式（未配置 AI）`
- Otherwise: `由 {model} 分析{provider=="cli" ? "（claude -p）" : ""}，包装食品会自动联网查询`

### 2.4 `POST /ai/meal`: start AI analysis of a meal (async)

**Body**:
| Field | Type | Required | Rule |
|---|---|---|---|
| `text` | string | one of text/photos | Trimmed, **silently cut** to 2000 characters. |
| `photos` | string[] | one of text/photos | Upload IDs from 2.1. Only the first 6 are used. Invalid or missing IDs are silently ignored by the AI step. |
| `date` | `YYYY-MM-DD` | no | Invalid or missing → today in the profile timezone (default `Asia/Shanghai`). Used only as prompt context. |
| `time` | `HH:MM` | no | Invalid or missing → `"12:00"`. Prompt context only. |
| `meal_type` | enum 1.6 | no | Otherwise `"other"`. Prompt context only. |

- Validation: if `text` is empty **and** `photos` is not a non-empty array → 400 `请描述吃了什么，或上传照片`.
- The check only looks at the array length, so `photos: ["bogus"]` with empty text passes and the AI then sees no input.
- A profile is **not** required. Without one, the prompt says the user is "未知".

**Response 200**: `{ "job_id": "8c0e7f5e-...-uuid" }`. Poll it with 2.7. The result is a `MealDraft` (1.13).

Server-side behavior worth knowing:
- The server pre-matches the user's accessible library foods (own and public) by checking whether the **text** contains a food's name, brand or alias of 2 or more characters, up to 15 candidates.
- The AI may then return `matched_food_id`. Such items become library items: `food_id` is set, `confidence "high"`, and nutrients come from the library.
- Library matching never happens from photos alone.
- Web search may be used for branded products, which is slower.

### 2.5 `POST /ai/food`: AI lookup of a food for the library (async)

**Body**:
| Field | Type | Required | Rule |
|---|---|---|---|
| `name` | string | one of name/photos | Max 80 (truncated) |
| `brand` | string | no | Max 60 |
| `note` | string | no | Max 500. Free-form hint such as `原味 335g 袋装；我一般只喝一半汤`. |
| `photos` | string[] | one of name/photos | Packaging, ingredient list or nutrition label photos |

- If both `name` and `photos` are empty → 400 `请输入食物名称或上传包装/营养成分表照片`.
- **Response**: `{ "job_id": "uuid" }`. The result is a `FoodDraft` (1.14).
- The draft is **not saved**. The user reviews it and then the app calls `POST /foods` (2.17).
- With photos, label values are preferred. Without photos, the AI searches the web for the official nutrition table.

### 2.6 `POST /ai/exercise`: legacy text-only exercise parser (async)

This endpoint is legacy; the web uses `/ai/activity` instead, and it is listed only because it lives in `log.ts`.
- Requires a profile, otherwise 400 `请先完善个人档案`.
- Body: `text` (required, max 500; empty → 400 `运动描述不能为空`) and `date` (optional).
- Response: `{job_id}`. The result shape is in 1.15.

### 2.7 `GET /ai/jobs/{id}`: poll an AI job
**Response 200**:
```json
{ "id": "uuid", "kind": "meal" | "food" | "exercise" | "activity" | "summary",
  "status": "queued" | "running" | "done" | "error",
  "error": null | "string",
  "result": null | <MealDraft | FoodDraft | {items,provider} | ActivityDraft | WeeklySummary | null> }
```
- 404 `任务不存在` if the job is unknown or belongs to another user.
- `result` is non-null only when `status == "done"`. A done `"summary"` job can legitimately have `result: null`.
- `error` is non-null only when `status == "error"`. It is a raw message, possibly technical or English, for example:
  - `claude -p 超时（480 秒）`
  - `模型拒绝了该请求：…`
  - `AI 输出超过长度上限`
  - `联网搜索轮次过多，未能完成`
  - `AI 未返回可解析的 JSON`
  - Anthropic SDK errors in English
  - `服务器重启，任务中断，请重试`

  It is at most 1000 characters. Show it as-is.
- **There are no progress fields.** Only `status` changes. The web shows a client-side elapsed timer with staged messages (section 6).

**Async semantics** (from `ai/jobs.ts` and `ai/providers.ts`):
- Jobs go into an **in-memory FIFO queue shared by all users**, with `AI_CONCURRENCY` running at once (default **2**). A job can therefore stay `queued` for a long time when others are running.
- Status moves `queued → running → done | error`. There is no cancel endpoint. Abandoning a job client-side just stops polling, and the server still runs it.
- Typical durations: about 10 s to 3 min, longer with web search. The web's own copy says "一般需要 30–120 秒" for food lookup.
- Per-AI-call timeout is `AI_TIMEOUT_MS`, default **480 s**. The API provider adds up to 2 SDK retries, up to 6 web-search continuation rounds, and a fallback re-call without structured output. There is **no overall job timeout**, so budget for jobs taking well over 8 minutes in the worst case.
- If the server restarts, all `queued` and `running` jobs become `error` with `服务器重启，任务中断，请重试`. Jobs older than 7 days are deleted, but only at server start. A `job_id` stays pollable at least until then.
- The web polls every **1.5 s** with no client timeout.

Recommendation for iOS:
- Poll every 1.5–2 s while in the foreground.
- Persist the `job_id` together with the draft context (date, time, meal type, text, photo IDs) so the app can resume polling after backgrounding or relaunch.
- Show elapsed time.
- Offer a client-side cancel, which only stops polling and discards the result.

### 2.8 `POST /preview`: what-if scoring before saving (no DB writes)

This endpoint is defined in `routes/body.ts` but is part of the meal flow. It requires a profile, otherwise 400 `请先完善个人档案`.

**Body** (all fields optional; only the meal part is used by the meal flow):
```json
{
  "date": "2026-10-03",                     // invalid/missing → today (profile tz)
  "meal": {
    "meal_type": "lunch",                   // NOT validated; default "other"
    "time": "12:30",                        // NOT validated; default "12:00"
    "items": [ /* MealItem 1.8 (DraftItems are fine) */ ],
    "replace_meal_id": 301                  // int; when editing, the existing meal with this id is excluded from "after"
  },
  "activity": { "steps": 0, "distance_km": 0, "active_kcal": 0, "resting_kcal": 0, "exercise_min": 0, "stand_hours": 0, "sleep_hours": 0 },
  "body": { "weight_kg": 70, "sbp": 120, "dbp": 80, "bp_treated": false },
  "workouts": [ /* see activity spec */ ]
}
```

Meal item handling in preview differs from `/meals`:
- Per item, only `name`, `amount_g` (`Number(x) || 0`, with no range check), `nutrients`, `groups`, `hazards` (filtered by known key only; amounts are **not** clamped) and `nova_group` are used.
- **`category` is dropped**, so a `fast_food` item does **not** raise `fastFoodMeals` in `after`. This is a server inconsistency: the numbers after saving can differ slightly from the preview.
- **`food_id` is ignored**: no library recompute happens; the client's numbers are used.
- If `meal.items` is not an array, the meal part is ignored entirely. An empty array adds an empty meal, so do not call preview with zero items.

Other validation (400s):
- `activity.*`: ranges are steps 0–200000, distance_km 0–500, active_kcal 0–10000, resting_kcal 0–5000, exercise_min 0–1440, stand_hours 0–24, sleep_hours 0–24. Messages use the key as the field name, for example `steps不能大于 200000`.
- `body.weight_kg` 20–350, `sbp` 60–260, `dbp` 30–160. Messages use the generic name `数值`, for example `数值不能小于 20`.
- `workouts[].duration_min` is required, 1–1440 (`时长不能为空`). `met` is 1–25.

**Response 200**:
```json
{ "date": "2026-10-03",
  "before": DailyScore, "after": DailyScore,
  "indices": { "before": HealthIndices, "after": HealthIndices } }   // rolling 7 days ending at date
```

Web usage:
- Called only in the review phase with ≥ 1 item.
- **Debounced 400 ms** after any change to items, date, time, meal type or edit ID.
- Errors are swallowed: the preview is hidden.
- Rendering is described in 6.4.

### 2.9 `POST /meals`: save a new meal

**Body**:
| Field | Type | Required | Rule |
|---|---|---|---|
| `date` | `YYYY-MM-DD` | **yes** | Invalid → 400 `日期格式不正确`. Future dates are not rejected; the web caps the picker at today. |
| `time` | `HH:MM` | **yes** | Must match `^\d{2}:\d{2}$`, else 400 `时间格式不正确` |
| `meal_type` | enum 1.6 | no | Otherwise `"other"` |
| `description` | string | no | The user's free text. Max 2000. |
| `photos` | string[] | no | Upload IDs. Non-strings and anything not matching `^[\w.-]+$` are dropped; the first 6 are kept. Existence is **not** checked. |
| `ai_summary` | string | no | Max 500. The web sends `draft.summary ?? ""`. |
| `ai_model` | string | no | Max 60. The web sends `draft.model ?? ""`. |
| `items` | MealItem[] (1.8) | **yes**, ≥ 1 | Items are validated in order and the first item error is returned. If the array is empty or missing → 400 `至少需要一种食物`. There is no maximum count. |

- Validation order: date, then time, then each item, then non-empty items.
- **Response 200**: `{ "id": 301 }`.
- Side effects:
  - The cached daily score for that date is invalidated and recomputed lazily.
  - Each library food used has its `use_count` incremented.

### 2.10 `PUT /meals/{id}`: replace a meal
- If the meal does not exist or is not the user's, the response is 404 `餐食不存在`. This check runs **before** body validation.
- The body is identical to 2.9 and validated the same way.
- **What is updated:** only `date`, `time`, `meal_type` and `description` on the meal row, and **all items are deleted and re-inserted**, so item IDs change.
- **What is NOT updated:** `photos`, `ai_summary`, `ai_model`. These keep their original values even if they are sent.
  - This matters for the web: its edit screen starts with an empty photo list and sends `photos: []`, so honoring `photos` on PUT would wipe photos.
- Library items are **recomputed from the current library values**. Editing an old meal that contains library items therefore picks up any later changes to that food. `use_count` is incremented again.
- Score caches for the old and new dates are invalidated.
- **Response**: `{ "ok": true }`.

### 2.11 `DELETE /meals/{id}`
- 404 `餐食不存在` if not found or not owned.
- Items are deleted by cascade. Score cache is invalidated.
- **Response**: `{ "ok": true }`.
- Web confirmation text: `删除 {time} 的{餐次zh}？`, toast `已删除`.

### 2.12 Listing meals: there is no `GET /meals`; use `GET /day/{date}`
- Meals for a day come from `GET /day/{date}` → `meals: Meal[]` (1.11). Other fields of that response (`score`, `targets`, `indices`, `activity`, `exercises`, `body`, `weightTrend`, `full`) are in the reports spec.
- Requires a profile, otherwise 400 `请先完善个人档案`.
- Invalid date → 400 `日期格式不正确`.
- With `?user={username}` the response shows another member's data. When the share is "summary" only, `meals` is `[]`.
- The web's edit flow loads `/day/{date}`, finds the meal by `id`, and converts its items with `toDraft` (4.2). There is no `GET /meals/{id}`.

### 2.13 `GET /meals/recent-items`: frequently eaten items (last 60 days)

This endpoint is not used by the web today.

Returns up to 20 rows, grouped by exact `name`, ordered by count descending, then most recent date:
```json
[ { "name": "鸡蛋", "food_id": 7, "amount_g": 50, "n": 14, "last": "2026-10-02" } ]
```
- `food_id` and `amount_g` come from the most recent row in each group; `food_id` may be null.
- The 60-day window uses the server's UTC "now".
- The water item `饮用水` can appear here; filter it out.

### 2.14 `POST /water`: quick water logging (accumulates per day)

**Body**:
| Field | Type | Required | Rule |
|---|---|---|---|
| `ml` | number | **yes** | −2000 to 3000. Negative values undo. Errors: `饮水量不能为空`, `饮水量格式不正确`, `饮水量不能小于 -2000`, `饮水量不能大于 3000`. |
| `date` | `YYYY-MM-DD` | no | Default: today in the profile timezone |

Behavior:
- `total = max(0, existing + ml)`.
- If `total ≤ 0` and a water meal exists, the water meal is **deleted**.
- If a water meal exists and `total > 0`, its single item is updated: `amount_g = total`, `amount_desc = "{total} ml"`, `nutrients = zeros + water_g = total`.
- If no water meal exists and `total > 0`, one is created:
  - Meal: `meal_type "drink"`, `description "饮水"`, `time` = server's current time in the profile timezone.
  - Item: `name "饮用水"`, `category "beverage"`, `nova_group 1`, `confidence "high"`, zero groups, `hazards []`.

**Response**: `{ "ok": true, "total_ml": 750 }`.

Web UI:
- Text: `饮水 {water} ml · 总水分 {score.totals.water_g} / {targets.intake.water_g.value} g（含食物）`.
- Buttons `+ 250 ml` and `−`. The `−` button has accessibility label `减少 250 毫升` and is shown only when water > 0.

### 2.15 `GET /foods?q=&scope=`: search the library
- `q`: optional, trimmed, max 60 characters. It is a SQL `LIKE %q%` match on `name`, `brand` and `aliases`.
  - Matching is case-insensitive for ASCII only.
  - `%` and `_` in `q` act as wildcards.
- `scope`: `"mine"` returns only the user's own foods. Anything else, including a missing value, means `"all"`: own foods plus everyone's public foods.
- Order: own foods first, then `use_count` descending, then `updated_at` descending. **Limit 200, no pagination.**
- **Response**: `Food[]` (1.12).
- The web debounces typing: 250 ms on the Foods page, 200 ms in the picker.

### 2.16 `GET /foods/{id}`
- Returns a `Food`. The food must be the user's own or public.
- Otherwise 404 `食物不存在`.

### 2.17 `POST /foods`: create a library food (per 100 g)

**Body (FoodInput)**:
| Field | Type | Required | Rule |
|---|---|---|---|
| `name` | string | **yes** | Trimmed; empty → 400 `名称不能为空`. Max 80. |
| `brand` | string | no | Max 60. Empty → stored as `null`. |
| `aliases` | string[] **or** string | no | Array: elements are joined with `,`. String: max 300. The result is cut to 300. The web sends an array split on `[,，、]+`, trimmed, with empties removed. |
| `category` | enum 1.3 | no | Otherwise `"other"` |
| `serving_g` | number or null | no | 0.1–10000 when present. `null` or `""` → null. **`0` is an error**: `每份重量不能小于 0.1`. |
| `serving_desc` | string | no | Max 60 |
| `per100` | NutrientVector | no | Sanitized. Missing keys become 0. |
| `groups100` | FoodGroupVector | no | Sanitized |
| `hazards100` | `[{key, amount_per_100g, note}]` | no | Filtered to known keys. Amount ≥ 0. Note max 200. |
| `nova_group` | 1–4 or null | no | |
| `ingredients` | string | no | Max 2000 |
| `label_fields` | string[] | no | Filtered to valid nutrient keys |
| `source` | `label` / `ai_search` / `ai_estimate` / `manual` | no | Default `"manual"` |
| `source_urls` | `[{title, url}]` | no | Only objects with a string `url` are kept, up to 10. Other properties are **not** stripped. |
| `notes` | string | no | Max 600 |
| `visibility` | `private` / `public` | no | Default `"private"` |

- **Response**: `{ "id": 13 }`.
- Extra fields are ignored. After an AI lookup the web sends `confidence`, `sources`, `provider` and `id`, and that is harmless.

### 2.18 `PUT /foods/{id}`: update a library food (owner only)
- 404 `食物不存在`; 403 `只能修改自己创建的食物`.
- The body is the same as 2.17, and it is a **full replacement**: every omitted field is reset to its default. For example, omitting `groups100` zeroes the groups, and omitting `hazards100`, `label_fields` or `source_urls` empties them.
  - The web sends the complete object it loaded, with aliases re-split into an array, even though its editor cannot edit groups or hazards. Do the same: round-trip all fields.
- `updated_at` is set to now.
- **Response**: `{ "ok": true }`.
- Already-saved meal items are **not** changed, because they store absolute numbers. Re-saving a meal through PUT will pick up the new values (2.10).

### 2.19 `DELETE /foods/{id}` (owner only)
- 404 `食物不存在`; 403 `只能删除自己创建的食物`.
- **Response**: `{ "ok": true }`.
- Meal items that referenced the food keep their numbers and get `food_id = null`.
- Web confirmation text: `删除这个食物？已记录的餐食不受影响。`, toast `已删除`.

### 2.20 `POST /foods/{id}/item`: library food + grams → ready-to-save item (no AI)
- **Body**: `{ "grams": number }`, optional, 0.1–20000. Errors: `克数格式不正确`, `克数不能小于 0.1`, `克数不能大于 20000`. If omitted: `serving_g ?? 100`.
- The food must be the user's own or public; otherwise 404 `食物不存在`.
- **Response**: a `DraftItem` (1.10, library variant), which can go straight into `items[]`.
- The app may instead compute this locally from the `Food` it already has, using the same formulas as `itemFromFood` in 1.10. The server recomputes on save anyway because `food_id` is set.

### 2.21 `POST /foods/from-item`: save a reviewed draft item into the library

**Body**:
| Field | Type | Required | Rule |
|---|---|---|---|
| `item` | DraftItem | **yes** | Must have `per100`; otherwise 400 `缺少食物数据` |
| `name` | string | no | Default `item.name`. Note: `""` is not treated as missing → 400 `名称不能为空`. |
| `brand` | string | no | Default `""` → null |
| `aliases` | string[] | no | Default `[]` |
| `serving_g` | number | no | Default `item.amount_g`. Must be 0.1–10000, so an item with more than 10000 g errors. |
| `serving_desc` | string | no | Default `item.amount_desc` (cut to 60) |
| `source_urls` | `[{title,url}]` | no | The web passes the MealDraft's `sources` |
| `visibility` | `private` / `public` | no | Default private |

- Values taken from `item`: `per100.nutrients` → `per100`, `per100.groups` → `groups100`, `per100.hazards` → `hazards100` (note becomes `""`), `category`, `nova_group`, `notes`.
- Fixed values: `source` is always `"ai_estimate"`, `ingredients` is `""`, `label_fields` is `[]`.
- **Response**: `{ "id": 14 }`.
- The web then sets `saved_food_id` on the draft item. It does **not** link `food_id`.

Web dialog (`SaveFoodModal`):
- Initial values: name = `item.name`, brand `""`, serving = `round(item.amount_g)`, aliases `""` (split on `[,，、\s]+` when sent), visibility `private`.
- The body also sends `serving_desc: item.amount_desc`.

---

## 3. End-to-end meal logging sequence (what the web does)

1. **Input phase.**
   - Defaults: date = `?date` or today (from `/auth/me` `today`), time = now (`HH:MM`), meal type = `guessMealType(now)`.
   - The user types text and/or picks photos. Each pick is uploaded immediately via `POST /uploads`, up to 6 in total.
   - Optional: the "常用食物（一键添加 1 份）" chips, built from the **first 12** of `GET /foods?scope=all`. Tapping one calls `POST /foods/{id}/item {grams: serving_g ?? 100}`, which gives `items = [thatItem]` and moves to the review phase. These chips show only while in the input phase with zero items.
2. **Analyze.** `POST /ai/meal {text, date, time, meal_type, photos: [ids]}` returns `job_id`. Then `GET /ai/jobs/{id}` every 1.5 s until done or error.
   - On done: `draft = result minus items`, then `items = [...old items that have food_id (only when NOT a follow-up), ...result.items]`. Move to review.
   - On error: toast the message, and go back to review if items exist, otherwise to input.
3. **Follow-up.** If `draft.questions` is not empty, show them with an input. Submitting re-runs step 2 with `text = "{text}\n补充：{extra}"`, replaces **all** items with the new result, and stores the combined text as the description.
4. **Review.**
   - Edit items (section 4).
   - Add from the library: the picker calls `POST /foods/{id}/item {grams}`.
   - Remove items.
   - Optionally save an item to the library (2.21).
   - Preview updates are debounced (2.8).
5. **Save.**
   - New meal: `POST /meals`. Editing: `PUT /meals/{editId}`.
   - Body: `{date, time, meal_type, description: text, photos: [ids], ai_summary: draft?.summary ?? "", ai_model: draft?.model ?? "", items}`. `items` are the DraftItems as-is; extra fields are ignored server-side.
   - Success toast `已保存，评分已更新`, then navigate to that day.
6. **Edit an existing meal.**
   - Load `GET /day/{date}`, take the meal with `id == editId`, and fill date, time, meal type and text (= `description`). Items become `m.items.map(toDraft)`. Go straight to review.
   - Photos are **not** loaded (the photo list starts empty), `draft` is null, and preview uses `replace_meal_id = editId`.

---

## 4. Client-side item math (replicate exactly)

The web keeps both the per-portion values and the per-100 g values on each DraftItem. All scaling is linear. No rounding is applied to stored values; rounding is display-only.

### 4.1 Grams change: `rescale(item, grams)`, applied when the user enters `grams > 0`
```
f = grams / 100
item.amount_g    = grams
item.amount_desc = fmt(grams) + " g"            // fmt = zh-CN integer formatting with grouping, e.g. 1200 → "1,200 g"
item.nutrients   = { k: per100.nutrients[k] * f  for every k in per100.nutrients }
item.groups      = { k: per100.groups[k]    * f  for every k in per100.groups }
item.hazards     = per100.hazards.map(h => { key: h.key, amount: h.amount_per_100g * f })   // per-portion hazard NOTES ARE DROPPED
// unchanged: name, food_id (kept!), category, cooking_method, nova_group, confidence, notes, per100, save_suggested
```
- Values ≤ 0 or non-numeric input are ignored, and the item is left unchanged.
- The grams field displays `round(amount_g × 10) / 10`.
- `food_id` is kept on purpose: the server recomputes library items from `amount_g` anyway.

### 4.2 Deriving per-100 g for already-saved items: `toDraft(mealItem)`
```
f = amount_g > 0 ? 100 / amount_g : 1
per100 = { nutrients: nutrients × f, groups: groups × f,
           hazards: hazards.map(h => { key: h.key, amount_per_100g: h.amount × f }) }
save_suggested = false
```

### 4.3 Direct value edits (the expanded "调整" panel)
- **Nutrient edit** of key `k` to `v`, where input is clamped `max(0, Number(v) || 0)`:
  - `nutrients[k] = v`
  - `per100.nutrients[k] = v × 100 / (amount_g || 1)`
  - **`food_id = null`**
- **Group edit**: the same, on `groups` and `per100.groups`, and **`food_id = null`**.
- **Remove hazard i**: remove index `i` from **both** `hazards` and `per100.hazards`; **`food_id = null`**.
  - This assumes the arrays are index-aligned, which they are for server-produced drafts. Keep them aligned.
- **Add hazard `key`**:
  - append `{key, amount: amount_g}` to `hazards`
  - append `{key, amount_per_100g: 100}` to `per100.hazards`
  - **`food_id = null`**

  That is, the whole portion is treated as the hazard food. Only `flag`-type keys not already present are offered.
- **Edits that do NOT unlink `food_id`**: name, category (picker over 1.3), NOVA (`未知` or 1–4), and portion description (`amount_desc`, free text).
- Nutrient inputs display `round(value × 100) / 100`.
- When `food_id` is set, the panel shows the banner: `这一项来自食物库。修改具体数值后将按你填写的数值保存，不再与食物库条目关联。`

### 4.4 Totals line under the item list
The line sums `nutrients` over all items: `合计 {kcal} kcal · 蛋白 {protein_g,1}g · 钠 {sodium_mg}mg · 添加糖 {added_sugars_g,1}g · 饱和脂肪 {sat_fat_g,1}g`, where `,1` means one decimal.

Per-item macro line: `{kcal} kcal · 蛋白 {g,1}g · 碳水 {g,1}g · 脂肪 {g,1}g · 钠 {mg}mg · 添加糖 {g,1}g · 纤维 {g,1}g`.

### 4.5 Library picker math (before calling `/foods/{id}/item`)
- Default grams = `serving_g ?? 100`.
- If `serving_g` is set, show quick chips `0.5 份 / 1 份 / 1.5 份 / 2 份`, each setting `grams = serving_g × m`.
- Live preview: `kcal = per100.energy_kcal × grams / 100`, and the same for `蛋白`, `钠` and `添加糖`.
- Confirm button: `添加 {grams} g`.

### 4.6 Number formatting: `fmt(v, d = 0)`
- `null` or non-finite → `—`.
- Otherwise `v.toLocaleString("zh-CN", {maximumFractionDigits: d, minimumFractionDigits: 0})`: grouping separator `,`, trailing zeros trimmed.
- iOS equivalent: `NumberFormatter` with locale `zh_CN`, `.decimal` style, `maximumFractionDigits = d`, `minimumFractionDigits = 0`.
- Use the nutrient `decimals` from 1.1 when showing per-100 g tables.

### 4.7 Food detail table (web `FoodDetail`)
- Columns: `营养素 | 每 100 g | 每份 {s} g | 占标签 DV`, where `s = serving_g ?? 100`.
- Per serving = `per100[k] × s / 100`.
- DV% = `round(per-serving / dv × 100)`, shown only when the nutrient has a `dv`.
- Nutrients listed in `label_fields` get a chip `标签`.

---

## 5. Server validation and error messages (verbatim, for matching or display)

| Endpoint | Message |
|---|---|
| any | `未登录或令牌已失效` (401) · `请求格式不正确` (400) · `服务器内部错误` (500) · `接口不存在` (404) · `文件太大` (413) |
| POST /uploads | `请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）` |
| GET /uploads/{id} | `不存在` (404) |
| POST /ai/meal | `请描述吃了什么，或上传照片` |
| POST /ai/food | `请输入食物名称或上传包装/营养成分表照片` |
| POST /ai/exercise, /preview, /day | `请先完善个人档案` |
| POST /ai/exercise | `运动描述不能为空` |
| GET /ai/jobs/{id} | `任务不存在` (404) |
| POST/PUT /meals | `日期格式不正确` · `时间格式不正确` · `至少需要一种食物` · `食物名称不能为空` · `重量不能为空` · `重量格式不正确` · `重量不能小于 0.1` · `重量不能大于 20000` |
| PUT/DELETE /meals/{id} | `餐食不存在` (404) |
| POST /water | `饮水量不能为空` · `饮水量格式不正确` · `饮水量不能小于 -2000` · `饮水量不能大于 3000` |
| foods | `食物不存在` (404) · `只能修改自己创建的食物` (403) · `只能删除自己创建的食物` (403) · `名称不能为空` · `每份重量不能小于 0.1` · `每份重量不能大于 10000` · `每份重量格式不正确` · `缺少食物数据` |
| POST /foods/{id}/item | `克数格式不正确` · `克数不能小于 0.1` · `克数不能大于 20000` |
| job `error` values | `服务器重启，任务中断，请重试` · `claude -p 超时（{n} 秒）` · `模型拒绝了该请求：{reason}` · `AI 输出超过长度上限` · `联网搜索轮次过多，未能完成` · `AI 未返回可解析的 JSON` · `无法启动 claude CLI：…` · `claude -p 失败：…` · `claude -p 输出无法解析（退出码 n）：…` · raw SDK messages |

Message templates generated by the server's validators (`{name}` is the field label):
- `{name}不能为空`
- `{name}格式不正确`
- `{name}不能小于 {min}`
- `{name}不能大于 {max}`

The default label is `数值` for numbers and `字段` for strings.

---

## 6. Chinese UI strings used by the web (reuse verbatim)

### 6.1 Log meal page (`LogMeal.tsx`)
- Title: `记一餐` / edit mode: `编辑这一餐`
- Subtitle: `用自然语言描述即可，比如“中午一碗牛肉面加一个卤蛋，喝了杯无糖豆浆”`
- Field labels: `日期`, `时间`, `餐次`, `吃了什么`
- Text placeholder: `例：早上两个水煮蛋、一杯燕麦牛奶、半个苹果；中午一包李子柒螺蛳粉…（写上品牌、份量、做法会更准）`
- Photos label: `照片（可选：食物照片、包装、配料表、营养成分表）`
- Photo accessibility: `已上传的照片`, `移除照片`, `添加照片`
- Analyze button: `AI 分析`. In review with items: `重新分析文字描述`
- Library button: `从食物库添加`
- Analyzing card:
  - Title: `排队中…` while status is `queued`, otherwise `Claude 正在分析`, followed by `{elapsed}s`
  - Staged hint by elapsed seconds:
    | elapsed | hint |
    |---|---|
    | < 8 | `识别食物与份量…` |
    | < 30 | `估算 40+ 种营养素、食物组与加工程度…` |
    | < 70 | `查询品牌产品的营养成分表…` |
    | otherwise | `快好了，正在核对致癌物与风险项…` |
- Summary banner shows `draft.summary`.
- Follow-up box:
  - Title: `AI 想确认：`, followed by the list of questions
  - Input placeholder: `补充说明后重新分析（可选）`
  - Button: `补充并重新分析`
- Assumptions disclosure: `估算假设（{n}）`
- Sources: `参考来源：` followed by link titles
- Review card:
  - Title: `审核解析结果`
  - Hint: `可改名称、克数和每项营养数值，删除多余项；确认后才合并`
  - Empty state: `没有食物，重新分析或从食物库添加`
- Footer buttons: `添加`, and the save button `确认修改` in edit mode, otherwise `确认合并到 今天` when date == today, else `确认合并到 {date}`
- Toasts: `请描述吃了什么，或上传照片`, `至少需要一种食物`, `已保存，评分已更新`
- Quick foods: title `常用食物（一键添加 1 份）`, chip `{name} · {serving_g}g`
- Library picker (modal `从食物库添加`):
  - Search placeholder: `搜索名称、品牌、别名…`
  - Empty state: `食物库里没有匹配项。可以在“食物库”里用 AI 联网查询或拍营养成分表来添加。`
  - Row subtitle: `每 100 g {kcal} kcal · 钠 {mg} mg · 一份 {g} g · 来自 {owner_name}`. The last part appears only when the food is not mine.
  - Amount label: `吃了多少`
  - Chips: `0.5 份`, `1 份`, `1.5 份`, `2 份`
  - Macro line: `{kcal} kcal · 蛋白 {g}g · 钠 {mg}mg · 添加糖 {g}g`
  - Buttons: `← 返回搜索`, `添加 {grams} g`
- Save-to-library modal (`存入食物库`):
  - Description: `按每 100 g 的营养数据保存。下次记录时说出名称会自动匹配，也可以在“从食物库添加”里直接选择克数。`
  - Fields: `名称`, `品牌（可选）`, `一份的重量`, `别名（逗号分隔）` with placeholder `如：螺狮粉, luosifen`, `可见范围` with segments `仅自己` / `所有成员可用`
  - Macro line: `每 100 g：{kcal} kcal · 蛋白 {g}g · 钠 {mg}mg`
  - Button: `保存`
  - Toast: `已存入食物库，下次可直接搜索选择`

### 6.2 Item editor (`ItemEditor.tsx`)
- Accessibility labels: `食物名称`, `克数`, `删除这一项`, `移除该风险标记`, `添加风险标记`
- Buttons: `调整`; `存入食物库（推荐）` when `save_suggested`, otherwise `存入食物库`
- Chips:
  - `{amount_desc}`
  - category zh
  - `NOVA {n} · {zh}`
  - `食物库` when `food_id` is set
  - `置信度低`
  - hazard zh
  - `加工肉 {g} g`, `红肉 {g} g`
  - `已存入食物库`
- Panel labels: `分类`, `加工程度（NOVA）` (with option `未知`), `份量描述`, `营养素（这一份的总量）`, `显示全部 {n} 项`, `食物组（影响 HEI-2020 与红肉/加工肉判断）`, `补充风险标记：` (with option `选择…` and items `{zh}（IARC {iarc}）`)
- Library banner: `这一项来自食物库。修改具体数值后将按你填写的数值保存，不再与食物库条目关联。`

### 6.3 Today: meals section (`Today.tsx`)
- Card title: `饮食记录`, hint `{mealCount} 餐 · {intake kcal} kcal`
- Empty state: `还没有记录。` with button `记录第一餐`. For another user's view: `这一天没有记录`
- Header button: `记一餐`
- Meal row: `{time}`, `{meal type zh}`, `{kcal} kcal`. Edit and delete accessibility labels: `编辑` / `删除`. The description is shown in Chinese quotes: `“{description}”`.
- Item row: `{name} {amount_desc || "{amount_g} g"}`, plus a hazard icon (accessibility `含风险项`) when `hazards.length > 0`, and `{kcal} kcal`
- Delete confirmation: `删除 {time} 的{meal type zh}？`, toast `已删除`
- Water line: see 2.14

### 6.4 Merge preview (`ImpactPreview` in `ActivityRecognizer.tsx`)
- Title: `合并预览`, hint `确认前不会写入；数值随修改实时更新`
- Columns: `指标 | 合并前 | → | 合并后`
- Rows. A row is shown if `|after − before| > 0.05` or it is marked always:

  | label | before → after source | unit | decimals | better | always |
  |---|---|---|---|---|---|
  | `膳食质量 HEI-2020` | `score` | | 1 | up | yes |
  | `微量营养素 MAR` | `mar.value` | | 0 | up | |
  | `心血管健康 LE8（近 7 天）` | `indices.*.le8.score` | | 0 | up | yes |
  | `防癌 WCRF/AICR（近 7 天）` | `indices.*.wcrf.score` | `/ {max}` | 2 | up | |
  | `摄入能量` | `energy.intake` | kcal | | | |
  | `当日消耗` | `energy.tdee` | kcal | | | |
  | `能量差额` | `intake − tdee` | kcal | | | |
  | `钠` | `totals.sodium_mg` | mg | | down | |
  | `添加糖` | `totals.added_sugars_g` | g | 1 | down | |
  | `饱和脂肪` | `totals.sat_fat_g` | g | 1 | down | |
  | `蛋白质` | `totals.protein_g` | g | 1 | up | |
  | `膳食纤维` | `totals.fiber_g` | g | 1 | up | |

- Coloring: the after value is green when it moved in the "better" direction and red otherwise. Rows without a "better" direction stay neutral.
- `状态变化：` lists after-items whose status label changed and whose status is not `info`, formatted as `{HEI·}{zh}（{before} → {after}）` and joined with `；`.
  - Status labels: `good`/`ok` → `达标`, `warn` → `偏离`, `bad` → `不达标`, `info` → `提示`.
  - The `HEI·` prefix applies only to category `hei`.
- `LE8 分项：` lists `{zh} {old ?? "—"} → {new ?? "—"}` for LE8 components whose points changed.
- `新增风险物：` lists hazards in after that are not in before, as `{zh}（IARC {iarc}）` joined with `、`, shown in red.

### 6.5 Food library page (`Foods.tsx`)
- Title: `食物库`, subtitle `常吃的包装食品、外卖、自制菜存下来，下次直接搜索并填克数，无需再调用 AI`
- Buttons: `手动录入`, `AI 查询 / 拍营养表`
- Search: `搜索名称、品牌、别名…`. Scope segments: `全部可用` (all) / `我创建的` (mine)
- Empty state: `还没有食物。记一餐时 AI 分析出的食物可以一键“存入食物库”，也可以在这里用 AI 联网查询或拍营养成分表添加。`
- Card:
  - `{name}` with a visibility icon (accessibility `公开` / `私有`)
  - `{brand} · {serving_desc || "一份 {serving_g} g"}`
  - `每 100 g {kcal} kcal · 蛋白 {g} · 钠 {mg}mg`
  - Chips: source zh, `NOVA {n}`, `用过 {use_count} 次` (when > 0), `来自 {owner_name}` (when not mine)
- Detail:
  - Chips: category zh, `NOVA {n} · {zh}`, source zh, hazard zh
  - `{notes}`, `配料：{ingredients}`, source links
  - Table headers per 4.7; label chip `标签`
  - Buttons (mine only): `删除` (confirmation and toast in 2.19), `编辑`
- AI lookup modal `AI 查询营养信息`:
  - Description: `输入产品名称让 {model} 联网查找官方营养成分表；或者上传包装、配料表、营养成分表照片，直接读取标签数值（更准确）。`
  - Fields: `名称` (placeholder `如：螺蛳粉`), `品牌` (placeholder `如：李子柒`), `补充说明（可选）` (placeholder `如：原味 335g 袋装；我一般只喝一半汤`), `照片（可选）`
  - Button: `开始`; while busy, a spinner and `{elapsed}s`
  - Busy text: `正在读取标签…` when there are photos, otherwise `正在联网查找营养成分表…`, followed by `一般需要 30–120 秒`
  - On result, the editor opens prefilled: `aliases` joined with `,`, `source_urls = draft.sources`, `hazards100`, `source`, and so on.
- Editor modal: title `编辑食物` / `保存到食物库`
  - Banner showing `notes` when `source != "manual"`; source links
  - Fields: `名称`, `品牌`, `分类`, `一份重量` (g), `份量描述` (placeholder `1 包 335 g`), `加工程度 (NOVA)` (`未知` / 1–4), `别名（逗号分隔，用于搜索和自动匹配）`, `可见范围` (`仅自己` / `所有成员可用`), `配料表（可选）`
  - Section: `每 100 g 营养成分` with toggle `显示全部 {n} 项`. The toggle starts on when editing an existing food or when `source != manual`. Hint when collapsed: `营养标签上通常只有这几项；其余营养素留空按 0 计，也可以让 AI 查询补全。`
  - Per-100 inputs display `round(x × 1000) / 1000`; an empty input becomes 0.
  - Button: `保存` (disabled while name is empty). Toast: `已保存到食物库`.
  - Blank defaults for manual entry: `name ""`, `brand ""`, `aliases ""`, `category "other"`, `serving_g 100`, `serving_desc ""`, `per100 {}`, `groups100 {}`, `hazards100 []`, `nova_group null`, `ingredients ""`, `label_fields []`, `source "manual"`, `source_urls []`, `notes ""`, `visibility "private"`.

### 6.6 Generic
- `waitJob` failure fallback: `AI 任务失败`; client cancel: `已取消`
- HTTP failure fallback: `请求失败（{status}）`

---

## 7. Risks, surprises and suggested ADDITIVE server changes

### 7.1 Client-side must-dos
1. Send JSON `{}` bodies on every POST and PUT (Express 5 `req.body` is undefined otherwise, which produces a 500).
2. Disable cookie storage. A stale `nl_session` cookie overrides the bearer token.
3. Convert HEIC to JPEG, keep the filename extension consistent with the bytes, and send at most 6 files, all under the field `photos`.
4. Load `/api/v1/uploads/{id}` with the auth header. `AsyncImage` cannot do this.
5. Set `food_id = null` whenever nutrient, group or hazard values are hand-edited; otherwise the server silently reverts them to library values.
6. Food `PUT` is a full replacement: round-trip every field.
7. `Food.aliases` is a comma-joined **string**, while `FoodDraft.aliases` is an **array**.
8. Hide and protect the `饮水` water pseudo-meal.
9. Decode nutrient and group vectors as dictionaries with a default of 0, and accept `""` or `null` for optional strings.
10. AI jobs: persist `job_id`, poll every 1.5–2 s, expect several minutes, and remember there is no cancel or progress on the server.
11. ATS/HTTP: production is HTTP on a bare IP, so the app needs an ATS exception and tokens travel unencrypted.

### 7.2 Server quirks to be aware of (no change required)
- `PUT /meals/{id}` ignores `photos`, `ai_summary` and `ai_model`.
- `use_count` is inflated on every edit.
- `/preview` drops `category`, so the after `fastFoodMeals` value can be under-counted, and it does not apply library recomputation.
- Multer count and field errors return 500 instead of 400.
- No pagination on `/foods` (limit 200).
- `GET /meals/recent-items` uses the server's UTC date window.
- The time regex does not check ranges.
- Future dates are accepted.

### 7.3 Optional additive changes that would help the iOS app without altering web behavior or layout
- `GET /meals?start=&end=`: a list of meals (1.11 shape) without computing scores, for a history list or offline cache.
- An opt-in `PATCH /meals/{id}` (or a new field `update_photos: true` on PUT) so the app can edit photos and `ai_summary` without changing what the web's PUT does.
- Return `ai_model` in `Meal`, and a `created_at` if useful for sync.
- `DELETE /ai/jobs/{id}` (cancel a queued job) and an optional `queue_position` in the job response. Both are purely additive fields.
- Map `LIMIT_FILE_COUNT` and `LIMIT_UNEXPECTED_FILE` to 400 with a Chinese message.
- Pass `category` through in `/preview`. This is a correctness fix that would also make the web preview slightly more accurate.
- Accept `image/heic` and convert server-side. Not needed if the client converts.
