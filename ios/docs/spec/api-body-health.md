# 食迹 NutriLog: Body, Activity and Health API spec (for the native iOS client)

Source of truth: `server/src/routes/body.ts`, `server/src/db/index.ts`, `server/src/auth.ts`, `server/src/lib/{http,dates}.ts`, `server/src/standards/{met,energy}.ts`, `server/src/services/userdata.ts`, `server/src/ai/{jobs,service,schema,prompts,mock}.ts`, `server/src/scoring/*`, `web/src/pages/Body.tsx`, `web/src/components/ActivityRecognizer.tsx`, `web/src/pages/Today.tsx`, `web/src/types.ts`.
The live spec (`openapi.live.json`) matches this source. Where the OpenAPI document and the code disagree, this file follows the code and marks the difference with **[spec gap]**.

Contents

1. Conventions (base URL, auth, errors, types, dates, coercion)
2. Database tables and the row shapes the API returns
3. Endpoints: body metrics, labs, daily activity, exercises
4. AI activity flow: `/uploads` → `/ai/activity` → `/ai/jobs/{id}` → `/preview` → `/activity/commit`
5. `/health/ingest` (iPhone Shortcut push)
6. `/health/import` (Apple Health export.zip / export.xml)
7. Related read endpoints (`/day/{date}`, `/trends`, `/standards/meta`)
8. How the server uses this data (energy model, LE8, WCRF, caches)
9. Standards tables: MET compendium, activity levels, BMR/EER, BMI
10. Nested response types (DailyScore, HealthIndices, …)
11. Chinese UI strings to reuse
12. **HealthKit direct sync design input**, including the proposed additive endpoints
13. Risks and surprises for a native client

---

## 1. Conventions

### 1.1 Base URL and prefixes
- Production: `http://45.63.23.52:8787`. It is plain HTTP with no TLS, so iOS ATS needs `NSAllowsArbitraryLoads`. ATS exception domains do not apply to bare IP addresses.
- Every route is mounted twice, at `/api/v1/...` and `/api/...`, with identical behavior. The app uses `/api/v1`.
- Unknown `/api/*` path: `404 {"error":"接口不存在"}` **only when authenticated**. Without valid auth an unknown path returns `401 未登录或令牌已失效`, because `logRouter`'s router-level `requireAuth` runs first (see `api-auth-account.md` §1.4).
- `GET /api/v1/health` → `{"ok": true, "version": "1"}` (no auth). This is the server liveness check. It is unrelated to Apple Health.

### 1.2 Authentication
| Middleware | Used by | Accepts |
|---|---|---|
| `requireAuth` | every endpoint in this file except `/health/ingest` | Cookie `nl_session=<token>`, **or** `Authorization: Bearer <token>` where token does **not** start with `nl_` (app tokens start with `nla_`) |
| `requireAuthOrToken` | `POST /health/ingest` only | everything `requireAuth` accepts, **plus** personal API token `Authorization: Bearer nl_...`, **or** query string `?token=nl_...` |

- App login: `POST /api/v1/auth/token` with body `{"username","password","device_name"?}` returns `{"token":"nla_…","expires_at":"<ISO>","user":{…}}`. The token is valid for 365 days (`APP_TOKEN_DAYS`). Each authenticated request updates `last_used_at`.
- **Cookie precedence trap:** the server evaluates `token = cookie ?? bearer`. If the request carries any `nl_session` cookie (for example one set by a `WKWebView` login and shared through `HTTPCookieStorage`), the server checks that cookie and **ignores the Bearer header**. A stale cookie therefore produces 401 even when the Bearer token is valid. The native client must not send cookies (`URLSessionConfiguration.httpShouldSetCookies = false`, `httpCookieStorage = nil`).
- 401 body: `{"error":"未登录或令牌已失效"}` from `requireAuth`, `{"error":"未登录或 Token 无效"}` from `requireAuthOrToken`.

### 1.3 Errors
Every error is HTTP status + JSON `{"error": "<Chinese message>"}`.

| Status | When | Message |
|---|---|---|
| 400 | validation (`bad()`) | specific, see per endpoint |
| 400 | malformed JSON body | `请求格式不正确` |
| 401 | not authenticated | see 1.2 |
| 404 | row not found / not owned | `不存在` (default) or `任务不存在` (jobs) |
| 413 | multipart file over limit | `文件太大` |
| 500 | anything else (including multer count errors) | `服务器内部错误` |

Numeric validation (`num()` helper). `<name>` is the Chinese field name given in the code, `数值` when none is given, or for `cleanActivity` the **English key** (for example `steps不能大于 200000`):
- missing (`undefined`/`null`/`""`) and required: `<name>不能为空`
- not finite after `Number(v)`: `<name>格式不正确`
- below min: `<name>不能小于 <min>`; above max: `<name>不能大于 <max>`

### 1.4 Types and coercion rules (important for Swift `Codable`)
- JSON bodies use `Content-Type: application/json`, 2 MB limit (`express.json({limit:"2mb"})`). `application/x-www-form-urlencoded` is also parsed.
- Numbers are parsed with JS `Number(v)`. Numeric strings such as `"68.2"` are accepted. `true` becomes `1`.
- **Booleans are evaluated for JS truthiness.** `true`, `1` and `"false"` (a non-empty string) all count as true. Send real JSON `true`/`false`.
- Strings go through `str()`: trimmed, then truncated to `max` (no error on overflow).
- Flags in **responses** are SQLite integers `0`/`1`, not JSON booleans: `bp_treated`, `in_device`, `lipid_treated`, `diabetes`.
- `steps` is an INTEGER column, but `/health/ingest` does not round, so a non-integral value (`8532.5`) is stored as REAL. **Decode `steps` as `Double`.**
- `created_at` / `updated_at` use the SQLite form `"YYYY-MM-DD HH:MM:SS"` in **UTC**, without a zone suffix.
- `id`s are integers. Job ids are UUID strings.

### 1.5 Dates and time zone
- Every `date` is the user's **local calendar date** `YYYY-MM-DD` in `profiles.timezone` (IANA, default `Asia/Shanghai`). Every `time` is local `HH:MM` (24 h, exactly 5 chars, `^\d{2}:\d{2}$`, no seconds).
- A date is valid when `/^\d{4}-\d{2}-\d{2}$/` matches and `Date.parse(date+"T00:00:00Z")` is not NaN. An invalid or omitted date **silently falls back to "today in the profile time zone"** on most write endpoints. Only `PUT /activity/{date}` returns an error.
- An omitted `time` falls back to "now" in the profile time zone (`nowTimeIn`), except where noted.
- Server "today": `GET /auth/me` → `today`. Use it as the default date instead of the device clock.

---

## 2. Tables and returned row shapes

Every list endpoint returns `SELECT *`, so `user_id` and `created_at` are included. Columns appear in migration order.

### 2.1 `body_metrics` (weight, body fat, waist, blood pressure)
| column | type | null | unit / meaning |
|---|---|---|---|
| id | int | no | PK |
| user_id | int | no | |
| date | text | no | local date |
| time | text | no | `HH:MM`, default `'22:00'` |
| weight_kg | real | yes | kg |
| body_fat_pct | real | yes | percent 0–100 (not a fraction) |
| waist_cm | real | yes | cm |
| note | text | yes | ≤200 chars |
| source | text | no | see enum below |
| created_at | text | no | UTC |
| sbp | real | yes | systolic mmHg |
| dbp | real | yes | diastolic mmHg |
| bp_treated | int 0/1 | no | 1 = taking antihypertensive medication |

`source` values written by the server: `manual` (POST /body, commit with source=manual), `profile` (first profile creation inserts a weight row with note `建档体重` at `08:00`), `ai` (commit from AI), `apple_shortcut` (/health/ingest), `apple_export` (/health/import).

A row can hold any combination of fields. One row per measurement event. Multiple rows per day are allowed and common.

### 2.2 `activity_days` (one row per user per local date, daily TOTALS)
PK `(user_id, date)`.

| column | type | null | unit |
|---|---|---|---|
| user_id | int | no | |
| date | text | no | local date |
| steps | int (may be real) | yes | count |
| active_kcal | real | yes | kcal (Apple "活动能量 / Active Energy") |
| resting_kcal | real | yes | kcal (Apple "静息能量 / Resting Energy") |
| distance_km | real | yes | walking + running km |
| exercise_min | real | yes | minutes (Apple green ring) |
| source | text | no | `manual` · `ai_screenshot` · `apple_shortcut` · `apple_export` |
| updated_at | text | no | UTC |
| sleep_hours | real | yes | hours slept the **night before** this date (decimal) |
| stand_hours | real | yes | Apple stand hours |

### 2.3 `exercises` (individual workouts)
| column | type | null | meaning |
|---|---|---|---|
| id | int | no | |
| user_id | int | no | |
| date | text | no | local date |
| time | text | no | `HH:MM` (default `12:00`). Often the insert time, not the workout start (see 4.5) |
| description | text | no | ≤80 chars |
| activity_key | text | yes | key from the MET table (§9.1), or null |
| met | real | no | MET used |
| duration_min | real | no | minutes |
| distance_km | real | yes | km |
| kcal | real | no | **net** kcal = round((MET−1) × weight_kg × hours), computed **server-side once at insert** with the weight on that date. It is never recomputed |
| in_device | int 0/1 | no | 1 = already included in the device's daily active energy, so it is not double-counted |
| source | text | no | `manual` · `ai` |
| created_at | text | no | UTC |
| avg_hr | real | yes | bpm (commit only) |
| device_kcal | real | yes | the device's displayed workout kcal (informational only, never used in math) |

### 2.4 `lab_results`
| column | type | null | unit |
|---|---|---|---|
| id | int | no | |
| user_id | int | no | |
| date | text | no | |
| total_chol | real | yes | **mg/dL** |
| hdl | real | yes | mg/dL |
| non_hdl | real | yes | mg/dL. If not supplied and both total and HDL are, the server stores `total − hdl` |
| ldl | real | yes | mg/dL |
| lipid_treated | int 0/1 | no | on lipid-lowering drugs |
| fasting_glucose | real | yes | **mg/dL** |
| hba1c | real | yes | **%** (NGSP) |
| diabetes | int 0/1 | no | diagnosed diabetes |
| note | text | yes | ≤200 |
| created_at | text | no | |

### 2.5 `ai_jobs` (async AI)
`id` (UUID text), `user_id`, `kind` (`activity`|`meal`|`food`|`exercise`|`summary`), `status` (`queued`|`running`|`done`|`error`), `input` (JSON), `result` (JSON), `error`, `created_at`, `finished_at`.
On server restart, unfinished jobs become `error` with message `服务器重启，任务中断，请重试`, and jobs older than 7 days are deleted.

### 2.6 `profiles` fields that matter here
`timezone` (day boundaries), `weight_kg` (fallback weight when no weigh-in exists), `height_cm` (BMI, step-length), `sex`, `birth_date`, `conditions` (contains `"diabetes"` → LE8 glucose treated as diabetic), `nicotine`, `secondhand_smoke`.

### 2.7 Suggested Swift models
```swift
struct BodyMetric: Codable, Identifiable { let id: Int; let date: String; let time: String
  let weight_kg: Double?; let body_fat_pct: Double?; let waist_cm: Double?
  let sbp: Double?; let dbp: Double?; let bp_treated: Int; let note: String?; let source: String; let created_at: String? }
struct ActivityDay: Codable { let date: String; let steps: Double?; let active_kcal: Double?; let resting_kcal: Double?
  let distance_km: Double?; let exercise_min: Double?; let sleep_hours: Double?; let stand_hours: Double?
  let source: String; let updated_at: String? }
struct Exercise: Codable, Identifiable { let id: Int; let date: String; let time: String; let description: String
  let activity_key: String?; let met: Double; let duration_min: Double; let distance_km: Double?; let kcal: Double
  let in_device: Int; let avg_hr: Double?; let device_kcal: Double?; let source: String }
struct LabResult: Codable, Identifiable { let id: Int; let date: String; let total_chol: Double?; let hdl: Double?
  let non_hdl: Double?; let ldl: Double?; let lipid_treated: Int; let fasting_glucose: Double?; let hba1c: Double?
  let diabetes: Int; let note: String? }
```

---

## 3. Endpoints: body, labs, activity, exercises

### 3.1 `GET /body`, list body metrics
- Auth: requireAuth.
- Query: `start` (date, optional, default `1900-01-01`), `end` (date, optional, default `2999-12-31`). An invalid value is treated as absent.
- Response 200: `BodyMetric[]` (all columns of §2.1), ordered `date DESC, time DESC, id DESC`. **No pagination.** The web asks for `start = today − 365`.

### 3.2 `POST /body`, add a measurement
- Auth: requireAuth. A profile is not required.
- Body:
| field | type | req | rule |
|---|---|---|---|
| date | string date | no | default today (profile tz) |
| time | string `HH:MM` | no | default now (profile tz) |
| weight_kg | number\|null | no | 20–350, name `体重` |
| body_fat_pct | number\|null | no | 2–70 (percent), name `体脂率` |
| waist_cm | number\|null | no | 30–250, name `腰围` |
| sbp | number\|null | no | 60–260, name `收缩压` |
| dbp | number\|null | no | 30–160, name `舒张压` |
| bp_treated | bool | no | truthy → 1, stored even when no BP is given |
| note | string | no | trimmed, ≤200 |
- Rule: if `weight_kg`, `body_fat_pct`, `waist_cm` **and `sbp`** are all null, the server returns 400 `请至少填写一项`. **`dbp` alone is rejected. `sbp` without `dbp` is accepted and stored**, but LE8 ignores rows that lack either value (§8.3). The client should require both.
- Stored `source = 'manual'`. Invalidates cached daily scores from `date` onward.
- Response 200: `{"id": <int>}`.

### 3.3 `DELETE /body/{id}`
- 404 `不存在` if the row is not the caller's. 200 `{"ok": true}`. Invalidates from the row's date.

### 3.4 `GET /labs`
- Response 200: `LabResult[]` (all columns), ordered `date DESC, id DESC`. **No date filter.**

### 3.5 `POST /labs`
- Body (all values in **mg/dL** except `hba1c` in %):
| field | type | rule (min–max) | name |
|---|---|---|---|
| date | date | default today | |
| total_chol | number\|null | 50–600 | 总胆固醇 |
| hdl | number\|null | 5–200 | HDL |
| non_hdl | number\|null | 20–600 | 非 HDL 胆固醇 |
| ldl | number\|null | 10–500 | LDL |
| fasting_glucose | number\|null | 30–600 | 空腹血糖 |
| hba1c | number\|null | 3–20 (%) | 糖化血红蛋白 |
| lipid_treated | bool | | |
| diabetes | bool | | |
| note | string ≤200 | | |
- If `non_hdl` is null and both `total_chol` and `hdl` are present, the server sets `non_hdl = total_chol − hdl`.
- Rule: if `total_chol`, `non_hdl` (after derivation), `fasting_glucose` and `hba1c` are all null, the server returns 400 `请至少填写一项`. HDL alone or LDL alone is rejected.
- Response 200: `{"id": <int>}`.
- **mmol/L conversion is client-side** and the web does it before POSTing:
  - cholesterol (total, HDL, LDL): `mg/dL = round(mmol/L × 38.67)`
  - glucose: `mg/dL = round(mmol/L × 18)`
  - HbA1c is always %. The web has no IFCC mode. If the app adds one: `% = mmol/mol × 0.0915 + 2.15`.
  - The web default unit state is `mgdl`, and the toggle reads `mmol/L（国内常用）` / `mg/dL`.

### 3.6 `DELETE /labs/{id}` **[spec gap: not in OpenAPI]**
- Always 200 `{"ok": true}`, even when the id does not exist or belongs to someone else (no 404). **Does not invalidate any cache.** LE8 is computed live, so it is unaffected.

### 3.7 `GET /activity`, daily activity and workouts in a range
- Query: `start`, `end` (dates, optional, same defaults as /body).
- Response 200:
```json
{ "days": [ActivityDay...],      // ORDER BY date DESC, all columns of §2.2
  "exercises": [Exercise...] }   // ORDER BY date DESC, time DESC, all columns of §2.3
```
- `start > end` returns empty arrays, not an error.

### 3.8 `PUT /activity/{date}`, manual full overwrite of one day
- Path `date` must be valid, else 400 `日期格式不正确`.
- Body (each value number\|null; **omitted means null**):
| field | min–max | name |
|---|---|---|
| steps | 0–200000 | 步数 |
| active_kcal | 0–10000 | 活动能量 |
| resting_kcal | 0–5000 | 静息能量 |
| distance_km | 0–500 | 距离 |
| exercise_min | 0–1440 | 锻炼分钟 |
| sleep_hours | 0–24 | 睡眠时长 |
| stand_hours | 0–24 | 站立小时 |
- Semantics: an UPSERT that **replaces every field** (an omitted field becomes NULL) and sets `source='manual'`. To edit one field, send all current values. This is the only endpoint that can **clear** a field. It cannot delete the row.
- Response 200 `{"ok": true}`. Invalidates that day's score.

### 3.9 `POST /exercises`, add a workout manually
- Auth: requireAuth. **A profile is required** (400 `请先完善个人档案`).
- Body:
| field | type | req | rule |
|---|---|---|---|
| date | date | no | default today |
| time | `HH:MM` | no | default now |
| activity_key | string | no | key from §9.1. An unknown key stores `activity_key = null` |
| met | number | **yes unless a valid activity_key is given** | 1–25, defaults to the activity's MET. Missing → 400 `MET不能为空` |
| duration_min | number | **yes** | 1–1440, name `时长` |
| distance_km | number\|null | no | 0–1000 |
| description | string | no | ≤80. Default: activity `zh` name, else `运动` |
| in_device | bool | no | default false |
| source | string | no | `"ai"` → `ai`, anything else → `manual` |
- The server computes `weight = latest weigh-in on or before date, else profile.weight_kg` and `kcal = round(max(0,(met−1) × weight × duration_min/60))`.
- Response 200: `{"id": <int>, "kcal": <int>}`.
- `avg_hr` and `device_kcal` are **not** accepted here; only `/activity/commit` takes them.
- Web behavior: the manual add sets `in_device = !!day?.active_kcal`, so the flag is true when that day already has device active energy.

### 3.10 `PATCH /exercises/{id}`
- Body `{"in_device": bool}`. Only this field can be changed. 404 `不存在`. 200 `{"ok": true}`. Invalidates that day.

### 3.11 `DELETE /exercises/{id}`
- 404 `不存在`. 200 `{"ok": true}`.

---

## 4. AI activity flow: text and/or screenshots → draft → live preview → commit

Sequence: (optional) `POST /uploads` → `POST /ai/activity` → poll `GET /ai/jobs/{id}` until `done` → the user edits the `ActivityDraft` → `POST /preview` on every edit (debounced ~350 ms) → `POST /activity/commit`.
The same `/preview` + `/activity/commit` pair also powers the **manual "填写" dialog** (`mode=manual`): the client builds a draft prefilled with the current day's activity values and empty body fields, and commits with `source:"manual"`.

### 4.1 `POST /uploads` (multipart)
- Field name `photos`, 1–6 files, ≤12 MB each. MIME type must be `image/jpeg|png|webp|gif`. **HEIC is filtered out**, so convert to JPEG first. If nothing valid remains: 400 `请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）`. More than 6 files: 500 (unhandled multer error).
- Response: `{"photos":[{"id":"<24hex>.jpg","url":"/api/uploads/<id>"}]}`. `GET /api/uploads/{id}` needs auth, so prefix the host and send the Bearer header to display it.

### 4.2 `POST /ai/activity`
- Auth: requireAuth. **A profile is required.**
- Body: `{"text"?: string (≤1000, truncated), "date"?: date (default today), "photos"?: string[] (upload ids; the server uses the first 6 with ext jpg/jpeg/png/webp/gif that exist)}`.
- If both `text` and `photos` are empty: 400 `请描述今天的活动，或上传健康 App / 手表截图`.
- Response 200: `{"job_id":"<uuid>"}`.

### 4.3 `GET /ai/jobs/{id}`
- Response 200: `{"id": string, "kind": "activity", "status": "queued"|"running"|"done"|"error", "error": string|null, "result": ActivityDraft|null}`. 404 `任务不存在` when the id is unknown or belongs to another user.
- The web polls every 1.5 s. Screenshots usually take 20–60 s. The server AI timeout defaults to 480 s. When `status == "error"`, show `error` (the web fallback text is `AI 任务失败`).
- Concurrency is server-wide (`AI_CONCURRENCY`, default 2), so jobs may sit in `queued`.

### 4.4 `ActivityDraft` (job result)
```jsonc
{
  "date": "2026-10-02",          // date read from screenshot if valid and <= today, else the requested date
  "date_from_image": false,      // true when the screenshot date differs from the requested date → show warning banner
  "activity": {                   // each number or null; out-of-range values are nulled (not errors)
    "steps": 8532,                // 0–200000
    "distance_km": 6.1,           // 0–500
    "active_kcal": 412,           // 0–10000
    "resting_kcal": 1620,         // 300–5000 (note: AI path nulls < 300)
    "exercise_min": 35,           // 0–1440
    "stand_hours": 11,            // 0–24  (the web UI does NOT show/edit this field but sends it back)
    "sleep_hours": 7.5            // 0–24
  },
  "body": { "weight_kg": 70.2, "body_fat_pct": null, "sbp": null, "dbp": null },  // 20–350, 2–70, 60–260, 30–160
  "workouts": [ {
      "description": "游泳",       // ≤80
      "activity_key": "swim_freestyle_medium",  // always a valid key (unknown → other_moderate)
      "met": 8.0,                 // AI path clamps 1–20
      "duration_min": 110,        // rounded int, 1–1440 (default 30 if missing)
      "distance_km": 5,           // 0 when unknown (NOT null)
      "kcal": 543,                // server estimate with the date's weight
      "notes": "…",               // ≤200
      "avg_hr": null,             // 30–230 or null
      "device_kcal": null,        // 1–10000 or null
      "in_device": false          // true when the workout came from a watch/phone screenshot
  } ],
  "notes": "…",                   // ≤600, overall explanation (show as banner)
  "provider": "cli" | "api" | "mock",
  "model": "claude-…" | "offline"
}
```
In mock mode (no AI configured), parsing is regex-based on text only: `notes = "离线规则解析（未配置 AI，无法识别截图）"`.

### 4.5 `POST /preview`, re-score a day with unsaved changes (no write)
- Auth: requireAuth. **A profile is required.** It is shared with the meal flow.
- Body (all optional):
```jsonc
{
  "date": "2026-10-02",                        // default today
  "activity": { "steps": 9000, ... },          // keys of ActivityDraft.activity; validated (0–200000 etc.; error text uses English key e.g. "steps不能大于 200000")
  "body": { "weight_kg": 70.2, "sbp": 118, "dbp": 76, "bp_treated": false },  // body_fat_pct ignored here
  "workouts": [ Workout ],                     // see below; max 20 used
  "meal": { "meal_type": "...", "time": "HH:MM", "items": [MealItem], "replace_meal_id": 12 }  // meal flow only
}
```
- `Workout` in requests: `{description?, activity_key?, met?, duration_min (required, 1–1440), distance_km?, in_device?, avg_hr? (30–230, 0 is an error), device_kcal? (0–10000)}`. An unknown `activity_key` falls back to `other_moderate`. `met` defaults to the activity's MET (1–25). `distance_km` 0 becomes null.
- **An invalid workout or activity returns 400** (for example `时长不能小于 1` while the user is typing). The web catches it and simply hides the preview. Do the same.
- Merge semantics: activity fields that are non-null **overlay** the existing day's values. Null fields leave the existing value. `weight_kg` replaces the day's weight and marks it weighed. BP counts only when both sbp and dbp are given. Workouts are appended.
- Response 200:
```jsonc
{ "date": "2026-10-02",
  "before": DailyScore, "after": DailyScore,                  // §10
  "indices": { "before": HealthIndices, "after": HealthIndices } }  // 7-day window ending at date (LE8/WCRF/MEPA)
```

### 4.6 `POST /activity/commit`, save the reviewed draft
- Auth: requireAuth. **A profile is required.**
- Body:
```jsonc
{
  "date": "2026-10-02",               // send draft.date (may differ from the page date when date_from_image)
  "source": "ai" | "manual",          // default "ai" for anything other than "manual"  [spec gap]
  "activity": { steps, distance_km, active_kcal, resting_kcal, exercise_min, stand_hours, sleep_hours },  // same ranges as PUT /activity
  "body": {
    "weight_kg": 20–350, "body_fat_pct": 2–70, "sbp": 60–260, "dbp": 30–160,
    "bp_treated": bool,               // [spec gap]
    "time": "HH:MM"                   // [spec gap] not validated, default "22:00"
  },
  "workouts": [ Workout ]             // max 20; per-workout date/time are IGNORED
}
```
- Effects, all in one transaction:
  1. If any activity field is non-null, the day is UPSERTed with **COALESCE**: given fields overwrite and null fields keep their current value. `source` becomes `ai_screenshot` (source=ai) or `manual`. **This endpoint cannot clear a field.**
  2. Each workout is inserted with `time = now` (profile tz), regardless of `date`. Source is `ai` or `manual`. `kcal` is recomputed server-side with `body.weight_kg` if given, else the date's weight.
  3. If `weight_kg` or `body_fat_pct` or `sbp` is non-null, one `body_metrics` row is inserted with `time = body.time || "22:00"` and source `ai`/`manual`. **`waist_cm` is not supported here. A `dbp`-only body is silently dropped.**
- Response 200: `{"ok": true, "date": "2026-10-02", "workouts": <count inserted>}`.

### 4.7 Legacy `POST /ai/exercise`
Body `{"text": string (required, ≤500, name 运动描述), "date"?}` → job whose result is `{"items":[{description, activity_key, met, duration_min, distance_km, kcal, notes}], "provider"}`. The web no longer uses it. Prefer `/ai/activity`.

---

## 5. `POST /health/ingest` (iPhone Shortcut / generic push)

- Auth: **requireAuthOrToken**. Accepts the app token `nla_…`, the personal token `nl_…` (created with `POST /settings/token`, which returns `{"token":"nl_…"}` once; the user row stores only a hash and the hint `nl_xxxx…abcd`), or `?token=nl_…`. A profile is not required (tz falls back to Asia/Shanghai).
- Body (JSON or form). **Every value is parsed "loosely":** commas are stripped and the first `-?\d+(\.\d+)?` is taken, so `"8,532"` → 8532, `"512 kcal"` → 512, `"abc"` → null. `"1e3"` → 1. **No range validation and no rounding.** Negative values pass.
| field | aliases | stored to |
|---|---|---|
| date | – | target date (invalid → today) |
| steps | – | activity_days.steps |
| active_kcal | `active_energy` | activity_days.active_kcal |
| resting_kcal | `resting_energy` | activity_days.resting_kcal |
| distance_km | – | activity_days.distance_km (must already be km) |
| exercise_min | – | activity_days.exercise_min |
| sleep_hours | – | activity_days.sleep_hours |
| weight_kg | – | new body_metrics row (only if 20 ≤ w ≤ 350, else silently ignored) |
| body_fat_pct | – | same row. **A value ≤ 1 is treated as a fraction and multiplied by 100.** Ignored when there is no valid weight |
- `stand_hours` is **not accepted**. Neither are waist or BP.
- Merge per day: if any activity value is non-null, the server runs `upsertActivity(…, source='apple_shortcut')`. That is **COALESCE per field**: provided values overwrite, including values the user entered manually; omitted values are kept; `source` is overwritten to `apple_shortcut` for the whole row. Only that day's score is invalidated.
- Weight: **every call INSERTs a new row** (`source='apple_shortcut'`, `time = server now in profile tz`, **not the sample time**). There is no dedupe, so repeated calls create duplicate weigh-ins.
- Response 200: `{"ok": true, "date": "...", "activity"?: {steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours}, "weight_kg"?: number}`. The `activity` and `weight_kg` keys appear only when written **[spec gap: OpenAPI shows only ok, date]**.

---

## 6. `POST /health/import` (Apple Health export.zip / export.xml)

- Auth: requireAuth (personal `nl_` tokens are not accepted). Multipart: `file` (required; `.zip` is detected by **filename** suffix, anything else is read as XML), `since` (date, optional; default **today − 365 days** in profile tz). Max 4 GB (413 `文件太大`).
- Errors: no file → 400 `请上传苹果健康导出的 export.xml 或 export.zip`. Zip without the `unzip` binary on the server → 400 `服务器没有 unzip 命令，请解压后上传 export.xml`. No entry matching `(^|/)export\.xml$` → 400 `压缩包中没有找到 export.xml`.
- The request is synchronous and long-running (streamed line by line). There is no job id, so set a long client timeout.
- Parsing: line-based. A line counts only when it contains `<Record ` and `type`, `startDate` and `value` attributes on the same line. `Workout`, `ActivitySummary` and `Correlation` elements are ignored.
- Types parsed:
| HK type | kind | unit handling |
|---|---|---|
| HKQuantityTypeIdentifierStepCount | steps | as is |
| HKQuantityTypeIdentifierActiveEnergyBurned | active | `kJ` → ÷4.184, else kcal |
| HKQuantityTypeIdentifierBasalEnergyBurned | resting | same |
| HKQuantityTypeIdentifierDistanceWalkingRunning | distance | `mi` ×1.60934, `m` ÷1000, else km |
| HKQuantityTypeIdentifierAppleExerciseTime | exercise | min |
| HKQuantityTypeIdentifierBodyMass | weight | `lb` ×0.453592, `g` ÷1000, else kg |
| HKQuantityTypeIdentifierBodyFatPercentage | fat | value ≤1 → ×100 |
- **Not imported**: sleep (`HKCategoryTypeIdentifierSleepAnalysis`), stand hours, blood pressure, waist, workouts, heart rate, glucose.
- Day attribution: `date = startDate.slice(0,10)`. Export timestamps look like `2026-10-02 08:30:00 +0800`, so the date is the **device-local date at recording**, not the profile tz. A sample spanning midnight goes entirely to its start date. Records with `date < since` are skipped.
- **iPhone/Watch dedupe:** for each date and kind, values are **summed per `sourceName`**, then the **max across sources** is taken. This approximates the de-duplication HealthKit itself does and undercounts when sources cover disjoint parts of the day (for example iPhone in the morning and Watch in the afternoon). `steps` is rounded to an integer. Other values are not rounded.
- Activity write: `upsertActivity(date, {steps, active_kcal, resting_kcal, distance_km, exercise_min}, 'apple_export')`. COALESCE semantics, so manual values for these fields are overwritten and sleep/stand are kept. Source becomes `apple_export`.
- Weight write: one row per date. The **last weight record of that date in file order** wins, and its time is `startDate HH:MM` (fallback `07:00`). Weight is rounded to 0.1 kg. Body fat on the same date is attached to it, and fat-only dates are skipped. Before inserting, `DELETE body_metrics WHERE date=? AND source='apple_export'`, so re-import is idempotent for its own rows. Manual or shortcut rows are untouched, which allows duplicates with them.
- All writes happen in one transaction. Cached scores are invalidated from the earliest imported date.
- Response 200: `{"ok": true, "records": <parsed records>, "days": <activity days written>, "weights": <weight rows written>, "since": "YYYY-MM-DD"}` (`since` is a spec gap).

---

## 7. Related read endpoints (owned by other specs; body-relevant fields only)
- `GET /day/{date}` (`?user=<username>` for shared users). Returns `activity` (ActivityDay row or null), `exercises` (rows ORDER BY time; empty when only a summary is shared), `body` (all body rows of that date ORDER BY time), `weightTrend` (EWMA kg or null), `score.energy` (EnergyResult), and `indices` (HealthIndices for the 7 days ending at date).
- `GET /trends?start&end` returns `days[]` with `steps`, `activeKcal`, `exerciseKcal`, `weight` (last weigh-in of the day or null) and `trend` (EWMA α=0.1, 2 decimals). The web uses it for the 90-day weight chart and the 30-day steps bar chart.
- `GET /standards/meta` returns `activities` (the MET table in §9.1, each item `{key, zh, met, speedKmh?, code?, intensity}`) and `activityLevels`. Use it for pickers instead of hard-coding them.

---

## 8. How the server uses this data (for UI explanations and HealthKit decisions)

### 8.1 Daily energy (`computeEnergy`, per day)
Inputs: `a` = activity row, `exercises` of the day, targets (`bmr`, `eer`, `heightCm`, …).
- `deviceResting = resting_kcal` **only if > 500**, else null. `resting = deviceResting ?? BMR(Mifflin)`. A partial-day resting value is therefore ignored.
- `extraExercise` = Σ kcal of exercises with `in_device = 0`. `allExercise` = Σ kcal of every exercise.
- If `active_kcal > 0` (device): `active = active_kcal + extraExercise`, `tdee = (resting + active)/0.9`, `tef = tdee×0.1`, `activeSource="device"`.
- else if `steps > 0`: `active = stepsNetKcal(steps) + extraExercise`, same tdee formula, `activeSource="steps"`.
- else if `allExercise > 0`: `tdee = EER(inactive) + allExercise`, `activeSource="exercise"`. **Here in_device workouts DO count.**
- else `tdee = EER(profile activity level)`, `method="eer"`.
- `target = max(energyFloor, tdee + goalDeltaKcal)`, `balance = intake − tdee`.
- Consequence: when the day has neither active_kcal nor steps, a workout flagged `in_device=1` is ignored in the steps branch. Set `in_device` true only when that day also has device active energy (§12.4).

### 8.2 Physical activity minutes
- Daily composite "身体活动" (20% weight): `min = Σ over exercises (MET≥6: 2×duration; 3≤MET<6: duration; <3: 0)`, then `min = max(min, exercise_min)`. Score `= clamp(max(min/30, steps/8000) × 100, 0, 100)`. When there are no exercises, no exercise_min and no steps, the part is null and listed as missing.
- LE8 / WCRF over a window: per date `max(exercise-derived minutes, exercise_min)`. LE8 counts vigorous minutes twice and WCRF does not. Result is per week = total / windowDays × 7. `strengthDays` counts dates with an `activity_key` matching `/strength|circuit|hiit/`.

### 8.3 Other uses
- **Sleep:** LE8 sleep = mean of `sleep_hours > 0` over activity rows in the window. Points: 7–<9 h → 100; 9–<10 → 90; 6–<7 → 70; 5–<6 or ≥10 → 40; 4–<5 → 20; <4 → 0.
- **Weight:** the weight for a date is the latest weigh-in on or before that date (ordered by date, time, id), else `profile.weight_kg`. Feeds BMI, which drives LE8 (<25 → 100; <30 → 70; <35 → 30; <40 → 15; else 0) and WCRF. Multiple weigh-ins on one day: the **last by time** wins.
- **Blood pressure:** the **3 most recent readings with both sbp and dbp** within the 90 days ending at the window end are averaged. `treated` = any of them has bp_treated. Points: ≥160/≥100 → 0; ≥140/≥90 → 25; ≥130/≥80 → 50; sbp ≥120 → 75; else 100; −20 if treated.
- **Labs:** the latest lab row with `date ≤ window end` is used, from **one row only** (not merged across rows). Lipids use `non_hdl`: <130 → 100, <160 → 60, <190 → 40, <220 → 20, else 0; −20 if treated. Glucose: when the user is diabetic (row flag or profile condition `diabetes`), HbA1c <7 → 40, <8 → 30, <9 → 20, <10 → 10, else 0 (null when there is no HbA1c). Otherwise fasting ≥126 or HbA1c ≥6.5 is scored as diabetic; ≥100 or ≥5.7 → 60; else 100.
- **Waist:** the latest waist within the 180 days ending at the window end. WCRF male <94 → 0.5, <102 → 0.25; female <80 → 0.5, <88 → 0.25.
- **Not used in any score:** `body_fat_pct`, `stand_hours`, `distance_km`, `avg_hr`, `device_kcal`. They are display only.

### 8.4 Caches
`daily_scores` caches DailyScore per date. Activity and exercise writes invalidate only that date. Body writes invalidate every date ≥ the row date and also delete stored period reports (`reports` rows with `end_date ≥ date` and no AI summary). LE8/WCRF indices are computed live on read.

---

## 9. Standards (what the client needs)

### 9.1 MET table (2024 Adult Compendium); `intensity`: MET ≥6 vigorous, ≥3 moderate, else light
| key | zh | MET | speedKmh |
|---|---|---|---|
| walk_slow | 散步 (约 4 km/h) | 3.0 | 4.0 |
| walk_moderate | 步行 (约 5 km/h) | 3.8 | 5.0 |
| walk_brisk | 快走 (约 6 km/h) | 4.8 | 6.0 |
| walk_very_brisk | 疾走 (约 6.8 km/h) | 5.5 | 6.8 |
| hiking | 徒步/爬山 | 6.0 | 4.0 |
| stairs | 爬楼梯 | 6.8 | |
| jogging | 慢跑 | 7.5 | 8.0 |
| run_10kmh | 跑步 (约 10 km/h) | 9.3 | 10.0 |
| run_13kmh | 跑步 (约 13 km/h) | 12.0 | 12.9 |
| run_16kmh | 跑步 (约 16 km/h) | 14.8 | 16.1 |
| cycle_leisure | 骑行 (休闲 17–19 km/h) | 6.8 | 18 |
| cycle_moderate | 骑行 (中速 19–22 km/h) | 8.0 | 21 |
| cycle_vigorous | 骑行 (快速 22–26 km/h) | 10.0 | 24 |
| cycle_stationary | 动感单车/固定自行车 | 6.8 | |
| swim_leisure | 游泳 (休闲，不计圈) | 6.0 | 1.8 |
| swim_freestyle_slow | 自由泳 (慢速) | 5.8 | 2.1 |
| swim_freestyle_medium | 自由泳 (中速 ~46 m/min) | 8.0 | 2.75 |
| swim_freestyle_fast | 自由泳 (快速 ~69 m/min) | 10.5 | 4.1 |
| swim_breaststroke | 蛙泳 (休闲) | 5.3 | 2.0 |
| swim_breaststroke_training | 蛙泳 (训练) | 10.3 | 3.0 |
| swim_backstroke | 仰泳 (休闲) | 4.8 | 1.9 |
| swim_butterfly | 蝶泳 | 13.8 | 3.2 |
| swim_open_water | 公开水域游泳 | 10.5 | 3.0 |
| jump_rope | 跳绳 (中速) | 11.8 | |
| basketball | 篮球 (比赛) | 8.0 | |
| soccer | 足球 (休闲) | 7.0 | |
| soccer_competitive | 足球 (比赛) | 9.5 | |
| badminton | 羽毛球 (休闲) | 5.5 | |
| badminton_competitive | 羽毛球 (比赛) | 7.0 | |
| tennis_singles | 网球单打 | 8.0 | |
| table_tennis | 乒乓球 | 4.0 | |
| yoga | 瑜伽 (哈他) | 2.3 | |
| pilates | 普拉提 | 3.0 | |
| strength_moderate | 力量训练 (中等) | 3.5 | |
| strength_vigorous | 力量训练 (大强度) | 6.0 | |
| circuit | 循环训练 | 5.0 | |
| hiit | HIIT 高强度间歇 | 7.0 | |
| hiit_vigorous | HIIT (极高强度) | 11.0 | |
| elliptical | 椭圆机 | 5.0 | |
| rowing_machine | 划船机 (中等) | 5.0 | |
| aerobic_dance | 有氧操/健身舞 | 7.3 | |
| dance_social | 跳舞 (广场舞/社交舞) | 4.8 | |
| housework | 家务 (打扫) | 3.3 | |
| other_light | 其他轻度活动 | 2.5 | |
| other_moderate | 其他中等强度活动 | 4.5 | |
| other_vigorous | 其他高强度活动 | 7.5 | |

Net kcal: `netKcal(met, weightKg, minutes) = max(0, (met − 1) × weightKg × minutes/60)`. The server rounds when storing. Local display only: the web shows `round(...)` using `profile.weight_kg`, but the stored value uses the dated weight.

### 9.2 Energy formulas (energy.ts)
- Activity levels: `inactive` 久坐 PAL 1.4 ("办公室工作，几乎不运动（PAL 1.0–1.53）"); `low_active` 轻度活动 1.6 ("每天步行约 30–60 分钟或少量运动（PAL 1.53–1.68）"); `active` 活跃 1.75 ("每天中等强度运动约 1 小时（PAL 1.68–1.85）"); `very_active` 非常活跃 2.05 ("体力劳动或每天高强度训练（PAL 1.85–2.5）").
- BMR (Mifflin–St Jeor): `10w + 6.25h − 5age + (male ? 5 : −161)`.
- EER (NASEM 2023, age ≥19): `a + b·age + c·height_cm + d·weight_kg`, with coefficients by [sex][level]:
  male inactive [753.07, −10.83, 6.5, 14.1]; low_active [581.47, −10.83, 8.3, 14.94]; active [1004.82, −10.83, 6.52, 15.91]; very_active [−517.88, −10.83, 15.61, 19.11].
  female inactive [584.9, −7.01, 5.72, 11.71]; low_active [575.77, −7.01, 6.6, 12.14]; active [710.25, −7.01, 6.54, 12.34]; very_active [511.83, −7.01, 9.07, 12.56].
  Age <19: BMR × PAL. Pregnant +340, lactating +330.
- Steps → net kcal: `km = steps × height_cm × 0.414 / 100000`, `kcal = km × weight_kg × 0.5`.
- BMI category: <18.5 偏瘦 (under), <25 正常 (normal), <30 超重 (over), else 肥胖 (obese). `KCAL_PER_KG = 7700`.

---

## 10. Nested response types (as returned by `/preview`, `/day`)

```ts
type Status = "good" | "ok" | "warn" | "bad" | "info";
CompositePart  { key: string; zh: string; weight: number; score: number|null; points: number|null; note: string }
CompositeScore { score: number|null; parts: CompositePart[]; missing: string[] }
ScoreItem { key; category: "hei"|"mar"|"adequacy"|"moderation"|"energy"; zh; value: number; unit; targetText;
            target?: number; ideal?: number; limit?: number; status: Status; score: number /*0–1*/;
            points: number; maxPoints: number; message: string; sources: string[] }
HazardResult { key; zh; iarc: string; dose: number; unit; foods: string[]; message; sources: string[] }
EnergyResult { intake; resting; restingSource: "device"|"bmr"; active; activeSource: "device"|"steps"|"exercise"|"none";
               exerciseKcal; tef; tdee; method: "measured"|"eer"; target; balance }   // all numbers kcal
DailyScore {
  date: string; hasData: boolean;
  score: number|null;                      // HEI-2020 total 0–100
  total: CompositeScore;                   // site composite 0–100
  categories: { key: "hei"|"mar"; zh; score: number; source; note }[];
  items: ScoreItem[];
  hei: { total: number; components: { key; zh; score; max; value; unit; hint }[] } | null;
  mar: { value: number; nutrients: { key; zh; intake; target; nar }[] } | null;
  hazards: HazardResult[];
  energy: EnergyResult;
  totals: Record<string, number>;          // nutrient vector (energy_kcal, sodium_mg, added_sugars_g, sat_fat_g, protein_g, fiber_g, water_g, …)
  groups: Record<string, number>;          // food group vector
  macroPct: { protein; carb; fat; satFat; addedSugar; alcohol };
  upfPct: number; mealCount: number; itemCount: number; fastFoodMeals: number;
  completeness: { level: "none"|"partial"|"likely"; note: string };
  top: { issues: string[]; wins: string[] };
  weightKg: number; weighedToday: number|null;
  version: number                          // SCORING_VERSION = 3 (not in web types)
}
Le8Component  { key: "diet"|"activity"|"nicotine"|"sleep"|"bmi"|"lipids"|"glucose"|"bp"; zh; points: number|null; value: string; rule: string; missing: string }
WcrfComponent { key; zh; points: number|null; max: number; detail: string; rule: string }
MepaItem      { key; zh; criterion: string; value: number; unit: string; met: boolean }
HealthIndices {
  windowDays: number; loggedDays: number;
  mepa: { score: number; days: number; items: MepaItem[] } | null;
  le8: { score: number|null; category: { key: "high"|"moderate"|"low"; zh: "高"|"中"|"低" } | null; available: number; components: Le8Component[] };
  wcrf: { score: number; max: number; components: WcrfComponent[] };
  pa: { le8MinPerWeek: number|null; mvpaMinPerWeek: number|null; strengthDays: number };
  sleepHours: number|null;
}
```
Daily composite weights: 膳食质量 HEI 50, 微量营养素 MAR 15, 能量平衡 15, 身体活动 20. A day without food logs has `total.score = null`.
LE8 component Chinese names: 饮食（MEPA）, 身体活动, 尼古丁暴露, 睡眠, 体重指数 BMI, 血脂（非 HDL 胆固醇）, 血糖, 血压. Their `missing` hints are server strings, for example `记录运动或同步“锻炼分钟”`, `填写或同步睡眠时长`, `记录体重`, `在身体页填写体检的总胆固醇与 HDL`, `在身体页填写体检的空腹血糖或糖化血红蛋白`, `记录血压`.

---

## 11. Chinese UI strings used by the web (reuse verbatim)

**Body page (身体与运动)**
- Title `身体与运动`; subtitle `睡前称重 + 步数/活动能量 + 运动记录，和饮食摄入交叉对照`; date picker aria `日期`.
- Card `记录体重`, hint `建议每晚睡前、同一时间称`. Fields `体重` (kg), `时间`, `体脂率（可选）` (%), `腰围（可选）` (cm), `血压（可选）` with placeholders `收缩压` / `舒张压`; checkbox (shown once sbp is entered) `正在服用降压药`; button `保存`; toast `已记录`.
- List row: `MM-DD HH:MM`, `{w} kg`, ` · 体脂 {x}%`, ` · 腰围 {x} cm`, ` · 血压 {sbp}/{dbp}`. Source label: manual → (none), profile → `建档`, ai → `AI 识别`, any other → `苹果健康`. Delete aria `删除`.
- Chart card `近 90 天体重`, series `称重`, `趋势（平滑）`, empty `还没有体重记录`.
- Card `记录运动`, banner `说一句“游泳 5km”“打了两小时羽毛球”，或上传手表的运动记录截图，由 {model|离线规则} 按 2024 运动代谢当量表识别，先预览再合并。`, button `AI 识别运动 / 截图`. Disclosure `手动选择运动类型`, option `{zh}（MET {met}）`, unit `分钟`, button `添加`.
- Exercise row: `{description} {duration} 分钟 · MET {met} · {km} km`, checkbox `已含在设备活动能量中`, `{kcal} kcal`; empty `这一天还没有运动记录`.
- Card `步数与活动能量`, hint `来源：手动` / `来源：iPhone 快捷指令` / `来源：苹果健康导出` (any other source), or `未记录`. Fields `步数`, `活动能量` (kcal), `静息能量（可选）` (kcal), `锻炼分钟（可选）`, `睡眠（小时）`, `站立（小时，可选）`. Buttons `保存 {date} 的活动数据`, `上传健康截图识别`; toast `已保存`. Footnote `有“活动能量”时，消耗 = 静息 + 活动能量 + 未被设备记录的运动；只有步数时按步长与体重估算。` Chart series `步数`, y unit `步`.
- Labs card `体检化验指标`, hint `用于美国心脏协会 LE8 的血脂、血糖两项；不填则这两项不计入`; date aria `化验日期`; unit toggle `mmol/L（国内常用）` / `mg/dL`; fields `总胆固醇`, `高密度脂蛋白 HDL`, `低密度脂蛋白 LDL（可选）`, `空腹血糖`, `糖化血红蛋白 HbA1c` (%), group `用药 / 诊断` with `服用降脂药`, `已诊断糖尿病`; button `保存化验结果`; toast `已保存化验结果`; table headers `日期`, `非 HDL 胆固醇`, `空腹血糖`, `HbA1c`; suffixes `（服药）`, `（糖尿病）`.
- Apple Health card `连接苹果健康`: `方式一：iPhone 快捷指令每天自动同步`, `网页无法直接读取 HealthKit。…`, `接口地址`, `生成个人 Token` / `重新生成 Token`, `当前：{hint}`, `查看设置步骤`, `只显示这一次，请复制保存：`, confirm `重新生成后旧 Token 立即失效，快捷指令需要更新。继续？`; `方式二：导入“健康”App 的导出文件`, `健康 App → 右上角头像 → 导出所有健康数据，得到 export.zip（或解压后的 export.xml）。会导入每日步数、活动/静息能量、步行距离、锻炼分钟、体重和体脂；iPhone 与 Apple Watch 的重复数据会自动去重。`, `导入起始日期`, `导入`, toast `导入完成：{days} 天活动数据、{weights} 条体重（共解析 {records} 条记录）`. The native app should replace this card with a "苹果健康同步" settings screen, but it can reuse `连接苹果健康`.

**Activity recognizer / manual fill dialog**
- Titles `填写 {date} 的活动与身体数据` (manual) / `AI 识别活动与身体数据`.
- Intro `用一句话描述，或上传苹果健康 / 健身圆环 / 手表运动记录 / 体脂秤 / 血压计的截图，由 {model|离线规则（未配置 AI，无法读图）} 识别步数、能量、睡眠、体重和每次运动。识别结果会先给你预览，确认后才合并。`
- Placeholder `例：今天走了 8500 步，下午游泳 5km，昨晚睡了 7 个半小时，睡前体重 70.2`; upload aria `上传截图`; alt `已上传的截图`; busy `正在识别… 读取截图通常需要 20–60 秒`; button `AI 识别` (busy shows `{n}s`).
- Banner when date differs: `截图显示的日期是 {date}，将合并到这一天。`
- Sections `活动`, `身体`, `运动`. Activity fields: `步数` (步), `活动能量` (kcal), `静息能量` (kcal), `步行+跑步距离` (km), `锻炼分钟` (分钟), `睡眠` (小时). Body fields: `体重` (kg), `体脂率` (%), `收缩压` (mmHg), `舒张压` (mmHg).
- `添加一项` (default `{description:"快走", activity_key:"walk_brisk", met:4.8, duration_min:30, distance_km:0, in_device:false}`), `没有运动`, `时长 … 分钟`, `MET`, `距离 … km`, `平均心率 {hr}`, `净消耗约 {kcal} kcal`, `（设备显示 {device_kcal}）`, checkbox `已含在设备活动能量中（避免重复计算）`; aria `描述`, `运动类型`.
- Footer `取消`, `确认合并到 {date}`; toast `已合并到当天记录`.
- Preview card `合并预览`, hint `确认前不会写入；数值随修改实时更新`, headers `指标`, `合并前`, `合并后`. Rows: `膳食质量 HEI-2020`, `微量营养素 MAR`, `心血管健康 LE8（近 7 天）`, `防癌 WCRF/AICR（近 7 天）` (unit `/ {max}`), `摄入能量`, `当日消耗`, `能量差额`, `钠`, `添加糖`, `饱和脂肪`, `蛋白质`, `膳食纤维`. Footers `状态变化：`, `LE8 分项：`, `新增风险物：`. Status words: good/ok → `达标`, warn → `偏离`, bad → `不达标`, info → `提示`. Rows are hidden when |after − before| ≤ 0.05, except HEI and LE8, which always show.

**Today page activity card**: `活动与身体`, buttons `填写`, `AI 识别截图`; stats `步数`, `活动能量` kcal, `运动消耗` kcal (= `score.energy.exerciseKcal`), `睡眠` 小时; exercise suffix `（已含在设备数据中）`; body row `{time} 称重`; empty `点“填写”直接录入今天的步数、活动能量、睡眠、体重；或点“AI 识别截图”上传苹果健康 / 手表截图，或者说一句“今天走了 8000 步，游泳 5km”。`

**Server errors seen in this area**: `请至少填写一项`, `日期格式不正确`, `请先完善个人档案`, `请描述今天的活动，或上传健康 App / 手表截图`, `MET不能为空`, `时长不能为空`, `时长不能小于 1`, `体重不能大于 350`, `任务不存在`, `不存在`, `请上传苹果健康导出的 export.xml 或 export.zip`, `压缩包中没有找到 export.xml`, `服务器重启，任务中断，请重试`.

---

## 12. HealthKit direct sync design input

### 12.1 HealthKit type → server storage map
| HealthKit type | Read via | Server target | Notes |
|---|---|---|---|
| `HKQuantityTypeIdentifierStepCount` | `HKStatisticsCollectionQuery`, `.cumulativeSum`, daily interval | `activity_days.steps` | HealthKit merges iPhone + Watch by source priority, which is better than the export's max-per-source. **Never sum raw samples.** Round to int |
| `HKQuantityTypeIdentifierActiveEnergyBurned` | same | `activity_days.active_kcal` | Already includes workout energy recorded by Watch/iPhone |
| `HKQuantityTypeIdentifierBasalEnergyBurned` | same | `activity_days.resting_kcal` | Usually Watch-only. Partial-day values ≤500 are ignored by the server's energy model |
| `HKQuantityTypeIdentifierDistanceWalkingRunning` | same | `activity_days.distance_km` | Cycling and swimming distances are per workout only |
| `HKQuantityTypeIdentifierAppleExerciseTime` | same | `activity_days.exercise_min` | Feeds the PA minutes (§8.2) |
| `HKCategoryTypeIdentifierAppleStandHour` | `HKSampleQuery` per day | `activity_days.stand_hours` | Count samples with value `.stood` (0). Alternative: `HKActivitySummaryQuery.appleStandHours`. **Not accepted by /health/ingest** |
| `HKCategoryTypeIdentifierSleepAnalysis` | `HKSampleQuery` | `activity_days.sleep_hours` | See 12.3 |
| `HKQuantityTypeIdentifierBodyMass` | `HKAnchoredObjectQuery` (samples) | `body_metrics.weight_kg` | One row per sample, with sample time |
| `HKQuantityTypeIdentifierBodyFatPercentage` | anchored | `body_metrics.body_fat_pct` | HK `.percent()` returns 0–1, so ×100 |
| `HKQuantityTypeIdentifierWaistCircumference` | anchored | `body_metrics.waist_cm` | |
| `HKCorrelationTypeIdentifierBloodPressure` (request read for `…BloodPressureSystolic` + `…BloodPressureDiastolic`) | anchored on the correlation | `body_metrics.sbp/dbp` | `bp_treated` is not in HealthKit; it comes from an app setting ("正在服用降压药") applied to synced readings |
| `HKWorkoutType` | anchored | `exercises` | See 12.4 |
| `HKQuantityTypeIdentifierBloodGlucose` | sample query | `lab_results.fasting_glucose` (mg/dL) | **Do not auto-sync.** CGM and post-meal samples are not fasting. Offer "从健康导入" so the user picks a reading, possibly with `HKMetadataKeyBloodGlucoseMealTime == .preprandial`, then POST /labs |
| `HKQuantityTypeIdentifierHeight`, `dateOfBirthComponents()`, `biologicalSex()` | characteristic / latest sample | profile prefill (`PUT /profile`) | Onboarding convenience only |
| `HKQuantityTypeIdentifierDietaryWater` | – | (`/water` is delta-based and not idempotent) | Do not sync now |
| HbA1c, total cholesterol, HDL, LDL | no HK quantity types (Health Records / FHIR only, needs entitlement and is not available in mainland China) | `lab_results` | Manual entry |
| Heart rate, HRV, VO2max, resting HR | – | no table | Only `avg_hr` per workout is stored |

**Exclude echo:** if the app ever writes to HealthKit (for example dietary energy, or a manual weight), filter out samples whose `sourceRevision.source.bundleIdentifier` equals the app's own bundle id. Otherwise those samples are synced back as duplicates.

### 12.2 Unit conversions (send exactly these units)
| field | HKUnit to request | conversion / rounding |
|---|---|---|
| steps | `.count()` | round to Int |
| active/resting kcal | `.kilocalorie()` | none (kJ ÷ 4.184 if ever needed), round to 0.1 |
| distance_km | `.meterUnit(with: .kilo)` | (mi × 1.60934), round to 0.01 |
| exercise_min | `.minute()` | round to 1 |
| stand_hours | count of `.stood` samples | Int |
| sleep_hours | seconds / 3600 | round to 0.01 |
| weight_kg | `.gramUnit(with: .kilo)` | (lb × 0.453592, 斤 ÷ 2), round to 0.1 like the export import |
| body_fat_pct | `.percent()` | **× 100**, round to 0.1 |
| waist_cm | `.meterUnit(with: .centi)` | round to 0.1 |
| sbp/dbp | `.millimeterOfMercury()` | round to 1 |
| avg_hr | `.count().unitDivided(by: .minute())` | round |
| workout energy | `.kilocalorie()` | → `device_kcal` |
| workout METs | `HKMetadataKeyAverageMETs` in `HKUnit(from: "kcal/hr·kg")` | → `met`, clamped 1–25 |
| glucose | `HKUnit(from: "mg/dL")` | mmol/L × 18 (the web factor) |

### 12.3 Aggregation rules the server expects
- **Day key:** local date in **`profile.timezone`**, not the device time zone. Build the `Calendar` for statistics queries with `TimeZone(identifier: profile.timezone)`, anchored at local midnight. When they differ (travel), warn once in the sync settings.
- **activity_days holds daily totals**, one row per date. Today's value is partial and is overwritten on every sync. Re-sync the **last 7 days** on every run, because the Watch delivers samples late. Initial backfill defaults to **365 days**, matching `/health/import`.
- **Sleep night attribution:** `sleep_hours` on date D is the sleep that **ended on the morning of D** (the AI schema describes it as "前一晚睡眠时长"). Suggested rule: take asleep intervals overlapping the window `(D−1 18:00, D 18:00]` local, and clip them to the window.
  - Count asleep values only: `.asleepUnspecified`(1), `.asleepCore`(3), `.asleepDeep`(4), `.asleepREM`(5). Exclude `.inBed`(0) and `.awake`(2).
  - Dedupe across sources by taking the **union of intervals**, not the sum (Watch + AutoSleep + others overlap). When Apple Watch data exists, use only the Watch.
  - If there is no asleep data at all, fall back to the `inBed` union (iPhone sleep schedule only) and flag it as approximate in the UI.
  - Send `null` (do not send 0) when there is no data. LE8 ignores 0, but 0 would display as "0 小时".
- **Dedupe iPhone vs Watch:** rely on `HKStatisticsCollectionQuery` cumulative sums (source-priority merge). `/health/import` does not do this, so after enabling native sync, warn users not to keep using Shortcut or export import for the same days.
- **Weights:** send every sample with its own timestamp. The server picks the last of the day by time for scoring, so there is no need to pre-aggregate.
- **Blood pressure:** one reading per correlation. The server averages the last 3 readings in 90 days.

### 12.4 Workouts → `exercises`
- Duration: `workout.duration / 60` (min, 1–1440). Distance: `totalDistance` in km (or the `statistics(for: distanceWalkingRunning/Cycling/Swimming).sumQuantity()`). `avg_hr`: `statistics(for: .heartRate)?.averageQuantity()`. `device_kcal`: `statistics(for: .activeEnergyBurned)?.sumQuantity()` (`totalEnergyBurned` is deprecated on iOS 18). `met`: `HKMetadataKeyAverageMETs` if present, else the activity's table MET.
- **`in_device` rule:** true when the workout has active-energy samples in HealthKit (`device_kcal > 0`) **and** the day's `active_kcal` being synced is > 0, because in that case the energy is already inside the day total. Otherwise false, and the server adds the net MET kcal on top. See §8.1.
- `HKWorkoutActivityType` → `activity_key` (client-side table; v = average speed km/h = distance/duration):
| HK type | activity_key |
|---|---|
| `.walking` | v<4.5 walk_slow; <5.5 walk_moderate; <6.4 walk_brisk; else walk_very_brisk (no distance → walk_moderate) |
| `.running` | v<9 jogging; <11.5 run_10kmh; <14.5 run_13kmh; else run_16kmh (no distance → jogging) |
| `.cycling` | indoor (`HKMetadataKeyIndoorWorkout`) → cycle_stationary; v<19.5 cycle_leisure; <22.5 cycle_moderate; else cycle_vigorous |
| `.swimming` | open water location → swim_open_water; pool: v<2.4 swim_freestyle_slow; <3.4 swim_freestyle_medium; else swim_freestyle_fast; unknown → swim_leisure |
| `.hiking` | hiking |
| `.stairClimbing`, `.stairs` | stairs |
| `.jumpRope` | jump_rope |
| `.basketball` | basketball |
| `.soccer` | soccer |
| `.badminton` | badminton |
| `.tennis` | tennis_singles |
| `.tableTennis` | table_tennis |
| `.yoga` | yoga |
| `.pilates` | pilates |
| `.traditionalStrengthTraining`, `.coreTraining` | strength_moderate |
| `.functionalStrengthTraining` | strength_vigorous |
| `.crossTraining`, `.mixedCardio` | circuit |
| `.highIntensityIntervalTraining` | hiit |
| `.elliptical` | elliptical |
| `.rowing` | rowing_machine |
| `.cardioDance`, `.dance` | aerobic_dance |
| `.socialDance` | dance_social |
| `.flexibility`, `.cooldown`, `.mindAndBody` | other_light |
| anything else | other_moderate (or other_vigorous when METs ≥ 6) |
- description: the Chinese name of the HK type (for example `户外跑步`, `泳池游泳`). Fall back to the activity `zh`.

### 12.5 Phase 0: what works today with NO server change (and its caveats)
1. Daily totals: `POST /health/ingest` (with the `nla_` token) once per date with `{date, steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours}`. Caveats:
   - one HTTP call per day (365 calls for a backfill)
   - stand_hours cannot be sent
   - manual values are overwritten
   - the source shows as `iPhone 快捷指令` on the web
   - no range validation, so the client must validate
2. Weight, fat, waist, BP: **do not** use ingest weight (duplicates, wrong time). Use `POST /body` with the sample's `date`/`time`. The row is stored as `manual`, and the client must keep a **local ledger HK UUID → server id** to avoid re-posting and to `DELETE /body/{id}` when HealthKit deletes the sample. If the ledger is lost on reinstall, every sample is duplicated.
3. Workouts: `POST /exercises` with `{date, time, activity_key, met, duration_min, distance_km, description, in_device}`. Needs the same local ledger. `avg_hr` and `device_kcal` are lost. Rows are labelled `manual`.

### 12.6 What is missing server-side for a robust native sync
1. **Batch multi-day upsert:** ingest takes one date per call, and each call invalidates separately.
2. **Idempotency / external ids:** no column stores HealthKit sample or workout UUIDs, so resubmits duplicate rows and HealthKit-side deletions cannot be propagated.
3. **Correct timestamps:** ingest weight uses server "now". Commit workouts use "now". Neither stores workout start or end.
4. **Missing fields:** ingest has no stand_hours, waist, BP, workouts, avg_hr or device_kcal.
5. **Source tagging and manual protection:**
   - ingest and import overwrite manual fields and relabel the whole row.
   - `PUT /activity` (web edit) sets `manual` on all fields, but there is no field-level provenance, so a later sync cannot tell which fields the user really changed.
6. **Ability to clear a value** (for example sleep deleted in HealthKit): only `PUT /activity` can, and it nulls everything else.
7. **Tombstones:** a row the user deletes on the web would be re-created by a full re-sync.
8. **Sync state:** there is no server record of the last sync per device or kind, which would show "上次同步" and drive backfill decisions across devices or reinstalls.
9. **Dedupe against legacy sources:** shortcut and export rows coexist with HealthKit rows for the same weigh-in or day.
10. **Payload limits:** JSON is capped at 2 MB, so the client must chunk (≈90 days or ≈1000 samples per call).

### 12.7 Proposed ADDITIVE server design
All existing endpoints, columns and web behavior stay unchanged. New columns are nullable, so `SELECT *` responses only gain extra keys, which the web ignores. New `source` value `healthkit`: the web body list already renders unknown sources as `苹果健康`. The activity hint falls back to `苹果健康导出`, which is acceptable; an optional one-word label tweak is possible but not required.

#### Migration v3 (append to `MIGRATIONS`)
```sql
ALTER TABLE body_metrics ADD COLUMN external_id TEXT;      -- HK sample UUID (BP: correlation UUID)
ALTER TABLE body_metrics ADD COLUMN source_name TEXT;      -- HKSource name, e.g. "Withings" / "XX 的 Apple Watch"
CREATE UNIQUE INDEX idx_body_ext ON body_metrics(user_id, external_id) WHERE external_id IS NOT NULL;

ALTER TABLE exercises ADD COLUMN external_id TEXT;         -- HKWorkout UUID
ALTER TABLE exercises ADD COLUMN source_name TEXT;
ALTER TABLE exercises ADD COLUMN started_at TEXT;          -- ISO-8601 with offset
ALTER TABLE exercises ADD COLUMN ended_at TEXT;
ALTER TABLE exercises ADD COLUMN hk_activity_type INTEGER; -- raw HKWorkoutActivityType for future re-mapping
CREATE UNIQUE INDEX idx_ex_ext ON exercises(user_id, external_id) WHERE external_id IS NOT NULL;

-- last values HealthKit wrote per day: lets sync update fields the user did not override
CREATE TABLE health_day_snapshots (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date TEXT NOT NULL,
  steps REAL, active_kcal REAL, resting_kcal REAL, distance_km REAL, exercise_min REAL, sleep_hours REAL, stand_hours REAL,
  synced_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, date)
);

-- rows deleted on the web (or in HK) must not be resurrected by a re-sync
CREATE TABLE health_tombstones (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  external_id TEXT NOT NULL,
  kind TEXT NOT NULL,                       -- body | exercise
  deleted_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, external_id)
);
CREATE TRIGGER trg_body_tomb AFTER DELETE ON body_metrics WHEN old.external_id IS NOT NULL
BEGIN INSERT OR IGNORE INTO health_tombstones (user_id, external_id, kind) VALUES (old.user_id, old.external_id, 'body'); END;
CREATE TRIGGER trg_ex_tomb AFTER DELETE ON exercises WHEN old.external_id IS NOT NULL
BEGIN INSERT OR IGNORE INTO health_tombstones (user_id, external_id, kind) VALUES (old.user_id, old.external_id, 'exercise'); END;

CREATE TABLE health_sync_state (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,                  -- client-generated install UUID
  device_name TEXT,
  kind TEXT NOT NULL,                       -- days | samples | workouts
  last_synced_at TEXT NOT NULL,
  min_date TEXT, max_date TEXT,
  cursor TEXT,                              -- opaque client cursor (e.g. base64 HKQueryAnchor), optional
  PRIMARY KEY (user_id, device_id, kind)
);
```
(The triggers live at the DB level, so the existing `DELETE /body/{id}` and `DELETE /exercises/{id}` code is untouched. They only fire for rows that have an `external_id`.)

#### `POST /api/v1/health/sync`, batched and idempotent (requireAuth: `nla_` token)
Request (every section optional; ≤2 MB; limits: days ≤ 400, samples ≤ 2000, workouts ≤ 500, deleted ≤ 2000):
```jsonc
{
  "device_id": "4F0C2E7A-…",                 // required, ≤64
  "device_name": "iPhone 16 Pro",            // optional, ≤60
  "timezone": "Asia/Shanghai",               // tz the client used for day keys; server echoes a warning if != profile tz
  "overwrite_manual": false,                 // true only after explicit user confirmation
  "days": [ {
    "date": "2026-10-02",                    // profile-tz local date
    "steps": 8532, "active_kcal": 412.3, "resting_kcal": 1620.4, "distance_km": 6.12,
    "exercise_min": 35, "stand_hours": 11, "sleep_hours": 7.25,
    // absent or null field = "HealthKit has no data, leave server value alone"
    "clear": ["sleep_hours"]                 // optional: fields HealthKit no longer has → set NULL (subject to manual protection)
  } ],
  "samples": [
    { "uuid": "8A1E…", "type": "body_mass",      "date": "2026-10-02", "time": "22:31", "start": "2026-10-02T22:31:05+08:00", "value": 68.2, "source_name": "Withings" },
    { "uuid": "…",     "type": "body_fat",       "date": "…", "time": "…", "value": 21.5 },     // percent 0–100
    { "uuid": "…",     "type": "waist",          "date": "…", "time": "…", "value": 82.0 },     // cm
    { "uuid": "<correlation uuid>", "type": "blood_pressure", "date": "…", "time": "…", "sbp": 118, "dbp": 76, "bp_treated": false }
  ],
  "workouts": [ {
    "uuid": "…", "date": "2026-10-02", "time": "18:05",
    "start": "2026-10-02T18:05:00+08:00", "end": "2026-10-02T18:50:12+08:00",
    "hk_activity_type": 37, "activity_key": "run_10kmh", "description": "户外跑步",
    "met": 9.3,                               // optional; default table MET
    "duration_min": 45.2, "distance_km": 7.4, "avg_hr": 152, "device_kcal": 480,
    "in_device": true, "source_name": "Apple Watch"
  } ],
  "deleted": ["uuid-1", "uuid-2"],            // HK deleted objects (from HKAnchoredObjectQuery deletedObjects)
  "cursors": { "days": null, "samples": "base64…", "workouts": "base64…" }  // optional, stored in health_sync_state
}
```
Validation per item: the same ranges as existing endpoints.
- days: `PUT /activity` ranges.
- body_mass 20–350, body_fat 2–70, waist 30–250, sbp 60–260, dbp 30–160 (BP needs **both** values).
- workouts: duration 1–1440, met 1–25, distance 0–1000, avg_hr 30–230, device_kcal 0–10000.
- `date` via `isDate`, `time` via `TIME_RE`, `uuid` ≤64.

An invalid item goes into `rejected` and **does not fail the batch**. All valid writes run in one `tx()`.

Server semantics:
- **days:** let `row` = the existing `activity_days` row and `snap` = `health_day_snapshots`. For each provided field f with a non-null value v:
  - no row → INSERT with `source='healthkit'`.
  - `row.source != 'manual'` (healthkit / apple_shortcut / apple_export / ai_screenshot) → set f = v and `source='healthkit'`.
  - `row.source == 'manual'` → set f = v **only if** `row.f IS NULL` or `row.f == snap.f` (the user has not changed what HealthKit last wrote) or `overwrite_manual`. Otherwise keep the value and report it in `kept_manual`. `source` stays `manual`.
  - `clear` fields follow the same protection rule, then become NULL.
  - Always UPSERT the snapshot with the new HealthKit values.
- **samples:** skip if `(user_id, uuid)` is in `health_tombstones`.
  - Otherwise `INSERT … ON CONFLICT(user_id, external_id) WHERE external_id IS NOT NULL DO UPDATE SET …` into `body_metrics` with `source='healthkit'`, `note=NULL`, mapping type → column (BP sets sbp, dbp and `bp_treated`).
  - Insert one row per sample. Weight and fat stay in separate rows; existing readers handle that.
- **workouts:** skip tombstoned UUIDs.
  - `met = met ?? ACTIVITY_MAP[activity_key].met` (an unknown key becomes `other_moderate`).
  - `kcal = round(netKcal(met, weightOn(getWeights(uid,date), date, profile.weight_kg), duration_min))`. Reuse the exact `/exercises` logic.
  - Upsert by `external_id` with `source='healthkit'`.
  - Report `possible_duplicates`: existing non-healthkit exercises on the same date with the same `activity_key` family and duration within ±20%. The server reports them and never auto-deletes.
  - Requires a profile (400 `请先完善个人档案`), as `/exercises` does.
- **deleted:** `DELETE FROM body_metrics|exercises WHERE user_id=? AND external_id IN (…)`. The triggers record tombstones.
- **Invalidation:** call `invalidateFrom(uid, minChangedDate)` once at the end. It covers daily scores and stale stored reports.
- **State:** upsert `health_sync_state` for each section present (`last_synced_at = now`, min/max date, cursor).

Response 200:
```jsonc
{
  "ok": true,
  "timezone": "Asia/Shanghai", "server_today": "2026-10-03",
  "timezone_mismatch": false,
  "days":     { "upserted": 30, "unchanged": 2, "kept_manual": [ { "date": "2026-10-01", "fields": ["sleep_hours"] } ], "rejected": [ { "date": "2026-13-01", "error": "日期格式不正确" } ] },
  "samples":  { "inserted": 12, "updated": 0, "skipped_tombstoned": 1, "rejected": [ { "uuid": "…", "error": "体重不能大于 350" } ] },
  "workouts": { "inserted": 3, "updated": 1, "skipped_tombstoned": 0, "rejected": [], "possible_duplicates": [ { "uuid": "…", "exercise_id": 812, "description": "游泳" } ] },
  "deleted":  { "body": 1, "exercises": 0, "not_found": 2 },
  "invalidated_from": "2026-09-03"
}
```
Errors: 400 only for whole-request problems (`device_id 不能为空`, payload > limits, `请先完善个人档案` when workouts are present without a profile). 401 and 413 as usual.

#### `GET /api/v1/health/sync/state`
Response:
```jsonc
{ "timezone": "Asia/Shanghai", "server_today": "2026-10-03",
  "devices": [ { "device_id": "…", "device_name": "iPhone 16 Pro",
      "kinds": { "days": { "last_synced_at": "2026-10-03 01:02:03", "min_date": "2025-10-03", "max_date": "2026-10-03", "cursor": null },
                 "samples": { … }, "workouts": { … } } } ],
  "counts": { "days": 365, "body": 120, "workouts": 80 },     // rows with source='healthkit'
  "legacy_sources": { "apple_shortcut_days": 12, "apple_export_days": 300 } }
```

#### Optional `POST /api/v1/health/sync/unlink`
Body `{"device_id": "…", "delete_data": false}`. Deletes the state rows. When `delete_data` is true, it also deletes `body_metrics`/`exercises` rows with `source='healthkit'` (tombstones are not needed here, so remove the tombstones those deletes create) and nulls the healthkit-written fields of `activity_days` using the snapshots. Then invalidates. Response `{"ok": true, "deleted": {"body": n, "exercises": n, "days": n}}`.

#### Client sync loop (reference)
1. On launch, foreground, and `HKObserverQuery` background delivery (needs the `com.apple.developer.healthkit.background-delivery` entitlement), read `GET /health/sync/state` once per session.
2. Days: statistics-collection queries for `[max(lastSyncedMaxDate−7, today−365) … today]` in the profile tz; chunk 90 days per call.
3. Samples and workouts: `HKAnchoredObjectQuery` per type with locally persisted anchors (also echoed to `cursors`). Send new objects plus `deletedObjects` UUIDs; chunk to ≤1000 per call.
4. Persist anchors only after a 200 response. Retries are safe because every write is idempotent by date or UUID.
5. HealthKit is unreadable while the device is locked (`errorDatabaseInaccessible`). Defer to the next foreground.

---

## 13. Risks and surprises for a native client
1. **Plain HTTP:** the production server has no TLS, so bearer tokens and health data travel in clear text. ATS needs `NSAllowsArbitraryLoads` (IP host). A domain with HTTPS should be set up before App Store review.
2. **A cookie overrides Bearer** (§1.2). Disable cookies in URLSession.
3. **Truthy booleans:** the string `"false"` is true, so always encode real booleans. Response flags are 0/1 integers.
4. `steps` can be fractional (ingest), so decode it as Double.
5. **`/health/ingest`:**
   - weight creates a duplicate row on every call, timestamped with server "now"
   - `body_fat_pct ≤ 1` is multiplied by 100
   - no range checks, negatives accepted
   - overwrites manual fields
   - relabels the row `apple_shortcut`
   - no stand_hours
6. **`/health/import`:**
   - dedupe is "max per source", not HealthKit's merge
   - skips sleep, stand, BP, waist and workouts
   - weight is the last record of the day in file order
   - dates come from the export's `startDate` string, not the profile tz
   - runs synchronously, so long uploads can time out
7. **`/activity/commit`:**
   - workout `time` = now
   - body time defaults to `22:00`
   - waist unsupported
   - a dbp-only body is dropped silently
   - cannot clear a field
   - the OpenAPI omits `source`, `body.bp_treated` and `body.time`
8. `PUT /activity/{date}` nulls every field you omit.
9. `POST /body` accepts sbp without dbp, which LE8 ignores. Validate pairs client-side.
10. `DELETE /labs/{id}` never 404s and is missing from the OpenAPI. Labs are always mg/dL; mmol conversion is client-side (×38.67 cholesterol, ×18 glucose).
11. **`/preview`:** returns 400 for half-typed workouts, and activity errors use English keys (`steps不能大于 200000`). Debounce and swallow errors as the web does.
12. **AI differences:** the AI path clamps MET to 1–20 (manual allows 1–25) and nulls `resting_kcal` below 300. The AI date may differ from the requested date (`date_from_image`); commit with `draft.date`.
13. **Uploads:** HEIC is rejected, so transcode to JPEG. More than 6 files returns a 500.
14. **Energy model:**
    - `resting_kcal` ≤ 500 is ignored
    - `in_device=1` workouts vanish from the energy total on days without device active energy
    - exercise `kcal` is frozen at insert time (a later weight change does not recompute it)
15. **Unused by scoring:** `body_fat_pct`, `stand_hours`, `distance_km`, `avg_hr` and `device_kcal` are display only.
16. **Web source labels:** `ai_screenshot` (and the proposed `healthkit`) show as `苹果健康导出` in the web's activity hint. The iOS app should map them properly: manual→手动, ai_screenshot→AI 识别, apple_shortcut→iPhone 快捷指令, apple_export→苹果健康导出, healthkit→苹果健康.
17. **AI jobs:** jobs die on server restart (`服务器重启，任务中断，请重试`) and are purged after 7 days. Concurrency is 2 server-wide.
