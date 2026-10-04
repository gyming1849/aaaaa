# 食迹 NutriLog iOS: spec index

This is the entry point to the specs in this folder. They are written for the native SwiftUI iOS client, which talks to the existing
Node/Express server at `http://45.63.23.52:8787/api/v1`. All the specs were derived by reading the source in
the repository root (read-only). Where the live OpenAPI (`openapi.live.json`) and the code disagree, **the code
(and therefore these specs) wins**.

Last completeness review: 2026-10-03. Section 6 lists what that review checked and fixed.

---

## 1. Files and reading order

| # | File | Scope | Read it for |
|---|---|---|---|
| 1 | `api-auth-account.md` | Routing, middleware, auth model (cookie / `nla_` app token / `nl_` personal token), register/login/token, sessions, `/auth/me`, profile, targets, settings and sharing, `/users` | Networking layer, login, onboarding, settings |
| 2 | `api-meals-ai-foods.md` | Nutrient / food-group / hazard / category vocabularies, uploads, AI jobs, meals, water, food library, `/preview` (meal side), client-side item math | Log Meal, Food library, AI polling |
| 3 | `api-body-health.md` | Body metrics, labs, daily activity, workouts, AI activity flow, `/preview` (activity side), `/activity/commit`, `/health/ingest`, `/health/import`, energy model, MET table, **HealthKit sync design and proposed additive endpoints** | Body screen, HealthKit integration |
| 4 | `api-reports-trends-standards.md` | `?user=` access control, `/day`, `DailyScore`, `Targets`, `HealthIndices` (LE8 / MEPA / WCRF), `/period`, `/period/summary`, `/reports`, `/trends`, `/users`, standards (`/standards/meta`, `/standards/dri`), docs endpoints, scheduler, caching | Today, Trends, Reports, Community, Standards |
| 5 | `web-features-today-log-body.md` | Web UI behaviour, layout and verbatim strings for Today, Log Meal (ItemEditor, FoodPicker, SaveFoodModal, ImpactPreview), ActivityRecognizer and Body | Building those screens |
| 6 | `web-features-trends-reports-misc.md` | Navigation, theme tokens, charts, Trends, Reports, LE8/WCRF cards, Community, Settings, ProfileForm, Onboarding, Login, Foods, Standards; Appendix A = `web/src/types.ts` verbatim; Appendix B = server types; Appendix C = suggested Swift `Codable` models; Appendix D = shared strings and errors; Appendix E = lucide → SF Symbols | Building those screens, Swift models |
| – | `openapi.live.json` | Live OpenAPI 3.1 snapshot from production | Reference only; it is shallow and misses 4 routes (section 2.2) |

---

## 2. Endpoint table (all 58 routes registered on the server)

Every route is mounted twice, under `/api/v1` and `/api`, with identical behaviour. The app uses **`/api/v1`**. Paths below are
relative to that prefix.

**Auth legend**
- **none**: public.
- **user**: `requireAuth`. Send `Authorization: Bearer nla_…`. A web cookie also works, but the iOS client must disable cookies (auth §2.2).
- **user|nl**: `requireAuthOrToken`, which also accepts the personal token `Bearer nl_…` or `?token=nl_…`.
- **opt**: no auth is required, but a presented token is used.

**Column legend**
- **Web**: whether `web/src` calls the route (Y/N).
- **iOS**: recommended use. *core* = needed for feature parity; *new* = not used by the web but useful for a native-only screen; *avoid* = do not use from iOS; *optional* = situational.
- **Spec**: the primary file and section, followed by secondary references. Abbreviations: `auth` = api-auth-account.md, `meals` = api-meals-ai-foods.md, `body` = api-body-health.md, `rep` = api-reports-trends-standards.md, `web1` = web-features-today-log-body.md, `web2` = web-features-trends-reports-misc.md.

### 2.1 Server routes

| # | Method | Path | Auth | Web | iOS | Spec (primary → secondary) |
|---|---|---|---|---|---|---|
| | **index.ts / docs.ts** | | | | | |
| 1 | GET | `/health` | none | N | core (reachability) | auth §3.1 |
| 2 | GET | `/openapi.json` | none | N | avoid (dev only) | rep §12 |
| 3 | GET | `/docs` | none | N | avoid (Swagger HTML) | rep §12 |
| | **routes/account.ts** | | | | | |
| 4 | POST | `/auth/register` | none | Y | core (**always with `device_name`**) | auth §3.2 → web2 §5.8 |
| 5 | POST | `/auth/token` | none | N | **core (iOS login)** | auth §3.3 → web2 §6.1 |
| 6 | POST | `/auth/login` | none | Y | avoid (sets a cookie) | auth §3.4 |
| 7 | POST | `/auth/logout` | opt (never 401) | Y | core | auth §3.5 |
| 8 | GET | `/auth/sessions` | user | N | new (device list) | auth §3.6, §4.7 |
| 9 | DELETE | `/auth/sessions/:id` | user | N | new (device list) | auth §3.7 |
| 10 | GET | `/auth/me` | user | Y | core (bootstrap) | auth §3.8, §4.4 → web1 §1.1, web2 §1.7 |
| 11 | POST | `/auth/password` | user | Y | core | auth §3.9 |
| 12 | PUT | `/profile` | user | Y | core (**full replace**) | auth §3.10, §4.3 → web2 §5.6 |
| 13 | GET | `/profile/targets` | user | Y | core | auth §3.11, §4.6 → rep §4 |
| 14 | PUT | `/settings` | user | Y | core (**send all 5 fields**) | auth §3.12 → web2 §5.5 |
| 15 | POST | `/settings/token` | user | Y | optional (Shortcuts users only) | auth §3.13 → web1 §7.2 Row 4 |
| | **routes/body.ts** | | | | | |
| 16 | GET | `/body` | user | Y | core | body §3.1, §2.1 |
| 17 | POST | `/body` | user | Y | core (also HealthKit Phase 0) | body §3.2 |
| 18 | DELETE | `/body/:id` | user | Y | core | body §3.3 |
| 19 | GET | `/labs` | user | Y | core | body §3.4, §2.4 |
| 20 | POST | `/labs` | user | Y | core | body §3.5 |
| 21 | DELETE | `/labs/:id` | user | Y | core (not in OpenAPI) | body §3.6 |
| 22 | GET | `/activity` | user | Y | core | body §3.7, §2.2–2.3 |
| 23 | PUT | `/activity/:date` | user | Y | core (**nulls omitted fields**) | body §3.8 |
| 24 | POST | `/exercises` | user | Y | core (also HealthKit Phase 0) | body §3.9 |
| 25 | PATCH | `/exercises/:id` | user | Y | core | body §3.10 |
| 26 | DELETE | `/exercises/:id` | user | Y | core | body §3.11 |
| 27 | POST | `/ai/activity` | user | Y | core (async job) | body §4.2, §4.4 → meals §1.15 |
| 28 | POST | `/preview` | user | Y | core (debounced, no writes) | body §4.5 (activity) **and** meals §2.8 (meal) → web1 §2.1, §3.7 |
| 29 | POST | `/activity/commit` | user | Y | core | body §4.6 → web1 §2.3 |
| 30 | POST | `/health/ingest` | user\|nl | N (Shortcut) | optional (HealthKit Phase 0 daily totals only) | body §5 → auth §3.16 |
| 31 | POST | `/health/import` | user (multipart) | Y | optional (export.zip import; superseded by HealthKit) | body §6 |
| | **routes/log.ts** (router-level `requireAuth`) | | | | | |
| 32 | POST | `/uploads` | user (multipart `photos`) | Y | core (**JPEG only, no HEIC**) | meals §2.1 |
| 33 | GET | `/uploads/:id` | user | Y (`<img src>`) | core (authenticated image loader) | meals §2.2 (not in OpenAPI) |
| 34 | GET | `/ai/status` | user | N | optional (`/auth/me.ai` suffices) | meals §2.3 |
| 35 | POST | `/ai/meal` | user | Y | core (async job) | meals §2.4, §1.13 |
| 36 | POST | `/ai/food` | user | Y | core (async job) | meals §2.5, §1.14 |
| 37 | POST | `/ai/exercise` | user | N | avoid (legacy; use `/ai/activity`) | meals §2.6 → body §4.7 |
| 38 | GET | `/ai/jobs/:id` | user | Y | core (poll every 1.5 s) | meals §2.7 → rep §7.2, auth §3.17 |
| 39 | POST | `/meals` | user | Y | core | meals §2.9, §1.8 → web1 §2.2 |
| 40 | PUT | `/meals/:id` | user | Y | core (ignores photos / ai_summary) | meals §2.10 |
| 41 | DELETE | `/meals/:id` | user | Y | core | meals §2.11 |
| 42 | GET | `/meals/recent-items` | user | N | new (quick-add chips) | meals §2.13 |
| 43 | POST | `/water` | user | Y | core | meals §2.14 |
| 44 | GET | `/foods` | user | Y | core | meals §2.15, §1.12 |
| 45 | GET | `/foods/:id` | user | N | new (deep link / refresh) | meals §2.16 |
| 46 | POST | `/foods` | user | Y | core | meals §2.17 → web2 §6.5 |
| 47 | PUT | `/foods/:id` | user (owner) | Y | core (**full replace**) | meals §2.18 |
| 48 | DELETE | `/foods/:id` | user (owner) | Y | core | meals §2.19 |
| 49 | POST | `/foods/:id/item` | user | Y | core | meals §2.20, §1.10 |
| 50 | POST | `/foods/from-item` | user | Y | core | meals §2.21 |
| | **routes/reports.ts** (router-level `requireAuth`) | | | | | |
| 51 | GET | `/day/:date` (`?user=`) | user | Y | core | rep §2 (+ §3 DailyScore, §4 Targets, §5 HealthIndices, §1 access) → web1 §1.2, §4 |
| 52 | GET | `/trends` (`?start&end&user`) | user | Y | core | rep §10 → web2 §5.1, §6.3 |
| 53 | GET | `/period` (`?start&end&user`) | user | Y | core | rep §6 → web2 §5.2, §6.3 |
| 54 | POST | `/period/summary` | user | Y | core (async job; gate on `ai.provider != mock`) | rep §7 |
| 55 | GET | `/reports` | user | N | new (report history) | rep §8 |
| 56 | GET | `/users` | user | Y | core (Community, Settings picker) | rep §11 → auth §3.14, §4.5 |
| 57 | GET | `/standards/meta` | user | Y | core (cache per `version`) | rep §9.0–9.8 |
| 58 | GET | `/standards/dri` | user | Y | core | rep §9.4 |

Count check: index/docs 3, account 12, body 16, log 19, reports 8, for a total of **58**. All 58 routes are documented with request and
response shapes.

### 2.2 OpenAPI coverage gaps
The live OpenAPI lists 54 operations. These 4 routes are missing from it but exist in code and are documented here: `DELETE /labs/{id}`, `GET /uploads/{id}`,
`GET /openapi.json` and `GET /docs`. The OpenAPI schemas are also shallow (auth §0 intro, rep §15).

### 2.3 Behaviour that applies to every route
- **Errors** are always `{"error": "<中文>"}`. Map statuses as in auth §1.3 and §7, rep §0.3, and meals §5.
- **Unknown path:** 401 without auth and `404 接口不存在` with auth (auth §1.4).
- **Bodies:** always send `Content-Type: application/json` and at least `{}` on POST, PUT and PATCH. Express 5 leaves `req.body` undefined otherwise, which gives a 500, and `PUT /settings` silently resets sharing (auth §0, §3.12).
- **Cookies:** a stored `nl_session` cookie overrides the Bearer token. Use a cookieless `URLSession` (auth §2.2).
- **Async AI jobs** (`/ai/meal`, `/ai/food`, `/ai/activity`, `/ai/exercise`, `/period/summary`) all return `{job_id}` and share the queue, which has a global concurrency of 2. Poll `GET /ai/jobs/:id` (meals §2.7).
- **Transport:** production uses plain HTTP on a bare IP, so ATS needs `NSAllowsArbitraryLoads` (auth §8 item 7).

### 2.4 Proposed ADDITIVE server endpoints (none exist yet; the web UI must stay unchanged)

| Proposal | Purpose | Where specified |
|---|---|---|
| `POST /health/sync` | Batched, idempotent HealthKit upload of days, samples, workouts and deletions, with manual-edit protection and tombstones. Includes migration v3. | body §12.7 (→ web1 §9 item 1) |
| `GET /health/sync/state` | Last sync per device and kind, plus counts | body §12.7 |
| `POST /health/sync/unlink` (optional) | Remove a device and optionally its `healthkit` rows | body §12.7 |
| `DELETE /account` | In-app account deletion (**App Store 5.1.1(v) blocker**) | auth §8 item 1 |
| `current` flag on `GET /auth/sessions` | Mark "本机" in the device list | auth §8 item 2 |
| `GET /auth/config` | Whether registration is open or needs an invite code | auth §8 item 3 |
| `POST /auth/refresh` or sliding expiry | Avoid forced re-login after 365 days | auth §8 item 4 |
| `revoke_others` on `/auth/password` | Sign out other devices | auth §8 item 5 |
| Prefer Bearer over cookie | Robustness | auth §8 item 6, web2 §7 item 1 |
| `GET /meals?start&end` | Meal history without scoring | meals §7.3 |
| `PATCH /meals/:id` or `update_photos` | Edit photos and `ai_summary` | meals §7.3 |
| `DELETE /ai/jobs/:id`, `queue_position` | Cancel a job, show queue position | meals §7.3 |
| Map multer count/field errors to 400 | Better errors | meals §7.3 |
| Pass `category` through `/preview` | Correct `fastFoodMeals` in previews | meals §7.3 |
| `GET /uploads/:id?user=` | Photos for full-share viewers | rep §16 P1 |
| `GET /standards/rules` | Serve the rule texts as JSON | rep §16 P2 |
| `GET /standards/dri?format=rows` | Ordered DRI rows | rep §16 P3 |
| `/trends?fields=core` plus gzip | Smaller payloads (up to ~3 MB today) | rep §16 P4, web2 §7 item 17 |
| `ORDER BY created_at DESC` in the `/period` summary lookup | Deterministic `aiSummary` | web2 §7 item 7 |

---

## 3. Screens (web → iOS)

Web routes are listed in web2 §2.1. The recommended iOS tab bar is **今日 / 趋势 / [+ 记一餐] / 身体 / 更多** (web2 §2.3–2.4).

| # | Screen (web title) | Web source | Primary UI spec | API calls (row # in §2.1) | Notes |
|---|---|---|---|---|---|
| 1 | Login / Register (欢迎回来 / 创建账号) | `pages/Login.tsx` | web2 §5.8; strings auth §6 | 5 (iOS login), 4, 10 | iOS uses `/auth/token`, never `/auth/login`; always shows the optional invite field |
| 2 | Onboarding (你好，{name}！先建立个人档案) | `pages/Onboarding.tsx` + `components/ProfileForm.tsx` | web2 §5.7, §5.6; auth §5 | 12, 10 | Shown while `me.profile == null`; HealthKit can prefill sex, birth date, height and weight |
| 3 | App shell / navigation | `App.tsx`, `lib/app.tsx`, `main.tsx` | web2 §1.7, §2; web1 §8 | 10, 57 | Bootstrap order, toasts, 401 handling |
| 4 | Today 今日概览 | `pages/Today.tsx` | web1 §4 (+ §3 shared components) | 51, 43, 41, 57 | Sections A–F: score ring, energy, highlights, key limits, LE8/WCRF, hazards, meals, water, activity, detail tabs |
| 5 | Member read-only day (@{username} 的记录) | `pages/Today.tsx` at `/u/:username` | web1 §4; rep §1 | 51 with `?user=` | Hide edits; `full=false` hides meals and messages; photos 404 for viewers |
| 6 | Log Meal 记一餐 / 编辑这一餐 | `pages/LogMeal.tsx` | web1 §5; meals §3, §4, §6.1 | 32, 35, 38, 28, 39, 40, 44, 49, 50, 51 | Phases: input → analyzing → review → save |
| 6a | ItemEditor (调整 panel) | `components/ItemEditor.tsx` | web1 §5.3; meals §4.3, §6.2 | – | Editing nutrients unlinks `food_id` |
| 6b | FollowUp (AI 想确认：) | `pages/LogMeal.tsx` | web1 §5.4 | 35, 38 | |
| 6c | FoodPicker modal (从食物库添加) | `pages/LogMeal.tsx` | web1 §5.6; meals §4.5 | 44, 49 | |
| 6d | SaveFoodModal (存入食物库) | `pages/LogMeal.tsx` | web1 §5.7; meals §2.21 | 50 | |
| 6e | ImpactPreview (合并预览) | `components/ActivityRecognizer.tsx` (shared) | web1 §3.7; meals §6.4 | 28 | Shared by Log Meal and ActivityRecognizer |
| 7 | ActivityRecognizer (填写 {date} 的活动与身体数据 / AI 识别活动与身体数据) | `components/ActivityRecognizer.tsx` | web1 §6; body §4, §11 | 32, 27, 38, 28, 29 | Manual and AI modes; commit uses `draft.date` |
| 8 | Body 身体与运动 | `pages/Body.tsx` | web1 §7; body §11 | 16–26, 52, 15, 31 | Cards: weight + 90-day chart, exercises, steps/activity + 30-day chart, labs, Apple Health |
| 8a | Apple Health card + Shortcuts guide modal (连接苹果健康 / iPhone 快捷指令设置步骤) | `pages/Body.tsx` | web1 §7.2 Row 4; body §5, §6 | 15, 31 | **Replace on iOS** with a native HealthKit sync screen (screen 18) |
| 9 | Trends 健康趋势 (own and `/u/:username/trends`) | `pages/Trends.tsx` | web2 §5.1; rep §10.3 | 52, 53, 13 | Client-side bucketing, 11 chart/table cards, calendar heatmap |
| 10 | Reports 周期报告 | `pages/Reports.tsx` | web2 §5.2 (AI card §5.2.5); rep §6–7 | 53, 54, 38 | 周报 defaults to last week; 月报 to the current month |
| 11 | LE8 card, MEPA modal, WCRF card, TotalParts | `components/HealthIndices.tsx`, `components/TotalScore.tsx` | web2 §5.3; web1 §3.4–3.6; rep §5 | – | Shared by Today, Trends and Reports |
| 12 | Community 社区 | `pages/Community.tsx` | web2 §5.4; rep §11; auth §3.14 | 56 | Tapping a shared card opens screen 5 |
| 13 | Settings 设置 (tab "更多") | `pages/Settings.tsx` | web2 §5.5; auth §6 | 56, 14, 11, 7, 12 | Quick links to Reports, Foods, Community and Standards; theme; AI banner; password |
| 14 | ProfileForm 个人档案 | `components/ProfileForm.tsx` | web2 §5.6; auth §3.10, §5 | 12 | Used by Onboarding and Settings |
| 15 | Foods 食物库: list, detail, AI lookup, editor | `pages/Foods.tsx` | web2 §5.9; meals §6.5 | 44, 46–48, 36, 38, 32 | Full-replace PUT; `aliases` is a string in responses and an array in requests |
| 16 | Standards 标准库 (tabs mine / dri / hazards / hei / met / rules / sources) | `pages/Standards.tsx` | web2 §5.10; rep §9 (rules text §9.9) | 13, 58, 57 | Deep link `?tab=rules` from Today's "评分依据" |
| 17 | Shared UI kit: Meter, ScoreRing, Modal, DateNav, Seg, IarcChip, SourceLinks, StatTile, Empty, Loading, Toast, Banner, charts, theme | `components/ui.tsx`, `components/EChart.tsx`, `lib/*.ts` | web1 §0.3–0.7, §3; web2 §3–4, Appendix E | – | Design tokens light/dark: web1 §0.4, web2 §3.2 |
| **iOS-only (new)** | | | | | |
| 18 | 苹果健康同步 (HealthKit sync settings and status) | – | body §12 (types map, units, aggregation, workouts, Phase 0, proposed sync API) | 30 or 17/24 (Phase 0); proposed `/health/sync` | Replaces web screen 8a |
| 19 | 登录设备 (device / session list) | – | auth §3.6–3.7, §8.2 | 8, 9 | No web equivalent |
| 20 | 删除账号 (account deletion) | – | auth §8 item 1 | proposed `DELETE /account` | Required for App Store review |
| 21 | 历史报告 (report history, optional) | – | rep §8 | 55, then 53 | |

---

## 4. Shared data types: where each is defined

| Type | Defined in | Also in |
|---|---|---|
| `Me`, `MeUser`, `PublicUser`, `Profile`, `Condition` | auth §4.1–4.4 | web1 §1.1, web2 §6.1 |
| `Targets` (incl. `amdr.n6/n3`, `limits` table) | auth §4.6 | rep §4, web1 §1.5 |
| `Session` | auth §4.7 | web2 §6.1 |
| `CommunityUser` | auth §4.5 | rep §11, web2 §6.2 |
| NutrientVector (43 keys), FoodGroupVector (22), categories, NOVA, meal types, hazards (15) | meals §1.1–1.7 | rep §9.1–9.3, web2 Appendix B.4 |
| Meal item request (`cleanItem`) | meals §1.8 | web1 §2.2 |
| Meal / meal item response | meals §1.9, §1.11 | rep §2.3 |
| `DraftItem`, `MealDraft`, `FoodDraft`, other job results | meals §1.10, §1.13–1.15 | web2 Appendix A |
| `Food` | meals §1.12 | web2 §6.5 |
| `Job` (`/ai/jobs/:id`) | meals §2.7 | rep §7.2, web1 §1.9 |
| `ActivityDraft` | body §4.4 | meals §1.15, web1 §1.8 |
| Raw rows `BodyMetric`, `ActivityDay`, `Exercise`, `LabResult` | body §2.1–2.4 (Swift §2.7) | rep §2.4–2.6, web1 §1.7 |
| `DailyScore`, `CompositeScore`, `ScoreItem` catalogue, `HazardResult`, `EnergyResult`, `MarResult` | rep §3 | body §10, meals §1.16, web1 §1.3, web2 Appendix B.1 |
| `HealthIndices` (`Le8Result`, `MepaResult`, `WcrfResult`, `pa`) | rep §5 | body §10, web1 §1.4 |
| `DayResponse` | rep §2.2 | web1 §1.2 |
| `TrendDay` | rep §10.2 | web2 §6.3 |
| `PeriodScore`, `PeriodCheck`, `PeriodEnergy`, `WeeklySummary` | rep §6.2–6.4 | web2 §6.3 |
| Stored report row | rep §8 | web2 §6.3 |
| `Meta` (`NutrientDef`, `FoodGroupDef`, `HazardDef`, `HeiComponentDef`, `Activity`, `Source`, …) | rep §9.0 | web2 §6.6, web1 §0.7 |
| DRI tables | rep §9.4 | web2 §6.6 |
| MET table (46 activities) | body §9.1 | rep §9.5 |
| Web `types.ts` (verbatim, checked identical to source) | web2 Appendix A | – |
| Suggested Swift `Codable` models | web2 Appendix C | body §2.7 |

---

## 5. Cross-cutting iOS must-dos (each detailed in the referenced section)

1. Use a cookieless `URLSession` with `Authorization: Bearer nla_…`, `Content-Type: application/json` and a `{}` body on every POST, PUT and PATCH (auth §2.2, §0).
2. Treat `me.today` and `profile.timezone` as the source of "today" and of day keys, including HealthKit day buckets (auth §3.8, body §12.3).
3. Decode keys verbatim, with no `.convertFromSnakeCase`. Decode measurements as `Double`. DB-row flags are `0/1` integers (rep §0.5, body §1.4).
4. Full-replace endpoints (`PUT /profile`, `PUT /settings` sharing fields, `PUT /foods/:id`, `PUT /activity/:date`) must round-trip every field.
5. Photos: upload JPEG with a matching filename extension, at most 6 per request and 12 MB each. Fetch with the Bearer header (meals §2.1–2.2).
6. AI jobs: persist `job_id`, poll every 1.5–2 s, and expect several minutes and server-restart errors (meals §2.7).
7. Hide the `饮水` water pseudo-meal from meal lists (meals §1.11).
8. When an item's nutrients, groups or hazards are hand-edited, set `food_id = null` (meals §1.8, §4.3).
9. Avoid double counting energy from HealthKit workouts with `in_device` (body §8.1, §12.4).
10. Production is plain HTTP on an IP, which needs an ATS exception. Plan for a domain with HTTPS (auth §8 item 7).

---

## 6. Completeness review log (2026-10-03)

**Method**
1. Enumerated every `router.get/post/put/patch/delete` call in `server/src/routes/*.ts`, plus the `app.get`/`app.use` mounts in `server/src/index.ts`: 58 routes.
2. Enumerated every `api.get/post/put/patch/del`, `uploadPhotos`, `waitJob` and `<img src>` call in `web/src`: 46 distinct method+path uses. Every one maps to a documented route.
3. Matched each route to a spec section (table in §2.1). All 58 have request and response shapes documented.
4. Spot-checked more than 20 documented shapes against source. All matched, apart from the errors listed under "Fixed" below:
   - `/auth/token`, `/auth/sessions`, `PUT /profile` validation, `PUT /settings`
   - `POST /body`, `POST /labs`, `PUT /activity/:date`, `POST /exercises`, `/preview`, `/activity/commit`, `/health/ingest`, `/health/import`
   - `/uploads`, `/ai/meal`, `/water`, `GET /foods`, `/foods/from-item`
   - `/period` (`PeriodScore` keys), `TrendDay`, `/users`, `/reports`
   - `DailyScore`, `HealthIndices`, `Le8Result`, `WcrfResult`, `MepaResult`, `CompositeScore`, `Targets`, `Profile`, `HazardDef`, `Activity`, `Source`, `ActivityDraft`, `FoodDraft`
   - web2 Appendix A, diffed byte-for-byte against `web/src/types.ts`: identical.
5. Screen coverage was checked by extracting all **997** Chinese UI string fragments from `web/src/**/*.ts(x)` and searching for each in the spec files. Before the fixes, 18 fragments were missing; after the fixes, **0** are missing. Every page and component file in `web/src/pages`, `web/src/components` and `web/src/lib` maps to a spec section (§3 above).
6. Server-side Chinese error strings in `routes/*.ts`, `auth.ts`, `lib/http.ts`, `ai/jobs.ts` and `ai/providers.ts` are all in the specs. The only exceptions are SQL, log and prompt literals, which are not user-facing.

**Gaps found and fixed**
- `web-features-trends-reports-misc.md`:
  - The nutrient count was stated as **45** in 6 places (Food detail table, TrendDay `totals`, `Food.per100`, FoodDraft `per100`, `meta.nutrients`, Appendix B.4 heading). It is **43** (verified: 43 `NUTRIENTS` + 22 `FOOD_GROUPS` = 65 keys in `standards/nutrients.ts`). Corrected.
  - It claimed that `FoodDraft` carries `model` on non-mock results (§6.5 and Appendix B.3). It does not (`ai/service.ts` `lookupFood`), so this was corrected to match `api-meals-ai-foods.md` §1.14.
  - TrendDay `hasData` was described as "≥ 1 meal logged". Corrected to "≥ 1 item **and** kcal > 0" (`scoring/daily.ts`).
  - The `/trends` "all" payload was stated as ~1 MB, which contradicted `api-reports-trends-standards.md` (~3 MB). Corrected to ~3 MB (~3 KB per logged day).
  - `POST /auth/logout` was labelled "(Auth)". Clarified that no auth is required and it never returns 401.
- `web-features-today-log-body.md`:
  - The **iPhone 快捷指令设置步骤** modal content (5 steps, the sample request body and the footnote) was not captured. Added verbatim to §7.2 Row 4.
  - The Today accessibility labels (`摄入 …，消耗 …，目标 … 千卡`, `蛋白质 …%，碳水 …%，脂肪 …%`, `问题`, `做得好`) were added to §4.3.
- `api-body-health.md` §1.1: "Unknown path → 404" was refined to note the 401-when-unauthenticated quirk.

**Cross-file consistency notes (no change needed)**
- `/preview` is documented in two places: body §4.5 (activity, body, workouts) and meals §2.8 (meal). The two describe complementary halves of one endpoint.
- The `/preview` debounce differs by caller and both values are correct: 350 ms in ActivityRecognizer and 400 ms in LogMeal.
- Swift `FoodDraft.model: String?` in web2 Appendix C is harmless because it is optional.
