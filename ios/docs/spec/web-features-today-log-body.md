# 食迹 NutriLog: Web feature spec for Today / Log Meal / Body (for the native iOS client)

Source of truth: `aaaaa/web/src/pages/Today.tsx`, `LogMeal.tsx`, `Body.tsx`, `web/src/components/{ItemEditor,ActivityRecognizer,HealthIndices,TotalScore,ui}.tsx`, plus the server code they call (`server/src/routes/{log,body,reports,account}.ts`, `server/src/scoring/*`, `server/src/ai/service.ts`, `server/src/standards/*`).
Where this document and `docs/screenshots/*.png` disagree, **the code wins**. The screenshots predate the composite "今日总分": they show "今日膳食质量" with grade "美国平均 58", but the current code shows "今日总分" with grade "满分 100" plus a line of composite parts.

Conventions in this doc:
- `T?` means the field may be `null`. "optional" means the key may be absent.
- JSON numbers are IEEE doubles unless marked `int`.
- Every string in 「」 or in `"..."` that the UI displays is **verbatim** Chinese. Reuse it as is.
- `{x}` inside a UI string is an interpolation.

---

## 0. Global conventions

### 0.1 Base URL, auth, errors
- Base: `http://45.63.23.52:8787/api/v1` (identical routes are also mounted at `/api`). Production is **plain HTTP**, so iOS needs an ATS exception (`NSAllowsArbitraryLoads` or a domain exception for that IP).
- Auth: `Authorization: Bearer nla_…`, from `POST /auth/token {username, password, device_name?}` → `{token, expires_at, user}`. The token lasts 365 days.
- Every endpoint in this document requires auth, except the liveness check `GET /health`.
- Error shape for every non-2xx response: `{"error": "<中文 message>"}`.
  - 400 validation: messages are listed per endpoint. Malformed JSON gives "请求格式不正确".
  - 401 `"未登录或令牌已失效"`. The web treats any 401 outside `/auth/*` as a logout. iOS should clear the token and show login.
  - 403: e.g. "对方没有向你共享数据".
  - 404: e.g. "餐食不存在", "食物不存在", "不存在", "任务不存在", "用户不存在".
  - 413 "文件太大" (an upload over 12 MB per photo).
  - 500 "服务器内部错误".
- The web client's generic fallback message, when the body has no `error`, is `请求失败（{status}）`.
- Request bodies are JSON with `Content-Type: application/json`, except the multipart uploads. Express caps JSON bodies at **2 MB**.
- Most user-facing endpoints need a profile. Without one, they return 400 "请先完善个人档案".

### 0.2 "Today" and dates
- All dates are local date strings `YYYY-MM-DD`. Times are `HH:MM` in 24-hour format.
- "Today" for the user is `GET /auth/me` → `today`, computed from the profile timezone (default `Asia/Shanghai`). The web only falls back to the device date when `me` is missing. **iOS must use `me.today`**, not the device date, for "today" logic: the date-picker max, the "今天" label, and the default dates.
- Date arithmetic in the web is UTC-based on `YYYY-MM-DD`: `addDays(date, n)` and `diffDays(a, b)` = whole days from `b − a`.
- `dateLabel(date, today)`:
  - base = `{M}月{D}日 {周X}`, where 周X is from `["周日","周一","周二","周三","周四","周五","周六"]`. Month and day have no zero padding.
  - If `diffDays(date, today) == 0`, the label is `今天 · {base}`. If it is `1`, the label is `昨天 · {base}`. Otherwise it is `base`.
  - Example: `今天 · 9月30日 周三`.

### 0.3 Number formatting `fmt(v, d = 0)`
- If `v` is null, undefined, NaN or ±∞, return `"—"` (U+2014).
- Otherwise use the `zh-CN` locale with a grouping separator ",", `maximumFractionDigits = d` and `minimumFractionDigits = 0`. Trailing zeros are dropped: `fmt(39.20, 1) = "39.2"` and `fmt(78.0, 1) = "78"`.
- Rounding is half away from zero (JS `Intl` halfExpand). In Swift, use `NumberFormatter` with `locale = zh_CN`, `numberStyle = .decimal`, `roundingMode = .halfUp` (ICU half-up means away from zero), `maximumFractionDigits = d` and `minimumFractionDigits = 0`.
- Negative numbers use ASCII "-", e.g. `-795`. Some strings deliberately use "−" (U+2212); this is called out where it happens.
- Examples: `fmt(1568) = "1,568"`, `fmt(4535) = "4,535"`, `fmt(10.6, 1) = "10.6"`.

### 0.4 Design tokens (light / dark)
Use these as Asset-catalog colors with "Any / Dark" variants.

| token | light | dark | use |
|---|---|---|---|
| page | #f6f5f1 | #0f0f0e | screen background |
| surface | #fcfcfb | #1a1a19 | cards |
| surface-2 | #f1f0ec | #232321 | banners, chips, seg background, group rows |
| surface-3 | #e9e8e2 | #2c2c2a | meter / ring track |
| ink | #0b0b0b | #ffffff | headings, big numbers |
| ink-1 | #262624 | #ecebe6 | body text |
| ink-2 | #52514e | #c3c2b7 | secondary text (`sec`) |
| ink-3 | #898781 | #898781 | muted text (`muted`) |
| hair | #e1e0d9 | #2c2c2a | separators |
| axis | #c3c2b7 | #383835 | "info"/null colour |
| border | rgba(11,11,11,.1) | rgba(255,255,255,.1) | card border |
| accent | #1f6f50 | #3a9c73 | primary buttons |
| accent-soft | #e2eee7 | #1b3128 | accent banner / chip background |
| accent-text | #1a5e44 | #6cc79f | links, accent banner text |
| good | #0ca30c | same | status fills |
| warning | #fab219 | same | |
| serious | #ec835a | same | |
| critical | #d03b3b | same | |
| good-text | #006300 | #3fc23f | coloured text |
| warning-text | #7a5200 | #fab219 | |
| serious-text | #9c4320 | #ef9670 | |
| critical-text | #b02e2e | #ea6b6b | |
| good-soft | #e6f4e4 | #17301a | badge backgrounds |
| warning-soft | #fdf1d6 | #342a12 | |
| serious-soft | #fbe8df | #3a2419 | |
| critical-soft | #f9e2e0 | #3a1c1c | |
| series-1 | #2a78d6 | #3987e5 | intake / protein / steps / weight trend |
| series-2 | #eb6834 | #d95926 | expenditure / fat / exercise flame |
| series-3 | #1baf7a | #199e70 | target / carbs |
| series-4 | #eda100 | #c98500 | |
| series-5 | #e87ba4 | #d55181 | alcohol |

Other visual constants:
- Card radius 14, padding 18×20 (16 on phones), 1 px border, very soft shadow.
- Small radius 10. Chip and pill radius 99.
- Font: system (PingFang SC).
- Headings: h1 24 (21 on mobile), h2 18, h3 15, weight about 650.
- Body text 15. `small` text 13. `muted` = ink-3. `sec` = ink-2. Numbers use tabular digits (`.monospacedDigit()`).

### 0.5 Status model
`Status = "good" | "ok" | "warn" | "bad" | "info"`

| status | badge text (`StatusBadge`) | icon | badge colours | `statusColor()` (bar fill) |
|---|---|---|---|---|
| good | 达标 | circle-check | good-text on good-soft | good |
| ok | 达标 | circle-check | good-text on good-soft | good |
| warn | 偏离 | triangle-alert | warning-text on warning-soft | warning |
| bad | 不达标 | circle-x | critical-text on critical-soft | critical |
| info | 提示 | info | ink-2 on surface-2 | axis |

The badge is a pill: 12.5 pt semibold, 14 pt icon, padding 2/8/2/6.

### 0.6 Shared enumerations and label maps
- `MEAL_TYPES` (key → zh, default time):

  | key | zh | default time |
  |---|---|---|
  | breakfast | 早餐 | 08:00 |
  | lunch | 午餐 | 12:30 |
  | dinner | 晚餐 | 18:30 |
  | snack | 加餐 | 15:30 |
  | drink | 饮品 | 10:00 |
  | other | 其他 | 12:00 |

  `mealZh(k)` returns the zh label, or the key itself when unknown. The server accepts only these 6 keys; anything else becomes `"other"`.
- `guessMealType(HH:MM)`, using the hour `h`:

  | hour | meal type |
  |---|---|
  | h < 10 | breakfast |
  | h < 14 | lunch |
  | h < 17 | snack |
  | h < 21 | dinner |
  | otherwise | snack |
- `CATEGORY_ZH`: staple 主食, vegetable 蔬菜, fruit 水果, meat 肉类, poultry 禽肉, seafood 水产, egg 蛋类, dairy 奶制品, soy_legume 豆制品/豆类, nut_seed 坚果种子, snack 零食, dessert 甜点, beverage 饮品, alcohol 酒类, condiment 调味品, fast_food 速食/快餐, dish 菜肴, supplement 补充剂, other 其他. This order is also the order of the category picker.
- `NOVA_ZH`: 1 未加工, 2 烹饪原料, 3 加工食品, 4 超加工.
- `SOURCE_ZH` (food library): label 营养标签, ai_search AI 联网查询, ai_estimate AI 估算, manual 手动录入.

### 0.7 Reference data: `GET /standards/meta`
Fetch once after login and cache it. It drives nutrient order, the food-group list, hazard definitions, the activity list and source links.

```
Meta {
  version: int,
  nutrients: [NutrientDef],
  foodGroups: [FoodGroupDef],
  hazards: [HazardDef],
  hazardsInfoOnly: [{zh, iarc, examples, why}],
  hei: [{key, zh, en, max, kind: "adequacy"|"moderation", best, worst, unit, hint}],
  activities: [Activity],
  activityLevels: [{key, zh, pal, desc}],
  sources: [Source],
  lifeStages: [{id, zh}],
  marNutrients: [string],
  heiUsMean: number,     // 58
  conditions: [{key, zh, effect}]
}
NutrientDef  { key, zh, en, unit, group: "energy"|"macro"|"carb"|"fat"|"mineral"|"vitamin"|"other", decimals: int, dv?: number, note?: string }
FoodGroupDef { key, zh, unit, note }
HazardDef    { key, zh, en, iarc: "1"|"2A"|"2B"|"—", category, risk, detect, examples, refAmount, aiFlag: bool, sources: [string], advice,
               dose: {from: "group", key, unit:"g"} | {from:"nutrient", key, unit} | {from:"flag", unit:"g"|"mg"|"ml"} }
Activity     { key, zh, met, speedKmh?, code?, intensity: "light"|"moderate"|"vigorous" }
Source       { id, org, title, year, url }
```

Nutrient keys in display order. `decimals` is in parentheses; the group changes where the header rows go.
- energy: `energy_kcal` 能量 kcal (0)
- macro: `protein_g` 蛋白质 (1), `carb_g` 碳水化合物 (1), `fat_g` 总脂肪 (1), `water_g` 水分(食物+饮品) (0)
- carb: `fiber_g` 膳食纤维 (1), `sugars_g` 总糖 (1), `added_sugars_g` 添加糖 (1)
- fat: `sat_fat_g` 饱和脂肪 (1), `trans_fat_g` 反式脂肪 (2), `mufa_g` (1), `pufa_g` (1), `linoleic_g` (1), `ala_g` (2), `epa_dha_g` (2), `cholesterol_mg` 胆固醇 (0)
- mineral: `sodium_mg` 钠 (0), `potassium_mg`, `calcium_mg`, `iron_mg` (1), `magnesium_mg`, `phosphorus_mg`, `zinc_mg` (1), `copper_mg` (2), `manganese_mg` (2), `selenium_ug` µg, `iodine_ug` µg
- vitamin: `vit_a_ug` µg RAE, `vit_c_mg`, `vit_d_ug` (1), `vit_e_mg` (1), `vit_k_ug`, `thiamin_mg` (2), `riboflavin_mg` (2), `niacin_mg` (1), `pantothenic_mg` (1), `vit_b6_mg` (2), `biotin_ug`, `folate_ug` µg DFE, `vit_b12_ug` (2), `choline_mg`
- other: `caffeine_mg` 咖啡因 (0), `alcohol_g` 酒精 (1)

Food-group keys (22). Unit `杯当量`, `盎司当量`, `g`, `份` or `ml`:
`fruit_total_cup`, `fruit_whole_cup`, `veg_total_cup`, `veg_dark_green_cup`, `legumes_cup`, `grains_whole_oz`, `grains_refined_oz`, `dairy_cup`, `protein_total_oz`, `seafood_oz`, `plant_protein_oz`, `red_meat_g`, `processed_meat_g`, `poultry_g`, `fruit_veg_g`, `berries_cup`, `olive_oil_g`, `butter_cream_g`, `cheese_g`, `nuts_g`, `sweets_serv`, `ssb_ml`.

Hazard keys:
- `dose.from = "group"`: `processed_meat` (1), `red_meat` (2A).
- `dose.from = "nutrient"`: `alcohol` (1).
- `dose.from = "flag"` (these are the only ones a user or the AI can attach to an item): `salted_fish_cantonese` 1, `areca_nut` 1, `aflatoxin_risk` 1, `high_temp_meat` 2A, `smoked_food` 2A, `acrylamide` 2A, `pickled_vegetables` 2B, `very_hot_beverage` 2A (ml), `bracken_fern` 2B, `high_mercury_fish` "—", `hijiki` 1, `aspartame` 2B (mg).

Activities (45, all with MET): `walk_slow` 3.0, `walk_moderate` 3.8, `walk_brisk` 4.8 (zh "快走 (约 6 km/h)"), …, `other_light` 2.5, `other_moderate` 4.5, `other_vigorous` 7.5. Always use `meta.activities` for pickers.

---

## 1. Data shapes (JSON as returned by the server)

### 1.1 `Me` (`GET /auth/me`)
```
{
  user: { id:int, username, display_name, avatar_color:"#rrggbb", share_mode:"private"|"public"|"selected",
          share_detail:"summary"|"full", api_token_hint: string?, share_with:[int] },
  profile: Profile?,                 // null → user must onboard; all screens below need it
  today: "YYYY-MM-DD",
  ai: { provider: "cli"|"api"|"mock", model: string },   // model === "offline" when provider is mock
  conditions: [{key, zh, effect}]
}
Profile { sex:"male"|"female", birth_date, height_cm, weight_kg /* 建档体重 */, activity_level, goal:"lose"|"maintain"|"gain",
          goal_rate_kg_week, target_weight_kg?, physiology:"none"|"pregnant"|"lactating", sodium_mode:"cdrr"|"aha",
          conditions:[string], timezone, nicotine, secondhand_smoke: bool }
```

### 1.2 `DayResponse` (`GET /day/{date}`)
```
{
  date: "YYYY-MM-DD",
  indices: HealthIndices,          // rolling 7-day window ending at date (date-6 … date)
  score: DailyScore,
  targets: Targets,
  meals: [Meal],                   // [] when viewing someone who shares "summary" only
  activity: ActivityDay?,          // null if no row for that date
  exercises: [Exercise],           // ordered by time; [] when summary-only share
  body: [BodyMetric],              // ordered by time (always returned, even for summary share)
  weightTrend: number?,            // EWMA-smoothed weight (alpha 0.1, 60-day warm-up), kg
  full: bool                       // false = summary-only share
}
```

### 1.3 `DailyScore`
```
{
  date, hasData: bool,             // hasData = itemCount>0 && total kcal>0
  score: number?,                  // HEI-2020 total (0–100); null when no data or kcal<200
  total: CompositeScore,           // "今日总分"
  categories: [{ key:"hei"|"mar", zh, score, source, note }],
  items: [ScoreItem],              // [] when !hasData
  hei: { total, components:[{ key, zh, score, max, value, unit, hint }] }?,   // null if kcal<200 or no data
  mar: { value /*0–100*/, nutrients:[{ key, zh, intake, target, nar /*0–1*/ }] }?,
  hazards: [HazardResult],         // sorted by IARC rank 1 < 2A < — < 2B
  energy: Energy,
  totals: { <every nutrient key>: number },   // always all keys, 0 when absent
  groups: { <every food group key>: number },
  macroPct: { protein, carb, fat, satFat, addedSugar, alcohol },      // % of kcal
  upfPct: number,                  // % kcal from NOVA-4 items
  mealCount: int,                  // meals with ≥5 kcal (water-only "meal" is NOT counted)
  itemCount: int, fastFoodMeals: int,
  completeness: { level: "none"|"partial"|"likely", note: string },
  top: { issues: [string], wins: [string] },  // ≤7 issues, ≤4 wins, pre-rendered Chinese sentences
  weightKg: number,                // weight used for the day (latest weighing ≤ date, else profile weight)
  weighedToday: number?,           // last weighing on that date, else null
  version: int                     // scoring version (3); ignore
}
CompositeScore { score: number? /*0–100*/, parts:[CompositePart], missing:[string /*zh of missing parts*/] }
CompositePart  { key:"hei"|"mar"|"energy"|"activity", zh, weight /*50,15,15,20*/, score: number?, points: number?, note }
ScoreItem { key, category:"hei"|"mar"|"adequacy"|"moderation"|"energy", zh, value, unit, targetText,
            target?, ideal?, limit?, status: Status, score /*0–1*/, points, maxPoints, message, sources:[sourceId] }
HazardResult { key, zh, iarc, dose, unit, foods:[string], message, sources:[sourceId] }
Energy { intake, resting, restingSource:"device"|"bmr", active, activeSource:"device"|"steps"|"exercise"|"none",
         exerciseKcal, tef, tdee, method:"measured"|"eer", target, balance }
```
- Composite part names (`zh`): 膳食质量 (50), 微量营养素 (15), 能量平衡 (15), 身体活动 (20). When some parts are null, the weights are rescaled to 100.
- `completeness.note` strings:
  - none: "今天还没有记录"
  - partial: "记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考"
  - likely: "记录较完整"
- ScoreItem keys the UI looks up directly:
  - `sodium_mg`, `added_sugars_g`, `sat_fat_pct`, `fiber_g`, `protein_g`, `alcohol_g`, `caffeine_mg`, `energy_balance`
  - plus `hei_<component>` (e.g. `hei_sodium`), `water_g`, `trans_fat_g`, `upf_pct`, `added_sugars_per_meal`, `amdr_protein|carb|fat`, `ul_<nutrient>`, `cholesterol_mg` (always `info`), and every RDA/AI nutrient key.

### 1.4 `HealthIndices`
```
{
  windowDays:int, loggedDays:int,
  mepa: { score:int /*0–16*/, days:int, items:[MepaItem] }?,     // null if <3 logged days
  le8: { score:number?, category:{key:"high"|"moderate"|"low", zh:"高"|"中"|"低"}?, available:int /*0–8*/, components:[Le8Component] },
  wcrf: { score:number, max:number /*sum of scored components' max, ≤6*/, components:[WcrfComponent] },
  pa: { le8MinPerWeek:number?, mvpaMinPerWeek:number?, strengthDays:int },
  sleepHours:number?
}
MepaItem      { key, zh, criterion, value, unit, met:bool }
Le8Component  { key:"diet"|"activity"|"nicotine"|"sleep"|"bmi"|"lipids"|"glucose"|"bp", zh, points:number? /*0–100*/, value:string, rule, missing }
WcrfComponent { key:"weight"|"activity"|"plants"|"upf"|"meat"|"ssb"|"alcohol", zh, points:number?, max:number /*1, or 0 for upf*/, detail, rule }
```

### 1.5 `Targets`
```
{ date, age, sex, lifeStage, lifeStageZh, physiology, sensitive:bool, weightKg, heightCm, bmi, bmiCategory:{key,zh},
  referenceWeightKg, bmr, eer, eerMethod:string /* e.g. "NASEM 2023 EER" */, goal, goalDeltaKcal /* negative when losing */,
  energyTarget, energyFloor,
  protein:{ rdaG, idealLowG /*1.2 g/kg*/, idealHighG /*1.6 g/kg*/, perKgRda },
  intake:{ <nutrientKey>: { key, value, kind:"RDA"|"AI", source, note? } },     // includes water_g, fiber_g, protein_g, sodium_mg …
  upper:{ <nutrientKey>: { value, appliesToTotal:bool, note? } },
  limits:{ sodium_mg|added_sugars_g|sat_fat_pct|trans_fat_g|alcohol_g|caffeine_mg|upf_pct:
           { key, zh, unit, ideal, limit, idealSource, limitSource, note? } },
  amdr:{ protein:[lo,hi], carb:[lo,hi], fat:[lo,hi], n6:[lo,hi], n3:[lo,hi] },
  addedSugarPerMealG: 10, aspartameAdiMg }
```

### 1.6 Meals
```
Meal { id:int, date, time, meal_type, description:string, photos:[photoId /* filename, not URL */], ai_summary:string?, items:[MealItem] }
MealItem { id:int, meal_id:int, name, amount_g, amount_desc:string?, food_id:int?, category:string?, cooking_method:string?,
           nova_group:int? /*1–4*/, confidence:string? /*"high"|"medium"|"low"*/,
           nutrients:{all nutrient keys}, groups:{all food-group keys}, hazards:[{key, amount, note?}], notes:string? }
DraftItem = MealItem fields (id/meal_id absent) + {
           per100:{ nutrients:{…}, groups:{…}, hazards:[{key, amount_per_100g, note?}] },
           save_suggested: bool, saved_food_id?: int /* client-only */ }
MealDraft { items:[DraftItem], summary, assumptions:[string], questions:[string], sources:[{title,url}], provider, model }
```
- A photo URL is `/api/uploads/{photoId}`, relative to the host. It **requires the Bearer header**, so a plain `AsyncImage` will not work; load it with an authenticated `URLSession`.

### 1.7 Body and activity rows (raw DB rows; extra columns are present)
```
ActivityDay { user_id, date, steps:int?, active_kcal?, resting_kcal?, distance_km?, exercise_min?, sleep_hours?, stand_hours?,
              source:"manual"|"apple_shortcut"|"apple_export"|"ai_screenshot", updated_at }   // NO id; key = date
Exercise    { id, user_id, date, time, description, activity_key:string?, met, duration_min, distance_km?, kcal /* net, (MET−1)×kg×h */,
              in_device: 0|1, avg_hr?, device_kcal?, source:"manual"|"ai", created_at }
BodyMetric  { id, user_id, date, time, weight_kg?, body_fat_pct?, waist_cm?, sbp?, dbp?, bp_treated:0|1, note?,
              source:"manual"|"profile"|"ai"|"apple_shortcut"|"apple_export", created_at }
Lab         { id, user_id, date, total_chol?, hdl?, non_hdl?, ldl?, lipid_treated:0|1, fasting_glucose?, hba1c?, diabetes:0|1, note?, created_at }
```
Booleans come back as **0/1 integers**, not `true`/`false`.

### 1.8 Preview and AI activity draft
```
DayPreview { date, before: DailyScore, after: DailyScore, indices: { before: HealthIndices, after: HealthIndices } }
ActivityDraft {
  date, date_from_image: bool,
  activity: { steps?, distance_km?, active_kcal?, resting_kcal?, exercise_min?, stand_hours?, sleep_hours? },  // each number|null
  body: { weight_kg?, body_fat_pct?, sbp?, dbp? },                                                            // each number|null
  workouts: [Workout], notes: string, provider, model }
Workout { description, activity_key, met, duration_min:int, distance_km /*0 if none*/, kcal, notes, avg_hr:number?, device_kcal:number?, in_device:bool }
```

### 1.9 AI job
```
Job { id: uuid, kind: "meal"|"food"|"exercise"|"activity"|"summary", status: "queued"|"running"|"done"|"error", error: string?, result: <T>? }
```

---

## 2. Endpoints used by these screens

**Async AI job semantics**
- `POST /ai/*` returns `{job_id}` immediately.
- Poll `GET /ai/jobs/{id}` every **1.5 s** until `status` is `done` (then use `result`) or `error` (show `error`, falling back to "AI 任务失败").
- The web has no client timeout. The server times out AI calls after 480 s.
- At most 2 jobs run at once server-wide; the others stay `queued`.
- A server restart turns running and queued jobs into `error` with "服务器重启，任务中断，请重试".
- Jobs are deleted after 7 days.
- For iOS: keep polling while foregrounded. On return from background, resume polling the same job id, because the server keeps it.

| # | Method & path | Body / query | Response | Notes and validation |
|---|---|---|---|---|
| E1 | GET `/day/{date}` | query `user=<username>` (optional, view a shared user) | `DayResponse` | 400 "日期格式不正确". With `user`: 404 "用户不存在", 403 "对方没有向你共享数据". For a summary-only share: `meals=[]`, `exercises=[]`, `score.items[*].message=""`, `score.hazards[*].foods=[]`, `score.top={issues:[],wins:[]}`. |
| E2 | POST `/water` | `{date?:string, ml:number}`; ml from −2000 to 3000 | `{ok:true, total_ml:number}` | Accumulates into one meal per day with `description:"饮水"`, `meal_type:"drink"`, a single item named `饮用水` with `amount_g = total ml`, `amount_desc="{total} ml"` and `nutrients.water_g = total`. When the total reaches ≤0 the meal is deleted. Error message prefix "饮水量". |
| E3 | DELETE `/meals/{id}` | – | `{ok:true}` | 404 "餐食不存在" |
| E4 | POST `/uploads` | multipart, field `photos` (1–6 files, each ≤12 MB, jpeg/png/webp/gif only) | `{photos:[{id, url:"/api/uploads/<id>"}]}` | Non-image or HEIC files are silently dropped, which gives 400 "请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）". **iOS must re-encode to JPEG** (e.g. quality 0.8, long edge ≤2048 px). More than 6 files errors on the server (500). |
| E5 | GET `/uploads/{id}` | – | image bytes | Needs auth. Only the owner's files are served. |
| E6 | POST `/ai/meal` | `{text?:string ≤2000, date?, time?:"HH:MM", meal_type?, photos?:[photoId]}` | `{job_id}` → result `MealDraft` | 400 "请描述吃了什么，或上传照片" when both text and photos are empty. Defaults: date = today, time "12:00", meal_type "other". |
| E7 | GET `/ai/jobs/{id}` | – | `Job` | 404 "任务不存在" |
| E8 | POST `/preview` | see §2.1 | `DayPreview` | Writes nothing. Needs a profile. |
| E9 | POST `/meals` | `MealBody` (§2.2) | `{id:int}` | – |
| E10 | PUT `/meals/{id}` | `MealBody` | `{ok:true}` | Updates only date, time, meal_type and description, and **replaces all items**. `photos`, `ai_summary` and `ai_model` are **ignored** on PUT. 404 "餐食不存在". |
| E11 | GET `/foods` | `q?` (≤60 chars, LIKE on name, brand and aliases), `scope=all\|mine` (default all) | `[Food]` (≤200) | Sorted with mine first, then use_count desc, then updated_at desc. |
| E12 | POST `/foods/{id}/item` | `{grams?: number 0.1–20000}`; default serving_g ?? 100 | `DraftItem` | `food_id` is set. `name` gets "（brand）" appended if the brand is not already in the name. `amount_desc` is the serving_desc (or "1 份 {g} g") when grams ≈ serving, else "{round(g)} g". `confidence:"high"`, `notes:"来自食物库"`. 404 "食物不存在". |
| E13 | POST `/foods/from-item` | `{item: DraftItem (must include per100), name?, brand?, serving_g?, serving_desc?, aliases?:[string], visibility?:"private"\|"public", source_urls?:[{title,url}]}` | `{id:int}` | 400 "缺少食物数据". Saved with `source:"ai_estimate"`. |
| E14 | GET `/body` | `start?`, `end?` | `[BodyMetric]` sorted date desc, time desc, id desc | – |
| E15 | POST `/body` | `{date?, time?, weight_kg? (20–350), body_fat_pct? (2–70), waist_cm? (30–250), sbp? (60–260), dbp? (30–160), bp_treated?:bool, note?}` | `{id}` | 400 "请至少填写一项" if weight, fat, waist and sbp are all null. Range errors read like "体重不能小于 20". Source is `manual`. |
| E16 | DELETE `/body/{id}` | – | `{ok:true}` | 404 "不存在" |
| E17 | GET `/labs` | – | `[Lab]` date desc | – |
| E18 | POST `/labs` | `{date?, total_chol? (50–600), hdl? (5–200), non_hdl? (20–600), ldl? (10–500), fasting_glucose? (30–600), hba1c? (3–20), lipid_treated?:bool, diabetes?:bool, note?}`. **All values are mg/dL** except hba1c (%). | `{id}` | `non_hdl` is computed as total − hdl when omitted. 400 "请至少填写一项" if total, non_hdl, glucose and a1c are all null (HDL or LDL alone is not enough). |
| E19 | DELETE `/labs/{id}` | – | `{ok:true}` | Present in the source, but missing from the live OpenAPI spec. |
| E20 | GET `/activity` | `start?`, `end?` | `{days:[ActivityDay] (date desc), exercises:[Exercise] (date desc, time desc)}` | – |
| E21 | PUT `/activity/{date}` | `{steps? (0–200000), active_kcal? (0–10000), resting_kcal? (0–5000), distance_km? (0–500), exercise_min? (0–1440), sleep_hours? (0–24), stand_hours? (0–24)}` | `{ok:true}` | **Full overwrite**: an omitted or null field CLEARS that column. Sets `source="manual"`. |
| E22 | POST `/exercises` | `{date?, time?, description? (≤80; default activity zh, then "运动"), activity_key?, met? (1–25, default activity MET), duration_min (1–1440, required), distance_km?, in_device?:bool, source?:"ai"}` | `{id, kcal}` | kcal = round(max(0, (MET−1) × weight × min/60)), using the server's latest weight on or before that date. |
| E23 | PATCH `/exercises/{id}` | `{in_device:bool}` | `{ok:true}` | – |
| E24 | DELETE `/exercises/{id}` | – | `{ok:true}` | – |
| E25 | POST `/ai/activity` | `{date?, text? ≤1000, photos?:[photoId]}` | `{job_id}` → `ActivityDraft` | 400 "请描述今天的活动，或上传健康 App / 手表截图". The AI may change `date` to the date read from a screenshot (never later than today); `date_from_image` is then true. |
| E26 | POST `/activity/commit` | see §2.3 | `{ok:true, date, workouts:int}` | – |
| E27 | GET `/trends` | `start`, `end` (default end = today, start = end−29) | `{start, end, days:[TrendDay]}` | The Body page uses `date, weight, trend, steps`. |
| E28 | POST `/settings/token` | – | `{token:"nl_…"}` | Personal token for Shortcuts. Not needed by the iOS app. |
| E29 | POST `/health/ingest` | `{date?, steps?, active_kcal?\|active_energy?, resting_kcal?\|resting_energy?, distance_km?, exercise_min?, sleep_hours?, weight_kg?, body_fat_pct?}`; values may be strings like "8,532" or "412 kcal" | `{ok:true, date, activity?, weight_kg?}` | Accepts `nla_` tokens too. See the risks in §9. |
| E30 | POST `/health/import` | multipart `file` (export.xml or export.zip), `since` | `{ok, records, days, weights, since}` | Web only. Replaced by HealthKit on iOS. |

### 2.1 `POST /preview` body
```
{
  date: "YYYY-MM-DD",
  // EITHER a meal patch (Log Meal screen):
  meal?: { meal_type, time, items:[DraftItem], replace_meal_id: int|null },
  // AND/OR activity/body/workouts patch (ActivityRecognizer):
  activity?: { steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours, stand_hours },   // nulls = "no change"
  body?: { weight_kg?, body_fat_pct?, sbp?, dbp?, bp_treated? },
  workouts?: [Workout]
}
```
Server semantics:
- `before` scores the stored day as it is. `after` scores the day with the patch applied.
- A meal with `replace_meal_id` removes that stored meal first (edit preview). The new meal's items are scored from the client-sent `nutrients`, `groups`, `hazards`, `nova_group`, `name` and `amount_g`. Library items are not recomputed, and `category` is ignored.
- Non-null activity fields overwrite.
- `body.weight_kg` becomes the day's weight.
- `sbp` and `dbp` both present add one BP reading to the 3-reading average used by the LE8 BP component.
- Workouts are appended. Their kcal is recomputed from the patched weight.
- Field-range violations still return 400, with messages like "MET不能小于 1" or "时长不能小于 1".
- `indices` = rolling 7 days (date−6 … date): before is stored data, after has the same patch applied.

### 2.2 `MealBody` (POST `/meals`, PUT `/meals/{id}`)
```
{ date (required, YYYY-MM-DD), time (required, HH:MM), meal_type, description?: string ≤2000,
  photos?: [photoId] (≤6, /^[\w.-]+$/), ai_summary?: ≤500, ai_model?: ≤60, items: [DraftItem or MealItem] (≥1) }
```
Per item (server `cleanItem`):
- `amount_g` must be 0.1–20000 ("重量不能小于 0.1" etc.).
- `name` is required and capped at 80 characters ("食物名称不能为空").
- An unknown `category` becomes `other`.
- `nova_group` must be one of 1–4, else null.
- `nutrients` and `groups` are sanitised: unknown keys are dropped and negative values become 0.
- Hazards with unknown keys are dropped.
- **If `food_id` points to an accessible library food, the server recomputes nutrients, groups and hazards from the library per-100 g values** and ignores the client numbers. That is why the client sets `food_id = null` whenever the user edits numbers.
- `id`, `meal_id`, `per100`, `save_suggested` and `saved_food_id` are ignored.

Errors: 400 "日期格式不正确", "时间格式不正确", "至少需要一种食物".

### 2.3 `POST /activity/commit` body
```
{ date, activity:{…as preview…}, body:{ weight_kg?, body_fat_pct?, sbp?, dbp?, bp_treated?, time? }, workouts:[Workout], source:"manual"|"ai" }
```
Server behaviour:
- If any activity field is non-null, the activity row is upserted. The upsert uses **COALESCE**, so null fields keep their stored values; commit can never clear a field. The row source becomes `ai_screenshot` (ai) or `manual`.
- Each workout (max 20) is inserted as an exercise with `time = now` (server timezone), with kcal recomputed and `source` = ai|manual.
  - Workout validation: met 1–25 ("MET不能小于 1"); duration 1–1440 ("时长不能小于 1"); an unknown activity_key becomes `other_moderate`; a `distance_km` of 0 becomes null.
- If weight, fat or sbp is present, one `body_metrics` row is inserted with `time = body.time || "22:00"`. A dbp without an sbp is not saved on its own.
- Range errors: "体重…", "体脂率…", "收缩压…", "舒张压…".

---

## 3. Shared UI components (`ui.tsx` and friends)

### 3.1 Meter (progress or limit bar), used everywhere
Inputs: `name`, `value`, `unit`, `max`, `marks[] {at, label, kind:"ideal"|"limit"}`, `status`, `foot` (text or view), `decimals` (default 0).

Layout:
- Top row: name on the left (ink-1, 13.5 pt, medium weight). On the right, **`fmt(value,decimals)` in bold ink** followed by a space and `unit` in ink-2.
- Then the track: 8 pt tall, fully rounded, surface-3.
- Then `foot` in 12 pt ink-3.

Math:
- `scale = max(max, value, all mark.at) × 1.08`. If the result is 0, use 1.
- Fill width = `min(100, value/scale × 100)%`, colour `statusColor(status)`, fully rounded, animated.
- Each mark is a vertical tick 2 pt wide, extending 3 pt above and below the track, at `at/scale × 100%` (offset −1 pt). Colour: ink-2 for kind `limit` (the default), ink-3 for kind `ideal`. The label is used only as an accessibility title.

### 3.2 ScoreRing
Inputs: `score: number?`, `grade?: string`, `size` (default 148; 132 for LE8).
- Circle radius = size/2 − 9, stroke 10. The track uses surface-3.
- The arc starts at 12 o'clock, clockwise, with round caps. Its length is `score/100` of the circumference; null counts as 0. Animate it over 0.6 s.
- Arc colour: if score is null → axis; else ≥70 good; ≥55 warning; ≥40 serious; else critical. **The same thresholds apply to every ring, including LE8.**
- Centre: `round(score)` or "—". Font size 48 bold, or 32 when size < 120. Below it, `grade` in 13 pt ink-2.

### 3.3 Other building blocks
- **Modal**:
  - Title row with a close "×" (aria "关闭"), a scrolling body, and an optional right-aligned footer of buttons.
  - Width: `wide` = 860 pt max, otherwise 560.
  - On phones (≤600 pt) the web shows it as a bottom sheet. On iOS use `.sheet` with `NavigationStack` and toolbar buttons, or a bottom `safeAreaInset` with the footer buttons.
  - Escape or a backdrop tap closes it.
- **Loading**: spinner plus "加载中…", centred, with 48 pt padding.
- **Empty**: a centred 36 pt icon at 60% opacity (default inbox, or a provided one) above the message text in ink-3, with 36 pt vertical padding.
- **DateNav**: one bordered pill containing `[<]`, the label, and `[>]`.
  - `<` is labelled "前一天" and moves −1 day, with no lower bound.
  - `>` is labelled "后一天", moves +1 day, and is **disabled when date ≥ today**.
  - The label is `dateLabel(date, today)`, semibold 14 pt, at least 128 pt wide. Tapping it opens a date picker with max = today.
- **Seg** (segmented control): one pill on surface-2; the selected segment is surface with a shadow. Use `Picker(.segmented)`.
- **IarcChip(group)**:
  - `"—"` → neutral chip "非致癌".
  - Otherwise the chip reads "IARC {group} 类", coloured by group: 1 = critical-soft/critical-text; 2A = serious-soft/serious-text; 2B = warning-soft/warning-text.
- **SourceLinks(ids)**: resolves `meta.sources` by id; unknown ids are dropped. Renders small muted "依据：" followed by `source.org` names joined by "、". Each name links to `source.url` when it has one. Nothing renders if the list is empty.
- **Chip**: pill with 3×10 padding, 12.5 pt, surface-2 background and ink-2 text. Variants: `accent`, the IARC colours above, and a selected state (accent background, white text) for selectable chips.
- **Toast**: top-centre pill.
  - Info: ink background with surface text, shown for 2.6 s.
  - Error: critical background with white text, shown for 5 s.
  - Every "toast(...)" below means this.
- **Banner**: 12×14 padding, 12 radius, 13.5 pt, with an 18 pt leading icon.
  - Default: surface-2 background with ink-2 text.
  - `warn`: warning-soft background with warning-text.
  - `accent`: accent-soft background with accent-text.

### 3.4 TotalParts (composite breakdown line), `TotalScore.tsx`
- If `total.score` is null, render nothing.
- `avail` = parts whose score is not null. `scale = 100 / max(1, Σ avail.weight)`.
- Text (13 pt, ink-2): for each available part `"{zh} {fmt(points,1)}/{fmt(weight×scale, missing.length ? 1 : 0)}"`, joined by `" · "`.
- If `missing` is not empty, append muted `"（缺{missing.join("、")}，其余按权重折算）"`.
- Example: `膳食质量 19.6/50 · 微量营养素 4.5/15 · 能量平衡 15/15 · 身体活动 20/20`.

### 3.5 Le8Card (`HealthIndices.tsx`)
- Header: heart-pulse icon + h2 "心血管健康 Life's Essential 8". Right hint: `美国心脏协会 2022 · 近 {ix.windowDays} 天`. Callers may override the title and subtitle.
- Hero row: ScoreRing (size 132) with score `le8.score`. Grade = `"{category.zh}（{available}/8 项）"` (e.g. "中（6/8 项）"), or `"数据不足"` when the category is null.
- Next to the ring, a column for each of the 8 components, in server order (饮食（MEPA）, 身体活动, 尼古丁暴露, 睡眠, 体重指数 BMI, 血脂（非 HDL 胆固醇）, 血糖, 血压):
  - When `points != null`: a Meter with name `zh`, value `points`, unit "/ 100", max 100.
    - Status: points ≥80 good, ≥50 warn, else bad.
    - Foot = `component.value` (e.g. "MEPA 7/16（近 7 天记录推算）"). For key `diet` with `ix.mepa` present, append " · " and a link "查看 16 题" that opens the MEPA modal.
  - When `points` is null: one row with `zh` (ink-2) on the left and muted `"缺数据：{missing}"` on the right.
- Footer note (small, muted): "总分 = 已有指标的等权平均（缺失指标不计入分母）；80–100 高，50–79 中，0–49 低。"

**MEPA modal**
- Title: `MEPA 饮食问卷：{score}/16`.
- Intro: "AHA Life's Essential 8 规定的个人饮食评分工具（Cerwinske 2017）。由你近 {mepa.days} 天的饮食记录自动推算每周 / 每天份数，每满足一题得 1 分。15–16 分 → 100，12–14 → 80，8–11 → 50，4–7 → 25，0–3 → 0。"
- Table with columns 题目 | 标准 | 你的记录 | (blank). Each row is `zh` | `criterion` | `fmt(value,1) unit` | (`met` ? good badge "✓ 1 分" : info badge "0 分").

### 3.6 WcrfCard
- Header: shield-check icon + h2 "防癌建议 WCRF/AICR". Hint: `2018 标准化评分 · 近 {windowDays} 天`.
- Row:
  - Big number `fmt(score,2)` (34 pt) with small "/ {max}".
  - Muted explanation: "7 条建议各 1 分、等权（Shams-White 2019）。“超加工食品”一条原文按研究人群三分位评分、没有绝对切点，此处只展示不计分。"
  - Chevron button that expands and collapses the list. It is **expanded by default**.
- List (one row per component, top-aligned):
  - Left column, 56 pt wide, tabular, semibold: `"—"` when points is null (ink-3); else `"{fmt(points,2)}/{max}"`, coloured good-text when points ≥ max, warning-text when points > 0, critical-text otherwise.
  - Then a stack: `zh` (semibold), `detail` (small, ink-2), `rule` (small, ink-3).
  - The `upf` component always shows "—" because max is 0.

### 3.7 ImpactPreview (the "合并预览" before/after diff), shared by Log Meal and ActivityRecognizer
- Container: a flat card on surface-2. Header h3 "合并预览". Hint: "确认前不会写入；数值随修改实时更新".
- Table columns: 指标 | 合并前 | → | 合并后.

Candidate rows, in this order (`d` = decimals; `better` = which direction is an improvement):

| label | before / after source | unit | d | better | always shown |
|---|---|---|---|---|---|
| 膳食质量 HEI-2020 | `score` (HEI, **not** the composite total) | "" | 1 | up | yes |
| 微量营养素 MAR | `mar?.value ?? null` | "" | 0 | up | |
| 心血管健康 LE8（近 7 天） | `indices.*.le8.score` | "" | 0 | up | yes |
| 防癌 WCRF/AICR（近 7 天） | `indices.*.wcrf.score` | "/ {after wcrf.max}" | 2 | up | |
| 摄入能量 | `energy.intake` | kcal | 0 | – | |
| 当日消耗 | `energy.tdee` | kcal | 0 | – | |
| 能量差额 | `intake − tdee` | kcal | 0 | – | |
| 钠 | `totals.sodium_mg` | mg | 0 | down | |
| 添加糖 | `totals.added_sugars_g` | g | 1 | down | |
| 饱和脂肪 | `totals.sat_fat_g` | g | 1 | down | |
| 蛋白质 | `totals.protein_g` | g | 1 | up | |
| 膳食纤维 | `totals.fiber_g` | g | 1 | up | |

Rows and colouring:
- A row is shown when `|after − before| > 0.05` (null counts as 0) or when it is "always".
- Each cell shows `"—"` when the value is null, else `"{fmt(v,d)} {unit}"`. The before cell is muted. The after cell is semibold.
- After-cell colour:
  - ink when either value is null, there is no `better`, or `|Δ| ≤ 0.05`.
  - Otherwise good-text when it moved in the `better` direction, critical-text when it moved against it.

Below the table (small text):
- **"状态变化："** lists each `after.items[i]` where status ≠ info, the key existed in `before.items`, and `statusZh(before) ≠ statusZh(after)`. Each entry is formatted as `"{category=="hei" ? "HEI·" : ""}{zh}（{statusZh(before)} → {statusZh(after)}）"`, joined by "；".
  - `statusZh` maps good and ok to 达标, warn to 偏离, bad to 不达标, info to 提示. good ↔ ok is therefore not a change.
- **"LE8 分项："** lists components whose points differ, as `"{zh} {old ?? "—"} → {new ?? "—"}"`, joined by "；".
- **"新增风险物："** (critical-text) lists `after.hazards` whose key is not in `before.hazards`, as `"{zh}（IARC {iarc}）"`, joined by "、".

---

## 4. Screen: Today (今日概览)

Purpose: the dashboard for one day. Routes: `/` for yourself, or `/u/:username` for the read-only view of a user who shares with you.

### 4.1 State and loading
- `today = me.today`.
- `date` comes from the `?date=` query and defaults to today. Changing the date updates the URL; the param is omitted when it is today.
- `other` = the username from the route, when it differs from the current user (read-only mode).
- Load: `GET /day/{date}` (E1), plus `?user={other}` in read-only mode. It reloads on every date change and after any mutation.
- While the first load has no data, show `Loading`. During a later reload the previous day stays visible.
- On error, show a `banner warn` with the error message.
- The page is pull-to-refresh friendly on iOS (the web has none).

### 4.2 Header
- h1: `"今日概览"`, or `"@{other} 的记录"` in read-only mode.
- Subtitle (ink-3, 14 pt): `"每一项都对照美国权威标准实时评估"`, or `"只读视图（对方开启了共享）"`.
- Right side: DateNav. Then:
  - Own view: primary button **"+ 记一餐"**. It opens Log Meal with `date` pre-filled; the query param is passed only when the date is not today.
  - Read-only: button **"看趋势"** (chart icon), which opens that user's Trends.
- On phones this wraps under the title (see `mobile.png`).

### 4.3 Sections in display order
Desktop uses a two-column grid. On phones every grid collapses to one column in the same order.

**A. Hero row** (grid 5fr | 7fr; single column at ≤1100 pt)

**A1. ScoreCard: h2 "今日总分"**
- Hint (only when `score.hasData`): `"四项按权重合成 · "` followed by a link **"评分依据"**, which goes to Standards → rules tab.
- Body, laid out horizontally and wrapping:
  - `ScoreRing(score = score.total.score, grade = total.score != null ? "满分 100" : "暂无记录")`, 148 pt.
  - A column, at least 200 pt wide. **If `score.hei` is present:**
    1. `TotalParts(score.total)` (§3.4).
    2. Meter "HEI-2020 膳食质量": value `hei.total`, unit "/ 100", max 100, decimals 1.
       - Status: ≥80 good, ≥51 warn, else bad.
       - Foot: `"13 个组分按每 1000 kcal 的密度计分，分值由 USDA 规定；美国人平均 {meta.heiUsMean ?? 58}"`.
    3. Only if `mar` is present, Meter "微量营养素充足 MAR": value `mar.value`, unit "/ 100", max 100, decimals 0.
       - Status: ≥90 good, ≥70 warn, else bad.
       - Foot: `"11 种微量营养素达到 RDA 的平均比例（每种封顶 100%，等权）；最缺：{the 2 nutrients with lowest nar, zh joined "、"}"`.
    4. If `hazards.length > 0`: a row in critical-text with a shield-alert icon and `"{n} 项致癌/风险物警示（见下方）"`.
  - **Otherwise** (no HEI): a muted paragraph "记录饮食后，这里显示 USDA 的 HEI-2020 膳食质量分和 11 种微量营养素的充足度（MAR）。"
- Footer: if `hasData && completeness.level == "partial"`, show a `banner warn` with an info icon and `completeness.note`.

**A2. EnergyCard: flame icon + h2 "能量平衡"**
- Hint:
  - If `energy.method == "eer"`: `"无活动数据，按 {targets.eerMethod} 估算"`.
  - Else: `"静息 {restingSource=="device" ? "来自设备" : "按 BMR"} · 活动：{ACTIVE_SRC[activeSource]}"`, where ACTIVE_SRC = device "手机/手表活动能量", steps "按步数估算", exercise "手动记录的运动", none "无活动数据".
- 4 stat tiles (4 columns; 2×2 at ≤1100 pt). Each tile has a label (13 pt, ink-2), a value (26 pt, semibold, ink) with a small unit (14 pt, ink-3), and an optional delta line (12.5 pt, ink-3).
  1. 摄入: `fmt(intake)`, unit kcal.
  2. 消耗: `fmt(tdee)`, unit kcal.
  3. 差额: `bal = intake − tdee`. Value `(bal>0 ? "+" : "") + fmt(bal)`, unit kcal. Delta `"≈ {bal>0?"+":""}{fmt(bal/7700×1000)} g 体重"`.
  4. 体重: `weighedToday != null ? fmt(weighedToday,1) : fmt(targets.weightKg,1)`, unit kg. Delta = `(weightTrend != null ? "趋势 {fmt(weightTrend,1)} kg" : "")`, followed by `"（今日未称重）"` when `weighedToday == null`.
- Three horizontal bars, each a row of label (30 pt wide, ink-2), track, and value (60 pt, right-aligned, `fmt`): The bar group has accessibility label `摄入 {fmt(intake)}，消耗 {fmt(tdee)}，目标 {fmt(target)} 千卡` (use it as the VoiceOver label of the whole group).
  - 摄入 = intake (series-1), 消耗 = tdee (series-2), 目标 = target (series-3).
  - Track: 10 pt tall, surface-2, rounded. Width ratio = `v / (max(intake, target, tdee) × 1.08 || 1)`.
- Muted small paragraph:
  - Text: `"目标 = 当日消耗 {X}，不低于 {fmt(energyFloor)} kcal · BMR {fmt(bmr)} · EER {fmt(eer)}"`.
  - X = when `goalDeltaKcal ≠ 0`: `"{goalDeltaKcal>0 ? "+" : "−"} {fmt(|goalDeltaKcal|)}（{goal=="lose" ? "减重" : "增重"}目标）"`. Note the U+2212 minus.
  - X = otherwise: `"（维持体重）"`.
- Only if `hasData`, after a divider:
  - Row: `"宏量营养素供能比"` (ink-2) on the left. On the right, muted: `"可接受范围：蛋白 {amdr.protein[0]}–{amdr.protein[1]}% · 碳水 {…}% · 脂肪 {…}%"` (en-dash).
  - Stacked bar, 10 pt, rounded, 2 pt gaps: protein% (series-1), carb% (series-3), fat% (series-2), then alcohol% (series-5) only if `macroPct.alcohol > 0.5`. Segment widths are the raw percentages. Accessibility label: `蛋白质 {fmt(p)}%，碳水 {fmt(c)}%，脂肪 {fmt(f)}%`.
  - Legend with 10 pt square swatches: `蛋白质 {fmt(p)}%`, `碳水 {fmt(c)}%`, `脂肪 {fmt(f)}%`, and `酒精 {fmt(a)}%` when shown.

**B. Only if `hasData`**: a two-column grid.

**B1. HighlightsCard: h2 "今日要点"**
- Hint: "风险警示、超标项、HEI 扣分最多的组分".
- For each `top.issues` string: a row with a critical-coloured circle-x icon (16 pt) and the text (14 pt). Icon accessibility label `问题`.
- Then for each `top.wins`: a good-coloured circle-check icon and the text in ink-2. Icon accessibility label `做得好`.
- If both are empty: muted "暂无".

**B2. KeyLimitsCard: h2 "关键指标"**
- Hint: "竖线 = 理想值 / 上限". `L = targets.limits`. Meters in a column with 14 pt spacing. `status` = the ScoreItem with that key's status, or `info` if absent.

| name | value | unit | max | dec | status key | marks (label, kind) | foot |
|---|---|---|---|---|---|---|---|
| 钠 | totals.sodium_mg | mg | L.sodium_mg.limit | 0 | sodium_mg | ideal "理想"(ideal), limit "上限" | `≈ 食盐 {fmt(sodium/393,1)} g · 上限 {fmt(limit)} mg，理想 ≤ {fmt(ideal)} mg` |
| 添加糖 | totals.added_sugars_g | g | L.added_sugars_g.limit | 1 | added_sugars_g | ideal "AHA"(ideal), limit "上限" | `上限 {fmt(limit)} g，AHA 建议 ≤ {fmt(ideal)} g；DGA 2025：每餐 ≤ 10 g` |
| 饱和脂肪供能比 | macroPct.satFat | % | 10 | 1 | sat_fat_pct | L.sat_fat_pct.ideal "理想"(ideal), 10 "上限" | `{fmt(totals.sat_fat_g,1)} g · 上限 10% 能量` |
| 膳食纤维 | totals.fiber_g | g | intake.fiber_g.value | 1 | fiber_g | target "AI" | `目标 ≥ {fmt(target)} g（14 g/1000 kcal）` |
| 蛋白质 | totals.protein_g | g | protein.idealHighG | 1 | protein_g | rdaG "RDA"; idealLowG "1.2 g/kg"(ideal); idealHighG "1.6 g/kg"(ideal) | `RDA {fmt(rdaG)} g；DGA 2025–2030 建议 {fmt(idealLowG)}–{fmt(idealHighG)} g` |
| 酒精 (only if totals.alcohol_g > 0) | totals.alcohol_g | g | max(L.alcohol_g.limit, 14) | 1 | alcohol_g | limit "上限" (only if limit > 0) | `≈ {fmt(alcohol/14,1)} 标准杯；IARC 1 类致癌物，越少越好` |
| 咖啡因 (only if totals.caffeine_mg > 0) | totals.caffeine_mg | mg | L.caffeine_mg.limit | 0 | caffeine_mg | limit "上限" | `上限 {fmt(limit)} mg` |

**C. Always**: a two-column grid with `Le8Card(day.indices)` (§3.5) and `WcrfCard(day.indices)` (§3.6).

**D. Only if `score.hazards.length > 0`: HazardsCard**
- Header: shield-alert icon + h2 "致癌物与风险物警示". Hint: "IARC 分级表示证据强度；加工肉、红肉、酒精、含糖饮料计入 WCRF 防癌评分".
- One list row per hazard, as a top-aligned stack:
  1. Bold `zh`, then `IarcChip(iarc)`, then small muted `"来自：{foods.join("、")}"` when foods is not empty.
  2. Small ink-2 `message`.
  3. If a `meta.hazards` definition exists: small muted `"{def.risk}。建议：{def.advice}"`.
  4. `SourceLinks(h.sources)`.

**E. Grid of two cards**

**E1. Meals card: utensils icon + h2 "饮食记录"**
- Hint: `"{score.mealCount} 餐 · {fmt(energy.intake)} kcal"`.
- **Water row** (own view only):
  - Content: a droplets icon (series-1), then small ink-2 text `"饮水 {fmt(water)} ml · 总水分 {fmt(totals.water_g ?? 0)} / {fmt(targets.intake.water_g?.value)} g（含食物）"`. The water figure is bold and tabular. `water` = the first item's `amount_g` of the meal whose `description == "饮水"`, else 0.
  - Buttons:
    - Small button **"−"** (aria "减少 250 毫升"), shown only when water > 0: calls `POST /water {date, ml:-250}`.
    - Small button **"+ 250 ml"**: calls `POST /water {date, ml:250}`.
  - After either call, reload the day. On error, toast the error.
- **Meal list**: `meals` with the `description == "饮水"` meal removed, in server order (time asc, id asc).
  - If the list is empty, show Empty with a utensils icon:
    - Read-only: "这一天没有记录".
    - Own: "还没有记录。" plus a primary button **"+ 记录第一餐"**, which opens Log Meal with this date.
  - Otherwise, one card per meal (bordered, 12 radius, 12×14 padding):
    - Head row: time (13 pt, ink-3, tabular, ≥42 pt), `mealZh(meal_type)` (semibold, ink), small muted `"{fmt(Σ items.nutrients.energy_kcal)} kcal"`, a spacer, then in own view an icon button pencil (aria "编辑") and an icon button trash (danger, aria "删除").
      - Edit opens Log Meal in edit mode, passing the meal id and `date`.
      - Delete shows a confirm dialog `"删除 {time} 的{mealZh}？"`. On confirm: `DELETE /meals/{id}`, toast "已删除", reload. On iOS use a destructive confirmation, and toast any errors (the web ignores them).
    - If `description` is not empty: small muted `“{description}”` (Chinese curly quotes).
    - Items, one row each, 14 pt: on the left, `name` followed by small muted `(amount_desc || "{fmt(amount_g)} g")`, plus a 13 pt shield-alert icon (serious colour, aria "含风险项") when `hazards.length > 0`. On the right, ink-3 tabular `"{fmt(nutrients.energy_kcal)} kcal"`.

**E2. ActivityCard: footprints icon + h2 "活动与身体"**
- Header buttons (own view only): small **"填写"** (pencil) and small primary **"AI 识别截图"** (sparkles). They open ActivityRecognizer (§6) in `manual` or `ai` mode, with `date` and `current = day.activity`.
- 4 stat tiles:
  - 步数: `activity.steps` via `fmt`, or "—".
  - 活动能量: `active_kcal` via `fmt`, or "—", unit kcal.
  - 运动消耗: `fmt(score.energy.exerciseKcal)`, unit kcal.
  - 睡眠: `fmt(sleep_hours,1)` or "—", unit 小时.
- If there are exercises, a list. Each row: a flame icon (series-2); `"{description}"` followed by small muted `"{fmt(duration_min)} 分钟 · MET {met}"`; on the right `"{fmt(kcal)} kcal"`, plus muted `"（已含在设备数据中）"` when `in_device`.
- If there are body rows, a list. Each row: a scale icon (series-1); `"{time} 称重"`; on the right the concatenation of `"{fmt(weight,1)} kg"` (if any), `" · 体脂 {fmt(fat,1)}%"` (if any) and `" · 血压 {fmt(sbp)}/{fmt(dbp)}"` (if sbp).
- If there is no activity row, no exercises and no body rows, show a small muted hint:
  - "点“填写”直接录入今天的步数、活动能量、睡眠、体重；或点“AI 识别截图”上传苹果健康 / 手表截图，或者说一句“今天走了 8000 步，游泳 5km”。"
  - In own view, append: " 也可以在 身体与运动 里设置 iPhone 快捷指令自动同步。" The phrase "身体与运动" is a link to the Body screen with the date.
  - On iOS, replace the Shortcuts sentence with HealthKit wording.
- When the recognizer finishes, close it and reload the day.

**F. Only if `hasData`: DetailTabs card**
- h2 "明细", with a Seg on the right: **全部营养素** (default) | **HEI-2020** | **评分明细**.

*Tab 全部营养素 (NutrientTable)*: one row per `meta.nutrients` entry, in that order.
- A group header row (surface-2, semibold, 12.5 pt) appears whenever `group` changes. GROUP_ZH: energy 能量, macro 宏量营养素, carb 碳水与糖, fat 脂肪酸, mineral 矿物质, vitamin 维生素, other 其他.
- Columns:
  - 营养素: `zh`, with muted `en` (hidden on phones).
  - 摄入: `fmt(v, decimals)` plus muted unit (right-aligned).
  - 目标.
  - 完成度: a 6 pt bar in statusColor, width `min(100, pct×100)%`, plus muted `"{fmt(pct×100)}%"`. Shown only when pct is not null.
  - 状态: StatusBadge, shown unless the status is info.
- Per-row logic, with `v = totals[key] ?? 0`, `it` = the ScoreItem with the same key, `intake = targets.intake[key]` and `upper = targets.upper[key]`:
  - key `energy_kcal`: target `"目标 {fmt(energy.target)}"`; `pct = v/energy.target`; status = the `energy_balance` item's status.
  - else if `it` exists: target = `it.targetText`; status = `it.status`; `pct = intake ? v/intake.value : (it.limit ? v/it.limit : null)`.
  - else if `intake` exists: target `"≥ {fmt(intake.value, decimals)}（{intake.kind}）"`; `pct = v/intake.value`; status good when pct ≥1, warn when ≥0.7, else bad.
  - else if key `sat_fat_g`: target `"≤ 10% 能量"`; status = the `sat_fat_pct` item's status; pct is null.
  - else if `dv`: target `"标签 DV {fmt(dv, decimals)}"`; pct is null; status info.
  - Then, if `upper.appliesToTotal`, append muted `" · UL {fmt(upper.value, decimals)}"` to the target, and if `v > upper.value` force the status to bad.
- On phones the table scrolls horizontally (min width 560). On iOS, a `List` of rows with two lines works better.

*Tab HEI-2020*
- If `hei` is null: muted "摄入能量不足 200 kcal，暂不计算 HEI。"
- Otherwise:
  - Stat "HEI-2020 总分" = `fmt(hei.total,1)` with small "/ 100". Beside it, muted: "美国农业部与国家癌症研究所的膳食质量指数，按每 1000 kcal 的密度评分；美国人平均约 58 分。"
  - A grid (cells ≥220 pt) with a Meter per component: name `zh`, value `score`, unit `"/ {max}"`, max `max`, decimals 1.
    - With `r = score/max`, status is good when r ≥0.999, warn when ≥0.6, else bad.
    - Foot `"{fmt(value,2)} {unit}"`, plus `" · {hint}"` when r < 0.999.
  - The 13 components are 水果总量, 完整水果, 蔬菜总量, 深绿色蔬菜与豆类, 全谷物, 奶制品, 蛋白质食物, 海产与植物蛋白, 脂肪酸比例, 精制谷物, 钠, 添加糖, 饱和脂肪.

*Tab 评分明细*: sections in this order, with empty sections skipped.

| category | section title (h3) | right-side summary |
|---|---|---|
| hei | HEI-2020 膳食质量（USDA 官方分值） | `"{fmt(hei.total,1)} / 100"` |
| mar | MAR 计分的 11 种微量营养素（等权） | `"MAR {fmt(mar.value)} / 100"` |
| adequacy | 其他营养素（对照 RDA/AI，只标状态） | – |
| moderation | 限量与其他标准（只标状态） | – |
| energy | 能量平衡（只标状态） | – |

Each item row: StatusBadge (110 pt column); then `message`, with a small muted line `"标准：{targetText} "` + SourceLinks; then, for HEI only, a right-aligned `"{fmt(points,1)} / {maxPoints}"`.

---

## 5. Screen: Log Meal (记一餐 / 编辑这一餐)

Route: `/log`. Params: `date?`; `edit?` = meal id, which turns on edit mode. On iOS, present it modally from the Today "+" button and the tab-bar FAB.

### 5.1 State

| state | initial value |
|---|---|
| `date` | param ?? me.today. The date picker max is today, so future dates are not allowed. |
| `time` | the current time HH:MM |
| `mealType` | `guessMealType(now)`. It is **not** re-guessed when the time changes. |
| `text` | "" |
| `photos` | [ {id, url} ] (max 6) |
| `phase` | "input" (one of `"input" \| "analyzing" \| "review"`) |
| `draft` | null. Holds MealDraft minus items: `{summary, assumptions, questions, sources, provider, model}`. |
| `items` | [DraftItem] |
| `preview` | DayPreview? |

**Edit mode**
- Fetch `GET /day/{param date ?? today}` and find the meal with `id == edit`. If none matches, nothing happens.
- Then set date, time, meal_type and `text = description`, and set `items = meal.items.map(toDraft)`, with phase = review.
- `toDraft(item)`: `f = amount_g > 0 ? 100/amount_g : 1`. Then `per100.nutrients = nutrients×f`, `per100.groups = groups×f`, `per100.hazards = hazards.map({key, amount_per_100g: amount×f})`, and `save_suggested = false`.
- The existing photos are NOT loaded, and PUT ignores photos anyway.

### 5.2 Layout (max width 900; a single column)

**Header**
- h1: `"记一餐"`, or `"编辑这一餐"` in edit mode.
- Subtitle: "用自然语言描述即可，比如“中午一碗牛肉面加一个卤蛋，喝了杯无糖豆浆”".

**Input card**
1. A three-field row (on phones: 2 + 1 full width):
   - **日期** (date picker, max today).
   - **时间** (time picker).
   - **餐次** (picker over MEAL_TYPES showing zh).
2. **吃了什么**: a multi-line text field, 3 rows, with placeholder "例：早上两个水煮蛋、一杯燕麦牛奶、半个苹果；中午一包李子柒螺蛳粉…（写上品牌、份量、做法会更准）".
3. **照片（可选：食物照片、包装、配料表、营养成分表）**:
   - A row of 72×72 rounded thumbnails, each with a round "×" button at the top-right (aria "移除照片") that removes it locally only.
   - While there are fewer than 6 photos, a dashed 72×72 "add" tile with a camera icon, which shows a spinner while uploading.
   - Picking photos: multiple selection, take only the first `6 − current` images, then call `POST /uploads` (E4) and append the result. On error, toast. On iOS offer `PhotosPicker` plus the camera, and convert to JPEG.
4. Action row:
   - Primary large button with a sparkles icon. Label: **"AI 分析"**, or **"重新分析文字描述"** when `items.length > 0 && phase == review`. Disabled while analyzing.
   - Large button **"从食物库添加"** (library icon), which opens FoodPicker (§5.6).
   - Small muted note:
     - If `me.ai.provider == "mock"`: "当前为离线估算模式（未配置 AI）".
     - Else: `"由 {me.ai.model} 分析{provider=="cli" ? "（claude -p）" : ""}，包装食品会自动联网查询"`.

**Analyzing card** (phase analyzing)
- A spinner. Next to it, a semibold title: `"排队中…"` when the last polled job status is `queued`, else `"Claude 正在分析"`, followed by muted `"{elapsed}s"`, where elapsed counts whole seconds since the start and updates every 0.5 s.
- A pulsing small muted message chosen by elapsed seconds:

  | elapsed | message |
  |---|---|
  | <8 | "识别食物与份量…" |
  | <30 | "估算 40+ 种营养素、食物组与加工程度…" |
  | <70 | "查询品牌产品的营养成分表…" |
  | otherwise | "快好了，正在核对致癌物与风险项…" |

**Review phase**
- **Draft info card**, only if `draft` exists and (`summary` is not empty or `questions` is not empty):
  - `banner accent` with a sparkles icon and `summary` (if not empty).
  - FollowUp (§5.4) if there are questions.
  - A collapsible disclosure `"估算假设（{n}）"` with a bullet list of `assumptions` (if any).
  - If there are sources: a link icon, "参考来源：", then each `sources[i].title` as a link to its url.
- **Review card: h2 "审核解析结果"**
  - Hint: "可改名称、克数和每项营养数值，删除多余项；确认后才合并".
  - If there are no items: Empty "没有食物，重新分析或从食物库添加".
  - One ItemEditor (§5.3) per item. onChange replaces item[i], onRemove deletes item[i], and onSave opens SaveFoodModal(i) (§5.7).
  - If `preview` exists and there are items: ImpactPreview(preview.before, preview.after, preview.indices) (§3.7).
  - If there are items, after a divider, a footer row:
    - On the left, a macro line (14 pt) computed client-side by summing `items[*].nutrients`: `合计 {fmt(kcal)} kcal`, `蛋白 {fmt(protein,1)}g`, `钠 {fmt(sodium)}mg`, `添加糖 {fmt(added_sugars,1)}g`, `饱和脂肪 {fmt(sat_fat,1)}g`. Numbers are bold.
    - On the right:
      - A button **"+ 添加"**, which opens FoodPicker.
      - A primary large save button with a check icon, or a spinner while saving. Label: **"确认修改"** in edit mode, else **`"确认合并到 {date == today ? "今天" : date}"`**, e.g. "确认合并到 今天" or "确认合并到 2026-09-28".

**QuickFoods card** (only while phase is input and there are no items)
- Fetch `GET /foods?scope=all` and take the first 12. Hide the card if the result is empty.
- Title h3 "常用食物（一键添加 1 份）".
- Each food is a chip labelled `"{name}{serving_g ? " · {fmt(serving_g)}g" : ""}"`. Tapping it calls `POST /foods/{id}/item {grams: serving_g ?? 100}`, then sets `items = [result]` and phase = review.

### 5.3 ItemEditor (one editable food row)
Container: a bordered card with 12 radius and 8 pt vertical spacing.

1. Row 1:
   - Name text field: semibold, grows, at least 160 pt wide, aria "食物名称". Editing it changes only `name`.
   - Grams field: 120 pt wide with suffix "g", decimal keyboard, showing `round(amount_g×10)/10`. When the new value is > 0, apply `rescale(item, v)`. Values ≤0 or empty are ignored.
   - Toggle button **"调整"** (sliders icon), styled primary while expanded.
   - Icon button trash (danger, aria "删除这一项"), which removes the item.
2. Macro line (12.5 pt, ink-2, numbers bold ink-1): `{fmt(kcal)} kcal`, `蛋白 {1}g`, `碳水 {1}g`, `脂肪 {1}g`, `钠 {0}mg`, `添加糖 {1}g`, `纤维 {1}g`.
3. Chip row, in this order:
   - `amount_desc` (if present).
   - `CATEGORY_ZH[category] ?? category` (if present).
   - `"NOVA {n} · {NOVA_ZH[n]}"` (if nova_group).
   - Accent chip with a library icon and **"食物库"** (if food_id).
   - **"置信度低"** (if confidence == "low").
   - For each hazard: an IARC-coloured chip (class `iarc-{meta.iarc ?? "2B"}`) with a shield-alert icon, the hazard zh (or the key), and a small "×" (aria "移除该风险标记") that calls removeHazard(i).
   - If `groups.processed_meat_g > 0`: iarc-1 chip with a shield-alert icon and `"加工肉 {fmt(g)} g"`.
   - If `groups.red_meat_g > 0`: iarc-2A chip `"红肉 {fmt(g)} g"`.
   - A spacer.
   - If neither `food_id` nor `saved_food_id` is set: a small button with a bookmark-plus icon. Label **"存入食物库（推荐）"** (primary style) when `save_suggested`, else **"存入食物库"**. It calls onSave.
   - If `saved_food_id` is set: accent chip with a check icon and **"已存入食物库"**.
4. `notes` in small muted text (e.g. "离线关键词估算（未配置 AI），数值为同类食物平均值" or "来自食物库").
5. **Expanded panel** (when 调整 is on), separated by a top hairline:
   - If `food_id` is set: a small banner "这一项来自食物库。修改具体数值后将按你填写的数值保存，不再与食物库条目关联。"
   - Three fields:
     - **分类**: picker over CATEGORY_ZH; the current value is `category ?? "other"`.
     - **加工程度（NOVA）**: picker with "未知" (null) and `"1 · 未加工"` … `"4 · 超加工"`.
     - **份量描述**: text field for `amount_desc`.
   - Nutrient section:
     - Header: bold small "营养素（这一份的总量）". On the right, a checkbox `"显示全部 {meta.nutrients.length} 项"`, off by default.
     - When off, show only MAIN = `energy_kcal, protein_g, carb_g, fat_g, sat_fat_g, trans_fat_g, sugars_g, added_sugars_g, fiber_g, sodium_mg, cholesterol_mg, caffeine_mg, alcohol_g`, in meta order.
     - Grid of cells ≥150 pt wide. Each cell has a label `zh` (12 pt) and a number field showing `round(v×100)/100` with a unit suffix. On change, call `setNutrient(key, max(0, Number(input) || 0))`.
   - Food-group section:
     - Header: bold small "食物组（影响 HEI-2020 与红肉/加工肉判断）".
     - Grid over all `meta.foodGroups`. Each cell has a label `zh` (tooltip/help = `note`) and a number field showing `round(v×100)/100`.
     - Suffix: "g" when unit == "g", else the first character of the unit (杯, 盎, 份, or "m" for ml; consider showing the full unit on iOS).
     - On change, call `setGroup(key, max(0, Number || 0))`.
   - If any hazards are flaggable (those with `meta.hazards[].dose.from == "flag"` that are not already on the item): a row "补充风险标记：" with a picker whose placeholder is "选择…" and whose options read `"{zh}（IARC {iarc}）"`. Choosing one calls `addHazard(key)`.

**Client-side math. Reproduce it exactly.** Here `g = amount_g || 1`.

`rescale(item, grams)` with `f = grams/100`:
```
amount_g    = grams
amount_desc = "{fmt(grams)} g"            // overwrites any "两片" style description
nutrients   = per100.nutrients × f        // every key
groups      = per100.groups × f
hazards     = per100.hazards.map({key, amount: amount_per_100g × f})   // hazard notes are dropped
// food_id is NOT cleared (server recomputes library items from the library anyway)
```

`setNutrient(k, v)`: `food_id = null`; `nutrients[k] = v`; `per100.nutrients[k] = v×100/g`. A later grams change then scales from the edited value.

`setGroup(k, v)`: the same for groups.

`removeHazard(i)`: `food_id = null`; remove index i from both `hazards` and `per100.hazards`. They are index-aligned.

`addHazard(key)`: `food_id = null`; append `{key, amount: g}` to hazards and `{key, amount_per_100g: 100}` to `per100.hazards`, meaning the whole item counts as the dose.

Name, category, NOVA and description edits do not clear `food_id`.

### 5.4 FollowUp (AI clarifying questions)
- Shown as a column banner.
- Title row: an info icon and bold **"AI 想确认："**. Below it, a bullet list of the questions.
- Then a row with a text field (placeholder "补充说明后重新分析（可选）") and a small button **"补充并重新分析"** (refresh icon), disabled when the field is blank. The button calls `analyze(extra = input)`.

### 5.5 Actions and flows

**`analyze(extra = "")`**
1. `fullText = extra ? "{text}\n补充：{extra}" : text`.
2. If `fullText.trim()` is empty and there are no photos, toast error "请描述吃了什么，或上传照片" and stop.
3. Set phase = analyzing and elapsed = 0.
4. Call `POST /ai/meal {text: fullText, date, time, meal_type, photos: [ids]}` (E6), then poll E7 every 1.5 s, recording each tick's `status`.
5. On `done`:
   - Set `draft` to the result without its items.
   - `items = [old items that have food_id] + result.items` when `extra` is empty; `items = result.items` when extra is set.
     - Quirk: a plain re-analysis keeps previous library items, including AI-matched ones, so library items can end up duplicated. iOS may keep this for parity, or dedupe by food_id.
   - If `extra` was set, `text = fullText`.
   - Set phase = review.
6. On error: toast the error message, and set phase = review if there were items, else input.

**Live merge preview** (only while in review with items)
- Whenever items, date, time, meal type or the edit id changes, debounce **400 ms**.
- Then call `POST /preview {date, meal: {meal_type, time, items, replace_meal_id: editId or null}}` (E8).
- On failure set `preview = null`, silently. Cancel any in-flight or debounced request when the inputs change again.

**`saveMeal()`**
1. If there are no items, toast error "至少需要一种食物".
2. Body: `{date, time, meal_type, description: text, photos: [ids], ai_summary: draft?.summary ?? "", ai_model: draft?.model ?? "", items}`.
3. Edit mode: `PUT /meals/{editId}`. New meal: `POST /meals`.
4. On success: toast "已保存，评分已更新", then go to Today for `date` (dismiss and switch to that date).
5. On error: toast it. The save button shows a spinner and is disabled while saving.

### 5.6 FoodPicker (modal "从食物库添加")
**Search state**
- A search field with autofocus, placeholder "搜索名称、品牌、别名…" and a search icon.
- Debounce 200 ms, then call `GET /foods?q={q}&scope=all`. An empty q is omitted, which returns all foods.
- If the result is empty: Empty "食物库里没有匹配项。可以在“食物库”里用 AI 联网查询或拍营养成分表来添加。"
- Results list. Each row is tappable and selects that food, setting `grams = serving_g ?? 100`:
  - Line 1 (semibold): `name`, followed by the muted `brand`.
  - Line 2 (small muted): `"每 100 g {fmt(per100.energy_kcal)} kcal · 钠 {fmt(per100.sodium_mg)} mg"`, then `" · 一份 {fmt(serving_g)} g"` if there is a serving, then `" · 来自 {owner_name}"` if `!mine`.

**Selected state**
- h3 `name`. Small muted line: `"{brand} {serving_desc}"`.
- Field **"吃了多少"**: a number field (140 pt, suffix g). If `serving_g` is set, add chips **"0.5 份" "1 份" "1.5 份" "2 份"**. A chip is selected when `grams == serving_g×m`, and tapping it sets grams.
- Macro line (live): `{fmt(per100.energy_kcal×grams/100)} kcal`, `蛋白 {…,1}g`, `钠 {…}mg`, `添加糖 {…,1}g`.
- Ghost button **"← 返回搜索"**, which clears the selection.
- Footer (only when a food is selected): primary **`"+ 添加 {fmt(grams)} g"`**.
  - It calls `POST /foods/{id}/item {grams}` (E12), appends the returned DraftItem to items, sets phase = review, and closes the picker.
  - Validate grams between 0.1 and 20000 client-side. The server's 400 error is "克数不能小于 0.1".

### 5.7 SaveFoodModal (modal "存入食物库")
- Intro (small ink-2): "按每 100 g 的营养数据保存。下次记录时说出名称会自动匹配，也可以在“从食物库添加”里直接选择克数。"
- Four fields:
  - **名称**: defaults to item.name.
  - **品牌（可选）**: defaults to "".
  - **一份的重量**: a number field with suffix g, defaulting to `round(item.amount_g)`.
  - **别名（逗号分隔）**: placeholder "如：螺狮粉, luosifen".
- **可见范围**: Seg **仅自己** (`private`, default) | **所有成员可用** (`public`).
- Macro line: `每 100 g：{fmt(per100.nutrients.energy_kcal)} kcal`, `蛋白 {…,1}g`, `钠 {…}mg`.
- Footer: primary **"保存"** (bookmark-plus icon), disabled while busy.
  - It calls `POST /foods/from-item {item, name, brand, serving_g, serving_desc: item.amount_desc, aliases: split(/[,，、\s]+/).filter(nonEmpty), visibility, source_urls: draft?.sources ?? []}`.
  - On success: toast "已存入食物库，下次可直接搜索选择", set `items[i].saved_food_id = id`, and close. Note that `food_id` stays null, so the meal is saved with its own numbers.

---

## 6. Component: ActivityRecognizer (modal for activity and body data)

Opened from Today (both modes) and from Body (`ai` mode). Inputs: `date`, `current: ActivityDay?`, `mode: "ai" | "manual"`.

- Title: manual → `"填写 {date} 的活动与身体数据"`; ai → `"AI 识别活动与身体数据"`.
- Width: wide (on iOS, a full-height sheet).

Field definitions:
- ACT_FIELDS (activity, 3-column grid):

  | key | label | unit | step |
  |---|---|---|---|
  | steps | 步数 | 步 | 1 |
  | active_kcal | 活动能量 | kcal | 1 |
  | resting_kcal | 静息能量 | kcal | 1 |
  | distance_km | 步行+跑步距离 | km | 0.1 |
  | exercise_min | 锻炼分钟 | 分钟 | 1 |
  | sleep_hours | 睡眠 | 小时 | 0.1 |
- BODY_FIELDS (body, 4-column grid):

  | key | label | unit | step |
  |---|---|---|---|
  | weight_kg | 体重 | kg | 0.1 |
  | body_fat_pct | 体脂率 | % | 0.1 |
  | sbp | 收缩压 | mmHg | 1 |
  | dbp | 舒张压 | mmHg | 1 |

**Initial draft**
- Manual mode: `{date, activity: the ACT_FIELDS values from current (or null), body: all null, workouts: []}`. `stand_hours` is not in the form.
- AI mode: draft is null, so the input stage is shown first.

**AI input stage** (draft is null)
- Small ink-2 text: `"用一句话描述，或上传苹果健康 / 健身圆环 / 手表运动记录 / 体脂秤 / 血压计的截图，由 {provider=="mock" ? "离线规则（未配置 AI，无法读图）" : me.ai.model} 识别步数、能量、睡眠、体重和每次运动。识别结果会先给你预览，确认后才合并。"`
- A 3-row text area, placeholder "例：今天走了 8500 步，下午游泳 5km，昨晚睡了 7 个半小时，睡前体重 70.2".
- A photo grid of 72 pt thumbnails, plus a camera add-tile (aria "上传截图"). Multiple selection, uploaded through E4 and appended. The web has no remove control and no 6-photo cap; iOS should cap at 6.
- While busy: pulsing small muted "正在识别… 读取截图通常需要 20–60 秒".
- Footer: a primary button. When idle it shows a sparkles icon and **"AI 识别"**; while busy it shows a spinner and `"{elapsed}s"`. It is disabled when busy, or when the text is blank and there are no photos.
- `recognize()`: `POST /ai/activity {date, text, photos: [ids]}` (E25), then poll. On done, set `draft = result` (an ActivityDraft). On error, toast.

**Draft / review stage**
- `notes`, if not empty: `banner accent` with sparkles (e.g. "离线规则解析（未配置 AI），无法识别截图").
- If `date_from_image`: `banner warn` "截图显示的日期是 {draft.date}，将合并到这一天。"
- h3 **"活动"**: number fields over ACT_FIELDS with unit suffixes. An empty field means `null`; otherwise `Number(input)`.
- h3 **"身体"**: number fields over BODY_FIELDS, with the same empty-means-null rule.
- Workouts header: h3 **"运动"** with a small button **"+ 添加一项"**. The button appends `{description:"快走", activity_key:"walk_brisk", met:4.8, duration_min:30, distance_km:0, in_device:false}`.
  - If there are no workouts, show small muted "没有运动".
  - Each workout card (bordered):
    - Row: a description text field (aria "描述"); an activity picker (aria "运动类型") over `meta.activities` zh, where choosing an activity sets `activity_key` and resets `met` to that activity's MET; and a delete icon (aria "删除").
    - Row (small):
      - `时长 [number, 76 pt] 分钟`.
      - `MET [number step 0.1]`.
      - `距离 [number step 0.1; shows empty when 0] km`.
      - If `avg_hr` is set: muted `"平均心率 {avg_hr}"`.
      - `"净消耗约 {fmt(kcalOf(w))} kcal"`, plus muted `"（设备显示 {fmt(device_kcal)}）"` if `device_kcal` is set.
    - Checkbox **"已含在设备活动能量中（避免重复计算）"** bound to `in_device`.
    - `notes` in small muted text.
    - Numeric parsing: an empty field becomes 0. The server rejects a duration < 1 with "时长不能小于 1", so validate client-side.
  - Client estimate: `kcalOf(w) = round(max(0, (met − 1) × weight × duration_min/60))`, where `weight = me.profile.weight_kg ?? 65` (the profile/onboarding weight; the server uses the latest weighing, so the numbers can differ slightly).
- ImpactPreview, live: debounce **350 ms** on any draft change, then call `POST /preview {date: draft.date, activity: draft.activity, body: draft.body, workouts: draft.workouts}`. On error, set `preview = null`.
- Footer: **"取消"** (closes) and primary **`"确认合并到 {draft.date}"`** (check icon, or a spinner while saving).
  - `commit()` calls `POST /activity/commit {...draft, source: mode=="manual" ? "manual" : "ai"}` (E26).
  - On success: toast "已合并到当天记录", then call `onDone` (the parent closes the modal and reloads).
  - On error: toast.
- Remember that commit cannot clear stored activity values (COALESCE). A user who empties a field in manual mode will see the old value come back. iOS should either explain this, or use `PUT /activity/{date}` for true edits.

---

## 7. Screen: Body (身体与运动)

Route `/body?date=`. On iOS, this is the "身体" tab.

### 7.1 State and loads
- `today = me.today`. `date` = the param ?? today, editable through a date picker in the header (max today, aria "日期").
- `body` = `GET /body?start={today−365}` (E14), loaded once and reloaded after any mutation.
- `act` = `GET /activity?start={date−30}&end={date}` (E20), reloaded when the date changes. `day` = the entry of `act.days` whose date equals `date`.
- `trend` = `GET /trends?start={today−89}&end={today}` (E27), reloaded whenever `body` reloads.

### 7.2 Layout in display order

**Header**
- h1 "身体与运动". Subtitle: "睡前称重 + 步数/活动能量 + 运动记录，和饮食摄入交叉对照".
- Date picker on the right.

**Row 1** (two columns)

**1a. Card "记录体重"** (scale icon)
- Hint: "建议每晚睡前、同一时间称".
- A two-column grid of fields:
  - **体重**: number, step 0.1, suffix kg, decimal keyboard.
  - **时间**: time picker, default **"22:00"**.
  - **体脂率（可选）**: suffix %, step 0.1.
  - **腰围（可选）**: suffix cm, step 0.5.
  - **血压（可选）**: two number fields with placeholders **"收缩压"** and **"舒张压"**, separated by "/".
- When sbp is not empty, a checkbox **"正在服用降压药"** (`bp_treated`) appears.
- Primary button **"保存"**, disabled unless at least one of weight, fat, waist or sbp is filled.
  - It calls `POST /body {date, time, weight_kg, body_fat_pct, waist_cm, sbp, dbp, bp_treated}`, with empty fields sent as null and numbers sent as numbers.
  - On success: toast "已记录", clear the five value fields (keep time and bp_treated), and reload. On error: toast.
- History list: the first 30 body rows, newest first, in a scroll area about 220 pt tall. Each row:
  - Muted tabular `"{MM-DD} {time}"` (92 pt wide).
  - The concatenation of bold `"{fmt(weight,1)} kg"`, `" · 体脂 {fmt(fat,1)}%"`, `" · 腰围 {fmt(waist,1)} cm"` and `" · 血压 {fmt(sbp)}/{fmt(dbp)}"`, each only if present.
  - Small muted source label: manual → "" (blank), profile → "建档", ai → "AI 识别", anything else → "苹果健康".
  - A delete icon (danger, aria "删除") that calls `DELETE /body/{id}` and reloads, with no confirmation. iOS should use swipe-to-delete.

**1b. Card "近 90 天体重"**
- If any `trend.days[].weight` is non-null, show a chart 320 pt tall:
  - X axis: the dates as `MM-DD`.
  - Series "称重": scatter points, 8 pt, ink-3 fill with a 2 pt surface-coloured border, from `days[].weight`.
  - Series "趋势（平滑）": a line in series-1, 2 pt, no point markers, connecting gaps, from `days[].trend`.
  - Legend at the top-left: "称重", "趋势（平滑）".
  - Y axis: min `floor(minValue − 1)`, max `ceil(maxValue + 1)`, labels via `fmt(v,1)`, solid hairline grid.
  - Tooltip: the date, then each series as `"{fmt(v,1)} kg"` or "—".
  - Swift Charts: `PointMark` plus `LineMark`.
- Otherwise: Empty with a scale icon, "还没有体重记录".

**Row 2** (two columns)

**2a. Card "记录运动"** (flame icon)
- Hint: the `date` string.
- `banner accent` (column):
  - Text: `"说一句“游泳 5km”“打了两小时羽毛球”，或上传手表的运动记录截图，由 {provider=="mock" ? "离线规则" : me.ai.model} 按 2024 运动代谢当量表识别，先预览再合并。"`
  - Small primary button **"AI 识别运动 / 截图"** (sparkles), which opens ActivityRecognizer in ai mode for `date`.
- Collapsible section **"手动选择运动类型"**:
  - An activity picker over `meta.activities` showing `"{zh}（MET {met}）"`, default `walk_brisk`.
  - A minutes field (default "30", aria "分钟") followed by "分钟".
  - Button **"添加"**: calls `POST /exercises {date, activity_key, duration_min, in_device: (day?.active_kcal is truthy)}`, then reloads the activity and toasts "已记录".
- List of the exercises whose date equals `date`. Each row:
  - Flame icon (series-2).
  - Line 1: `"{description}"` followed by small muted `"{fmt(duration_min)} 分钟 · MET {met}{distance_km ? " · {fmt(distance_km,1)} km" : ""}"`.
  - Line 2: a small muted checkbox **"已含在设备活动能量中"**, bound to `in_device`. Toggling calls `PATCH /exercises/{id} {in_device}`, then reloads.
  - Right side: tabular `"{fmt(kcal)} kcal"` and a delete icon that calls `DELETE /exercises/{id}` and reloads.
- If there are none: small muted "这一天还没有运动记录".

**2b. Card "步数与活动能量"** (footprints icon)
- Hint: if `day` exists, `"来源：{source}"`, where manual → "手动", apple_shortcut → "iPhone 快捷指令", and anything else (apple_export, ai_screenshot, future healthkit) → "苹果健康导出". Otherwise "未记录".
- A two-column form. Each field shows the local edit if there is one, else the stored `day` value, else "":
  - **步数**
  - **活动能量** (suffix kcal)
  - **静息能量（可选）** (kcal)
  - **锻炼分钟（可选）**
  - **睡眠（小时）** (step 0.1)
  - **站立（小时，可选）**
- Buttons:
  - **`"保存 {date} 的活动数据"`**: calls `PUT /activity/{date}` (E21) with all 7 fields. `distance_km` is not in the form but is sent with its stored value. Empty fields are sent as null and therefore **clear** the stored value. On success: toast "已保存", clear the local edits, and reload.
  - Primary **"上传健康截图识别"** (camera icon): opens ActivityRecognizer in ai mode.
  - Web quirk: local edits are not reset when the date changes. Do not copy this; reset the edits on date change.
- Small muted explanation: "有“活动能量”时，消耗 = 静息 + 活动能量 + 未被设备记录的运动；只有步数时按步长与体重估算。"
- If any trend day has steps: a bar chart 180 pt tall of the **last 30 trend days**. X labels `MM-DD`; bars in series-1 with rounded tops, max width 20; Y-axis name "步"; tooltip `"{fmt(steps)}"` labelled "步数".

**Row 3. Card "体检化验指标"** (Labs)
- Hint: "用于美国心脏协会 LE8 的血脂、血糖两项；不填则这两项不计入".
- Row:
  - A lab date picker (aria "化验日期"). It is initialised to the screen `date` on first render and does not follow later changes.
  - Seg with **"mmol/L（国内常用）"** (`mmol`) and **"mg/dL"** (`mgdl`, **the default**).
- Three-column fields. The unit suffix is "mmol/L" or "mg/dL" according to the Seg:
  - **总胆固醇**
  - **高密度脂蛋白 HDL**
  - **低密度脂蛋白 LDL（可选）**
  - **空腹血糖**
  - **糖化血红蛋白 HbA1c** (suffix %, step 0.1)
  - **用药 / 诊断**, with checkboxes **"服用降脂药"** (`lipid_treated`) and **"已诊断糖尿病"** (`diabetes`)
- Button **"保存化验结果"**:
  - Unit conversion before sending: in mmol mode, cholesterol values (total, HDL, LDL) are multiplied by **38.67** and rounded to an integer, and glucose is multiplied by **18** and rounded. HbA1c is never converted. Empty fields are sent as null.
  - Calls `POST /labs {date, total_chol, hdl, ldl, fasting_glucose, hba1c, lipid_treated, diabetes}`.
  - On success: toast "已保存化验结果", clear the five values (keep the unit, date and checkboxes), and reload.
  - On error: toast the server error (e.g. "请至少填写一项").
- Table, shown when there are labs. Columns: 日期 | 非 HDL 胆固醇 | 空腹血糖 | HbA1c | (delete).
  - 非 HDL 胆固醇: `"{fmt(non_hdl)} mg/dL"` or "—", plus "（服药）" when lipid_treated.
  - 空腹血糖: `"{fmt(fasting_glucose)} mg/dL"` or "—".
  - HbA1c: `"{hba1c}%"` (raw value) or "—", plus "（糖尿病）" when diabetes.
  - Delete: calls `DELETE /labs/{id}` with no confirmation, then reloads.

**Row 4. Card "连接苹果健康"** (smartphone icon). This is web-only; the iOS app should **replace** it with a native HealthKit section. For reference, the web shows:
- Left column, "方式一：iPhone 快捷指令每天自动同步":
  - Explanation: "网页无法直接读取 HealthKit。用“快捷指令 → 自动化”每晚定时读取当天的步数、活动能量、静息能量、体重，POST 到下面的地址即可。"
  - A read-only field **"接口地址"** = `{origin}/api/health/ingest`.
  - Button **"生成个人 Token"**, or **"重新生成 Token"** when a hint exists. Regenerating first asks for confirmation: "重新生成后旧 Token 立即失效，快捷指令需要更新。继续？". It calls E28.
  - Muted `"当前：{api_token_hint}"`.
  - Ghost button **"查看设置步骤"**, which opens a modal with the 5-step guide. Verbatim content (added by the completeness review; reuse it if the iOS app keeps a "快捷指令 (legacy)" help screen):
    - Modal title: `iPhone 快捷指令设置步骤`. An ordered list (`<b>` = bold, `<code>` = monospace):
      1. `打开“快捷指令” App → 新建快捷指令。`
      2. `添加“查找健康样本”：类型选`**`步数`**`，开始日期“今天”，分组“按天”，计算“总和”。再分别为`**`活动能量`**`、`**`静息能量`**`、`**`体重`**`（取最新 1 条）各添加一次。`
      3. `添加“字典”，键为 ` `steps`、`active_kcal`、`resting_kcal`、`weight_kg` `（可选 ` `distance_km`、`exercise_min`、`date` `），值选上一步的结果。`
      4. `添加“获取 URL 内容”：URL 填 ` `{origin}/api/health/ingest` `，方法 POST，请求体 JSON 选择上面的字典；头部添加 ` `Authorization` = `Bearer 你的Token` `。`
      5. `在“自动化”里设定每天 23:30 运行（关闭“运行前询问”）。`
    - Muted `请求体示例：` followed by a monospace block (surface-2 background, 10 pt padding, radius 8, 12 pt): `{"steps": 8532, "active_kcal": 412, "resting_kcal": 1620, "distance_km": 6.1, "exercise_min": 35, "weight_kg": 68.2}`.
    - Muted footnote: `数值带千分位或单位（如 “8,532”、“412 kcal”）也能识别；不传 date 时按你的时区记为今天。`
    - The copy button next to the one-time token toggles its icon from Copy to Check after `navigator.clipboard.writeText` (iOS: `UIPasteboard.general.string`, then a checkmark).
  - After generating: an accent banner "只显示这一次，请复制保存：" with the token and a copy button.
- Right column, "方式二：导入“健康”App 的导出文件":
  - A file picker for .xml or .zip.
  - "导入起始日期", defaulting to today−365.
  - Button **"导入"**, which calls E30. Success toast: `"导入完成：{days} 天活动数据、{weights} 条体重（共解析 {records} 条记录）"`.

---

## 8. Visual layout notes (from the screenshots)

- **today.png (desktop)**:
  - Left sidebar with the brand mark 食迹 / NUTRILOG, a full-width green "+ 记一餐" button, and nav items 今日 趋势 报告 身体与运动 食物库 社区 标准库 设置. The user's avatar and name sit at the bottom.
  - Content order: hero row (ring card on the left, energy card on the right); 今日要点 | 关键指标; LE8 | WCRF.
  - The meter marks render as thin dark ticks over the track.
  - The red-orange ring shows a low score with a thick round-capped arc.
- **mobile.png (phone, 390 pt)**:
  - The title is big at the top, with the date pill and the green "+ 记一餐" button on one row beneath it.
  - Cards are full width, and the ring is centred on its own line above the meters.
  - Bottom tab bar: 今日, 趋势, a centred raised green **+** FAB (46 pt circle, raised 18 pt), 身体, 更多.
  - Suggested iOS mapping: a `TabView` with 今日 / 趋势 / [+] / 身体 / 更多, where the centre item presents Log Meal modally.
- **review.png**:
  - Each ItemEditor shows name, grams and "调整" on one row; the macro line under it; then the chips.
  - The "存入食物库（推荐）" button is solid green and right-aligned on the chip row.
  - The merge preview is a grey inset card with the table, then the 状态变化 text paragraph, then a red 新增风险物 line.
  - The footer shows the totals line on the left and "+ 添加" plus the big green "确认合并到 今天" on the right.
- **activity.png**: the recognizer modal with sections 活动 (3 columns), 身体 (4 columns) and 运动 (workout cards), the merge preview, and a sticky footer with 取消 and the green "确认合并到 2026-09-30".
- **dark.png**: the Body page in dark mode. Same structure with dark surfaces (#1a1a19 cards on #0f0f0e), a brighter accent green, and a blue trend line with grey weigh-in dots.

---

## 9. Surprises and risks for the native iOS client

1. **`/health/ingest` is not idempotent for weight.** Every call with `weight_kg` inserts a new `body_metrics` row with source `apple_shortcut`. A HealthKit sync that runs often will create duplicate weight rows. Scoring uses the last weighing of the day, so scores survive, but the history list fills with duplicates.
   - Its activity upsert uses COALESCE, so it cannot clear values. It ignores `stand_hours`, BP and HealthKit workouts.
   - **Recommendation (additive server change):** a dedicated idempotent HealthKit sync endpoint, e.g. `POST /health/sync` with source `healthkit`, that upserts the per-day activity row and replaces that day's `healthkit` body rows, plus workouts keyed by a HealthKit UUID.
2. **Last write wins on `activity_days`.**
   - `PUT /activity/{date}` (the Body form) overwrites every column, and nulls clear values.
   - Commit and ingest only fill non-null values.
   - Background HealthKit sync can therefore overwrite a manual edit, and vice versa. Decide on a precedence rule; for example, never overwrite when `source == "manual"` and the row was updated after the last sync.
3. **Double counting of workouts.** Apple Watch workouts are already part of Active Energy. Any workout created from HealthKit must have `in_device = true`, or TDEE counts it twice. The web's manual add defaults `in_device` to `!!day.active_kcal`.
4. **Sleep date convention.** `sleep_hours` lives on one date. The AI prompt treats "昨晚睡了" as the logged date, so sleep that ends on the morning of date D belongs to D. HealthKit sleep analysis has to be aggregated (asleep stages only) into that convention, and it feeds the LE8 sleep score as a 7-day average.
5. **Image handling.**
   - Uploads reject HEIC; it is silently filtered and then you get a 400. Re-encode to JPEG.
   - Max 6 files per request and 12 MB each.
   - `GET /api/uploads/{id}` needs the Bearer header, so you need an authenticated image loader.
   - Meal edit does not round-trip photos: PUT ignores `photos`.
6. **Plain-HTTP production host** needs an ATS exception. Tokens travel in cleartext; consider HTTPS.
7. **Booleans arrive as 0/1 integers** on DB rows (`in_device`, `bp_treated`, `lipid_treated`, `diabetes`). Elsewhere (DraftItem, ActivityDraft, Workout) they are real bools. `ActivityDay` has **no `id`**. Many numeric fields are nullable. `totals` and `groups` always contain every key.
8. **Async AI jobs** can take 20 s to 8 minutes, queue behind other users (concurrency 2), and are failed by a server restart. Persist the `job_id` so polling resumes after the app is backgrounded or killed. The web never times out on the client.
9. **The preview's "HEI" row is not the composite "今日总分".** The `/preview` diff shows HEI, MAR, LE8 and WCRF, but not `total.score`. That keeps parity with the web, though iOS may add a row for `after.total.score` purely client-side (it is in the response).
10. **Client and server number mismatches.**
    - The workout kcal estimate in the recognizer uses the profile weight, while the server uses the latest weighing.
    - Rounding: use half-away-from-zero (§0.3).
    - The meal-type guess uses the device clock, while "today" uses the profile timezone. Use `me.today` for dates and the profile timezone for "now" if they differ.
11. **Re-analysis quirk.** "重新分析文字描述" keeps previous items that have a `food_id` and appends all the new AI items, which can duplicate library matches. A follow-up re-analysis replaces everything.
12. **Shared (read-only) day view.** With `share_detail = "summary"`, meals and exercises are empty arrays and item messages are blank, but scores, the activity row and body rows (weights) are still returned. The UI shows "这一天没有记录" in the meals card even if the user did log meals.
13. **Mock AI mode** (`me.ai.provider == "mock"`): images cannot be read and the notes say so. The UI copy switches as described in §5.2 and §6.
14. **Not in the live OpenAPI but present in the source:** `GET /uploads/{id}` and `DELETE /labs/{id}`. Verify them against production before relying on them.
