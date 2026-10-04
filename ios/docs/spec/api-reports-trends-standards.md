# 食迹 NutriLog: Reports, Trends, Community and Standards API (iOS implementation spec)

Scope: `server/src/routes/reports.ts`, `server/src/routes/docs.ts`, `server/src/services/userdata.ts`, `server/src/services/scheduler.ts`, and the output shapes of `server/src/scoring/*.ts` as they appear in API responses. Cross-references to `/ai/jobs/{id}`, `/profile/targets`, `/auth/me` and `/uploads/{id}` are included only where these screens depend on them.

Source of truth: the TypeScript source in the repository root, read on 2026-10-03. The live OpenAPI file (`openapi.live.json`) is much shallower than the real responses. Where they disagree, this document follows the code, and section 15 lists the gaps.

All field names below are copied verbatim from the code. **Do not rename them in Codable models** (use `CodingKeys` only to map to Swift style if needed).

---

## 0. Conventions that apply to every endpoint here

### 0.1 Base URL, mounting
- Every route is mounted twice: under `/api/v1` and under `/api`. **The iOS app must use `/api/v1`.** Production: `http://45.63.23.52:8787/api/v1`.
- `GET /api/v1/health` returns `{"ok": true, "version": "1"}` (no auth).

### 0.2 Authentication
- Header: `Authorization: Bearer nla_<...>` (app token from `POST /api/v1/auth/token`, valid 365 days by default).
- A token starting with `nl_` (personal token) is **rejected** by every endpoint in this document. It only works for `/health/ingest`.
- Every endpoint in this document **except** `/openapi.json` and `/docs` requires auth.
- Failed auth returns HTTP **401** `{"error": "未登录或令牌已失效"}`. This covers a missing, unknown or expired token. Expired tokens are deleted server-side.
- Note: because `logRouter` and `reportsRouter` apply auth at router level, an unauthenticated request to a **nonexistent** `/api/v1/...` path also gets 401 (not 404). An authenticated request to a nonexistent path gets 404 `{"error": "接口不存在"}`.

### 0.3 Error shape
Every error is JSON `{"error": "<Chinese message>"}` with one of these statuses:

| Status | When (in this document's endpoints) | `error` text |
|---|---|---|
| 400 | caller (or the viewed user) has no profile | `请先完善个人档案` |
| 400 | `/day/{date}` with malformed date | `日期格式不正确` |
| 400 | `start` > `end` on `/trends`, `/period`, `/period/summary` | `开始日期不能晚于结束日期` |
| 400 | malformed JSON body | `请求格式不正确` |
| 401 | not logged in | `未登录或令牌已失效` |
| 403 | `?user=` points to someone who has not shared with you | `对方没有向你共享数据` |
| 404 | `?user=` username does not exist | `用户不存在` |
| 404 | `/ai/jobs/{id}` unknown or belongs to another user | `任务不存在` |
| 500 | unexpected | `服务器内部错误` |

The web client falls back to `请求失败（<status>）` when the body has no `error`. Reuse that wording.

### 0.4 Dates and times
- Every date is a **local calendar date string** `YYYY-MM-DD` (no timezone). Times are `HH:MM` (24h).
- "Today" on the server = today in the **profile's** `timezone` (default `Asia/Shanghai`). When you view another user, the server uses **that user's** timezone. The app should always send explicit `start`/`end`/date values rather than relying on server defaults.
- `created_at` / `finished_at` are SQLite `datetime('now')` strings: `"YYYY-MM-DD HH:MM:SS"` in **UTC**, with no `T` and no `Z`. Parse them with a fixed-format UTC formatter.
- Weeks start on **Monday**.
- Date validation (`isDate`) = regex `^\d{4}-\d{2}-\d{2}$` plus a successful JS `Date.parse`. Send only real calendar dates. Impossible dates such as `02-30` are not reliably rejected.

### 0.5 Numbers
- JSON numbers come from JS doubles. **Decode every measurement as `Double`.** This includes values that look integral, such as `steps`, `score`, `intake` and `points`.
- Only decode these as `Int`: ids, and the explicit counts (`mealCount`, `itemCount`, `fastFoodMeals`, `windowDays`, `loggedDays`, `available`, `days`, `daysLogged`, `streak`, `strengthDays`, `hazardCount`, `good`/`ok`/`warn`/`bad`, the MEPA `score`). To be robust, a single tolerant decoder that maps any JSON number to `Double` is also fine.
- Booleans in **raw DB rows** (`activity`, `exercises`, `body` inside `/day`) are **integers 0/1** (`in_device`, `bp_treated`), not JSON booleans. Booleans in computed objects (`hasData`, `full`, `met`, `appliesToTotal`, `sensitive`, `is_me`, `shared_with_me`) are real JSON booleans.
- Numbers are **not rounded** unless this document says so. Round only for display.

### 0.6 Optional keys: "absent" is different from `null`
JS `undefined` properties are **omitted** from JSON. In the tables below:
- `T | null` means the key is always present and may be `null`.
- `T?` means the key may be **absent**. Use Swift optionals with `decodeIfPresent`.

### 0.7 Dictionary ordering (important for iOS)
Several responses are JSON objects whose **key order is meaningful for display**: DRI `intake`/`upper`, `targets.intake`, `targets.limits`, `targets.upper`, `totals`, `groups`. `JSONDecoder` into `[String: X]` loses that order. To render tables in the web's order, **order rows by the arrays documented here**: `meta.nutrients`, `meta.foodGroups`, the INTAKE/UPPER/LIMITS orders in section 9.4, or `limits` order in section 4.

### 0.8 Status enum (used everywhere)
`Status = "good" | "ok" | "warn" | "bad" | "info"`

The web shows these labels (reuse them exactly):

| status | label | color role |
|---|---|---|
| good | 达标 | good (green) |
| ok | 达标 | good (green) |
| warn | 偏离 | warning (amber) |
| bad | 不达标 | critical (red) |
| info | 提示 | neutral/axis |

---

## 1. Access control: viewing other users (`?user=`)

`GET /day/{date}`, `GET /trends` and `GET /period` accept the optional query `user=<username>`. Without it you see your own data with `full = true`.

Resolution (`resolveOwner` + `canView`):
1. Look up `users.username = <user>`. The lookup is **case-insensitive** (column is `COLLATE NOCASE`). If no row is found, return **404** `用户不存在`.
2. If the owner is the viewer, the viewer has full access.
3. If the owner's `share_mode` is `"public"`, the viewer can see the summary. If it is `"selected"`, the viewer can see the summary only if a `share_grants (owner_id, viewer_id)` row exists. If it is `"private"`, the viewer has no access.
4. If the viewer cannot see the summary, return **403** `对方没有向你共享数据`.
5. Full access means the viewer can see the summary **and** the owner's `share_detail == "full"`. Otherwise the viewer gets the summary only and `full = false`.
6. If the owner has no profile, return **400** `请先完善个人档案`.

What `full = false` changes (only on `/day` and `/period`; `/trends` ignores it):

| Endpoint | Changes when `full == false` |
|---|---|
| `/day` | `score.items[].message` = `""` (empty string); `score.hazards[].foods` = `[]`; `score.top` = `{"issues":[],"wins":[]}`; `meals` = `[]`; `exercises` = `[]`. **Everything else is still returned**: totals, MAR nutrients, `targets`, `activity`, `body` rows (including `note`, BP), `indices` (LE8 values incl. BP/lab strings). |
| `/period` | `aiSummary` forced to `null`. Everything else is returned. |
| `/trends` | nothing (full totals/groups are returned to summary viewers). |

The iOS client must mirror the web:
- When `full == false`, hide meal lists, the scoring item messages and the highlights.
- Show the read-only header strings (section 13.2).
- Disable all edit actions whenever `user` is set.

**Photo caveat:** `meals[].photos` are bare filenames. They are fetched with `GET /api/v1/uploads/{filename}` (auth required), and the server looks the file up **only in the requesting user's own folder**. A viewer of someone else's `full` day therefore gets **404** for every photo. Hide photo thumbnails when viewing other users (or see the proposal in section 16).

---

## 2. `GET /api/v1/day/{date}`: full day payload

### 2.1 Request
| Part | Name | Type | Required | Notes |
|---|---|---|---|---|
| path | `date` | `YYYY-MM-DD` | yes | Malformed returns 400 `日期格式不正确`. Future dates are accepted (web limits to ≤ today). |
| query | `user` | string | no | username of another member (section 1) |

Order of checks: resolve `user`, then the profile check, then date validation.

Side effect: the server computes and **caches** the DailyScore for `date` and for the 6 previous days (used for `indices`).

### 2.2 Response (`DayResponse`)
| Field | Type | Notes |
|---|---|---|
| `date` | string | echo of the path date |
| `indices` | `HealthIndices` | LE8 / MEPA / WCRF over the **7-day window `date−6 … date`** (section 5) |
| `score` | `DailyScore` | section 3 (stripped if `full == false`) |
| `targets` | `Targets` | section 4, computed for `date` with the weight in effect on `date` |
| `meals` | `DayMeal[]` | section 2.3. `[]` if `full == false`. Sorted by `time`, then `id`. |
| `activity` | `ActivityRow \| null` | section 2.4, the raw `activity_days` row |
| `exercises` | `ExerciseRow[]` | section 2.5, sorted by `time`. `[]` if `full == false`. |
| `body` | `BodyRow[]` | section 2.6, every `body_metrics` row of that date sorted by `time` (always returned) |
| `weightTrend` | `number \| null` | EMA trend weight (kg) on `date`, computed from weigh-ins in the last 60 days (α = 0.1). `null` if there are no weigh-ins in that window. Not rounded. |
| `full` | bool | section 1 |

### 2.3 `DayMeal` and `DayMealItem` (from `mealsForDay`)
`DayMeal`:
| Field | Type | Notes |
|---|---|---|
| `id` | int | |
| `date` | string | |
| `time` | string `HH:MM` | |
| `meal_type` | string | `breakfast`/`lunch`/`dinner`/`snack`/`drink`/`other` (zh: 早餐/午餐/晚餐/加餐/饮品/其他) |
| `description` | string | free text; **`"饮水"` marks the auto-managed water entry** (see below) |
| `photos` | string[] | upload filenames, e.g. `"3fa9…c1.jpg"` → `GET /api/v1/uploads/<name>` |
| `ai_summary` | `string \| null` | AI one-liner for the meal |
| `items` | `DayMealItem[]` | sorted by item `id` |

`DayMealItem`:
| Field | Type | Notes |
|---|---|---|
| `id` | int | |
| `meal_id` | int | |
| `name` | string | |
| `amount_g` | number | grams (ml for drinks) |
| `nutrients` | `{[nutrientKey]: number}` | **always contains all 43 nutrient keys** (section 9.1); values ≥ 0; totals for this portion |
| `groups` | `{[foodGroupKey]: number}` | **always contains all 22 food-group keys** (section 9.2) |
| `hazards` | `{key: string, amount: number, note?: string}[]` | AI-flagged hazard entries (`key` ∈ hazard keys, section 9.3); `amount` in the hazard's unit, `0` means "use refAmount" |
| `nova_group` | `1 \| 2 \| 3 \| 4 \| null` | NOVA class (4 = ultra-processed). zh: 1 未加工, 2 烹饪原料, 3 加工食品, 4 超加工 |
| `category` | `string \| null` | food category key (`staple`, `vegetable`, `fruit`, `meat`, `poultry`, `seafood`, `egg`, `dairy`, `soy_legume`, `nut_seed`, `snack`, `dessert`, `beverage`, `alcohol`, `condiment`, `fast_food`, `dish`, `supplement`, `other`) |
| `amount_desc` | `string \| null` | human portion text, e.g. "一碗" |
| `food_id` | `int \| null` | food-library reference |
| `cooking_method` | `string \| null` | |
| `confidence` | `string \| null` | AI confidence label |
| `notes` | `string \| null` | |

Category zh (web `CATEGORY_ZH`): staple 主食, vegetable 蔬菜, fruit 水果, meat 肉类, poultry 禽肉, seafood 水产, egg 蛋类, dairy 奶制品, soy_legume 豆制品/豆类, nut_seed 坚果种子, snack 零食, dessert 甜点, beverage 饮品, alcohol 酒类, condiment 调味品, fast_food 速食/快餐, dish 菜肴, supplement 补充剂, other 其他.

Water entry: `POST /water` keeps one meal per day with `meal_type = "drink"` and `description = "饮水"`. It has one item whose `amount_g` is the day's water in ml.
- The web **hides** this meal from the meal list.
- The web reads `water ml = meals.find(description=="饮水").items[0].amount_g`.

### 2.4 `ActivityRow` (raw `activity_days` row, `SELECT *`)
| Field | Type | Notes |
|---|---|---|
| `user_id` | int | |
| `date` | string | |
| `steps` | `number \| null` | |
| `active_kcal` | `number \| null` | device "Active Energy" |
| `resting_kcal` | `number \| null` | device "Resting Energy" |
| `distance_km` | `number \| null` | |
| `exercise_min` | `number \| null` | Apple "Exercise minutes" |
| `source` | string | free string; values written today: `manual`, `ai_screenshot`, `apple_shortcut`, `apple_export` |
| `updated_at` | string | UTC SQLite datetime |
| `sleep_hours` | `number \| null` | |
| `stand_hours` | `number \| null` | |

### 2.5 `ExerciseRow` (raw `exercises` row)
| Field | Type | Notes |
|---|---|---|
| `id`, `user_id` | int | |
| `date` | string | |
| `time` | string `HH:MM` | |
| `description` | string | |
| `activity_key` | `string \| null` | MET table key (section 9.5) |
| `met` | number | |
| `duration_min` | number | |
| `distance_km` | `number \| null` | |
| `kcal` | number | **net** kcal = (MET−1) × kg × h |
| `in_device` | **int 0/1** | 1 = already included in the device's active energy (not double-counted) |
| `source` | string | |
| `created_at` | string | |
| `avg_hr` | `number \| null` | |
| `device_kcal` | `number \| null` | |

### 2.6 `BodyRow` (raw `body_metrics` row)
| Field | Type | Notes |
|---|---|---|
| `id`, `user_id` | int | |
| `date` | string | |
| `time` | string `HH:MM` | default `"22:00"` |
| `weight_kg` | `number \| null` | |
| `body_fat_pct` | `number \| null` | |
| `waist_cm` | `number \| null` | |
| `note` | `string \| null` | (visible to summary viewers too) |
| `source` | string | |
| `created_at` | string | |
| `sbp` | `number \| null` | systolic mmHg |
| `dbp` | `number \| null` | diastolic mmHg |
| `bp_treated` | **int 0/1** | on BP medication |

---

## 3. `DailyScore` (the `score` object of `/day`; also the per-day building block of `/trends` and `/period`)

Scoring rules version: `version = 3`. The server cache is keyed on this. The field is present in responses but missing from the web's TS type.

### 3.1 Top-level fields
| Field | Type | Notes |
|---|---|---|
| `date` | string | |
| `hasData` | bool | `true` iff the day has ≥ 1 item **and** total energy > 0 kcal. A water-only day is `false`. |
| `score` | `number \| null` | **HEI-2020 total (0–100)**; `null` if `!hasData` or total kcal < 200 |
| `total` | `CompositeScore` | site composite 0–100 (section 3.2) |
| `categories` | `CategoryResult[]` | 0–2 entries (section 3.3) |
| `items` | `ScoreItem[]` | every check, in a fixed order (section 3.4). `[]` if `!hasData`. |
| `hei` | `{ total, components[] } \| null` | section 3.5. `null` if `!hasData` or kcal < 200. |
| `mar` | `MarResult \| null` | section 3.6. `null` if `!hasData`. |
| `hazards` | `HazardResult[]` | section 3.7. `[]` if `!hasData`. |
| `energy` | `EnergyResult` | section 3.8. **Always computed**, even with no food (intake 0). |
| `totals` | `{[nutrientKey]: number}` | all 43 nutrient keys, day sums (zeros if no food) |
| `groups` | `{[foodGroupKey]: number}` | all 22 food-group keys, day sums |
| `macroPct` | `{protein, carb, fat, satFat, addedSugar, alcohol}` (numbers) | % of total kcal (protein/carb/addedSugar ×4, fat/satFat ×9, alcohol ×7). All 0 if kcal = 0. |
| `upfPct` | number | % of kcal from `nova_group == 4` items |
| `mealCount` | int | meals with ≥ 5 kcal (water-only / black-coffee meals do not count) |
| `itemCount` | int | all items, including water |
| `fastFoodMeals` | int | meals containing ≥ 1 item with `category == "fast_food"` |
| `completeness` | `{level: "none" \| "partial" \| "likely", note: string}` | section 3.9 |
| `top` | `{issues: string[], wins: string[]}` | ≤ 7 issues, ≤ 4 wins (section 3.10) |
| `weightKg` | number | weight used for the day = latest weigh-in on/before `date`, else the profile weight |
| `weighedToday` | `number \| null` | that day's weigh-in (last of day), else `null` |
| `version` | int | `3` |

When `hasData == false`: `score: null`, `categories: []`, `items: []`, `hei: null`, `mar: null`, `hazards: []`, `top: {issues:[],wins:[]}`. `total` is still present (see 3.2).

### 3.2 `CompositeScore` (site composite; the big "总分" number)
```
CompositeScore { score: number|null, parts: CompositePart[], missing: string[] }
CompositePart  { key: string, zh: string, weight: number, score: number|null, points: number|null, note: string }
```
- `weight`: nominal weight; the four weights sum to 100.
- `score`: part score 0–100, or `null` if data is missing.
- `points`: contribution to the total after re-normalisation. `points = score/100 × weight × (100 / Σweights of non-null parts)`.
- `total.score` = Σ points, or `null` (see below).
- `missing`: the `zh` of every part whose `score` is null.

**Daily parts** (always in this order):
| key | zh | weight | score source | note (verbatim) |
|---|---|---|---|---|
| `hei` | 膳食质量 | 50 | HEI-2020 total (null if !hasData or kcal<200) | `HEI-2020 总分` |
| `mar` | 微量营养素 | 15 | MAR value | `MAR：11 种微量营养素达到 RDA 的平均比例` |
| `energy` | 能量平衡 | 15 | 100 if \|intake/target−1\| ≤ 0.10; 0 if ≥ 0.50; linear between: `(0.5−dev)/0.4×100`; 100 if target ≤ 0 | `摄入与今日目标偏差 ≤ 10% 满分，≥ 50% 为 0` |
| `activity` | 身体活动 | 20 | `min(100, max(minutes/30, steps/8000)×100)` | `没有运动或步数记录` if no data, else ``中高强度 {round(min)} 分钟{、{steps} 步 if steps}；30 分钟或 8000 步满分`` |

"minutes" for the activity part:
- Sum over exercises: MET ≥ 6 counts 2 × `duration_min`; 3 ≤ MET < 6 counts 1 × `duration_min`; MET < 3 counts 0.
- Then take `max(that, activity.exercise_min)`.
- The part is `null` when there are no exercises, `exercise_min` is null **and** steps is null or 0.

**Edge case:** when `hasData == false`, `total.score = null`, **all four `points` are null**, and `missing` lists all four zh names. The `activity` part's `score` **may still be a number** (computed from exercise/steps). Show "暂无记录" for the total in that case.

**Period parts** (on `/period`):
| key | zh | weight | score | note |
|---|---|---|---|---|
| `hei` | 膳食质量 | 40 | HEI-2020 on the whole period's summed intake | `按整个周期总摄入计算的 HEI-2020` |
| `mar` | 微量营养素 | 10 | `avgMar` | `MAR 日均` |
| `le8` | 心血管健康 | 35 | `indices.le8.score` | `AHA Life's Essential 8` |
| `wcrf` | 防癌建议 | 15 | `min(100, wcrf.score / wcrf.max × 100)`, null if `max ≤ 0` | `WCRF/AICR 评分折算为百分制（满分 {max}）` |

If `daysLogged == 0`: `score: null`, all points null, all four in `missing`.

Web display (`TotalParts`) shows one line:
- ``{zh} {points 1dp}/{weight×scale}`` joined with ` · ` for parts with non-null score.
- `scale` = 100/Σ available weights.
- The denominator has 0 decimals if nothing is missing, else 1 decimal.
- If something is missing, append ``（缺{missing joined by 、}，其余按权重折算）``.

### 3.3 `CategoryResult`
```
{ key: "hei" | "mar", zh: string, score: number (0–100), source: string, note: string }
```
| key | zh | source | note |
|---|---|---|---|
| hei | 膳食质量 HEI-2020 | hei_2020 | `美国人平均 58 分` |
| mar | 微量营养素充足 MAR | mar | `11 种微量营养素的平均充足比` |

An entry is present only if the corresponding block is non-null.

### 3.4 `ScoreItem` and the complete item catalog
```
ScoreItem {
  key: string
  category: "hei" | "mar" | "adequacy" | "moderation" | "energy"
  zh: string
  value: number
  unit: string
  targetText: string          // display text for the standard
  target?: number             // absent unless listed below
  ideal?: number              // absent unless listed below
  limit?: number              // absent unless listed below
  status: Status
  score: number               // 0–1
  points: number              // HEI official points; 0 for non-HEI items
  maxPoints: number           // HEI max points; 0 for non-HEI items
  message: string             // full Chinese explanation ("" when shared as summary)
  sources: string[]           // source ids → meta.sources (section 9.7)
}
```
Formatting inside server strings: numbers are formatted `en-US` with thousands separators (e.g. `2,300`) and at most the stated decimals.

**Order of `items`** (when `hasData`):
1. 13 HEI items (only if `hei != null`)
2. intake items (RDA/AI), in INTAKE order, excluding `sodium_mg`, `carb_g`, `water_g`
3. `water_g`
4. 7 moderation limits: `sodium_mg`, `added_sugars_g`, `sat_fat_pct`, `trans_fat_g`, `alcohol_g`, `caffeine_mg`, `upf_pct`
5. `added_sugars_per_meal` (if ≥ 1 meal with ≥ 5 kcal)
6. `amdr_protein`, `amdr_carb`, `amdr_fat` (only if day kcal ≥ 600)
7. `ul_<nutrient>` for each nutrient over a total-applicable UL
8. `cholesterol_mg` (info)
9. `energy_balance`

#### 3.4.1 HEI items (`category: "hei"`), key = `hei_<componentKey>`
- `zh`/`unit` come from the HEI component (section 9.6). `value` = density value.
- `points` = component score; `maxPoints` = component max; `score` = points/max.
- `status`: ratio ≥ 0.999 gives `good`; ≥ 0.6 gives `warn`; else `bad`.
- `targetText`:
  - adequacy components except fatty_acids: ``≥ {best} {unit} 得满分``
  - `fatty_acids`: ``≥ 2.5 得满分，≤ 1.2 得 0``
  - moderation components: ``≤ {best} 得满分，≥ {worst} 得 0（{unit}）``
- `message`: ``{zh} {value 2dp} {unit}：得 {points 1dp}/{max}``, followed by ``，扣 {lost 1dp} 分。建议：{hint}`` if lost > 0.05, else `，满分`.
- `sources: ["hei_2020"]`. No `target`/`ideal`/`limit`.

#### 3.4.2 Intake items (`category: "mar"` if the key is one of the 11 MAR nutrients, else `"adequacy"`), key = nutrient key
Keys (INTAKE order, minus skipped): `protein_g, fiber_g, linoleic_g, ala_g, vit_a_ug, vit_c_mg, vit_d_ug, vit_e_mg, vit_k_ug, thiamin_mg, riboflavin_mg, niacin_mg, vit_b6_mg, folate_ug, vit_b12_ug, pantothenic_mg, biotin_ug, choline_mg, calcium_mg, copper_mg, iodine_ug, iron_mg, magnesium_mg, manganese_mg, phosphorus_mg, selenium_ug, zinc_mg, potassium_mg`.

- `zh`/`unit` come from the nutrient dictionary. `value` = day total. `target` = personal RDA/AI (**present**).
- `targetText`: ``≥ {target} {unit}（{RDA|AI}）``. `score` = min(1, value/target).
- `status`: ratio ≥ 1 gives `good`; ≥ 0.7 gives `warn`; else `bad`. **Exception for `protein_g`:** if ratio ≥ 1 but g/kg (reference weight) < 1.2, the status is `ok`.
- `message`: ``{zh} {value} {unit}，达到{RDA|AI} 的 {pct}%``
  - plus, for protein, ``（{g/kg 2dp} g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg）``
  - plus, for MAR nutrients, ``（NAR {nar 2dp}）``
- `sources`: `[intake.source]` (`nasem_dri`, or `nasem_na_k` for potassium), with `"dga_2025"` appended for protein.

#### 3.4.3 `water_g` (`category: "adequacy"`)
- `zh: "总水分"`, `unit: "g"`, `target` present.
- `targetText: "≥ {AI} g（AI，含食物水分）"`. Status thresholds are the same as for intake items.
- `message`: ``总水分 {v} g，达到 AI 的 {pct}%（记得用“+250 ml”记录饮水）``
- `sources: ["nasem_dri"]`.

#### 3.4.4 Moderation limits (`category: "moderation"`; `ideal` and `limit` **present**)
| key | zh | unit | value | ideal | limit | decimals | sources | extra suffix |
|---|---|---|---|---|---|---|---|---|
| `sodium_mg` | 钠 | mg | totals.sodium_mg | targets.limits.sodium_mg.ideal | .limit | 0 | [limitSource, idealSource, "dga_2025"] | ``（约合食盐 {v/393 1dp} g）`` |
| `added_sugars_g` | 添加糖 | g | totals.added_sugars_g | limits.added_sugars_g.ideal | .limit | 1 | [limitSource, idealSource, "dga_2025"] | — |
| `sat_fat_pct` | 饱和脂肪供能比 | % | macroPct.satFat | limits.sat_fat_pct.ideal (8 or 6) | 10 | 1 | [limitSource, idealSource] | ``（{sat_fat_g 1dp} g）`` |
| `trans_fat_g` | 反式脂肪 | g | totals.trans_fat_g | **0.3** | **max(0.5, limits.trans_fat_g.limit)** | 2 | ["who_trans","dga_2020"] | — |
| `alcohol_g` | 酒精 | g | totals.alcohol_g | 0 | limits.alcohol_g.limit (28/14/0) | 1 | ["dga_2020","dga_2025","niaaa_drink"] | if >0: ``（≈ {g/14 1dp} 标准杯）`` |
| `caffeine_mg` | 咖啡因 | mg | totals.caffeine_mg | = limit | limits.caffeine_mg.limit | 0 | [limitSource] | — |
| `upf_pct` | 超加工食品供能比 | % | upfPct | 20 | 50 | 0 | ["dga_2025","nova"] | — |

Status/score function (`limitCurve(value, ideal, limit)`):
- If limit ≤ 0: value ≤ 0 gives (`good`, 1); otherwise (`bad`, 0).
- value ≤ ideal: `good`, 1.
- value ≤ limit: `ok`, `1 − 0.3 × (value−ideal)/(limit−ideal)`.
- Otherwise: `bad`, `max(0, 0.7 × (1 − (value−limit)/limit))`.

`targetText`: ``≤ {limit} {unit}`` if ideal == limit, else ``≤ {limit} {unit}（理想 ≤ {ideal}）``.

`message`: ``{zh} {value} {unit}``, then:
- `bad`: ``，超出上限 {over} 个百分点`` for unit `%`; else ``，超出上限 {over} {unit}（{over/limit×100}%）``. The parenthetical appears only when limit > 0.
- `ok`: ``，在上限内但高于理想值 {ideal} {unit}``
- `good`: `，达到理想水平`

Then the extra suffix from the table.

#### 3.4.5 `added_sugars_per_meal` (`category: "moderation"`)
- `zh: "每餐添加糖 ≤ 10 g"`. `value` = number of meals ≤ 10 g added sugar (≤ 10.05). `unit` = ``/{N} 餐``. N counts only meals with ≥ 5 kcal.
- `targetText: "每餐 ≤ 10 g（DGA 2025–2030）"`. `status`: `good` if all meals are OK, else `bad`. `score` = ok/N.
- `message`: `每餐添加糖都在 10 g 以内`, or ``{N−ok} 餐超过 10 g，最高一餐 {g 1dp} g（{HH:MM}）``.
- `sources: ["dga_2025"]`. No target/ideal/limit.

#### 3.4.6 AMDR (`category: "moderation"`, only when kcal ≥ 600)
| key | zh | value |
|---|---|---|
| `amdr_protein` | 蛋白质供能比 | macroPct.protein |
| `amdr_carb` | 碳水供能比 | macroPct.carb |
| `amdr_fat` | 脂肪供能比 | macroPct.fat |

- `unit: "%"`. `targetText: "{lo}–{hi}%（AMDR）"` (en dash).
- `status`: `good`/1 inside [lo, hi], else `bad`/0.
- `message`: ``{zh} {v}%`` followed by one of `，在可接受范围内`, ``，低于下限 {lo}%``, ``，高于上限 {hi}%``.
- `sources: ["nasem_dri"]`.
- AMDR ranges by age: <4 → protein 5–20, carb 45–65, fat 30–40. 4–18 → 10–30 / 45–65 / 25–35. ≥19 → 10–35 / 45–65 / 20–35.

#### 3.4.7 UL exceedances (`category: "moderation"`), key = `ul_<nutrientKey>`
- Emitted only for nutrients whose UL applies to total intake (`vit_c_mg, vit_d_ug, vit_b6_mg, choline_mg, calcium_mg, copper_mg, iodine_ug, iron_mg, manganese_mg, phosphorus_mg, selenium_ug, zinc_mg`) **and** value > UL.
- `zh: "{nutrient zh} 超过 UL"`. `limit` = UL (present). `status: "bad"`, `score: 0`.
- `targetText: "≤ {UL} {unit}（UL）"`.
- `message`: ``{zh} {v} {unit}，超过可耐受最高摄入量 {UL} {unit}，检查补充剂或强化食品``
- `sources: ["nasem_dri"]`.

#### 3.4.8 `cholesterol_mg` (`category: "moderation"`, **status `info`**)
- `zh: "膳食胆固醇（仅提示）"`, `unit: "mg"`, `targetText: "尽量低（现行 DGA 无数值上限）"`, `score: 1`.
- `message`: ``胆固醇 {v} mg。现行 DGA 不设数值上限，只建议在健康膳食模式内尽量低``
- `sources: ["nasem_dri","fda_dv"]`.

#### 3.4.9 `energy_balance` (`category: "energy"`)
- `zh: "能量摄入 vs 目标"`, `unit: "kcal"`, `value` = intake kcal, `target` = energy.target (present).
- `targetText: "{target} kcal ±10%"`.
- `status`: dev = |intake/target − 1|. dev ≤ 0.10 gives `good`; ≤ 0.25 gives `warn`; else `bad`. `score = max(0, 1−dev)`.
- `message`: ``摄入 {kcal} kcal，今日目标 {target} kcal（消耗 {tdee}{ + / − {|goalDelta|} 目标调整 if goalDelta≠0}），`` followed by ``多 {x} kcal`` or ``少 {x} kcal``. The minus sign is U+2212 `−`.
- `sources`: `["nasem_energy","mifflin"]` if `energy.method == "eer"`, else `["mifflin","compendium_2024"]`.

### 3.5 `hei` block (in DailyScore)
```
{ total: number (0–100),
  components: { key, zh, score: number, max: number, value: number, unit: string, hint: string }[] }   // 13 entries, order in 9.6
```
`null` when total kcal < 200 or `!hasData`.

Note: the **period** `hei` (section 6) has the same shape **plus `best: number` and `worst: number`** on each component.

### 3.6 `MarResult`
```
{ value: number (0–100),
  nutrients: { key: string, zh: string, intake: number, target: number, nar: number (0–1) }[] }   // 11 entries
```
- Order: `vit_a_ug, thiamin_mg, riboflavin_mg, niacin_mg, vit_b6_mg, folate_ug, vit_b12_ug, vit_c_mg, calcium_mg, iron_mg, zinc_mg`.
- `nar = min(1, intake/target)`. `value = mean(nar) × 100`.

### 3.7 `HazardResult`
```
{ key: string, zh: string, iarc: "1" | "2A" | "2B" | "—", dose: number, unit: "g" | "mg" | "ml",
  foods: string[], message: string, sources: string[] }
```
- One entry per hazard with dose > 0.01. Sorted by IARC rank: `"1"`, then `"2A"`, then `"—"` (U+2014, non-carcinogen), then `"2B"`. Ties keep the order of section 9.3.
- Dose source:
  - group-based (`processed_meat` → `groups.processed_meat_g`; `red_meat` → `groups.red_meat_g`)
  - nutrient-based (`alcohol` → `totals.alcohol_g`)
  - flag-based: Σ item hazard entries; an `amount` of 0 counts as `refAmount`
- `foods` = item names that contributed: group > 0, nutrient > 0.5, or a flag entry. It is `[]` when shared as summary.
- `message` templates:
  - `aspartame`: ``约 {dose} mg，为你体重对应 ADI（{adi} mg）的 {pct}%``, followed by `，已超过 ADI` or `，在 ADI 以内`. ADI = 40 mg/kg × the day's weight.
  - `processed_meat`: ``加工肉约 {dose} g（WHO：每天每 50 g 结直肠癌风险约 +18%；WCRF：<21 g/周）``
  - `red_meat`: ``红肉约 {dose} g（WCRF：每周 ≤500 g 熟重）``
  - `alcohol`: ``纯酒精约 {dose 1dp} g ≈ {dose/14 1dp} 标准杯（IARC：无安全剂量）``
  - others: ``相关食物约 {dose} {unit}``
- Web shows: name, IARC chip, ``来自：{foods joined 、}``, message, then from meta ``{risk}。建议：{advice}``, then source links.
- `hazards` **always includes** red meat < 72 g and aspartame within ADI. Those two are only suppressed from `top.issues` and from `/trends.hazardCount` (red meat only).

### 3.8 `EnergyResult`
```
{ intake: number, resting: number, restingSource: "device" | "bmr",
  active: number, activeSource: "device" | "steps" | "exercise" | "none",
  exerciseKcal: number, tef: number, tdee: number, method: "measured" | "eer",
  target: number, balance: number }
```
All values are kcal and unrounded. The case is chosen as follows, first match wins:
1. **`active_kcal` > 0** (device): `active = active_kcal + Σ kcal of exercises with in_device = 0`; `tdee = (resting + active)/0.9`; `tef = tdee×0.1`; `activeSource = "device"`.
2. **`steps` > 0**: `active = stepsNetKcal + same extra exercises`. Here stepsNetKcal = km × kg × 0.5, with km = steps × height_cm × 0.414 / 100000. Then `tdee = (resting+active)/0.9`; `activeSource = "steps"`.
3. **only exercises**: `base = EER("inactive")`; `active = Σ all exercise kcal`; `tdee = base + active`; `tef = base×0.1`; `activeSource = "exercise"`.
4. **nothing**: `tdee = targets.eer`; `method = "eer"`; `tef = tdee×0.1`; `active = 0`; `activeSource = "none"`.

Other fields:
- `resting` = `activity.resting_kcal` if it is > 500 (then `restingSource = "device"`), else BMR (Mifflin).
- `exerciseKcal` = Σ kcal of all exercises (including `in_device`).
- `target = max(energyFloor, tdee + goalDeltaKcal)`.
- `balance = intake − tdee`.

These rules matter for HealthKit uploads:
- Send `active_kcal` and `resting_kcal`.
- Mark watch workouts `in_device = 1` so they are not double-counted.
- `resting_kcal` ≤ 500 is ignored.

### 3.9 `completeness`
| level | note (verbatim) |
|---|---|
| `none` | `今天还没有记录` (mealCount == 0) |
| `partial` | `记录可能不完整：摄入明显低于基础代谢或少于 2 餐，评分仅供参考` (kcal < 0.6×BMR or mealCount < 2) |
| `likely` | `记录较完整` |

The web shows a warning banner with `note` only when `hasData && level == "partial"`.

### 3.10 `top` (highlights; precomputed Chinese sentences)
- `issues`: up to 7 strings, highest weight first.
  - Hazards: IARC 1 has weight 30, 2A has 20, others 15. Text: ``{zh}（IARC {iarc}）：{message}``. Red meat < 72 g and aspartame ≤ ADI are skipped.
  - Moderation items with status `bad` (weight 8): their `message`.
  - HEI components losing ≥ 1.5 points (weight = points lost): ``HEI「{zh}」扣 {lost 1dp} 分：{value 2dp} {unit}``.
  - MAR items, `fiber_g`, `potassium_mg` and `vit_d_ug` with score < 0.5 (weight 3): their `message`.
- `wins`: up to 4 `message`s, taken from:
  - HEI components with max ≥ 5 at full points
  - `sodium_mg` / `added_sugars_g` / `sat_fat_pct` with status `good`

---

## 4. `Targets` (in `/day.targets`; same shape as `GET /profile/targets`)

`GET /api/v1/profile/targets?date=YYYY-MM-DD` (own user only; `date` defaults to today). The web Trends page uses it to draw target lines, and Standards → 我的个性化目标 uses it. It is returned as-is.

| Field | Type | Notes |
|---|---|---|
| `date` | string | |
| `age` | int | ≥ 1 |
| `sex` | `"male" \| "female"` | |
| `lifeStage` | string | life-stage id (section 9.4) |
| `lifeStageZh` | string | e.g. `男 31–50 岁` |
| `physiology` | `"none" \| "pregnant" \| "lactating"` | always `none` for males |
| `sensitive` | bool | pregnant/lactating or age < 18 (web shows ` · 敏感人群`) |
| `weightKg` | number | |
| `heightCm` | number | |
| `bmi` | number | |
| `bmiCategory` | `{key: "under"\|"normal"\|"over"\|"obese", zh: "偏瘦"\|"正常"\|"超重"\|"肥胖"}` | <18.5 / <25 / <30 / ≥30 |
| `referenceWeightKg` | number | if BMI ≥ 30: ideal + 0.4×(weight−ideal), where ideal = 22.5×h²; else weight |
| `bmr` | number | Mifflin–St Jeor |
| `eer` | number | NASEM 2023 EER (+340 pregnant / +330 lactating) |
| `eerMethod` | string | `NASEM 2023 EER` or `Mifflin-St Jeor × PAL（未成年人近似）`, optionally followed by ` + 孕期增量` or ` + 哺乳期增量` |
| `goal` | `"lose" \| "maintain" \| "gain"` | **effective** goal: becomes `maintain` once the target weight is reached; `lose` becomes `maintain` while pregnant/lactating |
| `goalDeltaKcal` | number | lose: −rate×7700/7; gain: min(rate×7700/7, 500); rate is clamped 0.1–1 kg/week |
| `energyTarget` | number (int) | max(energyFloor, round(eer + goalDelta)), used when there is no activity data |
| `energyFloor` | number (int) | max(1500 male / 1200 female, round(bmr)) |
| `protein` | `{rdaG, idealLowG, idealHighG, perKgRda}` (numbers) | idealLow/High = 1.2/1.6 × referenceWeightKg |
| `intake` | `{[nutrientKey]: IntakeTarget}` | 31 keys (INTAKE order, section 9.4) |
| `upper` | `{[nutrientKey]: {value: number, appliesToTotal: bool, note?: string}}` | 17 keys (UPPER order) |
| `limits` | `{[limitKey]: LimitTarget}` | 7 keys, in order: `sodium_mg, added_sugars_g, sat_fat_pct, trans_fat_g, alcohol_g, caffeine_mg, upf_pct` |
| `amdr` | `{protein:[lo,hi], carb:[lo,hi], fat:[lo,hi], n6:[5,10], n3:[0.6,1.2]}` | percent of energy |
| `addedSugarPerMealG` | number | always 10 |
| `aspartameAdiMg` | number | 40 × weightKg |

`IntakeTarget = { key: string, value: number, kind: "RDA" | "AI", source: string, note?: string }`
- `source` is `"nasem_na_k"` for `sodium_mg` and `potassium_mg`, else `"nasem_dri"`.
- `note` is present only on:
  - `protein_g`: ``RDA {perKg} g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg``. Value = max(table RDA, perKg × referenceWeight).
  - `fiber_g`: `14 g / 1000 kcal × 你的能量目标`. Value = round(14 × energyTarget/1000).

`LimitTarget = { key, zh, unit, ideal: number, limit: number, idealSource: string, limitSource: string, note?: string }`

| key | zh | unit | ideal | limit | idealSource / limitSource | note |
|---|---|---|---|---|---|---|
| sodium_mg | 钠 | mg | adult 1500, else child AI | 1500 if adult and (sodium_mode=="aha" or hypertension), else CDRR (2300 adults) | aha_sodium (adult) / nasem_na_k, or aha_sodium when strict | `已按高血压/AHA 模式收紧` or `上限为 CDRR，与 DGA 一致` |
| added_sugars_g | 添加糖 | g | age<4: 0; else AHA (36 male ≥19, else 25) | age<4: 5; diabetes: AHA value; else max(round(energyTarget×0.1/4), AHA) | aha_sugar / dga_2020 (aha_sugar if diabetes) | `DGA 2025–2030：不推荐任何添加糖，每餐不超过 10 g` |
| sat_fat_pct | 饱和脂肪供能比 | `% 能量` | 6 if high_ldl else 8 | 10 | aha_satfat or hei_2020 / dga_2025 | (absent) |
| trans_fat_g | 反式脂肪 | g | 0 | round1(energyTarget×0.01/9) | dga_2020 / who_trans | `WHO：< 1% 总能量` |
| alcohol_g | 酒精 | g | 0 | 0 if pregnant/lactating/age<21; male 28; female 14 | iarc_list / dga_2020 | `孕期/哺乳期/未满 21 岁应完全避免` or `DGA 2020–2025：男 ≤2 杯、女 ≤1 杯；DGA 2025–2030：越少越好` |
| caffeine_mg | 咖啡因 | mg | = limit | 200 (pregnant/lactating), round(2.5×kg) (<18), else 400 | acog_caffeine / hc_caffeine / fda_caffeine | `未成年人按 2.5 mg/kg 体重` (absent for adults) |
| upf_pct | 超加工食品供能比 | `% 能量` | 20 | 50 | dga_2025 / system | `DGA 2025–2030 要求限制高度加工食品但未给数值；按 NOVA 4 类估算，阈值为本系统设定` |

---

## 5. `HealthIndices` (LE8, MEPA, WCRF): `/day.indices` (7-day window) and `/period.indices` (whole period)

```
HealthIndices {
  windowDays: int            // number of days in window (7 on /day)
  loggedDays: int            // days with hasData
  mepa: MepaResult | null    // null if loggedDays < 3
  le8: Le8Result
  wcrf: WcrfResult
  pa: { le8MinPerWeek: number|null, mvpaMinPerWeek: number|null, strengthDays: int }
  sleepHours: number | null  // mean of activity.sleep_hours > 0 within window
}
```

Inputs used, all read **up to the window end**:
- weight: latest weigh-in, else the profile weight
- waist: latest within 180 days
- BP: mean of the **last 3 readings within 90 days**; `treated` if any reading is treated
- lab: latest lab row on/before end, any age
- nicotine / secondhand smoke: from the profile
- diabetes = `lab.diabetes || profile.conditions contains "diabetes"`

Physical activity:
- For each date, take max(Σexercise minutes, `activity.exercise_min`). In the LE8 sum, MET ≥ 6 counts ×2; in the plain (WCRF) sum it counts ×1. MET < 3 is ignored.
- Per week = total / windowDays × 7.
- `le8MinPerWeek`/`mvpaMinPerWeek` are `null` when the window has **no exercise rows and no `activity.exercise_min`**. Steps alone do not count.
- `strengthDays` = dates with an exercise whose `activity_key` matches `strength|circuit|hiit`.

### 5.1 `Le8Result`
```
{ score: number|null,                         // mean of non-null component points (0–100)
  category: { key: "high"|"moderate"|"low", zh: "高"|"中"|"低" } | null,   // ≥80 / ≥50 / <50
  available: int,                             // number of non-null components (0–8)
  components: Le8Component[8] }
Le8Component { key: string, zh: string, points: number|null, value: string, rule: string, missing: string }
```
Components (always 8, this order). `value` is `"—"` when there is no data.

| key | zh | points | value (when data) | rule (verbatim) | missing (verbatim) |
|---|---|---|---|---|---|
| diet | 饮食（MEPA） | MEPA 15–16→100, 12–14→80, 8–11→50, 4–7→25, 0–3→0 | ``MEPA {score}/16（近 {mepa.days} 天记录推算）`` | `MEPA 15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0` | `需要至少 3 天饮食记录` |
| activity | 身体活动 | min/wk ≥150→100, ≥120→90, ≥90→80, ≥60→60, ≥30→40, ≥1→20, else 0 | ``{round(min)} 分钟/周`` | `≥150 → 100；120–149 → 90；90–119 → 80；60–89 → 60；30–59 → 40；1–29 → 20；0 → 0（高强度 1 分钟按 2 分钟计）` | `记录运动或同步“锻炼分钟”` |
| nicotine | 尼古丁暴露 | never 100, former_5y 75, former_1_5y 50, former_lt1y 25, ecig 25, current 0; secondhand −20 (only if >0); `unknown` → null | NIC_ZH, followed by `，家中有人室内吸烟` if secondhand | `从不 100；戒 ≥5 年 75；戒 1–5 年 50；戒 <1 年或电子烟 25；吸烟 0；家中二手烟 −20` | `在设置 → 个人档案中填写吸烟情况` |
| sleep | 睡眠 | 7–<9→100; 9–<10→90; 6–<7→70; 5–<6 or ≥10→40; 4–<5→20; <4→0 | ``平均 {h 1dp} 小时/晚`` | `7–<9 小时 100；9–<10 → 90；6–<7 → 70；5–<6 或 ≥10 → 40；4–<5 → 20；<4 → 0` | `填写或同步睡眠时长` |
| bmi | 体重指数 BMI | <25→100; <30→70; <35→30; <40→15; else 0 | ``BMI {1dp}`` | `<25 → 100；25–29.9 → 70；30–34.9 → 30；35–39.9 → 15；≥40 → 0` | `记录体重` |
| lipids | 血脂（非 HDL 胆固醇） | non-HDL <130→100; <160→60; <190→40; <220→20; else 0; treated −20 (min 0) | ``{round} mg/dL`` followed by `（服药）` if treated | `<130 → 100；130–159 → 60；160–189 → 40；190–219 → 20；≥220 → 0；服药 −20` | `在身体页填写体检的总胆固醇与 HDL` |
| glucose | 血糖 | see below | ``空腹 {round} mg/dL`` and/or ``HbA1c {v}%`` joined by `，`, followed by `（糖尿病）` if diabetes | `无糖尿病：空腹 <100 或 HbA1c <5.7 → 100；100–125 或 5.7–6.4 → 60；糖尿病：HbA1c <7 → 40，7–7.9 → 30，8–8.9 → 20，9–9.9 → 10，≥10 → 0` | `在身体页填写体检的空腹血糖或糖化血红蛋白` |
| bp | 血压 | ≥160 or ≥100 → 0; ≥140 or ≥90 → 25; ≥130 or ≥80 → 50; sbp ≥120 → 75; else 100; treated −20 (min 0) | ``{sbp}/{dbp} mmHg`` followed by `（服药）` if treated | `<120/<80 → 100；120–129/<80 → 75；130–139 或 80–89 → 50；140–159 或 90–99 → 25；≥160 或 ≥100 → 0；服药 −20` | `记录血压` |

NIC_ZH: never 从不吸烟, former_5y 已戒烟 ≥5 年, former_1_5y 已戒烟 1–5 年, former_lt1y 戒烟 <1 年, ecig 使用电子烟, current 目前吸烟.

Glucose points:
- Diabetic: requires HbA1c, else `null` even if fasting glucose exists. HbA1c <7 → 40, <8 → 30, <9 → 20, <10 → 10, else 0.
- Non-diabetic, both values null: `null`.
- Non-diabetic with fasting ≥ 126 or HbA1c ≥ 6.5: scored on the diabetic scale, using HbA1c (or 6.5 if missing).
- Non-diabetic otherwise: prediabetic (fasting ≥ 100 or HbA1c ≥ 5.7) → 60, else 100.
- Note: the `diabetes` condition is labeled "糖尿病 / 糖尿病前期", so prediabetic users are also scored on the diabetic scale.

### 5.2 `MepaResult` (`null` if loggedDays < 3)
```
{ score: int (0–16), days: int (= loggedDays), items: MepaItem[16] }
MepaItem { key: string, zh: string, criterion: string, value: number, unit: string, met: bool }
```
Per-day/per-week values are averages over **logged** days (×7 for per week).

| key | zh | criterion | unit | met when |
|---|---|---|---|---|
| olive_oil | 橄榄油 | `> 2 份/天（1 份 = 1 汤匙）` | 份/天 | > 2 |
| leafy | 绿叶蔬菜 | `> 7 份/周（1 份 = 1 杯生 / ½ 杯熟）` | 份/周 | > 7 |
| other_veg | 其他蔬菜 | `> 2 份/天（1 份 = ½ 杯）` | 份/天 | > 2 |
| berries | 浆果 | `> 2 份/周（1 份 = ½ 杯）` | 份/周 | > 2 |
| other_fruit | 其他水果 | `> 1 份/天（1 份 = ½ 杯）` | 份/天 | > 1 |
| meat | 红肉、汉堡、培根、香肠 | `< 3 份/周（1 份 = 3 盎司）` | 份/周 | < 3 |
| fish | 鱼和贝类 | `> 1 份/周（1 份 = 3 盎司）` | 份/周 | > 1 |
| chicken | 鸡肉 | `< 5 份/周（1 份 = 3 盎司）` | 份/周 | < 5 |
| cheese | 全脂奶酪 / 奶油奶酪 | `< 4 份/周（1 份 = 1 盎司）` | 份/周 | < 4 |
| butter | 黄油 / 奶油 | `< 5 份/周（1 份 = 1 汤匙）` | 份/周 | < 5 |
| beans | 豆类 | `> 3 份/周（1 份 = ½ 杯）` | 份/周 | > 3 |
| whole_grains | 全谷物 | `> 3 份/天（1 份 = 1 片面包 / ¾ 杯）` | 份/天 | > 3 |
| sweets | 商业甜点、糖果、糕点 | `< 4 份/周` | 份/周 | < 4 |
| nuts | 坚果 | `> 4 份/周（1 份 = ¼ 杯）` | 份/周 | > 4 |
| fast_food | 快餐 | `< 1 次/周` | 次/周 | < 1 |
| alcohol | 酒精 | ``> 0 且 < {2 male / 1 female} 杯/天（问卷原文；与 IARC“无安全剂量”的观点不同，防癌评分中以不饮酒为最佳）`` | 杯/天 | > 0 and < limit |

### 5.3 `WcrfResult`
```
{ score: number,      // Σ points of components with non-null points and max > 0 (always a number)
  max: number,        // Σ max of those components (0–6)
  components: WcrfComponent[7] }
WcrfComponent { key: string, zh: string, points: number|null, max: number, detail: string, rule: string }
```
Diet components use per-day means over logged days. They are `null` with detail `无数据` when loggedDays < 3.

| key | zh | max | points | detail | rule |
|---|---|---|---|---|---|
| weight | 保持健康体重 | 1 | BMI part: 18.5–24.9 → 0.5, 25–29.9 → 0.25, else 0. Waist part (male <94 / female <80 → 0.5; male <102 / female <88 → 0.25; else 0). If only one part has data it is doubled. | ``BMI {1dp}`` + `，` + ``腰围 {1dp} cm`` or `腰围未记录（按 BMI 计）` | ``BMI 18.5–24.9 得 0.5，25–29.9 得 0.25；腰围 男 <94 cm 得 0.5，94–101.9 得 0.25`` (female: `女 <80 cm 得 0.5，80–87.9 得 0.25`) |
| activity | 积极运动 | 1 | mvpa/wk ≥150 → 1, ≥75 → 0.5, else 0; null if no PA data | ``{round} 分钟/周`` or `无数据` | `中高强度活动 ≥150 分钟/周得 1，75–149 得 0.5` |
| plants | 多吃全谷物、蔬菜、水果、豆类 | 1 | fruit+veg g/day: ≥400 → 0.5, ≥200 → 0.25. Fiber g/day: ≥30 → 0.5, ≥15 → 0.25. Sum. | ``果蔬 {round} g/天，膳食纤维 {1dp} g/天`` | `果蔬 ≥400 g/天得 0.5（200–399 得 0.25）；膳食纤维 ≥30 g/天得 0.5（15–29 得 0.25）` |
| upf | 少吃快餐和高脂高糖高淀粉的加工食品 | **0** | **always null** (display only) | ``超加工食品供能 {round}%（仅展示）`` | `原文按研究人群内的三分位数评分，没有公开的绝对切点，本系统不计分` |
| meat | 限制红肉和加工肉 | 1 | red ≤500 g/wk and processed <21 → 1; red ≤500 and processed <100 → 0.5; else 0 | ``红肉 {round} g/周，加工肉 {round} g/周`` | `红肉 ≤500 g/周且加工肉 <21 g/周得 1；加工肉 21–99 得 0.5；红肉 >500 或加工肉 ≥100 得 0` |
| ssb | 限制含糖饮料 | 1 | ml/day ≤0.5 → 1; ≤250 → 0.5; else 0 | ``{round} ml/天`` | `0 得 1；≤250 ml/天得 0.5；>250 得 0` |
| alcohol | 限制饮酒 | 1 | g/day ≤0.5 → 1; ≤ (male 28 / female 14) → 0.5; else 0 | ``纯酒精 {1dp} g/天`` | ``不饮酒得 1；≤{lim} g/天得 0.5；>{lim} g 得 0`` |

Web display per component:
- `points == null`: `—`.
- Otherwise: ``{points 2dp}/{max}``. Color: points ≥ max is good, > 0 is warning, 0 is critical.

---

## 6. `GET /api/v1/period`: weekly / monthly / custom report

### 6.1 Request
| query | type | default | notes |
|---|---|---|---|
| `start` | `YYYY-MM-DD` | `end − 29` | invalid values are silently replaced by the default |
| `end` | `YYYY-MM-DD` | today (owner's TZ) | |
| `user` | string | — | section 1 |

- `start > end` returns 400.
- If the span is > 400 days, `start` is **silently moved** to `end − 400`, so the period can hold up to 401 days.
- Weekly report convention: `start` = Monday, `end` = start+6. Monthly: first to last day of the month.

### 6.2 Response = `PeriodScore` + `aiSummary` + `full`
| Field | Type | Notes |
|---|---|---|
| `start`, `end` | string | effective range |
| `days` | int | number of days in range (n) |
| `daysLogged` | int | days with `hasData` |
| `avgHei` | `number \| null` | mean daily HEI over days with a score |
| `avgMar` | `number \| null` | mean daily MAR over logged days |
| `score` | `number \| null` | **= `indices.le8.score`** (the LE8 period score) |
| `total` | `CompositeScore` | period composite (section 3.2): the "本周总分 / 本月总分" |
| `category` | `{key, zh} \| null` | = `indices.le8.category` |
| `indices` | `HealthIndices` | computed over the **whole period** (windowDays = n) |
| `hei` | `PeriodHei \| null` | HEI-2020 on summed period intake (null if total kcal < 200). Components have `{key, zh, max, score, value, best, worst, unit, hint}`. |
| `avgTotals` | `{[nutrientKey]: number}` | mean per **logged** day (all 43 keys; zeros if none) |
| `avgGroups` | `{[foodGroupKey]: number}` | mean per logged day (all 22 keys) |
| `itemStats` | `{key, zh, category, good: int, ok: int, warn: int, bad: int, days: int}[]` | per ScoreItem key: how many logged days had each status (`info` items excluded). Order = first appearance. Includes `hei_*` items (the web filters out `category == "hei"`). |
| `checks` | `PeriodCheck[]` | section 6.3 |
| `hazards` | `{key, zh, iarc, dose: number, unit, days: int}[]` | Σ dose over logged days and count of days present, **sorted by `days` desc**. No `foods`, no message. Includes small red-meat doses. |
| `energy` | `PeriodEnergy` | section 6.4 |
| `series` | `{date, score: number\|null, total: number\|null, intake: number, tdee: number, weight: number\|null, trend: number\|null}[]` | one per day, **unrounded**. `score` = HEI, `total` = daily composite, `weight` = that day's last weigh-in, `trend` = EMA. |
| `aiSummary` | `WeeklySummary \| null` | stored AI commentary for exactly this `start`/`end` (null if none, or if `full == false`) |
| `full` | bool | |

`WeeklySummary = { headline: string, summary: string, wins: string[], issues: string[], actions: string[] }`. Chinese text from Claude. `actions` holds 3–5 concrete suggestions.

### 6.3 `PeriodCheck`
```
{ key: string, zh: string, value: number, unit: string, targetText: string, status: Status, score: number, message: string, sources: string[] }
```
`f = n/7` (period length in weeks). Order and presence:

| key | zh | value / unit | target logic | status | message |
|---|---|---|---|---|---|
| `red_meat_week` | 红肉总量 | Σ red_meat_g, `g` | ideal 350f, limit 500f; `≤ {limit} g（理想 ≤ {ideal} g）` | limitCurve | ``期间红肉约 {v} g`` |
| `processed_meat_week` | 加工肉总量 | Σ processed_meat_g, `g` | `越少越好（WCRF：很少或不吃）` | 0 → good; ≤100f → warn; else bad (score always 1) | ``期间加工肉约 {v} g（计入 WCRF 防癌评分“红肉和加工肉”一项）`` or `没有吃加工肉` |
| `seafood_week` | 海产品 | seafood_oz×28.35, `g` | target 8f oz: ``≥ {8f×28.35} g（约 {8f 1dp} 盎司）`` | s = min(1, oz/target): ≥1 good, ≥0.5 warn, else bad | ``期间海产约 {g} g`` |
| `alcohol_week` | 饮酒量 | Σ alcohol_g/14, `标准杯` | heavy = (15 male / 8 female)×f; limit = 0 if daily alcohol limit is 0, else heavy − f. Text: `0（应避免）` or ``< {heavy 1dp} 杯（大量饮酒阈值）`` | limitCurve(drinks, 0, limit) | ``期间约 {1dp} 标准杯`` |
| `activity_week` | 中高强度运动 | Σ daily max(exercise eq. minutes, exercise_min), `分钟` | ``≥ {150f} 分钟（理想 {300f}）`` | ≥300f good; ≥150f ok; ≥75f warn; else bad | ``中等强度当量约 {v} 分钟（高强度按 2 倍计）`` |
| `strength_week` | 力量训练天数 | count, `天` | sTarget = max(1, round(2f)); ``≥ {sTarget} 天`` | ≥ target good; >0 warn; 0 bad | ``力量训练 {n} 天`` |
| `steps_avg` *(only if any day has steps)* | 日均步数（参考） | mean over days with steps, `步` | `参考 ≥ 7000 步` | ≥7000 good; ≥5000 warn; else bad (score 1) | ``日均 {v} 步（非官方标准，仅作参考）`` |
| `logging` | 记录天数 | daysLogged, ``/{n} 天`` | `每周至少 6 天` | s = min(1, logged/(n×6/7)): ≥1 good, ≥0.5 warn, else bad | ``{n} 天中记录了 {logged} 天`` |
| `weight_rate` *(only if ratePerWeek ≠ null and effective goal ≠ maintain)* | 体重变化速度 | ratePerWeek, `kg/周` | lose: `每周 −0.2 至 −1.0 kg`; gain: `每周 +0.1 至 +0.5 kg` | lose: −1.0…−0.2 good; < −1.0 warn; −0.2…0 ok; ≥0 bad. gain: 0.1…0.5 good; >0.5 warn; else bad | ``趋势体重每周 {+}{2dp} kg`` |

Sources:
- red/processed meat: `["wcrf","iarc_114"]`
- seafood: `["dga_2020","fda_fish"]`
- alcohol: `["niaaa_drink","dga_2025"]`
- activity/strength: `["pag_2018"]`
- steps/logging: `["system"]`
- weight_rate: `["cdc_weight"]`

Numbers in these messages use plain `toString` rounding, with no thousands separators.

### 6.4 `PeriodEnergy`
| Field | Type | Meaning |
|---|---|---|
| `avgIntake` | `number \| null` | mean intake over logged days |
| `avgTdee` | number | mean TDEE over **all** n days |
| `totalBalance` | number | Σ (intake − tdee) over logged days |
| `predictedChangeKg` | number | totalBalance / 7700 |
| `trendStart` / `trendEnd` | `number \| null` | first/last non-null EMA trend in range (warmed with 60 days of history) |
| `actualChangeKg` | `number \| null` | trendEnd − trendStart, only if the span between those dates is ≥ 3 days |
| `empiricalTdee` | `number \| null` | avgIntake − actualChangeKg×7700/span. Requires span ≥ 14 days **and** ≥ 70% of days with completeness `likely`. |
| `ratePerWeek` | `number \| null` | actualChangeKg/span×7, only if span ≥ 7 days |

---

## 7. AI commentary: `POST /api/v1/period/summary` + `GET /api/v1/ai/jobs/{id}`

### 7.1 `POST /period/summary`
- Auth: own data only (no `user`).
- JSON body (optional): `{ "start"?: "YYYY-MM-DD", "end"?: "YYYY-MM-DD" }`. The same defaulting and clamping as `/period` applies (default last 30 days, max 401 days, 400 if start > end).
- Response `200 {"job_id": "<uuid>"}`.
- Storage kind:
  - `"week"` if the range is exactly 7 days starting on a Monday, else `"custom"`.
  - A monthly range generated from the app is stored as `"custom"`; the scheduler uses `"month"`.
- The server does **not** check whether an AI provider is configured or whether there is data. The web only shows the button when `daysLogged > 0` **and** `GET /auth/me → ai.provider != "mock"`. The iOS app must apply the same gate.

### 7.2 Job polling: `GET /ai/jobs/{id}`
Response: `{ id: string, kind: "summary", status: "queued"|"running"|"done"|"error", error: string|null, result: WeeklySummary|null }`
- Poll every **1.5 s** (web behaviour) until `done` or `error`.
- On `error`, show `error`, or `AI 任务失败` if it is null.
- On `done`, **re-fetch `GET /period`** for the same range. `aiSummary` is now filled.
- `result` may legitimately be `null` with `status == "done"`. This happens when the provider is `mock` or `daysLogged == 0`.
  - **Warning:** in that case the server upserts the report row with `ai_summary = NULL`, which **erases** an earlier summary for the same (period kind, start).
- Duration: typically 1–3 minutes. The server timeout is 480 s. The AI queue concurrency is 2 for **all** AI jobs, so a job can wait in `queued`.
- If the server restarts mid-job, the job becomes `error` with `服务器重启，任务中断，请重试`. Jobs older than 7 days are purged at restart, and polling them returns 404 `任务不存在`.
- Because generation is long-running, use a background-safe poller in iOS (resume polling when returning to foreground; the job id stays valid).

---

## 8. `GET /api/v1/reports`: stored report list (own user only)

No params. Returns up to **60** rows ordered by `start_date` desc:
```
{ id: int,
  period: "week" | "month" | "custom",
  start_date: "YYYY-MM-DD",
  end_date: "YYYY-MM-DD",
  score: number | null,            // LE8 period score at generation time (NOT the composite total)
  ai_summary: WeeklySummary | null,
  created_at: "YYYY-MM-DD HH:MM:SS" (UTC) }[]
```
- The web does **not** use this endpoint. It computes reports live via `/period`.
- The iOS app can use it for a "历史报告" list. Tapping a row should call `GET /period?start=…&end=…`, which recomputes everything live.
- Rows with `ai_summary == null` and `end_date ≥ D` are deleted whenever data on/after D changes (`invalidateFrom`). Meal edits use `invalidateDay` and do not delete them.

---

## 9. Standards library

### 9.0 `GET /api/v1/standards/meta`
Static (does not depend on the user). The web loads it **once at login** and caches it. Do the same, keyed by `version`.
```
Meta {
  version: int                  // 3 = SCORING_VERSION
  nutrients: NutrientDef[]      // 43, display order (9.1)
  foodGroups: FoodGroupDef[]    // 22 (9.2)
  hazards: HazardDef[]          // 15 (9.3)
  hazardsInfoOnly: { zh: string, iarc: string, examples: string, why: string }[]   // 5; iarc may be "3"
  hei: HeiComponentDef[]        // 13 (9.6)
  activities: Activity[]        // 46 (9.5)
  activityLevels: { key: "inactive"|"low_active"|"active"|"very_active", zh: string, pal: number, desc: string }[]
  sources: Source[]             // 36 (9.7)
  lifeStages: { id: string, zh: string }[]   // 20 (9.4)
  marNutrients: string[]        // 11 keys (3.6 order)
  heiUsMean: number             // 58
  conditions: { key: string, zh: string, effect: string }[]   // 5
}
NutrientDef   { key, zh, en, unit, group: "energy"|"macro"|"carb"|"fat"|"mineral"|"vitamin"|"other", decimals: int, dv?: number, note?: string }
FoodGroupDef  { key, zh, unit, note }
HazardDef     { key, zh, en, iarc: "1"|"2A"|"2B"|"—", category: "carcinogen"|"toxicant"|"lifestyle", risk, detect, examples,
                dose: { from: "group"|"nutrient"|"flag", key?: string, unit: "g"|"mg"|"ml" },   // key absent for "flag"
                refAmount: number, aiFlag: bool, sources: string[], advice: string }
HeiComponentDef { key, zh, en, max: number, kind: "adequacy"|"moderation", best: number, worst: number, unit, hint }
Activity      { key, zh, met: number, speedKmh?: number, code?: string, intensity: "light"|"moderate"|"vigorous" }
Source        { id, org, title, year: string, url: string }   // url may be "" (id "system")
```

### 9.1 Nutrient keys (`totals`, item `nutrients`, `avgTotals`): 43, in display order
`group` / `decimals` / `dv`:

| key | zh | unit | group | dec | dv |
|---|---|---|---|---|---|
| energy_kcal | 能量 | kcal | energy | 0 | |
| protein_g | 蛋白质 | g | macro | 1 | 50 |
| carb_g | 碳水化合物 | g | macro | 1 | 275 |
| fat_g | 总脂肪 | g | macro | 1 | 78 |
| water_g | 水分(食物+饮品) | g | macro | 0 | |
| fiber_g | 膳食纤维 | g | carb | 1 | 28 |
| sugars_g | 总糖 | g | carb | 1 | |
| added_sugars_g | 添加糖 | g | carb | 1 | 50 |
| sat_fat_g | 饱和脂肪 | g | fat | 1 | 20 |
| trans_fat_g | 反式脂肪 | g | fat | 2 | |
| mufa_g | 单不饱和脂肪 | g | fat | 1 | |
| pufa_g | 多不饱和脂肪 | g | fat | 1 | |
| linoleic_g | 亚油酸 (ω-6) | g | fat | 1 | |
| ala_g | α-亚麻酸 (ω-3) | g | fat | 2 | |
| epa_dha_g | EPA+DHA (ω-3) | g | fat | 2 | |
| cholesterol_mg | 胆固醇 | mg | fat | 0 | 300 |
| sodium_mg | 钠 | mg | mineral | 0 | 2300 |
| potassium_mg | 钾 | mg | mineral | 0 | 4700 |
| calcium_mg | 钙 | mg | mineral | 0 | 1300 |
| iron_mg | 铁 | mg | mineral | 1 | 18 |
| magnesium_mg | 镁 | mg | mineral | 0 | 420 |
| phosphorus_mg | 磷 | mg | mineral | 0 | 1250 |
| zinc_mg | 锌 | mg | mineral | 1 | 11 |
| copper_mg | 铜 | mg | mineral | 2 | 0.9 |
| manganese_mg | 锰 | mg | mineral | 2 | 2.3 |
| selenium_ug | 硒 | µg | mineral | 0 | 55 |
| iodine_ug | 碘 | µg | mineral | 0 | 150 |
| vit_a_ug | 维生素 A | µg RAE | vitamin | 0 | 900 |
| vit_c_mg | 维生素 C | mg | vitamin | 0 | 90 |
| vit_d_ug | 维生素 D | µg | vitamin | 1 | 20 |
| vit_e_mg | 维生素 E | mg | vitamin | 1 | 15 |
| vit_k_ug | 维生素 K | µg | vitamin | 0 | 120 |
| thiamin_mg | 维生素 B1 (硫胺素) | mg | vitamin | 2 | 1.2 |
| riboflavin_mg | 维生素 B2 (核黄素) | mg | vitamin | 2 | 1.3 |
| niacin_mg | 烟酸 (B3) | mg | vitamin | 1 | 16 |
| pantothenic_mg | 泛酸 (B5) | mg | vitamin | 1 | 5 |
| vit_b6_mg | 维生素 B6 | mg | vitamin | 2 | 1.7 |
| biotin_ug | 生物素 (B7) | µg | vitamin | 0 | 30 |
| folate_ug | 叶酸 (B9) | µg DFE | vitamin | 0 | 400 |
| vit_b12_ug | 维生素 B12 | µg | vitamin | 2 | 2.4 |
| choline_mg | 胆碱 | mg | vitamin | 0 | 550 |
| caffeine_mg | 咖啡因 | mg | other | 0 | |
| alcohol_g | 酒精 | g | other | 1 | |

(The `µ` is U+00B5. `en`/`note` come from meta at runtime.)

Group headings (web `GROUP_ZH`): energy 能量, macro 宏量营养素, carb 碳水与糖, fat 脂肪酸, mineral 矿物质, vitamin 维生素, other 其他.

### 9.2 Food-group keys (`groups`, `avgGroups`): 22
`fruit_total_cup` 水果总量 (杯当量), `fruit_whole_cup` 完整水果 (杯当量), `veg_total_cup` 蔬菜总量 (杯当量), `veg_dark_green_cup` 深绿色蔬菜 (杯当量), `legumes_cup` 豆类(干豆/豌豆/扁豆) (杯当量), `grains_whole_oz` 全谷物 (盎司当量), `grains_refined_oz` 精制谷物 (盎司当量), `dairy_cup` 奶及奶制品 (杯当量), `protein_total_oz` 蛋白质食物总量 (盎司当量), `seafood_oz` 海产品 (盎司当量), `plant_protein_oz` 植物蛋白(坚果/种子/大豆/豆类) (盎司当量), `red_meat_g` 红肉(熟重) (g), `processed_meat_g` 加工肉 (g), `poultry_g` 禽肉 (g), `fruit_veg_g` 水果+非淀粉类蔬菜 (g), `berries_cup` 浆果 (杯当量), `olive_oil_g` 橄榄油 (g), `butter_cream_g` 黄油/奶油 (g), `cheese_g` 全脂奶酪/奶油奶酪 (g), `nuts_g` 坚果种子 (g), `sweets_serv` 商业甜点/糖果/糕点 (份), `ssb_ml` 含糖饮料 (ml).

### 9.3 Hazards (`meta.hazards`): 15, in this order
| key | zh | iarc | category | dose | refAmount | aiFlag |
|---|---|---|---|---|---|---|
| processed_meat | 加工肉 | 1 | carcinogen | group processed_meat_g, g | 50 | false |
| red_meat | 红肉 | 2A | carcinogen | group red_meat_g, g | 100 | false |
| alcohol | 酒精饮料 | 1 | carcinogen | nutrient alcohol_g, g | 14 | false |
| salted_fish_cantonese | 中式咸鱼 | 1 | carcinogen | flag, g | 50 | true |
| areca_nut | 槟榔 | 1 | carcinogen | flag, g | 10 | true |
| aflatoxin_risk | 黄曲霉毒素风险 | 1 | carcinogen | flag, g | 30 | true |
| high_temp_meat | 高温烧烤/焦糊肉类 | 2A | carcinogen | flag, g | 100 | true |
| smoked_food | 烟熏食品 | 2A | carcinogen | flag, g | 100 | true |
| acrylamide | 丙烯酰胺(高温油炸/烘烤淀粉) | 2A | carcinogen | flag, g | 100 | true |
| pickled_vegetables | 传统腌菜 | 2B | carcinogen | flag, g | 50 | true |
| very_hot_beverage | 过烫饮品(>65°C) | 2A | carcinogen | flag, ml | 250 | true |
| bracken_fern | 蕨菜 | 2B | carcinogen | flag, g | 100 | true |
| high_mercury_fish | 高汞鱼类 | — | toxicant | flag, g | 100 | true |
| hijiki | 羊栖菜(无机砷) | 1 | carcinogen | flag, g | 50 | true |
| aspartame | 阿斯巴甜(超过 ADI 时警示) | 2B | carcinogen | flag, mg | 1 | true |

`risk`, `detect`, `examples`, `advice` and `sources` are served in meta. Render them verbatim.

`hazardsInfoOnly` (5): 呋喃 (Furan) 2B, 4-甲基咪唑 (4-MEI) 2B, 咖啡 3, 亚硝酸盐 (内源性亚硝化条件下) 2A, 稻米中的无机砷 1. `examples` and `why` are served.

### 9.4 DRI: `GET /api/v1/standards/dri`
```
{ lifeStages: { id, zh }[20],
  intake: { [nutrientKey]: { kind: "RDA" | "AI", values: (number|null)[20] } },        // 31 keys
  upper:  { [nutrientKey]: { appliesToTotal: bool, note?: string, values: (number|null)[20] } },   // 17 keys
  sodiumCdrr: number[20],
  proteinPerKg: number[20] }
```
`values[i]` corresponds to `lifeStages[i]`. `null` means not determined; the web shows `ND`.

Life-stage order (index: id, zh):
0 c1_3 儿童 1–3 岁 · 1 c4_8 儿童 4–8 岁 · 2 m9_13 男 9–13 岁 · 3 m14_18 男 14–18 岁 · 4 m19_30 男 19–30 岁 · 5 m31_50 男 31–50 岁 · 6 m51_70 男 51–70 岁 · 7 m71 男 >70 岁 · 8 f9_13 女 9–13 岁 · 9 f14_18 女 14–18 岁 · 10 f19_30 女 19–30 岁 · 11 f31_50 女 31–50 岁 · 12 f51_70 女 51–70 岁 · 13 f71 女 >70 岁 · 14 p14_18 孕期 ≤18 岁 · 15 p19_30 孕期 19–30 岁 · 16 p31_50 孕期 31–50 岁 · 17 l14_18 哺乳期 ≤18 岁 · 18 l19_30 哺乳期 19–30 岁 · 19 l31_50 哺乳期 31–50 岁

**INTAKE key order** (render rows in this order; Swift dictionaries lose it):
`protein_g, carb_g, fiber_g, linoleic_g, ala_g, water_g, vit_a_ug, vit_c_mg, vit_d_ug, vit_e_mg, vit_k_ug, thiamin_mg, riboflavin_mg, niacin_mg, vit_b6_mg, folate_ug, vit_b12_ug, pantothenic_mg, biotin_ug, choline_mg, calcium_mg, copper_mg, iodine_ug, iron_mg, magnesium_mg, manganese_mg, phosphorus_mg, selenium_ug, zinc_mg, potassium_mg, sodium_mg`
(water is in g, from L×1000).

**UPPER key order** (appliesToTotal T/F):
`vit_a_ug F, vit_c_mg T, vit_d_ug T, vit_e_mg F, niacin_mg F, vit_b6_mg T, folate_ug F, choline_mg T, calcium_mg T, copper_mg T, iodine_ug T, iron_mg T, magnesium_mg F, manganese_mg T, phosphorus_mg T, selenium_ug T, zinc_mg T`.

`note` is present on the F rows only:
- vit_a_ug: `UL 仅针对预制维生素 A（视黄醇），不含 β-胡萝卜素`
- vit_e_mg: `UL 仅针对补充剂/强化食品中的 α-生育酚`
- niacin_mg: `UL 仅针对补充剂/强化食品`
- folate_ug: `UL 仅针对合成叶酸（补充剂/强化食品）`
- magnesium_mg: `UL 仅针对补充剂/药物中的镁`

Web table rendering:
- Two segments, `RDA / AI 推荐量` and `UL 可耐受最高摄入量`.
- Row label = nutrient `zh`, followed by a muted `unit`, then ` · RDA` / ` · AI` (intake mode) or ` · 仅补充剂` (upper rows with appliesToTotal = false).
- Cells use up to 2 decimals.
- The intake mode appends two extra rows: `蛋白质 g/kg` (proteinPerKg) and `钠 CDRR mg（超过即应减少）` (sodiumCdrr).
- The first column is sticky.

### 9.5 MET table (`meta.activities`): 46 entries
Net kcal = (MET − 1) × kg × h. Intensity: MET ≥ 6 is vigorous (高强度), ≥ 3 is moderate (中等), else light (轻度).

| key | zh | MET | speedKmh |
|---|---|---|---|
| walk_slow | 散步 (约 4 km/h) | 3.0 | 4 |
| walk_moderate | 步行 (约 5 km/h) | 3.8 | 5 |
| walk_brisk | 快走 (约 6 km/h) | 4.8 | 6 |
| walk_very_brisk | 疾走 (约 6.8 km/h) | 5.5 | 6.8 |
| hiking | 徒步/爬山 | 6.0 | 4 |
| stairs | 爬楼梯 | 6.8 | — |
| jogging | 慢跑 | 7.5 | 8 |
| run_10kmh | 跑步 (约 10 km/h) | 9.3 | 10 |
| run_13kmh | 跑步 (约 13 km/h) | 12.0 | 12.9 |
| run_16kmh | 跑步 (约 16 km/h) | 14.8 | 16.1 |
| cycle_leisure | 骑行 (休闲 17–19 km/h) | 6.8 | 18 |
| cycle_moderate | 骑行 (中速 19–22 km/h) | 8.0 | 21 |
| cycle_vigorous | 骑行 (快速 22–26 km/h) | 10.0 | 24 |
| cycle_stationary | 动感单车/固定自行车 | 6.8 | — |
| swim_leisure | 游泳 (休闲，不计圈) | 6.0 | 1.8 |
| swim_freestyle_slow | 自由泳 (慢速) | 5.8 | 2.1 |
| swim_freestyle_medium | 自由泳 (中速 ~46 m/min) | 8.0 | 2.75 |
| swim_freestyle_fast | 自由泳 (快速 ~69 m/min) | 10.5 | 4.1 |
| swim_breaststroke | 蛙泳 (休闲) | 5.3 | 2.0 |
| swim_breaststroke_training | 蛙泳 (训练) | 10.3 | 3.0 |
| swim_backstroke | 仰泳 (休闲) | 4.8 | 1.9 |
| swim_butterfly | 蝶泳 | 13.8 | 3.2 |
| swim_open_water | 公开水域游泳 | 10.5 | 3.0 |
| jump_rope | 跳绳 (中速) | 11.8 | — |
| basketball | 篮球 (比赛) | 8.0 | — |
| soccer | 足球 (休闲) | 7.0 | — |
| soccer_competitive | 足球 (比赛) | 9.5 | — |
| badminton | 羽毛球 (休闲) | 5.5 | — |
| badminton_competitive | 羽毛球 (比赛) | 7.0 | — |
| tennis_singles | 网球单打 | 8.0 | — |
| table_tennis | 乒乓球 | 4.0 | — |
| yoga | 瑜伽 (哈他) | 2.3 | — |
| pilates | 普拉提 | 3.0 | — |
| strength_moderate | 力量训练 (中等) | 3.5 | — |
| strength_vigorous | 力量训练 (大强度) | 6.0 | — |
| circuit | 循环训练 | 5.0 | — |
| hiit | HIIT 高强度间歇 | 7.0 | — |
| hiit_vigorous | HIIT (极高强度) | 11.0 | — |
| elliptical | 椭圆机 | 5.0 | — |
| rowing_machine | 划船机 (中等) | 5.0 | — |
| aerobic_dance | 有氧操/健身舞 | 7.3 | — |
| dance_social | 跳舞 (广场舞/社交舞) | 4.8 | — |
| housework | 家务 (打扫) | 3.3 | — |
| other_light | 其他轻度活动 | 2.5 | — |
| other_moderate | 其他中等强度活动 | 4.5 | — |
| other_vigorous | 其他高强度活动 | 7.5 | — |

Keys that count as **strength** days: any key containing `strength`, `circuit` or `hiit`. This matters for mapping HealthKit `HKWorkoutActivityType` to `activity_key`. For example, `traditionalStrengthTraining` / `functionalStrengthTraining` map to `strength_*`, and `highIntensityIntervalTraining` maps to `hiit`.

### 9.6 HEI-2020 components (`meta.hei`): 13, order
| key | zh | en | max | kind | best | worst | unit | hint |
|---|---|---|---|---|---|---|---|---|
| total_fruits | 水果总量 | Total Fruits | 5 | adequacy | 0.8 | 0 | 杯当量/1000kcal | 每天吃水果（含果汁） |
| whole_fruits | 完整水果 | Whole Fruits | 5 | adequacy | 0.4 | 0 | 杯当量/1000kcal | 优先吃整个水果而不是果汁 |
| total_vegetables | 蔬菜总量 | Total Vegetables | 5 | adequacy | 1.1 | 0 | 杯当量/1000kcal | 每餐都有蔬菜 |
| greens_beans | 深绿色蔬菜与豆类 | Greens and Beans | 5 | adequacy | 0.2 | 0 | 杯当量/1000kcal | 菠菜、西兰花、豆类 |
| whole_grains | 全谷物 | Whole Grains | 10 | adequacy | 1.5 | 0 | 盎司当量/1000kcal | 糙米、燕麦、全麦替代部分白米白面 |
| dairy | 奶制品 | Dairy | 10 | adequacy | 1.3 | 0 | 杯当量/1000kcal | 牛奶、酸奶、奶酪或强化豆奶 |
| total_protein | 蛋白质食物 | Total Protein Foods | 5 | adequacy | 2.5 | 0 | 盎司当量/1000kcal | 肉蛋鱼禽豆坚果 |
| seafood_plant_protein | 海产与植物蛋白 | Seafood and Plant Proteins | 5 | adequacy | 0.8 | 0 | 盎司当量/1000kcal | 鱼虾、豆腐、坚果 |
| fatty_acids | 脂肪酸比例 | Fatty Acids | 10 | adequacy | 2.5 | 1.2 | (PUFA+MUFA)/SFA | 植物油、坚果、鱼替代动物脂肪 |
| refined_grains | 精制谷物 | Refined Grains | 10 | moderation | 1.8 | 4.3 | 盎司当量/1000kcal | 减少白米白面 |
| sodium | 钠 | Sodium | 10 | moderation | 1.1 | 2.0 | g/1000kcal | 少盐少酱油 |
| added_sugars | 添加糖 | Added Sugars | 10 | moderation | 6.5 | 26 | % 能量 | 少喝含糖饮料、少吃甜点 |
| saturated_fats | 饱和脂肪 | Saturated Fats | 10 | moderation | 8 | 16 | % 能量 | 少肥肉、黄油、椰子油、奶油 |

Scoring is linear between `worst` (0 points) and `best` (max points). Legumes count toward vegetables, greens & beans, total protein (×4 oz) and seafood & plant protein. If SFA = 0, the fatty-acid ratio is 2.5. HEI needs ≥ 200 kcal.

### 9.7 Sources (`meta.sources`): 36 ids
`nasem_dri, nasem_na_k, nasem_energy, dga_2020, dga_2025, hei_2020, fda_dv, aha_sugar, aha_sodium, aha_satfat, who_trans, fda_caffeine, acog_caffeine, hc_caffeine, niaaa_drink, iarc_list, iarc_114, iarc_qa_meat, wcrf, iarc_hot_bev, iarc_aspartame, fda_fish, fda_acrylamide, nci_hca_pah, pag_2018, compendium_2024, mifflin, nova, cdc_weight, nhlbi_bmi, hei_us_mean, mar, le8, mepa, wcrf_score, system`

`system` = org `本系统`, title `本系统设定的阈值（无权威数值时的保守折中，已在规则中注明）`, url `""`.

Web `SourceLinks` renders ``依据：{org}、{org}…``, linking `org` to `url` when the url is non-empty. Unknown ids are skipped.

### 9.8 Other meta enums
- `activityLevels`: inactive 久坐 (PAL 1.4), low_active 轻度活动 (1.6), active 活跃 (1.75), very_active 非常活跃 (2.05). `desc` is served.
- `conditions`: hypertension 高血压, high_ldl 高胆固醇 / 高 LDL, diabetes 糖尿病 / 糖尿病前期, kidney 慢性肾病, gout 痛风 / 高尿酸. `effect` is served.

### 9.9 Scoring-rules text is **not** served by any endpoint
The web "评分规则" tab hardcodes these texts (`web/src/pages/Standards.tsx`). The iOS app must embed them verbatim (or see proposal P2 in section 16).

Banner:
> 评分规则 v2：各分项全部采用已发表、经同行评议的评分体系。“美国心脏协会 LE8”“WCRF/AICR”“MAR”都是等权合成；HEI-2020 的组分分值由 USDA 规定。
> 总分（满分 100）是本站按自定权重把分项合成的一个数字，没有权威出处：每天 = HEI × 50% + MAR × 15% + 能量平衡 × 15% + 身体活动 × 20%；每周 = 周期 HEI × 40% + MAR 日均 × 10% + LE8 × 35% + WCRF（折算百分制）× 15%。缺少的分项不计入，其余按权重折算。

Card **每日：膳食质量 HEI-2020 + 微量营养素 MAR** (key/value list):
- 今日膳食质量: `HEI-2020 总分（USDA / NCI）。13 个组分按每 1000 kcal 的密度在“零分标准”与“满分标准”之间线性计分，分值见“HEI-2020”标签页。例如钠 ≤1.1 g/1000 kcal 得 10 分，≥2.0 g 得 0 分，页面会写明“钠组分扣 x 分”。美国人平均 {heiUsMean} 分（NHANES 2017–2018）。`
- 微量营养素 MAR: `平均充足比（Madden & Yoder 1972；FAO 最低膳食多样性验证研究采用的 11 种微量营养素：{marNutrients zh joined 、}）。每种 NAR = min(摄入 ÷ RDA, 1)，等权平均 × 100。注：IOM 指出按 RDA 判断个人单日摄入只是粗略参考。`
- 其他检查项: `其余营养素对照 RDA/AI；钠（CDRR 2300 mg / AHA 1500 mg）、添加糖、饱和脂肪、反式脂肪、酒精、咖啡因、超加工食品、每餐添加糖、AMDR、UL；能量平衡。这些只标“达标 / 偏离 / 不达标”并写明超出多少，不另设权重。`
- 致癌物与风险物: `按 IARC 分级给出警示与剂量，不另设扣分；加工肉、红肉、酒精、含糖饮料在 WCRF/AICR 评分中计分。`

Card **综合：美国心脏协会 Life's Essential 8（LE8）**:
- Intro: `Lloyd-Jones DM et al., Circulation 2022。8 项各 0–100 分，总分 = 已有指标的等权平均（缺失指标不计入分母，按官方补充材料）；80–100 高，50–79 中，0–49 低。今日页显示近 7 天，周报 / 月报显示整个周期。`
- Table rows:
  - 饮食 | 个人用 MEPA 16 题问卷：15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0（本站由饮食记录自动推算每周份数）
  - 身体活动（分钟/周，高强度 ×2） | ≥150 → 100；120–149 → 90；90–119 → 80；60–89 → 60；30–59 → 40；1–29 → 20；0 → 0
  - 尼古丁暴露 | 从不 100；戒 ≥5 年 75；戒 1–5 年 50；戒 <1 年或电子烟 25；吸烟 0；家中有人室内吸烟 −20
  - 睡眠（小时/晚） | 7–<9 → 100；9–<10 → 90；6–<7 → 70；5–<6 或 ≥10 → 40；4–<5 → 20；<4 → 0
  - BMI | <25 → 100；25–29.9 → 70；30–34.9 → 30；35–39.9 → 15；≥40 → 0
  - 非 HDL 胆固醇（mg/dL） | <130 → 100；130–159 → 60；160–189 → 40；190–219 → 20；≥220 → 0；服药 −20
  - 血糖 | 无糖尿病：空腹 <100 或 HbA1c <5.7 → 100；100–125 或 5.7–6.4 → 60；糖尿病：HbA1c <7 → 40，7–7.9 → 30，8–8.9 → 20，9–9.9 → 10，≥10 → 0
  - 血压（mmHg） | <120/<80 → 100；120–129/<80 → 75；130–139 或 80–89 → 50；140–159 或 90–99 → 25；≥160 或 ≥100 → 0；服药 −20

Card **防癌：2018 WCRF/AICR 标准化评分**:
- Intro: `Shams-White MM et al., Nutrients 2019。7 条建议各 1 分、等权，子项平分该条的 1 分（母乳喂养为可选项，不计）。`
- Table rows:
  - 保持健康体重 | BMI 18.5–24.9 → 0.5，25–29.9 → 0.25；腰围 男 <94 / 女 <80 cm → 0.5，男 94–101.9 / 女 80–87.9 → 0.25（只有一项时分数加倍）
  - 积极运动 | 中高强度 ≥150 分钟/周 → 1；75–149 → 0.5；<75 → 0
  - 多吃全谷物、蔬菜、水果、豆类 | 果蔬 ≥400 g/天 → 0.5（200–399 → 0.25）；膳食纤维 ≥30 g/天 → 0.5（15–29 → 0.25）
  - 少吃快餐和加工食品 | 原文按研究人群内超加工供能比的三分位数评分，没有绝对切点 —— 本站只展示、不计分
  - 限制红肉和加工肉 | 红肉 ≤500 g/周且加工肉 <21 g/周 → 1；加工肉 21–99 g/周 → 0.5；红肉 >500 或加工肉 ≥100 → 0
  - 限制含糖饮料 | 0 → 1；≤250 ml/天 → 0.5；>250 → 0
  - 限制饮酒 | 不饮酒 → 1；男 ≤28 / 女 ≤14 g 纯酒精/天 → 0.5；以上 → 0

Card **能量与体重**:
> 能量需求：NASEM 2023 EER 方程（19 岁以上）；基础代谢：Mifflin-St Jeor。有设备数据时，消耗 = (静息 + 活动能量 + 未被设备记录的运动) ÷ 0.9；运动净消耗 = (MET − 1) × 体重 × 小时（2024 Compendium）。体重趋势用指数移动平均（α = 0.1）；“反推日消耗” = 日均摄入 − 趋势体重变化 × 7700 ÷ 天数。能量平衡只标状态，体重结果体现在 LE8 的 BMI 与 WCRF 的健康体重中。

---

## 10. `GET /api/v1/trends`: daily series

### 10.1 Request
| query | type | default | notes |
|---|---|---|---|
| `start` | `YYYY-MM-DD` | `end − 29` | invalid values are silently replaced by the default |
| `end` | `YYYY-MM-DD` | today (owner's TZ) | |
| `user` | string | — | section 1 (`full` is ignored) |

- `start > end` returns 400.
- If the span is > 1100 days, `start` is silently moved to `end − 1100` (max 1101 days).
- **There are no `ranges` / `metrics` / `nutrient` parameters.** Every day carries every metric. Range presets, bucketing and metric selection are all **client-side** (section 10.3).
- Side effect: computes and caches the DailyScore for every day in range. A first call over ~3 years is slow.
- Payload is roughly 3 KB per day, so "全部" (~1100 days) is about **3 MB uncompressed**. The server has no gzip middleware. Cache on device.

### 10.2 Response
```
{ start: string, end: string, days: TrendDay[] }   // one entry per calendar day, ascending
TrendDay {
  date: string
  hasData: bool
  score: number|null          // HEI-2020 total, 1 dp
  total: number|null          // daily composite total, 1 dp
  categories: { hei?: number, mar?: number }   // 1 dp; keys present only when available; {} when no data
  hazardCount: int            // # hazards that day, excluding red_meat with dose < 72 g (aspartame within ADI IS counted)
  hei: number|null            // = score (HEI total, 1 dp)
  mar: number|null            // MAR value, 1 dp
  intake: number              // kcal, integer-rounded
  tdee: number                // kcal, integer-rounded (always computed)
  target: number              // kcal, integer-rounded
  exerciseKcal: number        // integer-rounded
  energyMethod: "measured" | "eer"
  weight: number|null         // last weigh-in of that date (kg), unrounded
  trend: number|null          // EMA trend weight, 2 dp (warmed with 60 days before start)
  steps: number|null          // activity_days.steps
  activeKcal: number|null     // activity_days.active_kcal
  completeness: "none" | "partial" | "likely"
  totals: { [43 nutrient keys]: number }   // 2 dp
  groups: { [22 food-group keys]: number } // 2 dp
  macroPct: { protein, carb, fat, satFat, addedSugar, alcohol }   // 1 dp
  upfPct: number              // 1 dp
  statuses: { [scoreItemKey]: Status }     // every ScoreItem except status "info"; {} when no data
}
```
`statuses` keys follow section 3.4: `hei_*`, nutrient keys, `water_g`, `sodium_mg`, `added_sugars_g`, `sat_fat_pct`, `trans_fat_g`, `alcohol_g`, `caffeine_mg`, `upf_pct`, `added_sugars_per_meal`, `amdr_*`, `ul_*`, `energy_balance`.

### 10.3 Client-side behaviour to replicate (web `Trends.tsx`)
- **Range presets** (Seg): `7 天`, `30 天` (default), `90 天`, `今年`, `一年`, `全部`, `自定义`.
  - 7/30/90/365: `start = today − (N−1)`, `end = today`.
  - 今年: `start = YYYY-01-01`.
  - 全部: `start = today − 1095`; afterwards, drop the leading days before the first day with `hasData || weight != null`.
  - 自定义: two date pickers. Default is the last 60 days (`today − 59 … today`), `end ≤ today`, `start ≤ end`. Separator text: `至`.
- The same screen also calls `GET /period?start=…&end=…`. If the span is > 400 days it uses `start = end − 400`. That response feeds the summary tiles, LE8/WCRF cards, pass rates, periodic checks and the hazard table.
- When viewing your own data it also calls `GET /profile/targets` to draw target lines. It skips this when viewing others.
- **Bucketing**:
  - Span ≤ 92 days: per **day**; label `M/D`.
  - Span ≤ 400 days: per **week** (Monday key); label `M/D` of the Monday.
  - Otherwise: per **month**; label ``{YY}/{M}月``.
  - Subtitle: ``{start} 至 {end} · {每日|每周平均|每月平均}``.
- Averages per bucket:
  - Score/intake/categories/nutrients: mean over **logged** days of the bucket.
  - tdee/target: mean over all days.
  - Weight: mean of non-null weights; trend: last non-null trend in the bucket.
  - Steps: mean over days with non-null steps.
  - Values are rounded to 1 dp for charts.
- **Charts and cards**:
  1. Summary tiles:
     - `区间总分`: period.total.score `/ 100`; delta ``LE8 {period.score} · HEI 日均 {avg} · {logged}/{n} 天有记录``.
     - `日均摄入 / 消耗`: ``{avg intake} / {avg tdee} kcal``.
     - `趋势体重变化`: actualChangeKg (signed, 1 dp, `kg`); delta ``能量差预测 {±predictedChangeKg 1dp} kg``.
     - `按实际数据反推的日消耗`: empiricalTdee; delta ``公式估算 {avgTdee}``, or `需 ≥14 天体重与较完整的记录`.
  2. `膳食质量 HEI-2020`, hint `USDA 健康饮食指数，0–100；虚线为美国人平均 58 分`.
     - Series `日评分` (or `平均评分` when bucketed) and `7 日均值` (day view only, rolling mean of the last 7 buckets).
     - Dashed reference line `美国平均 58`. y axis 0–100. Tooltip shows `无记录` for null.
  3. `摄入 vs 消耗`, hint `消耗 = 静息代谢 + 活动（设备/步数/运动）+ 食物热效应`. Series `摄入`, `消耗`, `目标` (dashed). Unit kcal.
  4. `体重`: scatter `称重` (`平均称重` when bucketed) and line `趋势（平滑）`.
     - Hint: ``趋势每周 {±ratePerWeek 2dp} kg（EMA 平滑，过滤每日水分波动）`` or `建议每晚睡前固定时间称重`.
     - Empty state: `这段时间没有体重记录`.
  5. `膳食质量与营养素充足`, hint `HEI-2020 与 MAR（11 种微量营养素平均充足比），均为 0–100`. Series `HEI-2020`, `微量营养素 MAR`.
  6. ``营养素追踪：{zh}`` (bar chart). Hint ``{每日|每周日均|每月日均}（仅计有记录的天）；横线为你的个人目标/上限``.
     - Picker groups: `营养素` (all 43 meta nutrients, ``{zh}（{unit}）``) and `其他指标`:

       | key | zh | unit | value source |
       |---|---|---|---|
       | macro:satFat | 饱和脂肪供能比 | % | `macroPct.satFat` |
       | macro:addedSugar | 添加糖供能比 | % | `macroPct.addedSugar` |
       | macro:protein | 蛋白质供能比 | % | `macroPct.protein` |
       | upf | 超加工食品供能比 | % | `upfPct` |
       | group:processed_meat_g | 加工肉 | g | `groups.processed_meat_g` |
       | group:red_meat_g | 红肉 | g | `groups.red_meat_g` |
       | group:veg_total_cup | 蔬菜 | 杯当量 | `groups.veg_total_cup` |
       | group:fruit_total_cup | 水果 | 杯当量 | `groups.fruit_total_cup` |
       | group:grains_whole_oz | 全谷物 | 盎司当量 | `groups.grains_whole_oz` |
       | hei | HEI-2020 分数 | 分 | `hei` |
       | steps | 步数 | 步 | `steps` (averaged over days with steps) |
       | hazard | 风险物警示数 | 项 | `hazardCount` |
       | mar | 微量营养素 MAR | 分 | `mar` |

     - Default metric: `sodium_mg`.
     - Reference lines from `/profile/targets`:
       - If `targets.limits[key]` exists (`macro:satFat` maps to `sat_fat_pct`, `upf` to `upf_pct`): ``上限 {limit 1dp}`` (red), and ``理想 {ideal 1dp}`` (green) when ideal > 0 and ≠ limit.
       - Else if `targets.intake[key]` exists: ``{RDA|AI} {value 1dp}`` (green).
       - `energy_kcal` adds ``目标 {energyTarget}``.
       - `group:red_meat_g` adds `日均建议 ≤70` (red).
     - Tooltip shows `无记录` for empty buckets.
  7. `每日评分日历` (only if span ≥ 45 days): a heatmap of the **HEI score** per day for the last 3 years in range.
     - Legend: `≥85 优秀`, `70–85 良好`, `55–70 一般`, `<55 较差`. Weeks start Monday.
  8. LE8 card and WCRF card from `period.indices`, subtitle ``{period.start} 至 {period.end}``.
  9. `各项达标天数`, hint ``按未达标比例排序（{start} 至 {end}）``.
     - Uses `period.itemStats` excluding category `hei`, sorted by (bad+warn)/days desc, top 18.
     - Stacked bar: good+ok `达标` / warn `偏离` / bad `不达标`, with ``{good}/{days}`` on the right.
     - Accessibility text: ``{zh}：达标 {g} 天，偏离 {w} 天，不达标 {b} 天``.
  10. `周期性指标`, hint `只在按周/月看才有意义的标准`: `period.checks` with status badge, zh, message, ``目标：{targetText}``.
  11. `风险物暴露汇总`, hint `只作警示，不另设扣分`. Columns `项目 / 分级 / 出现天数 / 累计量`. Shown only if `period.hazards` is non-empty.
- Every chart card has a toggle `表格` / `图表` to show the same data as a table; the first column header is `日期`. Null cells display `—`.

---

## 11. `GET /api/v1/users`: community list

No params. Returns **all** users (ordered by id), including users without a profile:
```
CommunityUser {
  id: int, username: string, display_name: string, avatar_color: string ("#rrggbb"),
  is_me: bool,
  shared_with_me: bool,                         // viewer may see at least the summary
  share_detail: "full" | "summary" | "none",    // effective access for the viewer (NOT the owner's raw setting)
  last_log_date: string|null,                   // MAX(meals.date) incl. water-only entries; null if not shared
  streak: int,                                  // 0–14, consecutive logged days ending today (owner's TZ); today being empty does not break it
  recent: { date: string, score: number|null }[] // 14 days today−13…today, score = HEI rounded to integer; [] if not shared or no profile
}
```
- Cost: computes 14 days of scores for every user who shares with you (cached thereafter).

Web rendering:
- Grid of cards: avatar (first character of `display_name`, uppercased, on `avatar_color`), name, the chip `我` if `is_me`, and ``@{username}``.
- If `shared_with_me`:
  - Header `近 14 天膳食质量（HEI-2020）` with ``均分 {avg of non-null}``.
  - A 14-bar sparkline (height = max(6, score)%; empty bar for null; tooltip ``{date}：{score|无记录}``).
  - ``连续记录 {streak} 天``, ``最近记录 {last_log_date|—}``.
  - Chip: `这是你` / `共享了完整记录` / `只共享评分摘要`.
  - Tapping opens that user's day view (`/day/{today}?user=<username>`), or your own Today screen if `is_me`.
- If not shared: lock icon plus `未向你共享每日数据`. The card is not tappable.
- Page title `社区`. Subtitle: `所有成员都能看到彼此的用户名；每日数据是否共享、共享给谁、共享多少由每个人自己决定（我的分享设置）`. "我的分享设置" links to Settings → share settings (`PUT /settings` with `share_mode`, `share_detail`, `share_with`, covered in the account spec).

---

## 12. Docs endpoints (`routes/docs.ts`), no auth
- `GET /api/v1/openapi.json` returns the OpenAPI 3.1 JSON. `servers` = `<protocol>://<host>/api/v1` and `/api`.
- `GET /api/v1/docs` returns a Swagger UI HTML page.

These are developer-only and not for the app UI. The OpenAPI schemas for this domain are incomplete (section 15), so use this document instead.

---

## 13. Background jobs (`services/scheduler.ts`)
- Enabled unless `SCHEDULER=false`. The first tick runs 20 s after boot, then every **15 min**. Ticks never overlap.
- For each user with a profile, using that user's timezone "today":
  1. Compute and cache yesterday's DailyScore.
  2. **Weekly report** for last week (Monday…Sunday before the current week). It is generated if no `reports` row exists for (user, `week`, start) **and** the user logged meals on ≥ **3** distinct dates in that week.
  3. **Monthly report** for last calendar month. Same rule with ≥ **10** distinct dates and kind `month`.
  4. Generation = `generateAndStoreSummary`, which calls the AI and upserts `reports`. It runs only if `WEEKLY_AI_SUMMARY != false`. Failures are logged and retried on the next tick (no row was written).
- If the AI provider is `mock`, a row is written with `ai_summary = NULL` and is not regenerated, unless later data edits on/after its end date delete it.
- "Logged" here counts any `meals` row, including water-only entries.
- For iOS: there is **no push** when a report is ready. Show the latest week/month by calling `GET /period` for those ranges; `aiSummary` appears once generated. A local notification on Monday morning is optional and client-side.

---

## 14. Caching and invalidation (`services/userdata.ts`): what the app should know
- `daily_scores` caches the full `DailyScore` JSON per (user, date, version 3). Any GET computes the missing days and stores them.
- Writes elsewhere invalidate the cache:
  - Meal create/edit/delete and water: that day only.
  - Weight / body / BP changes and some activity commits: `invalidateFrom(date)`, which clears all days ≥ date and unsummarised report rows.
  - Activity day edits / exercises: that day.
  - Profile change: everything.
- **After uploading HealthKit data** (activity, workouts, weight, BP, sleep; see the body/activity spec), re-fetch `/day`, `/trends` and `/period`. They are always consistent with the DB, and there is no client-side score computation.
- How HealthKit inputs drive these outputs (keep uploads faithful):
  - `active_kcal` > 0 makes `energy.method = "measured"` with `activeSource = "device"`.
  - `resting_kcal` > 500 replaces BMR.
  - `steps` drives the composite activity part (8000 = full), the `steps_avg` check and step-based energy when there is no `active_kcal`.
  - `exercise_min` feeds LE8 activity, WCRF activity, composite minutes and `activity_week`.
  - `sleep_hours` (> 0) feeds LE8 sleep (window mean).
  - Workouts with `in_device = 1` are not added on top of device active energy, but they still count for minutes, strength days and `exerciseKcal`.
  - Weight affects BMI (LE8, WCRF), targets, EMA trend and empirical TDEE. Waist (≤ 180 days old) affects WCRF weight.
  - BP: last 3 readings within 90 days. Lab values: latest.

---

## 15. Gaps between live OpenAPI and real responses
- `/day/{date}`: OpenAPI omits `full`. `DailyScore` there lists only `score` and `total`. The real object is section 3, including `version`.
- `/trends`: `days` items have no schema in OpenAPI. The real shape is section 10.2.
- `/period`: OpenAPI omits `aiSummary`, `full` and all PeriodScore fields except `score` and `total`.
- `/reports`, `/standards/meta`, `/standards/dri`, `Targets`: empty object schemas in OpenAPI.
- `/users`: OpenAPI omits `avatar_color`, `is_me`, `share_detail`, `last_log_date`, `streak`.
- `HealthIndices.wcrf.score` is typed nullable in OpenAPI but is always a number.
- OpenAPI `Exercise`/`BodyMetric` omit `user_id`, `created_at`, `note`, `bp_treated`, `avg_hr`, `device_kcal`.
- The web TS types also omit `DailyScore.version`, period `hei.components[].best/worst`, and `amdr.n6/n3`. Those are extra fields; decoding must tolerate unknown keys.

---

## 16. Optional additive server changes (proposals only; none exist today)
Each of these is purely additive and does not change the web UI.
- **P1, photos for shared viewers:** let `GET /uploads/{id}?user=<owner>` serve the owner's file when the viewer has `full` access. Today it always 404s for other users.
- **P2, `GET /standards/rules`:** return the LE8/WCRF/composite rule tables of section 9.9 as JSON, so the app does not hardcode them. The web can keep its hardcoded copy.
- **P3, ordered DRI/targets arrays:** e.g. `GET /standards/dri?format=rows` returning `[{key, kind, values}]`, which avoids dictionary-order issues.
- **P4, a lighter `/trends`:** e.g. `?fields=core` to drop `totals`/`groups`/`statuses` (or `?keys=sodium_mg,…`), plus gzip compression. This cuts the ~3 MB "全部" payload.
- **P5, OpenAPI completeness:** fill in the schemas listed in section 15 (documentation-only).
- **P6, AI gate:** `POST /period/summary` could return 400 when the provider is `mock`, to avoid erasing a stored summary with NULL. This is a behaviour change, so coordinate it with the web.

---

## 17. Chinese UI strings used by these web screens (reuse verbatim)

### 17.1 Global / navigation
- Brand `食迹` / `NUTRILOG`.
- Nav: `今日`, `趋势`, `报告`, `身体与运动`, `食物库`, `社区`, `标准库`, `设置`. Mobile bottom bar: `今日`, `趋势`, (+), `身体`, `更多`. Primary action `记一餐`.
- Loading `加载中…`. Modal close `关闭`. Date nav accessibility labels `前一天` / `后一天`.
- Date label: ``{M}月{D}日 {周日|周一|周二|周三|周四|周五|周六}``, prefixed with `今天 · ` or `昨天 · ` when applicable.
- Status labels in section 0.8.
- IARC chip: ``IARC {g} 类``, `非致癌` for `—`, `IARC 3 类` for "3".
- `依据：` before source links.
- Generic request error ``请求失败（{status}）``. Job errors `已取消`, `AI 任务失败`.
- Number display: `zh-CN` grouping, `—` for null.

### 17.2 Today / day view (`/day`)
- Title `今日概览`, sub `每一项都对照美国权威标准实时评估`.
- Other user: title ``@{username} 的记录``, sub `只读视图（对方开启了共享）`, button `看趋势`.
- Score card:
  - Title `今日总分`, hint `四项按权重合成 · 评分依据` (links to Standards → 评分规则). Ring sub-label `满分 100` / `暂无记录`.
  - Meter `HEI-2020 膳食质量 … / 100`, foot `13 个组分按每 1000 kcal 的密度计分，分值由 USDA 规定；美国人平均 58`.
  - Meter `微量营养素充足 MAR … / 100`, foot ``11 种微量营养素达到 RDA 的平均比例（每种封顶 100%，等权）；最缺：{2 lowest NAR zh joined 、}``.
  - ``{n} 项致癌/风险物警示（见下方）``.
  - Empty text: `记录饮食后，这里显示 USDA 的 HEI-2020 膳食质量分和 11 种微量营养素的充足度（MAR）。`
  - Score-ring colors: ≥70 good, ≥55 warning, ≥40 serious, else critical.
  - Meter status: HEI ≥80 good / ≥51 warn / else bad. MAR ≥90 / ≥70.
- Energy card:
  - Title `能量平衡`. Hint: if `method == "eer"`, ``无活动数据，按 {targets.eerMethod} 估算``. Otherwise ``静息 {来自设备|按 BMR} · 活动：{手机/手表活动能量|按步数估算|手动记录的运动|无活动数据}``.
  - Stats `摄入`, `消耗`, `差额` (delta ``≈ {±bal/7700×1000} g 体重``), `体重` (value = weighedToday, else targets.weightKg; delta ``趋势 {weightTrend 1dp} kg``, plus `（今日未称重）` if no weigh-in).
  - Bars `摄入` / `消耗` / `目标`.
  - Foot: ``目标 = 当日消耗 {− X（减重目标）| + X（增重目标）|（维持体重）}，不低于 {energyFloor} kcal · BMR {bmr} · EER {eer}``.
  - Macro section `宏量营养素供能比`, ``可接受范围：蛋白 {lo–hi}% · 碳水 {lo–hi}% · 脂肪 {lo–hi}%``. Legend `蛋白质 X%`, `碳水 X%`, `脂肪 X%`, `酒精 X%` (only if > 0.5%).
- Highlights: `今日要点`, hint `风险警示、超标项、HEI 扣分最多的组分`, empty `暂无`.
- Key metrics: `关键指标`, hint `竖线 = 理想值 / 上限`. Meters:
  - 钠: foot ``≈ 食盐 {g} g · 上限 {limit} mg，理想 ≤ {ideal} mg``; marks `理想`/`上限`.
  - 添加糖: foot ``上限 {limit} g，AHA 建议 ≤ {ideal} g；DGA 2025：每餐 ≤ 10 g``; marks `AHA`/`上限`.
  - 饱和脂肪供能比: foot ``{g} g · 上限 10% 能量``.
  - 膳食纤维: mark `AI`, foot ``目标 ≥ {AI} g（14 g/1000 kcal）``.
  - 蛋白质: marks `RDA`, `1.2 g/kg`, `1.6 g/kg`; foot ``RDA {rdaG} g；DGA 2025–2030 建议 {low}–{high} g``.
  - 酒精 (if > 0): foot ``≈ {drinks} 标准杯；IARC 1 类致癌物，越少越好``.
  - 咖啡因 (if > 0): foot ``上限 {limit} mg``.
- Hazards: `致癌物与风险物警示`, hint `IARC 分级表示证据强度；加工肉、红肉、酒精、含糖饮料计入 WCRF 防癌评分`, ``来自：{foods}``, ``{risk}。建议：{advice}``.
- Meals card:
  - Title `饮食记录`, hint ``{mealCount} 餐 · {intake} kcal``.
  - Water row: ``饮水 {ml} ml · 总水分 {water_g} / {AI} g（含食物）``, buttons `+ 250 ml` and `−` (accessibility label `减少 250 毫升`).
  - Empty state `还没有记录。` with button `记录第一餐`; for other users `这一天没有记录`.
  - Delete confirm ``删除 {time} 的{餐次}？``, toast `已删除`. Item hazard icon label `含风险项`.
- Activity card:
  - Title `活动与身体`, buttons `填写` / `AI 识别截图`. Stats `步数`, `活动能量` kcal, `运动消耗` kcal, `睡眠` 小时.
  - Exercise row ``{description} {min} 分钟 · MET {met}`` and ``{kcal} kcal``, plus `（已含在设备数据中）` if in_device.
  - Body row ``{time} 称重`` and ``{kg} kg · 体脂 {x}% · 血压 {s}/{d}``.
  - Empty hint: `点“填写”直接录入今天的步数、活动能量、睡眠、体重；或点“AI 识别截图”上传苹果健康 / 手表截图，或者说一句“今天走了 8000 步，游泳 5km”。 也可以在 身体与运动 里设置 iPhone 快捷指令自动同步。` (for the iOS app, adapt the last sentence to Apple Health sync).
- Detail tabs `明细`: `全部营养素` / `HEI-2020` / `评分明细`.
  - Nutrient table headers `营养素 / 摄入 / 目标 / 完成度 / 状态`. Target texts: ``目标 {kcal}``, item `targetText`, ``≥ {v}（{RDA|AI}）``, `≤ 10% 能量`, ``标签 DV {dv}``, suffix `` · UL {v}``.
  - HEI tab: `HEI-2020 总分`, `美国农业部与国家癌症研究所的膳食质量指数，按每 1000 kcal 的密度评分；美国人平均约 58 分。`. Empty: `摄入能量不足 200 kcal，暂不计算 HEI。`.
  - Items tab sections:
    - `HEI-2020 膳食质量（USDA 官方分值）`: shows ``{points 1dp} / {maxPoints}`` and ``{hei.total} / 100``.
    - `MAR 计分的 11 种微量营养素（等权）`: ``MAR {value} / 100``.
    - `其他营养素（对照 RDA/AI，只标状态）`
    - `限量与其他标准（只标状态）`
    - `能量平衡（只标状态）`
    - Each row: status badge, `message`, ``标准：{targetText}`` + sources.

### 17.3 LE8 / MEPA / WCRF cards
- LE8:
  - Title `心血管健康 Life's Essential 8`, or `心血管健康 LE8` on reports. Subtitle ``美国心脏协会 2022 · 近 {windowDays} 天`` (reports: ``AHA Life's Essential 8 · {daysLogged}/{days} 天有记录``).
  - Ring label ``{高|中|低}（{available}/8 项）`` or `数据不足`. Component meters ``{points} / 100``, foot = `value`; on the diet row add the link `查看 16 题`. Missing rows: ``缺数据：{missing}``.
  - Footer: `总分 = 已有指标的等权平均（缺失指标不计入分母）；80–100 高，50–79 中，0–49 低。`
  - Meter status: ≥80 good, ≥50 warn, else bad.
- MEPA sheet:
  - Title ``MEPA 饮食问卷：{score}/16``.
  - Text: ``AHA Life's Essential 8 规定的个人饮食评分工具（Cerwinske 2017）。由你近 {days} 天的饮食记录自动推算每周 / 每天份数，每满足一题得 1 分。15–16 分 → 100，12–14 → 80，8–11 → 50，4–7 → 25，0–3 → 0。``
  - Columns `题目 / 标准 / 你的记录`. Badges `✓ 1 分` / `0 分`.
- WCRF:
  - Title `防癌建议 WCRF/AICR`. Subtitle ``2018 标准化评分 · 近 {windowDays} 天`` (or ``{start} 至 {end}``). Big number ``{score 2dp}/ {max}``.
  - Text: `7 条建议各 1 分、等权（Shams-White 2019）。“超加工食品”一条原文按研究人群三分位评分、没有绝对切点，此处只展示不计分。`
  - Rows: points, zh, detail, rule.

### 17.4 Reports (`/period`)
- Title `周期报告`. Sub: `总分由膳食质量、微量营养素、心血管健康 LE8 和防癌建议按权重合成；每周一自动生成上周报告，每月 1 日生成上月报告（含 AI 点评）`.
- Segment `周报` / `月报`. Defaults: week = **last** full week; month = current month. Prev/next labels `上一期` / `下一期`; next is disabled when `end ≥ today`.
- Period label: week ``{start} ~ {MM-DD of end}``; month ``{YYYY} 年 {M} 月``.
- Total tile `本周总分` / `本月总分` `/ 100`, plus the TotalParts line.
- Tiles:
  - `HEI-2020（按周期总摄入）` (delta `美国人平均 58`)
  - `HEI-2020 日均`
  - `微量营养素 MAR 日均`
  - `防癌建议 WCRF/AICR` ``{score 2dp}/ {max}``
- AI card:
  - Title `AI 点评`. Buttons `生成点评` / `重新生成`. Progress text `Claude 正在阅读本期评分数据并撰写点评…`.
  - Empty texts: `未配置 AI，无法生成点评。离线评分结果仍然完整可用。` (mock) / `点击“生成点评”，让 Claude 根据离线评分结果给出下期最值得改进的 3–5 件事。` / `这一期没有记录。`
  - Content: `headline`, `summary`, wins (check icons), issues (x icons), box `下期行动` with `actions`.
- `其他按周评估的指标` (hint `只标状态，不加权`): checks with ``目标：{targetText}``.
- `能量与体重` key/value list:
  - `日均摄入`, `日均消耗`
  - `累计能量差` ``{±} kcal（≈ {kg 2dp} kg）``
  - `趋势体重变化` (else `称重数据不足`)
  - `反推日消耗` (else `需 ≥14 天完整数据`)
- `日均关键营养`: `钠`, `添加糖`, `饱和脂肪`, `膳食纤维`, `蛋白质`, `钙 / 钾 / 维生素 D` (from avgTotals).
- `致癌物与风险物警示`, hint `只作警示；加工肉、红肉、酒精、含糖饮料已计入 WCRF 评分`. Chips ``{zh} IARC… {days} 天 · {dose} {unit}``.
- `HEI-2020 各组分（按周期总量计算）`: meters ``{score}/ {max}`` with the hint when not full.

### 17.5 Trends
Section 10.3. Title `健康趋势`, or ``@{username} 的健康趋势`` for another user.

### 17.6 Community
Section 11.

### 17.7 Standards (`标准库`)
- Sub: `本站离线评分使用的全部标准：美国 NASEM DRI、膳食指南 DGA 2020–2025 / 2025–2030、HEI-2020、FDA、AHA、IARC、WCRF、体力活动指南`.
- Tabs: `我的个性化目标`, `DRI 总表`, `致癌物与风险物`, `HEI-2020`, `运动 MET`, `评分规则`, `资料来源`.
- **我的个性化目标** (uses `/profile/targets` + meta):
  - Tiles:
    - `适用人群` = lifeStageZh, ``{age} 岁`` plus ` · 敏感人群`
    - `BMI` = bmiCategory.zh, plus `` · 按体重的目标使用校正体重 {kg} kg`` when the reference weight ≠ weight
    - `基础代谢 / 能量需求` ``{bmr}/ {eer} kcal`` with eerMethod
    - `每日能量目标（无活动数据时）` with ``含目标调整 {±}`` or `维持`
  - Table `推荐摄入量（下限，越接近越好）` (hint `RDA = 推荐膳食供给量；AI = 适宜摄入量`). Columns `营养素 / 目标 / 类型 / UL 上限`; a UL that does not apply to the total gets the suffix `*`.
    - Footnote: `* 该 UL 只针对补充剂/强化食品或特定形式（如预制维生素 A、合成叶酸），食物总量不参与 UL 评分。`
  - Table `限量标准（上限，越少越好）`. Columns `项目 / 理想 / 上限 / 依据`, rows in `targets.limits` order, plus:
    - `每餐添加糖 | 0 | {10} g | dga_2025`
    - `阿斯巴甜 ADI（按体重） | — | {adi} mg | iarc_aspartame`
  - `宏量营养素可接受范围（AMDR）`:
    - `蛋白质` ``{lo–hi}% 能量（RDA {g} g；DGA 2025–2030 建议 {lo}–{hi} g）``
    - `碳水化合物` ``{lo–hi}% 能量``
    - `脂肪` ``{lo–hi}% 能量``
- **DRI 总表**: section 9.4. Hint `来源：NASEM DRI 汇总表（钠/钾为 2019 版）`.
- **致癌物与风险物**:
  - Banner: `IARC 分级表示“证据强度”而不是“危险程度”：加工肉与吸烟同属 1 类，意味着致癌证据同样充分，而不是危害同样大。没有权威机构发布过把这些分级换算成扣分的方法，所以本站只按剂量给出警示、不另设扣分；其中加工肉、红肉、酒精、含糖饮料按 WCRF/AICR 标准化评分计分。`
  - Cards with `风险：`, `判定：`, `例：`, `建议：`.
  - Table `已知但不警示的项目`, columns `项目 / 分级 / 常见来源 / 原因`.
- **HEI-2020**:
  - Title `HEI-2020 组分与评分标准`, hint `满分 100；按每 1000 kcal 密度计算，两端之间线性插值`.
  - Columns `组分 / 类型 / 满分 / 满分标准 / 零分标准`. Type `充足（越多越好）` / `适度（越少越好）`.
  - Full-score column ``≥|≤ {best} {unit}``. Zero-score column: adequacy ``≤ {worst}`` or `0`; moderation ``≥ {worst}``.
  - Footnote: `豆类同时计入“蔬菜总量”“深绿色蔬菜与豆类”“蛋白质食物”“海产与植物蛋白”四个组分（HEI-2015 起的做法）。`
- **运动 MET**:
  - Title `运动代谢当量（2024 Adult Compendium）`, hint `净消耗 = (MET − 1) × 体重 × 小时，扣除静息部分避免与基础代谢重复`.
  - Columns `活动 / MET / 强度 / 典型速度` (``{v} km/h`` or `—`). Intensity `高强度`/`中等`/`轻度`.
- **评分规则**: section 9.9.
- **资料来源**: list of `year` chip, `title` (linked if url), `org`.
