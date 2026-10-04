# 食迹 NutriLog — Web feature spec for the native iOS client

## Part 2: Trends, Reports, Community, Settings, Foods, Standards, Onboarding, Login, navigation, theme

> Scope: `web/src/pages/{Trends,Reports,Community,Settings,Foods,Standards,Onboarding,Login}.tsx`, `web/src/components/{ProfileForm,HealthIndices,TotalScore,ui,EChart}.tsx`, `web/src/App.tsx`, `web/src/lib/*.ts(x)`, `web/src/types.ts`, `web/public/manifest.webmanifest`, and the server routes these screens call (`server/src/routes/{reports,account,log}.ts`, `server/src/auth.ts`, `server/src/ai/jobs.ts`, `server/src/scoring/*`).
> The Today, LogMeal and Body pages are out of scope here. They are covered by other spec files; this one only notes where they link.
>
> **Source of truth:** the code (read on 2026-10-03). The screenshots in `aaaaa/docs/screenshots/*.png` are slightly older than the code. For example, the first Trends tile in the screenshot reads "心血管健康 LE8", while the code shows "区间总分". The Reports screenshot has an older "周期总分：心血管健康 LE8" hero; the code renders a separate "本周总分" tile first. Follow the code for content and the screenshots for general visual density and style.
>
> Notation: `"…"` = verbatim Chinese string to reuse; `${x}` = interpolation; `fmt(v, d)` = the number formatter in §1.3; `?` after a type = nullable / may be `null` in JSON.

---

## 0. Table of contents

1. Global conventions (base URL, auth, errors, dates, number formatting, async jobs, bootstrap, toasts)
2. Navigation structure (App.tsx), with an iOS mapping
3. Design tokens and theme (colors light/dark, typography, shared UI components)
4. Chart conventions (lib/charts.ts), mapped to Swift Charts
5. Screens
   - 5.1 Trends 健康趋势
   - 5.2 Reports 周期报告
   - 5.3 Shared cards: Le8Card, MEPA modal, WcrfCard, TotalParts
   - 5.4 Community 社区
   - 5.5 Settings 设置
   - 5.6 ProfileForm 个人档案表单
   - 5.7 Onboarding 建档
   - 5.8 Login / Register 登录注册
   - 5.9 Foods 食物库 (list, detail, AI lookup, editor)
   - 5.10 Standards 标准库 (7 tabs)
6. API reference for every endpoint used by these screens
7. Risks, surprises, and suggested additive server changes
- Appendix A: `web/src/types.ts` (verbatim)
- Appendix B: server-side types that differ from or extend the web types (verbatim + notes)
- Appendix C: Suggested Swift `Codable` models
- Appendix D: Global / shared Chinese strings and server error messages
- Appendix E: Icon mapping (lucide → SF Symbols)

---

## 1. Global conventions

### 1.1 Base URL, prefixes, transport

- Production: `http://45.63.23.52:8787`. Every API route is mounted twice, at **`/api/v1/...`** and at `/api/...`. They behave identically. The iOS app should use `/api/v1`.
- The server is **plain HTTP on a bare IP address**. iOS App Transport Security blocks this by default. `NSExceptionDomains` does not accept IP addresses, so the app needs `NSAllowsArbitraryLoads = YES` (or HTTPS on a domain). This is a deployment decision to make before shipping.
- Request bodies are JSON (`Content-Type: application/json`), except `POST /uploads`, which is `multipart/form-data`. The JSON body limit is 2 MB.
- `GET /api/v1/health` → `{ "ok": true, "version": "1" }` (no auth). Use it for reachability checks.

### 1.2 Authentication

| Token kind | Prefix | How to get | Lifetime | Used for |
|---|---|---|---|---|
| **App token** (use this) | `nla_` | `POST /auth/token` (login) or `POST /auth/register` with `device_name` | 365 days (`APP_TOKEN_DAYS`) | Every authenticated endpoint, via `Authorization: Bearer nla_…` |
| Web session cookie | cookie `nl_session` | `POST /auth/login` | 30 days | Web only |
| Personal API token | `nl_` | `POST /settings/token` | until regenerated | **Only** `/health/ingest` (iPhone Shortcuts). Not accepted by normal endpoints. |

Server resolution (`auth.ts → userFromSession`):

```
token = cookie("nl_session") ?? (bearer && !bearer.startsWith("nl_") ? bearer : nil)
```

> **Gotcha: the cookie wins.** If the request carries any `nl_session` cookie, even an expired or invalid one, the Bearer token is **ignored**, and the request gets 401. The iOS client must not send cookies. Use `URLSessionConfiguration.ephemeral`, or set `httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never`, and never call `/auth/login` (which sets the cookie).

- Every successful request with an app token updates `last_used_at` for that session (visible in `GET /auth/sessions`).
- Unauthenticated → **HTTP 401** `{ "error": "未登录或令牌已失效" }`. The web reacts to any 401 on a non-`/auth/*` URL by dropping to the Login screen. iOS: on 401, clear the Keychain token and show Login.
- `/standards/meta` and `/standards/dri` **require auth** too, because they sit on a router with `requireAuth`. The login screen cannot load meta.

### 1.3 Error shape and status codes

All errors are JSON: `{ "error": "<Chinese message>" }`. The web shows `error` verbatim, as a toast or a warning banner. If the body has no `error` field, the web shows `请求失败（${status}）`.

| Status | Meaning | Example `error` |
|---|---|---|
| 400 | validation / bad input | `请先完善个人档案`, `开始日期不能晚于结束日期`, `密码至少 6 位`, `请求格式不正确` (invalid JSON) |
| 401 | not logged in / bad credentials | `未登录或令牌已失效`, `用户名或密码错误` |
| 403 | forbidden | `对方没有向你共享数据`, `当前站点已关闭注册`, `只能修改自己创建的食物` |
| 404 | not found | `用户不存在`, `食物不存在`, `任务不存在`, `接口不存在` |
| 413 | upload too large | `文件太大` |
| 500 | unhandled | `服务器内部错误` |

Full message list: Appendix D.

### 1.4 Dates and "today"

- Every date in the API is a **local calendar date string `YYYY-MM-DD`** in the *profile owner's* timezone (`profile.timezone`). Times are `HH:MM`. Never convert these to `Date` with the device timezone. Treat them as plain calendar dates.
- **"Today" = `me.today`** from `GET /auth/me`. The server computes it in the user's profile timezone. The web falls back to the device date only before `me` is loaded. iOS: refresh `me` on app foreground so `today` rolls over correctly.
- The web does date arithmetic in **UTC** to avoid DST drift (`lib/format.ts`). Reproduce it with a `Calendar(identifier: .gregorian)` whose `timeZone = TimeZone(identifier: "UTC")`:

| Helper | Definition |
|---|---|
| `addDays(date, n)` | date ± n days |
| `diffDays(a, b)` | whole days from a to b (b − a) |
| `weekStart(date)` | **Monday** of that week: `addDays(date, -((weekday + 6) % 7))` where weekday 0 = Sunday |
| `monthStart(date)` | `YYYY-MM-01` |
| `monthEnd(date)` | last day of that month |
| `shortDate(date)` | `"${M}/${D}"` without zero padding, e.g. `2026-09-04` → `9/4` |
| `dateLabel(date, today)` | `"${M}月${D}日 ${周X}"` where 周X ∈ `周日 周一 周二 周三 周四 周五 周六`; prefix `"今天 · "` if date == today, `"昨天 · "` if date == today − 1 |

### 1.5 Number formatting (`fmt`)

```
fmt(v, d = 0):
  if v is null / NaN / ±Inf → "—"   (U+2014 em dash)
  else v.toLocaleString("zh-CN", { maximumFractionDigits: d, minimumFractionDigits: 0 })
```

- Uses thousands grouping with `,` (e.g. `2017` → `"2,017"`). Trailing zeros are **dropped** (`fmt(1.50, 1)` → `"1.5"`, `fmt(2.0, 1)` → `"2"`).
- JS rounds half away from zero. In Swift use `NumberFormatter` with `locale = zh_CN`, `numberStyle = .decimal`, `minimumFractionDigits = 0`, `maximumFractionDigits = d`, and **`roundingMode = .halfUp`**. The default `.halfEven` gives different results.
- `compact(v)`: if `|v| ≥ 10000` → `"${fmt(v/10000, 1)}万"`, else `fmt(v)`.
- Signed values: the web writes `${v > 0 ? "+" : ""}${fmt(v, d)}`. Negative numbers already carry `-` from the formatter; zero gets no sign.
- Table cells (ChartCard table mode): numbers → `fmt(c, 1)`, `null` → `"—"`, strings as-is.

### 1.6 Asynchronous AI jobs (`/ai/*`, `/period/summary`)

The flow (web `api.ts → waitJob`):

1. `POST` the job endpoint → `200 { "job_id": "<uuid>" }`. The server inserts an `ai_jobs` row (`queued`) and starts it when a slot is free. Server concurrency is `AI_CONCURRENCY = 2` jobs per server, not per user.
2. Poll `GET /ai/jobs/{job_id}` **every 1500 ms** until `status` is `done` or `error`. The web has **no client timeout**. The server's AI call times out after 480 s (`AI_TIMEOUT_MS`), and the job then ends as `error`.
3. Job shape:

```json
{ "id": "uuid", "kind": "meal|food|exercise|activity|summary",
  "status": "queued|running|done|error",
  "error": "string or null",
  "result": <T or null> }
```

- `done` → use `result`. It may legitimately be `null` (see the period summary in §5.2).
- `error` → show `error`, or `"AI 任务失败"` if it is null.
- Jobs belong to a user. Polling another user's job, or an unknown one → 404 `任务不存在`.
- On server restart, every queued or running job becomes `error` with `"服务器重启，任务中断，请重试"`. Jobs older than 7 days are deleted.
- iOS: persist in-flight job IDs, so polling can resume after the app is backgrounded or killed. The job keeps running server-side.

### 1.7 App bootstrap and gating (`lib/app.tsx`, `App.tsx`)

1. On launch (if a token exists): `GET /auth/me` → `Me`. If it succeeds and `meta` is not cached yet, `GET /standards/meta` → `Meta`. The web loads meta **once** per session and keeps it for the app's lifetime.
2. While loading: full-screen `Loading` ("加载中…").
3. `GET /auth/me` fails → **Login** screen.
4. `me.profile == null` → **Onboarding** (profile form). There is no other navigation.
5. Otherwise → main shell.
6. `refreshMe()` re-calls `/auth/me` after login, register, profile save, settings save and logout.

### 1.8 Toasts

- A top-center toast stack. Info toasts last **2.6 s**. Error toasts last **5 s**, with a red background (`--critical`, white text).
- Info toast: `--ink` background, `--surface` text, radius 10, 14 px.
- iOS: a lightweight overlay banner, or a HUD with the same timings.

---

## 2. Navigation structure (`App.tsx`)

### 2.1 Web routes

| Route | Page | Notes |
|---|---|---|
| `/` | Today (今日) | other spec |
| `/log` | LogMeal (记一餐) | other spec; query `?date=YYYY-MM-DD`, `?edit=<mealId>&date=` |
| `/trends` | **Trends** | own data |
| `/reports` | **Reports** | own data only |
| `/body` | Body (身体与运动) | other spec; `?date=` |
| `/foods` | **Foods** | |
| `/community` | **Community** | |
| `/u/:username` | Today, read-only, for another member | header `@${username} 的记录`, sub `只读视图（对方开启了共享）`, button `看趋势` → `/u/:username/trends` |
| `/u/:username/trends` | **Trends** for another member | passes `user=<username>` to the API |
| `/standards` | **Standards** | `?tab=mine|dri|hazards|hei|met|rules|sources` (Today links to `?tab=rules` via "评分依据") |
| `/settings` | **Settings** | anchor `#share` (Community links to it) |
| `*` | redirect to `/` | |

### 2.2 Desktop sidebar (width > 860 px)

- Brand: a 34×34 rounded square (radius 10) in `--accent`, with a white Leaf icon. Next to it, `食迹` (700, 18 px) above `NUTRILOG` (11 px, letter-spaced, `--ink-3`).
- Primary full-width button: `+ 记一餐` → `/log`.
- Nav items, in order (label · icon):
  1. `今日` · House → `/`
  2. `趋势` · ChartLine → `/trends`
  3. `报告` · FileText → `/reports`
  4. `身体与运动` · Scale → `/body`
  5. `食物库` · Library → `/foods`
  6. `社区` · Users → `/community`
  7. `标准库` · BookOpen → `/standards`
  8. `设置` · Settings → `/settings`
- Bottom: the user's Avatar, `display_name`, `@username`.
- Active item: `--accent-soft` background, `--accent-text` text.

### 2.3 Mobile bottom nav (width ≤ 860 px)

5 slots: `今日` (House) · `趋势` (ChartLine) · **center FAB** (a 46 px accent circle with Plus, raised 18 px) → `/log` · `身体` (Scale) → `/body` · `更多` (Settings) → `/settings`.
Settings then shows a mobile-only 4-tile grid linking to `周期报告` (FileText) `/reports`, `食物库` (Library) `/foods`, `社区` (Users) `/community`, `标准库` (BookOpen) `/standards`.

### 2.4 Recommended iOS mapping

A `TabView` with 5 tabs mirroring the mobile web: **今日 / 趋势 / [记一餐 center action] / 身体 / 更多**. "更多" is a `NavigationStack` list containing 周期报告, 食物库, 社区, 标准库, then the Settings sections (§5.5). Another member's Today and Trends are pushed from Community (Today → `看趋势` → Trends with `user`).

---

## 3. Design tokens and theme

### 3.1 Brand (`manifest.webmanifest`, `favicon.svg`)

- `name`: `食迹 NutriLog`, `short_name`: `食迹`, `display`: standalone.
- `background_color`: **`#f6f5f1`** (warm paper), `theme_color`: **`#1f6f50`** (deep green).
- Favicon / app icon: a 64×64 rounded square (rx 16) filled `#1f6f50`, with a leaf shape `#f6f5f1` (path `M20 40c0-11 8-20 20-22-1 12-8 21-20 22z`), a leaf vein stroke `#1f6f50` 3 px round cap from (20,40) to (32,28), and a dot circle at (44,44), r 5, `#f6f5f1`.
- Design intent (from the stylesheet comment): "克制、温和的纸感界面：暖白底 + 深绿主色；数据色板与状态色遵循可视化规范（色盲安全已校验）". The palette is restrained, warm and paper-like, and was checked for color blindness.

### 3.2 Color tokens (CSS variables → define as asset-catalog colors with light/dark variants)

The theme preference is `system | light | dark` (Settings → 外观). The web stores it in `localStorage["nl-theme"]`; iOS uses `UserDefaults` plus `.preferredColorScheme`.

| Token | Light | Dark | Usage |
|---|---|---|---|
| `page` | `#f6f5f1` | `#0f0f0e` | screen background |
| `surface` | `#fcfcfb` | `#1a1a19` | cards, inputs, tooltip bg |
| `surface-2` | `#f1f0ec` | `#232321` | chips, segmented control bg, info banner |
| `surface-3` | `#e9e8e2` | `#2c2c2a` | meter track, ring track, empty sparkline bar |
| `ink` | `#0b0b0b` | `#ffffff` | headings, big numbers |
| `ink-1` | `#262624` | `#ecebe6` | body text |
| `ink-2` | `#52514e` | `#c3c2b7` | secondary text, labels |
| `ink-3` | `#898781` | `#898781` | muted text, axis labels |
| `hair` | `#e1e0d9` | `#2c2c2a` | dividers, grid lines |
| `axis` | `#c3c2b7` | `#383835` | axis line, crosshair, null status |
| `border` | `rgba(11,11,11,.10)` | `rgba(255,255,255,.10)` | card/input borders |
| `accent` | `#1f6f50` | `#3a9c73` | primary buttons, FAB, selected chip |
| `accent-hover` | `#185a41` | `#46ad83` | pressed |
| `accent-ink` | `#ffffff` | `#ffffff` | text on accent |
| `accent-soft` | `#e2eee7` | `#1b3128` | selected nav bg, accent banner/chip bg |
| `accent-text` | `#1a5e44` | `#6cc79f` | links, accent chip text |
| `good` | `#0ca30c` | `#0ca30c` | status fill (same in both) |
| `warning` | `#fab219` | `#fab219` | status fill |
| `serious` | `#ec835a` | `#ec835a` | ring 40–55 |
| `critical` | `#d03b3b` | `#d03b3b` | status fill, error toast, limit lines |
| `good-text` | `#006300` | `#3fc23f` | |
| `warning-text` | `#7a5200` | `#fab219` | |
| `serious-text` | `#9c4320` | `#ef9670` | |
| `critical-text` | `#b02e2e` | `#ea6b6b` | danger button text |
| `good-soft` | `#e6f4e4` | `#17301a` | status badge bg |
| `warning-soft` | `#fdf1d6` | `#342a12` | |
| `serious-soft` | `#fbe8df` | `#3a2419` | |
| `critical-soft` | `#f9e2e0` | `#3a1c1c` | |
| `series-1` (s1) | `#2a78d6` | `#3987e5` | primary data series (blue) |
| `series-2` (s2) | `#eb6834` | `#d95926` | second series (orange) |
| `series-3` (s3) | `#1baf7a` | `#199e70` | third series (green) |
| `series-4` (s4) | `#eda100` | `#c98500` | |
| `series-5` (s5) | `#e87ba4` | `#d55181` | |

Sequential palette (calendar heatmap), 7 steps:

- Light `seq` = `["#cde2fb","#9ec5f4","#6da7ec","#3987e5","#256abf","#184f95","#0d366b"]`
- Dark `seq` = the same array **reversed**: `["#0d366b","#184f95","#256abf","#3987e5","#6da7ec","#9ec5f4","#cde2fb"]`

### 3.3 Typography and metrics

- Font: system (`-apple-system`, `PingFang SC`). Body 15 pt, line-height 1.55.
- Headings use weight 650: h1 24 (21 on mobile), h2 18, h3 15.
- `small` 13. Muted text = `ink-3`; secondary = `ink-2`. Use tabular digits (`.monospacedDigit()`) for numbers.
- **Card**: `surface` bg, 1 px `border`, radius **14**, padding 18×20 (16 on narrow), soft shadow.
  - Card head: title on the left (h2/h3 with an optional leading icon); `hint` on the right, or wrapped under the title (12.5, `ink-3`).
- **Stat tile** (`stat-card`): padding 14×16.
  - `label` 13 `ink-2`.
  - `value` 26 weight 650 `ink`, with an inline `<small>` suffix (14, weight 500, `ink-3`, left margin 3).
  - `delta` line 12.5 `ink-3`.
- Buttons: height 38, radius 10, 14 pt, weight 550. Variants: `primary` (accent bg), `ghost` (transparent), `danger` (critical-text). Sizes: `sm` height 30 / radius 8 / 13 pt; `lg` height 46 / 15 pt.
- **Segmented control (`Seg`)**: `surface-2` track, radius 10, padding 3. Items are 13.5 pt weight 550 `ink-2`. The selected item has a `surface` background, a shadow and `ink` text. It wraps on narrow screens. iOS: use a custom capsule segmented control (the system `Picker(.segmented)` cannot wrap 7 options).
- **Chip**: capsule, padding 3×10, 12.5 pt, `surface-2` bg, `ink-2` text. `chip.accent` uses accent-soft / accent-text. A toggle chip in the on state uses accent bg / accent-ink text.
- **Tabs** (Standards): horizontal, scrollable, 14.5 pt weight 550 `ink-3`. Selected = `ink` with a 2 px `accent` underline.
- **Banner**: radius 12, padding 12×14, 13.5 pt. Default `surface-2`/`ink-2`; `warn` warning-soft/warning-text; `accent` accent-soft/accent-text. Optional leading 18 pt icon.
- **Modal**: centered card, radius 18, max width 560 (`wide` 860). On ≤600 px it becomes a **bottom sheet** (top corners 18, max height 92 vh). It has a header (title + X close button), a scrolling body, and a right-aligned footer with action buttons. iOS: `.sheet` with `NavigationStack` toolbar buttons.
- **Table**: 13.5 pt. Header 12.5 `ink-3` weight 600 with a bottom hairline. Rows have hairline separators. Numeric columns are right-aligned with tabular digits.
- **Empty**: centered `ink-3` text, 36 pt icon (Inbox default) at 0.6 opacity.
- **Loading**: centered spinner + `"加载中…"` in `ink-3`, 48 pt padding.
- Spinner: 18 pt ring, `hair` track, `accent` head.
- Layout grids: `g4` = 4 columns (2 below 1100 px, 2 with 10 pt gap below 480 px). `g2`/`g3` = 2/3 columns (1 below 860 px). `g-hero` = 5fr / 7fr (1 column below 1100 px). **On iPhone:** g4 → 2×2, everything else single column.

### 3.4 Shared UI components (`components/ui.tsx`)

**StatusBadge(status)**: a capsule, 12.5 pt, weight 600, with an icon plus text. *Never color-only.*

| status | text | icon | fg / bg |
|---|---|---|---|
| `good` | `达标` | CircleCheck | good-text / good-soft |
| `ok` | `达标` | CircleCheck | good-text / good-soft |
| `warn` | `偏离` | TriangleAlert | warning-text / warning-soft |
| `bad` | `不达标` | CircleX | critical-text / critical-soft |
| `info` | `提示` | Info | ink-2 / surface-2 |

`statusColor(s)` (bar fills): good/ok → `good`, warn → `warning`, bad → `critical`, info → `axis`.

**Meter(name, value, unit, max, marks?, status, foot?, decimals = 0)** is a horizontal bar.

- Top row: `name` on the left (13.5 pt, weight 550, `ink-1`). On the right, **bold `fmt(value, decimals)`** in `ink`, then a space and `unit` in `ink-2`.
- Track: 8 pt high, capsule, `surface-3`.
- Fill width = `min(100, value / scale × 100)%`, where `scale = max(max, value, …marks.at) × 1.08`. A full score therefore fills about 92.6 %. Fill color = `statusColor(status)`.
- Optional marks: 2 pt vertical ticks (ideal = `ink-3`, limit = `ink-2`).
- Optional `foot`: 12 pt `ink-3`.

**ScoreRing(score, grade?, size = 148)** is a circular progress ring.

- Stroke 10, round cap, starts at 12 o'clock, track `surface-3`, arc = score / 100.
- Color: `null` → `axis`; ≥ 70 → `good`; ≥ 55 → `warning`; ≥ 40 → `serious`; else `critical`. These are the ring's own thresholds, even when it shows LE8.
- Center: `Math.round(score)` (48 pt weight 700 when size ≥ 120, else 32), or `"—"` if null. `grade` sits under it (13 pt `ink-2`).

**Avatar(name, color, size)** is a circle filled with `color`.

- It shows the first character of `name`, uppercased, in white weight 650.
- Sizes: 32 pt / 14 pt font by default; `lg` 48 pt / 19 pt font.

**IarcChip(group)**

| group | text | colors |
|---|---|---|
| `"—"` | `非致癌` | default chip |
| `1` | `IARC 1 类` | critical-soft / critical-text |
| `2A` | `IARC 2A 类` | serious-soft / serious-text |
| `2B` | `IARC 2B 类` | warning-soft / warning-text |
| other | `IARC ${group} 类` | default chip |

**SourceLinks(ids, sources)**: `"依据："` followed by each source's `org`, joined with `、`. Each `org` links to `url` when `url` is non-empty. Renders nothing if no id resolves. Sources come from `meta.sources`.

---

## 4. Chart conventions (`lib/charts.ts`, `lib/theme.ts`, `components/EChart.tsx`)

The web uses ECharts (SVG renderer). The iOS port should use Swift Charts with these exact semantics.

**Chart theme mapping (`useChartTheme`)**: `surface, ink, ink2, ink3, hair, axis, s1…s5, good, warning, serious, critical` = the tokens in §3.2 for the current scheme. `seq` = light or dark sequential palette. Charts must re-render on color-scheme change.

**`baseOption(t, {yName?, yMin?, yMax?, legend?})`**

- Animation 400 ms.
- Plot insets: left 8, right 16, top **36 if a legend is shown else 16**, bottom 8. Labels are contained.
- **X axis**: categorical (string labels, in data order).
  - `boundaryGap: false` for line charts (first and last points sit on the plot edges); bar charts use `true`.
  - Axis line in `axis` color, **no ticks**.
  - Labels 11 pt `ink3`; overlapping labels are hidden (use automatic stride / `AxisMarks(values: .automatic(desiredCount: ~6))`).
- **Y axis**: value.
  - Unit title = `yName` (11 pt `ink3`, left-aligned at the top), shown **only when there is no legend**.
  - Optional fixed `min`/`max`.
  - Gridlines: solid 1 pt `hair`.
  - Labels 11 pt `ink3`, formatted `fmt(v, 1)`.
- **Tooltip**: axis-triggered (all series at the hovered x).
  - Box: `surface` bg, 1 pt `hair` border, radius 10, padding 8×12, shadow.
  - Crosshair: a vertical line, 1 pt `axis` color.
  - iOS: `chartXSelection` (iOS 17+) + `RuleMark` + an overlay card.
- **Tooltip content (`tipHtml`)**:
  - Title: the x label, 12 pt `ink3`.
  - One row per series: a **12×3 pt rounded color swatch**, the **bold value first** (`ink`, weight 650, tabular), then the series name (`ink2`). Rows have 8 pt gaps and 1.7 line-height.
- **Legend (`legendOption`)**: top-left. Each item has a roundRect swatch **14×3 pt**, then the label (12 pt `ink2`). ECharts legends toggle series visibility on tap (optional on iOS). Build a custom legend row rather than Swift Charts' default.

**`lineSeries(name, data, color, extra)` defaults**

- Line width 2, round caps/joins, straight segments (`smooth: false`).
- **`connectNulls: false`**: a `null` value breaks the line into a gap.
  - Swift Charts connects across missing points. To get gaps, split the data into contiguous segments and give each segment its own `series:` identity, e.g. `"\(name)-\(segmentIndex)"`, all with the same color.
- Point symbols: filled circles, size 7 pt, **shown only when the series has ≤ 45 points**. They enlarge ×1.4 on emphasis.

---

## 5. Screens

### 5.1 Trends 健康趋势 (`pages/Trends.tsx`)

**Purpose:** a multi-range dashboard of daily scores, energy, weight, nutrient tracking, a score calendar, LE8/WCRF indices for the range, pass rates and hazard exposure. It works for the current user (`/trends`) or for another member who shares data (`/u/:username/trends`, where `other = username`). If `username == me.user.username`, it is treated as self.

#### 5.1.1 State and range logic

- `today = me.today`.
- `range` ∈ `"7" | "30" | "90" | "year" | "365" | "all" | "custom"`. **Default `"30"`.**
- Custom default: `{ start: addDays(today, -59), end: today }`.
- Computed `start` / `end` (`end = today` except for custom):

| range key | label | start |
|---|---|---|
| `7` | `7 天` | `addDays(today, -6)` |
| `30` | `30 天` | `addDays(today, -29)` |
| `90` | `90 天` | `addDays(today, -89)` |
| `year` | `今年` | `${today.year}-01-01` |
| `365` | `一年` | `addDays(today, -364)` |
| `all` | `全部` | `addDays(today, -1095)` |
| `custom` | `自定义` | user-chosen |

- Custom mode shows two date pickers: start (max = custom end), the text `"至"` (muted), then end (max = today). There is no other validation. If start > end, the server returns 400 `开始日期不能晚于结束日期`, which is shown in the warning banner.

#### 5.1.2 Data loading (three parallel requests; each re-fires when start/end/other change)

1. `GET /trends?start=${start}&end=${end}[&user=${other}]` → `{ start, end, days: TrendDay[] }`
2. `GET /period?start=${pStart}&end=${end}[&user=${other}]` → `PeriodScore`, where `pStart = diffDays(start, end) > 400 ? addDays(end, -400) : start`. `/period` caps ranges at 400 days.
3. Own view only: `GET /profile/targets` → `Targets` (today's targets). For another member's view, `targets = null`, so the nutrient explorer has no target lines.

**Post-processing of `days`:**

- If `range == "all"`: find the first index where `hasData || weight != null`. If that index is > 0, drop the leading days (trims the empty history before the first record).
- `span = days.count` (after trimming).
- **Bucket unit**: `span ≤ 92 → "day"`; `span ≤ 400 → "week"`; else `"month"`.
- `unitZh`: day → `每日`, week → `每周平均`, month → `每月平均`.

**Bucketize** (preserve first-seen order; days are already sorted ascending):

- key: day → the date; week → `weekStart(date)` (Monday); month → `monthStart(date)`.
- label:
  - day / week → `shortDate(key)`, e.g. `9/21`. A week bucket is labeled by its Monday, which can fall before `start`.
  - month → `"${YY}/${M}月"`, e.g. `2025-03-01` → `25/3月`.
- Each bucket keeps `days` (all days) and `logged` (days with `hasData == true`).
- Helpers:
  - `avg(xs)` = arithmetic mean, or `null` if xs is empty.
  - `r1(v)` = round to 1 dp (`Math.round(v*10)/10`), with null passthrough.

#### 5.1.3 Header

- Title: own `健康趋势`; other `@${other} 的健康趋势`.
- Subtitle: `${start} 至 ${end} · ${unitZh}`. Uses the computed start, not the trimmed one.
- Range segmented control (7 options, wraps), plus the custom date row when `custom` is selected.

#### 5.1.4 States

- First load (no data yet): `Loading`.
- `/trends` error: warning banner (`banner warn`) with the error message, e.g. `对方没有向你共享数据`, `用户不存在`, `请先完善个人档案`.
- Reloading with data present: content stays visible at **opacity 0.55** (0.2 s fade).
- Errors from `/period` or `/profile/targets` are silent. Their sections fall back to `—` or are hidden.

#### 5.1.5 Sections in order

**(1) Summary tiles** (4 tiles, 2×2 on phone). Here `logged = days.filter(hasData)` and `e = period.energy`.

| # | label | value | small suffix | delta line |
|---|---|---|---|---|
| 1 | `区间总分` | `fmt(period.total.score)` | `/ 100` | `LE8 ${fmt(period.score)} · HEI 日均 ${fmt(avgScore)} · ${logged.count}/${days.count} 天有记录` where `avgScore = avg(logged.map { $0.score ?? 0 })` |
| 2 | `日均摄入 / 消耗` | `fmt(avg(logged.intake))` | `/ ${fmt(avg(days.tdee))} kcal` | (none) |
| 3 | `趋势体重变化` | `e.actualChangeKg != null ? sign + fmt(e.actualChangeKg, 1) : "—"` | `kg` | `能量差预测 ${e ? sign + fmt(e.predictedChangeKg, 1) + " kg" : "—"}` |
| 4 | `按实际数据反推的日消耗` | `e.empiricalTdee != null ? fmt(e.empiricalTdee) : "—"` | `kcal` | `e.empiricalTdee != null ? "公式估算 ${fmt(e.avgTdee)}" : "需 ≥14 天体重与较完整的记录"` |

(sign = `"+"` if > 0.)

**(2) Row: Score chart | Energy chart** (side by side on desktop, stacked on phone). **(3) Row: Weight chart | Category chart.** All four (plus the nutrient explorer) use **ChartCard**:

- Header: title (h3), an optional hint under it (small, muted), and a right-aligned ghost toggle button. In chart mode the button shows the Table2 icon + `"表格"`; in table mode, the ChartLine icon + `"图表"`. The toggle state is per card, local, and not persisted.
- Table mode: a scrollable table (**max height 300**). The first column is left-aligned; the others are right-aligned numbers. Cells: numbers `fmt(c, 1)`, `null` → `—`.
- Chart height: **260 pt**.

**Chart A: `膳食质量 HEI-2020`**

- Hint: `USDA 健康饮食指数，0–100；虚线为美国人平均 58 分`
- `score[b] = r1(avg(b.logged.map { $0.score ?? 0 }))`.
  - **Quirk:** a logged day with `score == null` (under 200 kcal, so HEI cannot be computed) counts as **0**.
  - A bucket with no logged days → `null` (gap).
- Day unit only: `rolling[i] = r1(avg(score[max(0,i-6)...i].compactMap{$0}))`, a 7-bucket trailing mean that ignores nulls; null if all are null.
- Y axis fixed **0…100**; legend shown.
- Series, when `unit == day` (legend order: `日评分`, `7 日均值`, `美国平均 58`):
  - `日评分`: line width **1.5**, color **`axis`**, point color **`ink3`** (points only if ≤ 45 buckets).
  - `7 日均值`: line, **`s1`**, width 2, **no points**.
  - `美国平均 58`: a horizontal **dashed** line at y = 58 (dash [4,4]), width 1, color `ink3`, not interactive, **excluded from the tooltip**.
- Series when `unit` is week/month: `平均评分` (s1, width 2, points ≤ 45) + `美国平均 58` (same dashed line). Legend `[平均评分, 美国平均 58]`.
- Tooltip rows: value `null` → `"无记录"`, else `fmt(v, 1)`.
- Table: head `["日期", "评分"]`, plus `"7 日均值"` in day mode. Rows: `[label, score, rolling?]`.

**Chart B: `摄入 vs 消耗`**

- Hint: `消耗 = 静息代谢 + 活动（设备/步数/运动）+ 食物热效应`
- `intake[b] = r1(avg(b.logged.intake))` (null if no logged days).
- `tdee[b] = r1(avg(b.days.tdee))` and `target[b] = r1(avg(b.days.target))` (all days, never null).
- Legend `[摄入, 消耗, 目标]`. Series:
  - `摄入`: s1 line.
  - `消耗`: s2 line.
  - `目标`: s3, **dashed [4,4]**, width 1.5, no points.
- The Y axis is unbounded, and **no y-axis unit title** (because the legend is shown).
- Tooltip value: `"${fmt(v)} kcal"`, null → `"—"`.
- Table: `["日期","摄入","消耗","目标"]`.

**Chart C: `体重`**

- Hint:
  - If `period.energy.ratePerWeek != null`: `趋势每周 ${sign}${fmt(rate, 2)} kg（EMA 平滑，过滤每日水分波动）`
  - else: `建议每晚睡前固定时间称重`.
- `raw[b] = r1(avg(b.days.compactMap{$0.weight}))` (average of actual weigh-ins in the bucket, or null).
- `trend[b]` = the `trend` value of the **last day in the bucket with a non-null `trend`** (unrounded in the chart, `r1` in the table).
- If no bucket has a raw weigh-in: show `Empty` with `这段时间没有体重记录` instead of the chart. This happens even if trend values exist.
- Y axis: `min = floor(dataMin − 1)`, `max = ceil(dataMax + 1)`. No unit title (legend shown).
- Legend `[称重 | 平均称重 (non-day), 趋势（平滑）]`. Series:
  - `称重` / `平均称重`: **scatter** points, 8 pt diameter, fill `ink3`, 2 pt `surface` border.
  - `趋势（平滑）`: s1 line, no points, **`connectNulls: true`** (continuous).
- Tooltip: `"${fmt(v, 1)} kg"`, null → `—`.
- Table: `["日期","称重","趋势"]`.

**Chart D: `膳食质量与营养素充足`**

- Hint: `HEI-2020 与 MAR（11 种微量营养素平均充足比），均为 0–100`
- Two series:
  - `HEI-2020` (s1): `r1(avg(b.logged.map{ $0.categories["hei"] ?? 0 }))`
  - `微量营养素 MAR` (s2): same with `categories["mar"]`
- Y axis 0…100, legend shown. Tooltip value `fmt(v)` (0 dp), null → `—`.
- Table: `["日期","HEI-2020","微量营养素 MAR"]`.

**(4) Nutrient explorer: `营养素追踪：${zh}`** (full width)

- Hint: `${每日 | 每周日均 | 每月日均}（仅计有记录的天）；横线为你的个人目标/上限`
- Metric picker (web: a `<select>` 240 wide, aria-label `选择指标`), with two groups:
  - `营养素`: every `meta.nutrients` entry as `${n.zh}（${n.unit}）`, in meta order.
  - `其他指标`: the fixed list below, as `${zh}（${unit}）`.
- **Default key: `sodium_mg`** (钠).
- Extra metrics (exact keys and labels):

| key | zh | unit | value per day `pick(d)` |
|---|---|---|---|
| `macro:satFat` | 饱和脂肪供能比 | % | `d.macroPct["satFat"] ?? 0` |
| `macro:addedSugar` | 添加糖供能比 | % | `d.macroPct["addedSugar"] ?? 0` |
| `macro:protein` | 蛋白质供能比 | % | `d.macroPct["protein"] ?? 0` |
| `upf` | 超加工食品供能比 | % | `d.upfPct` |
| `group:processed_meat_g` | 加工肉 | g | `d.groups["processed_meat_g"] ?? 0` |
| `group:red_meat_g` | 红肉 | g | `d.groups["red_meat_g"] ?? 0` |
| `group:veg_total_cup` | 蔬菜 | 杯当量 | `d.groups["veg_total_cup"] ?? 0` |
| `group:fruit_total_cup` | 水果 | 杯当量 | `d.groups["fruit_total_cup"] ?? 0` |
| `group:grains_whole_oz` | 全谷物 | 盎司当量 | `d.groups["grains_whole_oz"] ?? 0` |
| `hei` | HEI-2020 分数 | 分 | `d.hei` (nullable) |
| `steps` | 步数 | 步 | `d.steps` (nullable) |
| `hazard` | 风险物警示数 | 项 | `d.hazardCount` |
| `mar` | 微量营养素 MAR | 分 | `d.mar` (nullable) |
| *(any nutrient key)* | `n.zh` | `n.unit` | `d.totals[key] ?? 0` |

- `values[b] = r1(avg(src.map(pick).compactMap{$0}))`.
  - `src = b.logged`, except for `steps`, where `src = b.days.filter{ $0.steps != nil }`.
- **Target / limit lines** (own view only, i.e. `targets != null`), computed in order:
  1. Look up the limit:
     - `lim = targets.limits[key]`
     - if that is missing: `key == "macro:satFat"` → `targets.limits["sat_fat_pct"]`; `key == "upf"` → `targets.limits["upf_pct"]`
  2. If `lim` exists:
     - Add line `上限 ${fmt(lim.limit, 1)}` at `lim.limit`, color **critical**.
     - If `lim.ideal > 0 && lim.ideal != lim.limit`, also add `理想 ${fmt(lim.ideal, 1)}` at `lim.ideal`, color **good**.
  3. Otherwise, if `targets.intake[key]` exists: add line `${intake.kind} ${fmt(intake.value, 1)}` (e.g. `RDA 56`, `AI 38`), color **good**.
  4. If `key == "energy_kcal"`: add `目标 ${fmt(targets.energyTarget)}` at energyTarget, color **good**.
  5. If `key == "group:red_meat_g"`: add `日均建议 ≤70` at 70, color **critical**.

  Server `limits` keys are `sodium_mg`, `added_sugars_g`, `sat_fat_pct`, `trans_fat_g`, `alcohol_g`, `caffeine_mg`, `upf_pct`. `intake` keys are nutrient keys with an RDA/AI.
- Chart: **bar chart**, bars s1, max bar width 24, top corners radius 4, x `boundaryGap: true`. No legend.
- **Y-axis title = the unit string.**
- Target lines: solid, width 1.5, not interactive. Each is labeled with its name at the **trailing end, above the line**, in an 11 pt `ink2` label on a `surface` background (padding 1×4, radius 4). iOS: `RuleMark(y:)` + `.annotation(position: .top, alignment: .trailing)`.
- Tooltip: axis pointer = a **shaded band** (`hair` at 40 % opacity) instead of a line. One row: swatch s1, name zh, value `"${fmt(v,1)} ${unit}"`, or `"无记录"` if null.
- Table: `["日期", "${zh} (${unit})"]`.
- Web quirk: in table mode the picker disappears, because it is part of the chart body. iOS should keep the picker visible in both modes.

**(5) Calendar heatmap `每日评分日历`**: shown **only when `span ≥ 45`**.

- Years = the distinct `YYYY` values in `days`, keeping the **last 3**. Each year renders a full **Jan–Dec** calendar strip:
  - Columns = weeks, rows = weekdays **Monday first** (`firstDay: 1`).
  - Chinese month labels (一月 … 十二月) and weekday labels (一 二 三 四 五 六 日), plus a year label on the left.
  - Cells are 14 pt high, width auto (fills the width), with a 2 pt `surface` gap.
  - Empty cells are `surface` colored.
  - Each strip takes about 150 pt; total chart height = `40 + years × 150`.
  - It scrolls horizontally inside a min width of 720 pt.
- Data: days with `score != null` → `round(score)`.
- Color pieces (by rounded score):

| range | label | light | dark |
|---|---|---|---|
| ≥ 85 | `≥85 优秀` | `seq[6]` `#0d366b` | `#cde2fb` |
| 70 ≤ s < 85 | `70–85 良好` | `seq[4]` `#256abf` | `#6da7ec` |
| 55 ≤ s < 70 | `55–70 一般` | `seq[2]` `#6da7ec` | `#256abf` |
| < 55 | `<55 较差` | `seq[0]` `#cde2fb` | `#0d366b` |

- Card head legend (right side), in order: `<55 较差`, `55–70 一般`, `70–85 良好`, `≥85 优秀`. Each has a 12×12 rounded swatch.
- Tooltip: title = the date; row = swatch s1, name `日评分`, value `fmt(score)`.
- iOS: draw this as a custom SwiftUI grid or Canvas rather than Swift Charts.

**(6) Row: Le8Card | WcrfCard** (only if `period` is loaded). Both use subtitle `${period.start} 至 ${period.end}`. The Le8Card title stays at its default `心血管健康 Life's Essential 8`. See §5.3.

**(7) Row: pass rates | periodic checks** (only if `period`).

- Left card `各项达标天数`, hint `按未达标比例排序（${period.start} 至 ${period.end}）`.
  - Legend (10×10 rounded squares): `达标` (good), `偏离` (warning), `不达标` (critical).
  - Rows: `period.itemStats`, minus `category == "hei"`, sorted descending by `(bad + warn) / days`, **first 18**.
  - Each row:
    - Label `zh`: 128 pt wide, single line, truncated.
    - A **stacked horizontal bar**, 10 pt high, capsule ends, 2 pt gaps. Segments in order: `good + ok` (good color), `warn` (warning), `bad` (critical). Each segment's width = count / days. Zero-width segments are omitted.
    - Right label `${good+ok}/${days}`: 52 pt, right-aligned, muted, tabular.
  - Accessibility label: `${zh} 达标 ${good} 天 偏离 ${warn} 天 不达标 ${bad} 天`.
- Right card `周期性指标`, hint `只在按周/月看才有意义的标准`. A list of `period.checks`. Each item:
  - StatusBadge(status).
  - Then `zh` (weight 600), `message` (small, secondary), and `目标：${targetText}` (small, muted).

**(8) Hazard table `风险物暴露汇总`** (only if `period.hazards` is non-empty). Hint `只作警示，不另设扣分`.

| Column | Header | Content |
|---|---|---|
| 1 | `项目` | `zh` |
| 2 | `分级` | IarcChip(iarc) |
| 3 | `出现天数` | `days` (numeric) |
| 4 | `累计量` | `"${fmt(dose)} ${unit}"` (numeric) |

The server sorts the rows by days descending.

### 5.2 Reports 周期报告 (`pages/Reports.tsx`)

**Purpose:** a weekly or monthly report for the **current user only**, with the composite total, LE8, HEI, MAR, WCRF, checks, energy and weight, key nutrients, hazards, HEI components and an AI commentary.

#### 5.2.1 State

- `kind` ∈ `week | month`, **default `week`**.
- `anchor` default = `addDays(weekStart(today), -7)`, i.e. **last week's Monday**.
- Switching kind: to `week` → anchor = last week's Monday; to `month` → anchor = **today** (the *current* month). This asymmetry is intentional in the code.
- `start = kind == week ? weekStart(anchor) : monthStart(anchor)`.
- `end = kind == week ? addDays(start, 6) : monthEnd(anchor)`. `end` can be in the future for the current week or month.
- Navigation:
  - prev (aria `上一期`) / next (aria `下一期`).
  - Week: ±7 days.
  - Month: ±1 calendar month from `start` (UTC month arithmetic).
  - **Next is disabled when `end >= today`.**
- Period label:
  - week: `"${start} ~ ${end[5...]}"`, e.g. `2026-09-21 ~ 09-27`.
  - month: `"${YYYY} 年 ${M} 月"`, e.g. `2026 年 9 月`.

#### 5.2.2 Data

`GET /period?start=${start}&end=${end}` → `PeriodScore` (including `aiSummary` and `full`). It is reloaded after AI generation.

- First load: `Loading`. Reload: content at opacity 0.55.
- **Web shows nothing on error** (the page stays blank). iOS should show the error banner.

#### 5.2.3 Header

- Title `周期报告`.
- Subtitle: `总分由膳食质量、微量营养素、心血管健康 LE8 和防癌建议按权重合成；每周一自动生成上周报告，每月 1 日生成上月报告（含 AI 点评）`
- Right side: Seg `周报` (week) / `月报` (month), and a date-nav pill (‹ label ›) with a `surface` background, border, radius 10, label weight 600 and min width 128.

#### 5.2.4 Sections in order

1. **Total tile** (full width `stat-card`):
   - Label `本周总分` (week) or `本月总分` (month).
   - Value `fmt(total.score)` with small `/ 100`.
   - Below it, the **TotalParts** line (§5.3.4).
2. **Hero row** (`g-hero`: 5fr left / 7fr right; stacked on phone):
   - **Left:** Le8Card with title **`心血管健康 LE8`** and subtitle `AHA Life's Essential 8 · ${daysLogged}/${days} 天有记录`.
   - **Right**, stacked:
     - A 2×2 grid of stat tiles:

       | label | value | suffix | delta |
       |---|---|---|---|
       | `HEI-2020（按周期总摄入）` | `fmt(hei?.total, 1)` | `/ 100` | `美国人平均 58` |
       | `HEI-2020 日均` | `fmt(avgHei, 1)` | `/ 100` | |
       | `微量营养素 MAR 日均` | `fmt(avgMar)` | `/ 100` | |
       | `防癌建议 WCRF/AICR` | `fmt(indices.wcrf.score, 2)` | `/ ${indices.wcrf.max}` | |

     - **AI summary card** (§5.2.5).
3. **WcrfCard**, subtitle `${start} 至 ${end}`.
4. **Two-column row:**
   - Card `其他按周评估的指标`, hint `只标状态，不加权`: a list of `checks`. Each item is StatusBadge + bold `zh` + `message` + `目标：${targetText}`.
   - Card `能量与体重`: a key/value list (keys `ink-3`, values `ink-1`, 14 pt):

     | key | value |
     |---|---|
     | `日均摄入` | `${fmt(energy.avgIntake)} kcal` |
     | `日均消耗` | `${fmt(energy.avgTdee)} kcal` |
     | `累计能量差` | `${sign}${fmt(energy.totalBalance)} kcal（≈ ${fmt(energy.predictedChangeKg, 2)} kg）` |
     | `趋势体重变化` | `actualChangeKg != null ? "${sign}${fmt(actualChangeKg, 2)} kg" : "称重数据不足"` |
     | `反推日消耗` | `empiricalTdee != null ? "${fmt(empiricalTdee)} kcal" : "需 ≥14 天完整数据"` |

     Then a divider, h3 `日均关键营养`, and a second key/value list from `avgTotals`:

     | key | value |
     |---|---|
     | `钠` | `${fmt(sodium_mg)} mg` |
     | `添加糖` | `${fmt(added_sugars_g, 1)} g` |
     | `饱和脂肪` | `${fmt(sat_fat_g, 1)} g` |
     | `膳食纤维` | `${fmt(fiber_g, 1)} g` |
     | `蛋白质` | `${fmt(protein_g, 1)} g` |
     | `钙 / 钾 / 维生素 D` | `${fmt(calcium_mg)} mg / ${fmt(potassium_mg)} mg / ${fmt(vit_d_ug, 1)} µg` |
5. **Hazards card** (only if `hazards` is non-empty):
   - Title `致癌物与风险物警示`, hint `只作警示；加工肉、红肉、酒精、含糖饮料已计入 WCRF 评分`.
   - A wrapping row of chips (padding 6×12). Each chip has **bold `zh`**, an IarcChip, and ` ${days} 天 · ${fmt(dose)} ${unit}`.
6. **HEI components card** (only if `hei != null`):
   - Title `HEI-2020 各组分（按周期总量计算）`.
   - A grid of Meters (auto-fill, min column 220 pt; one column on phone). Each Meter:
     - name `c.zh`, value `c.score`, unit `/ ${c.max}`, max `c.max`, decimals 1.
     - status: `r = score / max`; `r ≥ 0.999` → good; `≥ 0.6` → warn; else bad.
     - foot: `c.hint`, shown only if `r < 0.999`.

#### 5.2.5 AI summary card (`AiSummary`)

- Header: Sparkles icon + h2 `AI 点评`.
- Action button, shown only if `daysLogged > 0 && me.ai.provider != "mock"`:
  - Label: `重新生成` if a summary exists, else `生成点评`.
  - Icon: Sparkles, or a spinner while generating. Disabled while generating.
- Body states:
  - Generating: pulsing muted text `Claude 正在阅读本期评分数据并撰写点评…`
  - No summary and provider `mock`: `未配置 AI，无法生成点评。离线评分结果仍然完整可用。`
  - No summary and `daysLogged > 0`: `点击“生成点评”，让 Claude 根据离线评分结果给出下期最值得改进的 3–5 件事。`
  - No summary and no logged days: `这一期没有记录。`
  - Summary present (`aiSummary = {headline, summary, wins[], issues[], actions[]}`):
    - `headline`: h3, 17 pt.
    - `summary`: secondary text.
    - Each `wins[i]`: a row with a green CircleCheck (good color) + text.
    - Each `issues[i]`: a row with a red CircleX (critical color) + text.
    - If `actions` is non-empty: an **accent banner** (vertical) with bold `下期行动`, then each action as a row with an ArrowUpRight icon (15 pt) + text.
- Generate flow:
  1. `POST /period/summary` with body `{ "start": start, "end": end }` → `{ job_id }`.
  2. Poll `/ai/jobs/{id}` (§1.6) until done.
  3. Reload `GET /period` (the stored summary appears in `aiSummary`).
  4. Errors → error toast with the message.
- Server notes:
  - The job's `result` is the summary object, or **`null`** if the provider is mock or `daysLogged == 0`. In that case nothing is stored and the card stays empty, with no error.
  - A 7-day range that starts on a Monday is stored as `week`; every other range (including whole months) is stored as `custom`.
  - The scheduler auto-generates reports: last week every Monday (needs ≥ 3 logged days) and last month on the 1st (needs ≥ 10 logged days), stored as `week` / `month`. It runs 20 s after boot, then every 15 min.
  - **Server bug (affects month regeneration):** `GET /period` returns the first stored row matching `start_date`/`end_date` with a non-null summary, **without ordering**. A user-triggered monthly regeneration (`custom` row) can therefore stay hidden behind the scheduler's older `month` row. See §7.

### 5.3 Shared health-index cards (`components/HealthIndices.tsx`, `components/TotalScore.tsx`)

#### 5.3.1 Le8Card(ix: HealthIndices, title = `心血管健康 Life's Essential 8`, subtitle?)

- Header: HeartPulse icon + h2 `title`. Hint = `subtitle ?? "美国心脏协会 2022 · 近 ${ix.windowDays} 天"`.
- Body (`hero-score` row, wraps on phone):
  - **ScoreRing** at size **132**, with `score = ix.le8.score`.
    - `grade = ix.le8.category ? "${category.zh}（${le8.available}/8 项）" : "数据不足"`. Category zh is `高` / `中` / `低` (≥ 80 / ≥ 50 / < 50).
  - A column (min width 220, 10 pt gaps) with one entry per `ix.le8.components` (in server order):
    - If `points != null`: a **Meter** with name `zh`, value `points`, unit `/ 100`, max 100.
      - status: `points ≥ 80` → good; `≥ 50` → warn; else bad.
      - foot = `c.value`. If `c.key == "diet"` and `ix.mepa != null`, append ` · ` and a link `查看 16 题`, which opens the MEPA modal.
    - Else: a row with `zh` (secondary) on the left and `缺数据：${c.missing}` (muted) on the right.
  - Component keys and labels from the server, in order:
    - `diet` 饮食（MEPA）
    - `activity` 身体活动
    - `nicotine` 尼古丁暴露
    - `sleep` 睡眠
    - `bmi` 体重指数 BMI
    - `lipids` 血脂（非 HDL 胆固醇）
    - `glucose` 血糖
    - `bp` 血压
- Footer (small, muted): `总分 = 已有指标的等权平均（缺失指标不计入分母）；80–100 高，50–79 中，0–49 低。`

#### 5.3.2 MEPA modal

- Title: `MEPA 饮食问卷：${mepa.score}/16`.
- Paragraph: `AHA Life's Essential 8 规定的个人饮食评分工具（Cerwinske 2017）。由你近 ${mepa.days} 天的饮食记录自动推算每周 / 每天份数，每满足一题得 1 分。15–16 分 → 100，12–14 → 80，8–11 → 50，4–7 → 25，0–3 → 0。`
- Table headers: `题目` | `标准` | `你的记录` (numeric) | *(blank)*.
- Each row: `i.zh` | `i.criterion` (small, secondary) | `${fmt(i.value, 1)} ${i.unit}` | `i.met` → green badge `✓ 1 分`, else grey badge `0 分`.
- `ix.mepa` is `null` when there are fewer than 3 logged days. The link is hidden then.

#### 5.3.3 WcrfCard(ix, subtitle?)

- Header: ShieldCheck icon + h2 `防癌建议 WCRF/AICR`. Hint `subtitle ?? "2018 标准化评分 · 近 ${ix.windowDays} 天"`.
- Summary row:
  - Big value `fmt(wcrf.score, 2)` (34 pt) + small `/ ${wcrf.max}`. **`max` is not fixed at 6.** The server sums `max` only over components whose `points != null` (and `max > 0`), so it equals the number of scorable recommendations (≤ 6). Diet-based components are null when there are fewer than 3 logged days, which makes `max` smaller (e.g. `1.5 / 3`). `score` is the sum of the non-null points.
  - Muted text: `7 条建议各 1 分、等权（Shams-White 2019）。“超加工食品”一条原文按研究人群三分位评分、没有绝对切点，此处只展示不计分。`
  - Collapse toggle (chevron up/down, aria `展开`). **Default expanded.**
- List (when expanded), one row per `wcrf.components`:
  - Left 56 pt: tabular, weight 650.
    - Text: `points == null` → `"—"` (`ink-3`); else `"${fmt(points,2)}/${max}"`.
    - Color: `points ≥ max` → good-text; `points > 0` → warning-text; `0` → critical-text.
  - Right: `zh` (weight 600), `detail` (small, secondary), `rule` (small, muted).
- Component keys:
  - `weight` 保持健康体重
  - `activity` 积极运动
  - `plants` 多吃全谷物、蔬菜、水果、豆类
  - `upf` 少吃快餐和高脂高糖高淀粉的加工食品 (always `points null`, `max 0`)
  - `meat` 限制红肉和加工肉
  - `ssb` 限制含糖饮料
  - `alcohol` 限制饮酒

#### 5.3.4 TotalParts(total: CompositeScore)

Renders nothing if `total.score == null`. Otherwise, a small secondary line:

```
avail = total.parts.filter { $0.score != nil }
scale = 100 / max(1, Σ avail.weight)
text  = avail.map { "\($0.zh) \(fmt($0.points, 1))/\(fmt($0.weight * scale, total.missing.isEmpty ? 0 : 1))" }.joined(" · ")
if !total.missing.isEmpty: append (muted) "（缺\(total.missing.joined("、"))，其余按权重折算）"
```

- Period parts (weights): `膳食质量` 40, `微量营养素` 10, `心血管健康` 35, `防癌建议` 15.
- Daily parts: `膳食质量` 50, `微量营养素` 15, `能量平衡` 15, `身体活动` 20.

### 5.4 Community 社区 (`pages/Community.tsx`)

**Purpose:** list all members. Usernames are always visible; each member's data is visible only if they share it with the viewer.

- Data: `GET /users` → `CommunityUser[]`, ordered by user id ascending. Loading → `Loading`. Errors are ignored on the web.
- Header:
  - Title `社区`.
  - Subtitle: `所有成员都能看到彼此的用户名；每日数据是否共享、共享给谁、共享多少由每个人自己决定（` + link `我的分享设置` → Settings, section `#share` + `）`.
- Grid: 3 columns on desktop, 1 on phone. One card per user (equal heights, 12 pt gaps):
  - Top row:
    - Avatar `lg` (48 pt).
    - `display_name` (weight 650, 16 pt), plus an accent chip `我` if `is_me`.
    - Under the name: `@${username}` (small, muted).
  - If `shared_with_me`:
    - A row: `近 14 天膳食质量（HEI-2020）` (small, secondary) on the left; `均分 ${fmt(avg)}` (muted, tabular) on the right. `avg` = the mean of the non-null `recent[].score`, or `—`.
    - **Sparkline**: 14 vertical bars, 28 pt total height, 2 pt gaps, flex-equal widths, top corners radius 2, color `series-1`.
      - Bar height = `max(6, score)%` of 28 pt.
      - A null score → a 2 pt bar in `surface-3`.
      - Tooltip (long-press on iOS): `${date}：${score ?? "无记录"}`.
      - Accessibility label: `近 14 天平均 ${fmt(avg)} 分`.
    - A small secondary row:
      - Flame icon (14 pt, `series-2`) + `连续记录 ${streak} 天`.
      - Muted `最近记录 ${last_log_date ?? "—"}`.
    - A chip with an Eye icon:
      - `is_me` → `这是你`
      - `share_detail == "full"` → `共享了完整记录`
      - else `只共享评分摘要`
    - **Tap** → if `is_me`, go to own Today; else go to the member's read-only Today (`/u/${username}`).
  - Else: a small muted row with a Lock icon + `未向你共享每日数据`. Not tappable.
- Server semantics (`GET /users`):
  - Access is granted when the target is the viewer, or `share_mode == "public"`, or `share_mode == "selected"` and the viewer is in the target's `share_grants`.
  - `share_detail` = `"full"` if access is granted and the owner chose full, `"summary"` if granted, else `"none"`.
  - `recent`: the last 14 days (the owner's timezone today − 13 … today) as `{date, score: rounded HEI integer or null}`. It is **empty** if access is denied or the owner has no profile.
  - `streak`: counts backwards from today over those 14 days, consecutive days with `hasData`. **Today without data does not break the streak** (it is skipped); the first earlier gap stops counting. Max 14. It is 0 when the owner has no profile or access is denied.
  - `last_log_date`: the most recent meal date if access is granted, else `null`.

### 5.5 Settings 设置 (`pages/Settings.tsx`)

- Data:
  - `me` from context.
  - `GET /users` (for the "选择成员" picker).
  - Local theme preference.
- Header:
  - Title `设置`, subtitle `@${username}`.
  - Button `退出登录` (LogOut icon) → `POST /auth/logout` → `refreshMe()`, which drops to Login.
  - iOS: call logout (it deletes the app session server-side), then delete the Keychain token.
- Mobile-only quick links (4 tight cards): `周期报告` / `食物库` / `社区` / `标准库` (see §2.3).

**Card `个人档案`**

- Hint `修改后所有历史评分会按新档案重新计算`.
- Body: **ProfileForm** (`initial = me.profile`, submit text `保存`; §5.6).

**Card `资料与分享`** (anchor `share`):

- Local state starts from `me.user`: `{display_name, avatar_color, share_mode, share_detail, share_with}`.
- Fields:
  - `昵称`: text field (server max 32 chars; an empty string keeps the old name).
  - `头像颜色`: 8 circular swatches, 28 pt, in this order: `#2f7d5b #3b6fb6 #b5523b #7a5bb5 #b58a2f #2f8c93 #b53b72 #5b7a2f`. The selected swatch gets a 3 pt `ink` border; the others a 2 pt `surface` border.
  - `谁能看到我的每日数据（所有人都能看到你的用户名）`: Seg `仅自己` (`private`) / `所有成员` (`public`) / `指定成员` (`selected`).
  - If `share_mode != private`: `共享内容` Seg `仅评分与趋势` (`summary`) / `完整记录（含吃了什么）` (`full`).
  - If `share_mode == selected`: `选择成员`, a wrapping list of toggle chips (Avatar + display_name), one per other user (`!is_me`). It toggles their id in `share_with`. If `users.count ≤ 1`: muted `还没有其他成员`.
- Primary button `保存` (right-aligned):
  1. `PUT /settings` with **all five fields**: `{display_name, avatar_color, share_mode, share_detail, share_with}`.
  2. `refreshMe()`.
  3. Toast `已保存`.
  4. Errors → error toast.
- Meaning of the share options:
  - `summary`: other people see scores and trends, but meals, exercises, item messages and hazard food names are stripped.
  - `full`: everything.

**Card `外观`**

- Seg `跟随系统` (Monitor icon, `system`) / `浅色` (Sun, `light`) / `深色` (Moon, `dark`).
- It is local only. The web stores it in `localStorage["nl-theme"]` (removed for system); iOS uses UserDefaults.

**`AI` section** (same card): a banner with a Sparkles icon.

- `me.ai.provider == "mock"`: `未配置 AI：使用离线关键词估算。在服务器上安装并登录 Claude Code（claude -p），或设置 ANTHROPIC_API_KEY 后重启即可启用。`
- otherwise: `当前使用 ${me.ai.model}（${provider == "cli" ? "claude -p 命令行" : "Anthropic API"}）`

**Card `修改密码`**

- Fields: `原密码` (secure field), `新密码` (secure field).
- Button `修改`, enabled only if old is non-empty and new length ≥ 6:
  1. `POST /auth/password` with `{old_password, new_password}`.
  2. Clear both fields.
  3. Toast `密码已修改`.
  4. Errors → error toast (`原密码不正确`, `密码至少 6 位`).
- Changing the password does **not** revoke existing app tokens.

**iOS additions** (no web UI exists, but the endpoints do):

- "已登录设备" via `GET /auth/sessions` / `DELETE /auth/sessions/{id}` (§6).
- A HealthKit permissions/sync section (other spec).

### 5.6 ProfileForm 个人档案表单 (`components/ProfileForm.tsx`)

Used by Onboarding (no `initial`, submit text `开始记录`) and by Settings (`initial = me.profile`, submit text `保存`).

**Defaults when there is no initial profile:**

```json
{ "sex": "male", "birth_date": "1995-01-01", "height_cm": 170, "weight_kg": 65,
  "activity_level": "low_active", "goal": "maintain", "goal_rate_kg_week": 0.5,
  "target_weight_kg": null, "physiology": "none", "sodium_mode": "cdrr", "conditions": [],
  "timezone": "<device IANA tz, fallback Asia/Shanghai>", "nicotine": "unknown", "secondhand_smoke": false }
```

**Fields in order** (two-column grid on desktop, single column on phone):

1. `性别`: Seg `男` (`male`) / `女` (`female`).
2. `出生日期`: date picker (`YYYY-MM-DD`).
3. `身高`: number field with suffix `cm`.
4. Weight: label **`当前体重`** in onboarding, **`建档体重`** in Settings. Number field (step 0.1), suffix `kg`. In Settings, help text: `日常体重请在“身体与运动”中记录，评分会自动使用最近一次称重`.
5. `日常活动水平（NASEM 2023 能量方程分档）`:
   - A 2-column grid of radio cards from `meta.activityLevels`. Each card shows a radio dot + **bold `zh`**, with small muted `desc` below.
   - The selected card gets an `accent` border and `accent-soft` background.
   - Help: `如果连接了苹果健康的步数/活动能量，每天的消耗会用实测数据，这里只作为没有数据时的基准。`
   - The levels (from meta) are:

     | key | zh | desc |
     |---|---|---|
     | `inactive` | 久坐 | 办公室工作，几乎不运动（PAL 1.0–1.53） |
     | `low_active` | 轻度活动 | 每天步行约 30–60 分钟或少量运动（PAL 1.53–1.68） |
     | `active` | 活跃 | 每天中等强度运动约 1 小时（PAL 1.68–1.85） |
     | `very_active` | 非常活跃 | 体力劳动或每天高强度训练（PAL 1.85–2.5） |

6. `目标`: Seg `减重` (`lose`) / `维持` (`maintain`) / `增重` (`gain`).
7. If goal ≠ maintain: `目标速度`, a picker over `[0.25, 0.5, 0.75, 1]`. Each option is labeled `每周 ${r} kg（约 ${round(r*7700/7)} kcal/天）`:
   - `每周 0.25 kg（约 275 kcal/天）`
   - `每周 0.5 kg（约 550 kcal/天）`
   - `每周 0.75 kg（约 825 kcal/天）`
   - `每周 1 kg（约 1100 kcal/天）`
8. If goal ≠ maintain: `目标体重`, a number field (step 0.1), suffix `kg`. Empty → `null`.
9. If sex == female: `特殊生理阶段`, Seg `无` (`none`) / `孕期` (`pregnant`) / `哺乳期` (`lactating`). Help: `孕期/哺乳期会使用对应的 DRI（如铁 27 mg、叶酸 600 µg），酒精与咖啡因限值更严格，且不建议主动减重。`
10. `健康状况（会收紧相应标准）`: toggle chips from `me.conditions` (fallback `meta.conditions`). The tooltip is `effect`; on iOS, show it as a caption or context menu. Values:

    | key | zh | effect |
    |---|---|---|
    | `hypertension` | 高血压 | 钠上限收紧到 1500 mg（AHA） |
    | `high_ldl` | 高胆固醇 / 高 LDL | 饱和脂肪理想值收紧到 6% 能量（AHA） |
    | `diabetes` | 糖尿病 / 糖尿病前期 | 添加糖上限收紧到 AHA 建议值 |
    | `kidney` | 慢性肾病 | 仅提示：蛋白质、钾、磷目标请遵医嘱，本系统不据此加分 |
    | `gout` | 痛风 / 高尿酸 | 仅提示：注意红肉、海鲜、酒精与含糖饮料 |

11. `吸烟情况（AHA Life's Essential 8 的“尼古丁暴露”）`: a picker with these options:
    - `unknown` 不填写（LE8 不计这一项）
    - `never` 从不吸烟
    - `former_5y` 已戒烟 5 年以上
    - `former_1_5y` 已戒烟 1–5 年
    - `former_lt1y` 戒烟不到 1 年
    - `ecig` 使用电子烟
    - `current` 目前吸烟
12. `二手烟`: a checkbox/toggle labeled `家中有人在室内吸烟` → `secondhand_smoke`.
13. `钠上限标准`: Seg `2300 mg（DGA/NASEM）` (`cdrr`) / `1500 mg（AHA 理想）` (`aha`).
14. `时区（决定“今天”从何时开始）`: a picker over this list:
    `Asia/Shanghai, Asia/Hong_Kong, Asia/Taipei, Asia/Tokyo, Asia/Singapore, Europe/London, Europe/Berlin, America/New_York, America/Chicago, America/Los_Angeles, Australia/Sydney`
    If the current value is not in the list, it is prepended.
15. Primary large button (right-aligned) = submit text. It shows a spinner while busy.
    1. `PUT /profile` with the **entire profile object**.
    2. `refreshMe()`.
    3. Toast `档案已保存，评分已按新档案重新计算`.
    4. Errors → error toast.

**Server behavior (`PUT /profile`)**

- Validation:
  - `sex` is required (`male|female`); an invalid value → 400 `取值必须是 male / female`.
  - `birth_date` is required, format `YYYY-MM-DD`.
  - `height_cm` 80–250; `weight_kg` 20–350.
  - `goal_rate_kg_week` 0.1–1 (missing → 0.5).
  - `target_weight_kg` 20–350 or null.
- Enum fields that are invalid or missing **silently fall back to defaults**: activity `low_active`, goal `maintain`, physiology `none` (always `none` for males), sodium `cdrr`, nicotine `unknown`.
- `conditions` is filtered to known keys. `timezone` must be a valid IANA zone, else `Asia/Shanghai`.
- **Always send every field**, or values reset to their defaults.
- On first creation, the server also inserts a weight record: today, 08:00, `weight_kg`, note `建档体重`, source `profile`.
- All cached daily scores are invalidated.
- Response: `{ "ok": true, "profile": Profile }`.

### 5.7 Onboarding 建档 (`pages/Onboarding.tsx`)

Shown when `me.profile == null` (right after registration). Centered, max width 720, padding 32/16/64.

- A brand mark (34 pt accent rounded square with a white Leaf) next to:
  - h1 `你好，${me.user.display_name}！先建立个人档案`
  - Small muted paragraph: `身高、体重、年龄和性别决定你的营养目标（DRI 分人群）、能量需求（NASEM 2023 方程）和按体重计算的限量（如蛋白质、咖啡因、阿斯巴甜 ADI）。`
- A card containing **ProfileForm** with submit text **`开始记录`**.
- Once saved, `refreshMe()` sees the profile and enters the main shell.

### 5.8 Login / Register 登录注册 (`pages/Login.tsx`)

**Layout:** a two-column page; on phone the art panel is stacked on top (min height 220).

- **Art panel** (`accent` background):
  - Brand: a translucent white square (rgba 255,255,255,.14) with a white Leaf, and white `食迹 NutriLog` (700, 18 pt).
  - h1 (white, 36 pt; 26 on phone): `把每一餐，` / `变成看得见的健康趋势` (with a line break).
  - Feature list (white at 88 %, icon + text):
    - Sparkles `用一句话描述吃了什么，Claude 自动拆解成 40+ 种营养素与食物组`
    - ShieldAlert `对照美国 DRI、膳食指南、HEI-2020 与 IARC 致癌物分级逐项打分`
    - ChartLine `摄入、消耗、体重交叉对照，按日 / 周 / 月 / 年追踪`
    - Users `和家人朋友一起记录，自己决定分享哪些数据`
  - Footer (small, 60 % opacity): `评分仅用于自我管理参考，不构成医疗建议。`
- **Form card** (max width 400, padding 28):
  - Title (22 pt): login `欢迎回来` / register `创建账号`.
  - Sub (muted): login `登录以继续记录` / register `注册后先建立个人档案`.
  - Fields:
    - `用户名` (required, username content type).
    - Register only: `昵称（其他成员看到的名字）` (optional).
    - `密码` (required, secure; register requires min length 6).
    - Register only: `邀请码（站点设置了才需要）` (optional).
  - Submit button (primary, large, full width): `登录` / `注册`. Spinner while busy.
  - Toggle (ghost, full width): `还没有账号？注册` / `已有账号？登录`.
  - Errors → error toast with the server message.

**iOS API flow** (replaces the web cookie flow):

- Login: `POST /auth/token` with `{username, password, device_name}` → `{token, expires_at, user}`. Store `token` in the Keychain, then `GET /auth/me`.
- Register: `POST /auth/register` with `{username, password, display_name, invite_code, device_name}`. With `device_name` it returns `{ok: true, token, expires_at}` (**no `user` object**). Store the token, then `GET /auth/me` → profile is null → Onboarding.
- Suggested `device_name`: `UIDevice.current.name`, or "iPhone · NutriLog" (server trims it to 60 chars).
- Messages:
  - Login: 401 `用户名或密码错误`. (The live OpenAPI lists 400; the code returns **401**.)
  - Register:
    - 403 `当前站点已关闭注册`
    - 400 `邀请码不正确`
    - 400 `用户名为 2–32 位，可用中文、字母、数字、_ . -` (regex `^[\w一-龥.-]{2,32}$`)
    - 400 `密码至少 6 位`
    - 400 `用户名已被占用`
    - 400 `用户名不能为空` / `密码不能为空`
- `display_name` defaults to the username when empty. The avatar color is assigned at random from the 8 colors.

### 5.9 Foods 食物库 (`pages/Foods.tsx`)

**Purpose:** a personal and shared library of foods with per-100 g nutrients. Saved foods are reused when logging meals without calling the AI.

#### 5.9.1 List screen

- Header:
  - Title `食物库`.
  - Subtitle `常吃的包装食品、外卖、自制菜存下来，下次直接搜索并填克数，无需再调用 AI`.
  - Buttons: `手动录入` (Plus) opens the editor with a blank food; primary `AI 查询 / 拍营养表` (Sparkles) opens the AI lookup sheet.
- Controls:
  - Search field (max width 320), placeholder `搜索名称、品牌、别名…`, trailing Search icon. **Debounced 250 ms.**
  - Seg `全部可用` (`all`, default) / `我创建的` (`mine`).
- Data: `GET /foods?q=${q}&scope=${scope}`. `q` is omitted when empty.
  - The server returns up to **200** foods: own foods first, then by `use_count` descending, then `updated_at` descending.
  - Search uses `LIKE %q%` on name, brand and aliases. `q` is trimmed to 60 chars.
  - `all` = own foods + every public food from other users.
- States:
  - First load: `Loading`.
  - Empty array (including no search matches): a card with the Library icon and `还没有食物。记一餐时 AI 分析出的食物可以一键“存入食物库”，也可以在这里用 AI 联网查询或拍营养成分表添加。`
- **Food card** (3-column grid; 1 column on phone; tappable):
  - Row: **`name`** (15.5 pt bold) on the left; on the right a visibility icon: Globe (`公开`) if `visibility == public`, else Lock (`私有`), in `ink-3`.
  - Subtitle (small, muted): `[brand, serving_desc || (serving_g ? "一份 ${fmt(serving_g)} g" : "")]`, empty parts filtered out, joined with ` · `.
  - Macro line (12.5 pt, `ink-2`, bold values `ink-1`):
    - `每 100 g **${fmt(per100.energy_kcal)}** kcal`
    - `蛋白 **${fmt(per100.protein_g, 1)}**`
    - `钠 **${fmt(per100.sodium_mg)}**mg`
  - Chips:
    - `SOURCE_ZH[source] ?? source`
    - if `nova_group`: `NOVA ${nova_group}`
    - if `use_count > 0`: `用过 ${use_count} 次`
    - if `!mine`: accent chip `来自 ${owner_name}`

Lookup tables:

- `SOURCE_ZH`: `label` 营养标签, `ai_search` AI 联网查询, `ai_estimate` AI 估算, `manual` 手动录入.
- `NOVA_ZH`: `1` 未加工, `2` 烹饪原料, `3` 加工食品, `4` 超加工.
- `CATEGORY_ZH` (picker order):
  - `staple` 主食
  - `vegetable` 蔬菜
  - `fruit` 水果
  - `meat` 肉类
  - `poultry` 禽肉
  - `seafood` 水产
  - `egg` 蛋类
  - `dairy` 奶制品
  - `soy_legume` 豆制品/豆类
  - `nut_seed` 坚果种子
  - `snack` 零食
  - `dessert` 甜点
  - `beverage` 饮品
  - `alcohol` 酒类
  - `condiment` 调味品
  - `fast_food` 速食/快餐
  - `dish` 菜肴
  - `supplement` 补充剂
  - `other` 其他

#### 5.9.2 Food detail (wide modal / sheet)

- Title: `name` + muted small `brand`.
- Chips:
  - `CATEGORY_ZH[category ?? "other"]`
  - if `nova_group`: `NOVA ${n} · ${NOVA_ZH[n]}`
  - `SOURCE_ZH[source]`
  - One chip per `hazards100` entry: text = `meta.hazards[key].zh` (fallback `key`), colored like the IARC chip of that hazard's `iarc`.
- `notes` (small, secondary), if non-empty.
- `配料：${ingredients}` (small, muted), if non-empty.
- Source links: a link icon + each `source_urls[i].title` linking to `.url` (opens in Safari).
- Nutrient table, with `s = serving_g ?? 100`. Headers: `营养素` | `每 100 g` | `每份 ${fmt(s)} g` | `占标签 DV`. One row per `meta.nutrients` entry (all 43, in meta order), with `v = per100[key] ?? 0`:
  - Name: `zh`, plus an accent mini-chip `标签` if `key ∈ label_fields`.
  - Per 100 g: `fmt(v, decimals)` + muted `unit`.
  - Per serving: `fmt(v*s/100, decimals)`.
  - DV: if `dv`, `"${fmt(v*s/100/dv*100)}%"`; else blank.
- Footer (**only if `mine`**):
  - `删除` (danger, Trash2): confirm `删除这个食物？已记录的餐食不受影响。` → `DELETE /foods/{id}` → toast `已删除` → close and reload.
  - `编辑` (primary, Pencil): opens the editor prefilled from the food. Nulls become `""`, `serving_g ?? 100`, `category ?? "other"`.

#### 5.9.3 AI lookup sheet (`AI 查询营养信息`)

- Intro (small, secondary): `输入产品名称让 ${me.ai.model ?? "Claude"} 联网查找官方营养成分表；或者上传包装、配料表、营养成分表照片，直接读取标签数值（更准确）。`
- Fields:
  - `名称`, placeholder `如：螺蛳粉` (autofocus).
  - `品牌`, placeholder `如：李子柒`.
  - `补充说明（可选）`, placeholder `如：原味 335g 袋装；我一般只喝一半汤`.
  - `照片（可选）`: a row of 72×72 thumbnails (radius 10) plus a dashed "add" tile with a Camera icon (aria `添加照片`).
- Photo upload:
  - Selecting photos uploads them **immediately** via `POST /uploads` (multipart field `photos`, JPEG/PNG/WebP, up to 6 files, ≤ 12 MB each). The response's `{id, url}` items are appended.
  - **Convert HEIC to JPEG before uploading.** The server rejects HEIC with 400 `请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）`.
  - Thumbnails load from `url` (`/api/uploads/<id>`, auth required; see §7).
- Footer button `开始` (Sparkles):
  - Disabled while busy, or when `name.trim()` is empty **and** there are no photos.
  - While busy it shows a spinner + elapsed seconds (`${elapsed}s`, updated every 0.5 s).
- Busy text (small, muted, pulsing): `正在读取标签…` if there are photos, else `正在联网查找营养成分表…`, followed by ` 一般需要 30–120 秒`.
- Flow:
  1. `POST /ai/food` with `{name, brand, note, photos: [ids]}` → `{job_id}`. With no name and no photos → 400 `请输入食物名称或上传包装/营养成分表照片`.
  2. Poll the job → `FoodDraft`.
  3. Close the sheet and open the editor prefilled with `{...blank, ...draft, aliases: draft.aliases.joined(","), source_urls: draft.sources, hazards100: draft.hazards100, source: draft.source}`.
  4. Errors → error toast.
- With the mock provider, the draft has `notes: "离线估算（未配置 AI），请手动核对标签数值"`, `confidence: "low"` and `provider: "mock"`.

#### 5.9.4 Food editor (wide modal / sheet)

- Title: `编辑食物` if `id` exists, else `保存到食物库`.
- Footer: `保存` (primary), disabled while busy or when `name` is empty.
- Content, in order:
  1. If `notes` is non-empty and `source != manual`: an accent banner with a Sparkles icon + `notes`.
  2. Source links (as in the detail view).
  3. A 3-column grid:
     - `名称`
     - `品牌`
     - `分类` (picker over CATEGORY_ZH)
     - `一份重量` (number, suffix `g`)
     - `份量描述` (placeholder `1 包 335 g`)
     - `加工程度 (NOVA)`: picker with `未知` (null), then `1 · 未加工` … `4 · 超加工`
  4. A 2-column grid:
     - `别名（逗号分隔，用于搜索和自动匹配）`: text
     - `可见范围`: Seg `仅自己` (`private`) / `所有成员可用` (`public`)
  5. Section header h3 `每 100 g 营养成分`, with a right-aligned checkbox `显示全部 ${meta.nutrients.count} 项`.
     - Default checked if editing an existing food or `source != manual`; unchecked for a new manual entry.
     - When unchecked, only these 10 keys show: `energy_kcal, protein_g, fat_g, sat_fat_g, trans_fat_g, carb_g, sugars_g, added_sugars_g, fiber_g, sodium_mg`.
     - Grid of number fields (auto-fill, min 190 pt):
       - Label: `zh`, plus a `标签` chip if the key is in `label_fields`.
       - Value: `per100[key]` rounded to 3 decimals, or empty. Typing sets `Number(text)`, so an empty field becomes 0.
       - Suffix: `unit`.
     - When unchecked, a footnote: `营养标签上通常只有这几项；其余营养素留空按 0 计，也可以让 AI 查询补全。`
  6. `配料表（可选）`: multiline text (2 rows).
- `groups100` and `hazards100` are **not editable**, but they are preserved and sent back.
- Save:
  1. Build the body = the full state, with `aliases` split on `[,，、]+`, trimmed, empties removed → array of strings.
  2. `PUT /foods/{id}` if the food has an id, else `POST /foods`.
  3. Toast `已保存到食物库`, close, reload the list.
  4. Errors → error toast.

### 5.10 Standards 标准库 (`pages/Standards.tsx`)

- Header:
  - Title `标准库`.
  - Subtitle `本站离线评分使用的全部标准：美国 NASEM DRI、膳食指南 DGA 2020–2025 / 2025–2030、HEI-2020、FDA、AHA、IARC、WCRF、体力活动指南`.
- Tabs (the URL `?tab=` keeps the state; default `mine`). Labels in order:
  1. `我的个性化目标` (`mine`)
  2. `DRI 总表` (`dri`)
  3. `致癌物与风险物` (`hazards`)
  4. `HEI-2020` (`hei`)
  5. `运动 MET` (`met`)
  6. `评分规则` (`rules`)
  7. `资料来源` (`sources`)

  Today links straight to the `rules` tab ("评分依据"); support deep-linking to a tab.
- Data: `mine` → `GET /profile/targets`; `dri` → `GET /standards/dri`; all other tabs use the cached `meta`. Each shows `Loading` until its data is available.

**Tab `mine`, 我的个性化目标**

- 4 stat tiles:

  | label | value | suffix | delta |
  |---|---|---|---|
  | `适用人群` | `lifeStageZh` (font 20) | | `${age} 岁${sensitive ? " · 敏感人群" : ""}` |
  | `BMI` | `fmt(bmi, 1)` | | `${bmiCategory.zh}${referenceWeightKg != weightKg ? " · 按体重的目标使用校正体重 ${fmt(referenceWeightKg, 1)} kg" : ""}` |
  | `基础代谢 / 能量需求` | `fmt(bmr)` | `/ ${fmt(eer)} kcal` | `eerMethod` |
  | `每日能量目标（无活动数据时）` | `fmt(energyTarget)` | `kcal` | `goalDeltaKcal != 0 ? "含目标调整 ${sign}${fmt(goalDeltaKcal)}" : "维持"` |

- Card `推荐摄入量（下限，越接近越好）`, hint `RDA = 推荐膳食供给量；AI = 适宜摄入量`.
  - Table columns: `营养素` | `目标` | `类型` | `UL 上限`.
  - Rows: `meta.nutrients` (meta order) that have an `intake[key]`:
    - Name: `zh`, plus a small muted `note` line if present.
    - Target: `${fmt(value, decimals)} ${unit}`.
    - Type: `kind` (`RDA`/`AI`).
    - UL: `upper[key] ? "${fmt(upper.value, decimals)}${appliesToTotal ? "" : "*"}" : "—"`.
  - Footnote: `* 该 UL 只针对补充剂/强化食品或特定形式（如预制维生素 A、合成叶酸），食物总量不参与 UL 评分。`
- Card `限量标准（上限，越少越好）`.
  - Table columns: `项目` | `理想` | `上限` | `依据`.
  - One row per `Object.values(limits)`, in server insertion order (sodium, added sugars, sat-fat %, trans fat, alcohol, caffeine, UPF %):
    - Item: `zh`, plus a small muted `note`.
    - Ideal: `${fmt(ideal,1)} ${unit}`.
    - Limit: `${fmt(limit,1)} ${unit}`.
    - Basis: SourceLinks over the unique `[idealSource, limitSource]`.
  - Then two fixed rows:
    - `每餐添加糖` | `0` | `${addedSugarPerMealG} g` | SourceLinks `["dga_2025"]`
    - `阿斯巴甜 ADI（按体重）` | `—` | `${fmt(aspartameAdiMg)} mg` | SourceLinks `["iarc_aspartame"]`
  - Divider, then h3 `宏量营养素可接受范围（AMDR）` and a key/value list:
    - `蛋白质`: `${amdr.protein[0]}–${amdr.protein[1]}% 能量（RDA ${fmt(protein.rdaG)} g；DGA 2025–2030 建议 ${fmt(protein.idealLowG)}–${fmt(protein.idealHighG)} g）`
    - `碳水化合物`: `${amdr.carb[0]}–${amdr.carb[1]}% 能量`
    - `脂肪`: `${amdr.fat[0]}–${amdr.fat[1]}% 能量`

**Tab `dri`, DRI 总表** (`GET /standards/dri`)

- Card head: Seg `RDA / AI 推荐量` (`intake`) / `UL 可耐受最高摄入量` (`upper`), plus hint `来源：NASEM DRI 汇总表（钠/钾为 2019 版）`.
- A wide table that scrolls both ways (max height 620, 12.5 pt) with a **sticky first column** `营养素`. The remaining columns are the 20 life stages (`lifeStages[i].zh`).
- Rows: `Object.entries(intake | upper)`, in server order. Each row:
  - First cell: `meta.nutrients[key].zh ?? key`, then muted ` ${unit}` plus:
    - intake mode: ` · ${kind}`
    - upper mode: `""` if `appliesToTotal`, else ` · 仅补充剂`
  - Values: `null` → `ND`, else `fmt(v, 2)`.
- Intake mode adds two rows:
  - `蛋白质` + muted `g/kg`: the raw `proteinPerKg[i]` values (unformatted).
  - `钠 CDRR` + muted `mg（超过即应减少）`: `fmt(sodiumCdrr[i])`.

**Tab `hazards`, 致癌物与风险物** (from meta)

- Info banner (verbatim): `IARC 分级表示“证据强度”而不是“危险程度”：加工肉与吸烟同属 1 类，意味着致癌证据同样充分，而不是危害同样大。没有权威机构发布过把这些分级换算成扣分的方法，所以本站只按剂量给出警示、不另设扣分；其中加工肉、红肉、酒精、含糖饮料按 WCRF/AICR 标准化评分计分。`
- A 2-column grid with one card per `meta.hazards` entry:
  - Row: h3 `zh` + IarcChip(`iarc`) + muted `en`.
  - `**风险：**${risk}`
  - `**判定：**${detect}`
  - `**例：**${examples}` (secondary)
  - `**建议：**${advice}` (accent-text color)
  - SourceLinks(`sources`)
- Card `已知但不警示的项目`, a table with columns `项目` | `分级` | `常见来源` | `原因`, built from `meta.hazardsInfoOnly`.
  - Grade cell: if `iarc == "3"`, a plain chip `IARC 3 类`; else IarcChip.

**Tab `hei`, HEI-2020** (from `meta.hei`)

- Card `HEI-2020 组分与评分标准`, hint `满分 100；按每 1000 kcal 密度计算，两端之间线性插值`.
- Table columns: `组分` | `类型` | `满分` | `满分标准` | `零分标准`. Each row:
  - Component: `zh` + muted `en`.
  - Type: `kind == "adequacy"` → `充足（越多越好）`, else `适度（越少越好）`.
  - Max: `max`.
  - Full-score criterion: `"${kind == adequacy ? "≥" : "≤"} ${best} ${unit}"`.
  - Zero-score criterion: adequacy → `worst != 0 ? "≤ ${worst}" : "0"`; moderation → `"≥ ${worst}"`. Followed by ` ${unit}`.
  - Numbers are printed raw, without `fmt`.
- Footnote: `豆类同时计入“蔬菜总量”“深绿色蔬菜与豆类”“蛋白质食物”“海产与植物蛋白”四个组分（HEI-2015 起的做法）。`

**Tab `met`, 运动 MET** (from `meta.activities`)

- Card `运动代谢当量（2024 Adult Compendium）`, hint `净消耗 = (MET − 1) × 体重 × 小时，扣除静息部分避免与基础代谢重复`.
- Table columns: `活动` | `MET` | `强度` | `典型速度`.
  - Intensity: `vigorous` → `高强度`, `moderate` → `中等`, else `轻度`.
  - Speed: `"${speedKmh} km/h"`, or `—`.

**Tab `rules`, 评分规则** (static text, verbatim)

- Accent banner:
  `评分规则 v2：各分项全部采用已发表、经同行评议的评分体系。“美国心脏协会 LE8”“WCRF/AICR”“MAR”都是等权合成；HEI-2020 的组分分值由 USDA 规定。`
  (line break)
  `总分（满分 100）是本站按自定权重把分项合成的一个数字，没有权威出处：每天 = HEI × 50% + MAR × 15% + 能量平衡 × 15% + 身体活动 × 20%；每周 = 周期 HEI × 40% + MAR 日均 × 10% + LE8 × 35% + WCRF（折算百分制）× 15%。缺少的分项不计入，其余按权重折算。`
- Card h2 `每日：膳食质量 HEI-2020 + 微量营养素 MAR`, a key/value list:
  - `今日膳食质量`: `HEI-2020 总分（USDA / NCI）。13 个组分按每 1000 kcal 的密度在“零分标准”与“满分标准”之间线性计分，分值见“HEI-2020”标签页。例如钠 ≤1.1 g/1000 kcal 得 10 分，≥2.0 g 得 0 分，页面会写明“钠组分扣 x 分”。美国人平均 ${meta.heiUsMean} 分（NHANES 2017–2018）。`
  - `微量营养素 MAR`: `平均充足比（Madden & Yoder 1972；FAO 最低膳食多样性验证研究采用的 11 种微量营养素：${meta.marNutrients.map{nutrient zh}.joined("、")}）。每种 NAR = min(摄入 ÷ RDA, 1)，等权平均 × 100。注：IOM 指出按 RDA 判断个人单日摄入只是粗略参考。`
    The resolved list is: 维生素 A、维生素 B1 (硫胺素)、维生素 B2 (核黄素)、烟酸 (B3)、维生素 B6、叶酸 (B9)、维生素 B12、维生素 C、钙、铁、锌.
  - `其他检查项`: `其余营养素对照 RDA/AI；钠（CDRR 2300 mg / AHA 1500 mg）、添加糖、饱和脂肪、反式脂肪、酒精、咖啡因、超加工食品、每餐添加糖、AMDR、UL；能量平衡。这些只标“达标 / 偏离 / 不达标”并写明超出多少，不另设权重。`
  - `致癌物与风险物`: `按 IARC 分级给出警示与剂量，不另设扣分；加工肉、红肉、酒精、含糖饮料在 WCRF/AICR 评分中计分。`
- Card h2 `综合：美国心脏协会 Life's Essential 8（LE8）`.
  - Paragraph: `Lloyd-Jones DM et al., Circulation 2022。8 项各 0–100 分，**总分 = 已有指标的等权平均**（缺失指标不计入分母，按官方补充材料）；80–100 高，50–79 中，0–49 低。今日页显示近 7 天，周报 / 月报显示整个周期。`
  - A table with two columns (bold label 200 pt | small rule):

    | label | rule |
    |---|---|
    | 饮食 | 个人用 MEPA 16 题问卷：15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0（本站由饮食记录自动推算每周份数） |
    | 身体活动（分钟/周，高强度 ×2） | ≥150 → 100；120–149 → 90；90–119 → 80；60–89 → 60；30–59 → 40；1–29 → 20；0 → 0 |
    | 尼古丁暴露 | 从不 100；戒 ≥5 年 75；戒 1–5 年 50；戒 <1 年或电子烟 25；吸烟 0；家中有人室内吸烟 −20 |
    | 睡眠（小时/晚） | 7–<9 → 100；9–<10 → 90；6–<7 → 70；5–<6 或 ≥10 → 40；4–<5 → 20；<4 → 0 |
    | BMI | <25 → 100；25–29.9 → 70；30–34.9 → 30；35–39.9 → 15；≥40 → 0 |
    | 非 HDL 胆固醇（mg/dL） | <130 → 100；130–159 → 60；160–189 → 40；190–219 → 20；≥220 → 0；服药 −20 |
    | 血糖 | 无糖尿病：空腹 <100 或 HbA1c <5.7 → 100；100–125 或 5.7–6.4 → 60；糖尿病：HbA1c <7 → 40，7–7.9 → 30，8–8.9 → 20，9–9.9 → 10，≥10 → 0 |
    | 血压（mmHg） | <120/<80 → 100；120–129/<80 → 75；130–139 或 80–89 → 50；140–159 或 90–99 → 25；≥160 或 ≥100 → 0；服药 −20 |

- Card h2 `防癌：2018 WCRF/AICR 标准化评分`.
  - Paragraph: `Shams-White MM et al., Nutrients 2019。7 条建议各 1 分、等权，子项平分该条的 1 分（母乳喂养为可选项，不计）。`
  - Table:

    | label | rule |
    |---|---|
    | 保持健康体重 | BMI 18.5–24.9 → 0.5，25–29.9 → 0.25；腰围 男 <94 / 女 <80 cm → 0.5，男 94–101.9 / 女 80–87.9 → 0.25（只有一项时分数加倍） |
    | 积极运动 | 中高强度 ≥150 分钟/周 → 1；75–149 → 0.5；<75 → 0 |
    | 多吃全谷物、蔬菜、水果、豆类 | 果蔬 ≥400 g/天 → 0.5（200–399 → 0.25）；膳食纤维 ≥30 g/天 → 0.5（15–29 → 0.25） |
    | 少吃快餐和加工食品 | 原文按研究人群内超加工供能比的三分位数评分，没有绝对切点 —— 本站只展示、不计分 |
    | 限制红肉和加工肉 | 红肉 ≤500 g/周且加工肉 <21 g/周 → 1；加工肉 21–99 g/周 → 0.5；红肉 >500 或加工肉 ≥100 → 0 |
    | 限制含糖饮料 | 0 → 1；≤250 ml/天 → 0.5；>250 → 0 |
    | 限制饮酒 | 不饮酒 → 1；男 ≤28 / 女 ≤14 g 纯酒精/天 → 0.5；以上 → 0 |

- Card h2 `能量与体重`, paragraph: `能量需求：NASEM 2023 EER 方程（19 岁以上）；基础代谢：Mifflin-St Jeor。有设备数据时，消耗 = (静息 + 活动能量 + 未被设备记录的运动) ÷ 0.9；运动净消耗 = (MET − 1) × 体重 × 小时（2024 Compendium）。体重趋势用指数移动平均（α = 0.1）；“反推日消耗” = 日均摄入 − 趋势体重变化 × 7700 ÷ 天数。能量平衡只标状态，体重结果体现在 LE8 的 BMI 与 WCRF 的健康体重中。`

**Tab `sources`, 资料来源** (from `meta.sources`; 36 entries)

A list. Each row has a chip with `year` (min width 60, centered), then the title in weight 600 (a link if `url` is non-empty), then `org` (small, muted).

---

## 6. API reference (endpoints used by the screens above)

All endpoints are under `/api/v1`. "Auth" = `Authorization: Bearer nla_…` required. A 401 response is possible on every authenticated endpoint. Every error body is `{error}`.

### 6.1 Account and auth

**`POST /auth/token`** (no auth): App login.

- Body: `{ username: string (required), password: string (required), device_name?: string (≤ 60, default "App") }`
- 200: `{ token: string ("nla_…"), expires_at: string (ISO-8601 UTC, e.g. "2027-10-03T09:00:00.000Z"), user: User }`. Here `user` has **no** `share_with`.
- 400 `用户名不能为空` / `密码不能为空`; 401 `用户名或密码错误`.

**`POST /auth/register`** (no auth)

- Body: `{ username, password, display_name?, invite_code?, device_name? }`
- 200, with `device_name`: `{ ok: true, token, expires_at }`. Without it: `{ ok: true }` + a web cookie (do not use).
- Errors: §5.8.

**`POST /auth/logout`** (no auth required; send the Bearer so its session is deleted): deletes the session belonging to the presented token (cookie first, else Bearer) → always `{ ok: true }`, never 401. Send a `{}` JSON body.

**`GET /auth/me`** (Auth) → `Me`:

```json
{ "user": { "id": 1, "username": "demo", "display_name": "演示用户", "avatar_color": "#2f7d5b",
            "share_mode": "private|public|selected", "share_detail": "summary|full",
            "api_token_hint": "nl_abcd…wxyz" | null, "share_with": [2, 3] },
  "profile": Profile | null,
  "today": "2026-10-03",
  "ai": { "provider": "cli|api|mock", "model": "claude-opus-5-5" | "offline" },
  "conditions": [ { "key": "hypertension", "zh": "高血压", "effect": "…" }, … ] }
```

**`POST /auth/password`** (Auth)

- Body: `{ old_password: string, new_password: string (≥ 6) }` → `{ ok: true }`.
- 400 `原密码不正确` / `新密码不能为空` / `密码至少 6 位`.

**`GET /auth/sessions`** (Auth): not used by the web; useful on iOS.

- Returns `[{ id: number (rowid), kind: "web"|"app", device_name: string|null, created_at: string|null, last_used_at: string|null, expires_at: string }]`, sorted by `last_used_at` descending.
- `created_at` / `last_used_at` use the SQLite format `"YYYY-MM-DD HH:MM:SS"` (UTC). `expires_at` is ISO.

**`DELETE /auth/sessions/{id}`** (Auth) → `{ ok: true }`. Only deletes the caller's own sessions; no error for unknown ids.

**`PUT /profile`** (Auth)

- Body: the full `Profile` (§5.6) → `{ ok: true, profile: Profile }`.
- Errors: 400 messages per field (Appendix D).

**`GET /profile/targets?date=YYYY-MM-DD`** (Auth)

- `date` is optional (default: today in the profile timezone) → `Targets`.
- 400 `请先完善个人档案`.
- Always the caller's own targets; there is no `user` param.

**`PUT /settings`** (Auth)

- Body:

  ```json
  { "display_name": "string (≤32; empty string = keep current)",
    "avatar_color": "#RRGGBB (must match ^#[0-9a-f]{6}$ case-insensitive, else ignored)",
    "share_mode": "private|public|selected",
    "share_detail": "summary|full",
    "share_with": [userId, …] }
  ```

  → `{ ok: true }`.
- **`share_mode` and `share_detail` fall back to `private` / `summary` when missing or invalid. Always send both.**
- If `share_with` is an array, the grant list is **replaced**. Self ids and unknown ids are ignored.

**`POST /settings/token`** (Auth) → `{ token: "nl_…" }`. Regenerates the personal Shortcuts token; the old one is invalidated. This is the Body page's feature; listed for completeness.

### 6.2 Community

**`GET /users`** (Auth) → `CommunityUser[]` (every registered user, by id):

```json
[{ "id": 2, "username": "alice", "display_name": "Alice", "avatar_color": "#3b6fb6",
   "is_me": false, "shared_with_me": true, "share_detail": "full|summary|none",
   "last_log_date": "2026-10-02" | null, "streak": 5,
   "recent": [ { "date": "2026-09-20", "score": 64 | null }, … 14 items or [] ] }]
```

Semantics: §5.4. This is a potentially slow call, because it computes 14 days of scores per member.

### 6.3 Trends and period reports

**`GET /trends?start&end&user`** (Auth)

- Query:
  - `start`, `end`: `YYYY-MM-DD`, optional. Defaults: `end` = today in the **owner's** timezone; `start` = end − 29.
  - Invalid date strings are ignored, so the defaults apply.
  - `user`: a username to view another member (requires sharing at summary level or above).
- Clamping: if `diffDays(start, end) > 1100`, start becomes end − 1100. `start > end` → 400 `开始日期不能晚于结束日期`.
- 200:

  ```json
  { "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "days": [TrendDay, …] }
  ```

  `days` has one entry per calendar day from start to end inclusive, ascending.
- Errors: 404 `用户不存在`, 403 `对方没有向你共享数据`, 400 `请先完善个人档案` (the owner has no profile).
- `TrendDay` fields (all always present):

  | field | type | meaning |
  |---|---|---|
  | `date` | string | YYYY-MM-DD |
  | `hasData` | bool | the day has ≥ 1 meal item **and** total energy > 0 kcal (a water-only day is `false`) |
  | `score` | number? | HEI-2020 total 0–100, 1 dp; null if no data or < 200 kcal |
  | `total` | number? | daily composite 0–100, 1 dp; null if no data |
  | `categories` | {string: number} | `{"hei": x, "mar": y}` (1 dp); `{}` when no data; a key is missing if that index could not be computed |
  | `hazardCount` | int | hazard warnings that day (red meat only counts when its dose ≥ 72 g) |
  | `hei` | number? | same as `score` when present |
  | `mar` | number? | MAR 0–100, 1 dp |
  | `intake` | number | kcal eaten (integer-rounded) |
  | `tdee` | number | kcal burned (integer) |
  | `target` | number | energy target (integer) |
  | `exerciseKcal` | number | integer |
  | `energyMethod` | string | `measured` (device data) or `eer` (formula) |
  | `weight` | number? | kg, the weigh-in recorded **on that date** (last of the day), else null |
  | `trend` | number? | EMA weight trend (α = 0.1, warmed up with 60 prior days), 2 dp |
  | `steps` | number? | from `activity_days` |
  | `activeKcal` | number? | from `activity_days` |
  | `completeness` | string | `none` / `partial` / `likely` |
  | `totals` | {nutrientKey: number} | all 43 nutrient keys, 2 dp (0 when none) |
  | `groups` | {foodGroupKey: number} | all 22 food-group keys, 2 dp |
  | `macroPct` | {string: number} | `protein, carb, fat, satFat, addedSugar, alcohol`, % of energy, 1 dp |
  | `upfPct` | number | ultra-processed share of energy %, 1 dp |
  | `statuses` | {itemKey: Status} | per scored item, non-`info` statuses only |

- Payload size: each day carries 43 totals + 22 groups + ~60 statuses, so a logged day is roughly 3 KB and an empty day roughly 1.5 KB. An "all" range (up to 1101 days) can reach **~3 MB** of uncompressed JSON (the server has no gzip). Decode it off the main thread. *(Corrected by the completeness review; earlier text said ~1 MB.)*

**`GET /period?start&end&user`** (Auth)

- Same query semantics as `/trends`, except the clamp is **400 days** (start → end − 400 silently).
- 200: a `PeriodScore` (Appendix A/B) plus:
  - `aiSummary: {headline, summary, wins[], issues[], actions[]} | null`. Null unless the viewer has full access and a stored summary exists.
  - `full: bool`.
- Field notes:
  - `days` = number of calendar days in the range; `daysLogged` = days with meals.
  - `avgHei`, `avgMar`: averages over logged days, or null.
  - `score` = LE8 score (nullable). `category` = `{key: "high"|"moderate"|"low", zh: "高"|"中"|"低"}` | null.
  - `total` = the period composite (§5.3.4).
  - `indices` = `HealthIndices` over the period.
  - `hei` = HEI computed on the **period totals**, or null if total kcal < 200. Each component has `{key, zh, max, score, value, best, worst, unit, hint}`.
  - `avgTotals` / `avgGroups` = per-logged-day averages over all keys.
  - `itemStats[]` = `{key, zh, category, good, ok, warn, bad, days}`.
  - `checks[]` = `PeriodCheck`. Possible keys:
    - `red_meat_week`
    - `processed_meat_week`
    - `seafood_week`
    - `alcohol_week`
    - `activity_week`
    - `strength_week`
    - `steps_avg` (only if any step data)
    - `logging`
    - `weight_rate` (only if the goal ≠ maintain and the weight trend spans ≥ 7 days)
  - `hazards[]` = `{key, zh, iarc, dose (sum), unit, days}`, sorted by days descending.
  - `energy` = `{avgIntake?, avgTdee, totalBalance, predictedChangeKg (= totalBalance/7700), trendStart?, trendEnd?, actualChangeKg?, empiricalTdee?, ratePerWeek?}`:
    - `actualChangeKg` needs trend points spanning ≥ 3 days.
    - `ratePerWeek` needs ≥ 7 days.
    - `empiricalTdee` needs ≥ 14 days of trend and ≥ 70 % of days logged as "likely complete".
  - `series[]` = daily `{date, score?, total?, intake, tdee, weight?, trend?}`. **Unrounded.** The web does not use it.

**`POST /period/summary`** (Auth)

- Body: `{ start: "YYYY-MM-DD", end: "YYYY-MM-DD" }` (same defaults and 400-day clamp) → `{ job_id }`.
- Job `kind: "summary"`. Job `result`: `{headline, summary, wins[], issues[], actions[]}` or `null`.
- 400 `请先完善个人档案`.

**`GET /reports`** (Auth): not used by the web; a candidate for an iOS "历史报告" list.

- Returns `[{ id, period: "week"|"month"|"custom", start_date, end_date, score: number|null (LE8), ai_summary: {headline,summary,wins,issues,actions}|null, created_at: "YYYY-MM-DD HH:MM:SS" }]`.
- Newest `start_date` first, max 60 rows.

### 6.4 AI jobs and uploads

**`GET /ai/jobs/{id}`** (Auth) → the Job shape (§1.6). 404 `任务不存在`.

**`GET /ai/status`** (Auth) → `{ provider: "cli"|"api"|"mock", model: string, web_search: bool }`.

**`POST /uploads`** (Auth, `multipart/form-data`)

- Field name `photos`, repeated up to **6** files. Each file ≤ **12 MB**, MIME `image/jpeg|png|webp|gif`.
- 200: `{ photos: [{ id: "<24 hex>.jpg", url: "/api/uploads/<id>" }] }`. Pass the ids to AI endpoints.
- Errors:
  - Non-image files are silently dropped. If none remain → 400 `请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）`.
  - A file that is too big → 413 `文件太大`.

**`GET /uploads/{id}`** (Auth) → the image bytes, only for the caller's own uploads (otherwise 404). `url` is **host-relative**: prefix it with the server origin and send the Bearer header (`AsyncImage` cannot do that; use a custom loader).

### 6.5 Foods

**`GET /foods?q&scope`** (Auth): `q` ≤ 60 chars, optional; `scope` = `mine` or anything else (= `all`) → `Food[]` (≤ 200).

**`GET /foods/{id}`** (Auth) → a `Food` (own foods, or public foods from others); 404 `食物不存在`.

`Food` JSON:

```json
{ "id": 12, "owner_id": 1, "owner_name": "演示用户", "visibility": "private|public",
  "name": "螺蛳粉", "brand": "李子柒" | null, "aliases": "comma,separated,string",
  "category": "staple" | null, "serving_g": 335 | null, "serving_desc": "1 包 335 g" | "" | null,
  "per100": { "<all 43 nutrient keys>": number },
  "groups100": { "<all 22 food-group keys>": number },
  "hazards100": [ { "key": "pickled_vegetables", "amount_per_100g": 10, "note": "" } ],
  "nova_group": 1|2|3|4|null, "ingredients": "…" | "" | null,
  "label_fields": ["energy_kcal", …], "source": "label|ai_search|ai_estimate|manual",
  "source_urls": [ { "title": "…", "url": "https://…" } ], "notes": "…" | "" | null,
  "use_count": 3, "mine": true,
  "created_at": "YYYY-MM-DD HH:MM:SS", "updated_at": "YYYY-MM-DD HH:MM:SS" }
```

- `aliases` is a **string** in responses, but the request accepts an array or a string.
- Treat `""` the same as null for brand, serving_desc, ingredients and notes.

**`POST /foods`** (Auth) / **`PUT /foods/{id}`** (Auth, owner only)

- Body (`FoodInput`):

  | field | rule |
  |---|---|
  | `name` | required, ≤ 80 |
  | `brand` | ≤ 60; empty → null |
  | `aliases` | string[] or comma string; ≤ 300 total |
  | `category` | one of CATEGORY keys, else `other` |
  | `serving_g` | 0.1–10000 or null |
  | `serving_desc` | ≤ 60 |
  | `per100` | object; unknown keys dropped; non-positive / NaN values → 0 |
  | `groups100` | same rules as `per100` |
  | `hazards100` | `[{key (must be a known hazard), amount_per_100g ≥ 0, note ≤ 200}]` |
  | `nova_group` | 1–4 or null |
  | `ingredients` | ≤ 2000 |
  | `label_fields` | known nutrient keys only |
  | `source` | `label|ai_search|ai_estimate|manual`, default `manual` |
  | `source_urls` | entries need a string `url`; max 10 |
  | `notes` | ≤ 600 |
  | `visibility` | `private|public`, default `private` |

  Extra fields such as `confidence`, `provider`, `sources` and `id` are ignored.
- POST → `{ id }`; PUT → `{ ok: true }`.
- Errors: 400 `名称不能为空`, `每份重量不能小于 0.1` / `每份重量不能大于 10000`; PUT also 404 `食物不存在`, 403 `只能修改自己创建的食物`.

**`DELETE /foods/{id}`** (Auth, owner only) → `{ ok: true }`. 404 `食物不存在`; 403 `只能删除自己创建的食物`. Meals already logged with the food are unaffected.

**`POST /ai/food`** (Auth)

- Body: `{ name?: string (≤ 80), brand?: string (≤ 60), note?: string (≤ 500), photos?: [uploadId] }`. At least one of name or photos is required, else 400.
- → `{ job_id }`, kind `food`. Result `FoodDraft`:

  ```json
  { "name": "", "brand": "", "aliases": ["…"], "category": "…", "serving_g": 100, "serving_desc": "",
    "per100": {…43}, "groups100": {…22}, "hazards100": [ { "key": "", "amount_per_100g": 0, "note": "" } ],
    "nova_group": 1|2|3|4|null, "ingredients": "", "label_fields": [], "confidence": "low|medium|high",
    "sources": [ { "title": "", "url": "" } ], "notes": "", "source": "label|ai_search|ai_estimate", "provider": "cli|api|mock" }
  ```

  - `source` is `label` if photos or label fields were present, `ai_search` if web sources were found, else `ai_estimate`.
  - There is **no `model` field** in a FoodDraft (mock or not; verified in `ai/service.ts` `lookupFood`). `confidence` is not validated server-side (default `"medium"`; mock gives `"low"`). Use `me.ai.model` for the "由 {model}" wording.

**Related (other spec):** `POST /foods/{id}/item` `{grams?}` → a meal item ready to save; `POST /foods/from-item`.

### 6.6 Standards

**`GET /standards/meta`** (Auth) → `Meta`:

| field | content |
|---|---|
| `version` | `3` (scoring version) |
| `nutrients` | `NutrientDef[]` (43, in display order) |
| `foodGroups` | `FoodGroupDef[]` (22) |
| `hazards` | `HazardDef[]`, plus server-only `aiFlag: bool`; `dose` = `{from: "group"|"nutrient"|"flag", key?, unit}` |
| `hazardsInfoOnly` | `[{zh, iarc, examples, why}]` |
| `hei` | `[{key, zh, en, max, kind: "adequacy"|"moderation", best, worst, unit, hint}]` (13) |
| `activities` | `[{key, zh, met, speedKmh?, code?, intensity: "light"|"moderate"|"vigorous"}]` |
| `activityLevels` | `[{key, zh, pal, desc}]` |
| `sources` | `[{id, org, title, year, url}]` |
| `lifeStages` | `[{id, zh}]` (20) |
| `marNutrients` | string[] (11 keys) |
| `heiUsMean` | `58` |
| `conditions` | `[{key, zh, effect}]` |

Cache it per app session (it only changes with server deploys).

**`GET /standards/dri`** (Auth):

```json
{ "lifeStages": [ { "id": "c1_3", "zh": "儿童 1–3 岁" }, … 20 ],
  "intake": { "<nutrientKey>": { "kind": "RDA|AI", "values": [number|null × 20] }, … },
  "upper":  { "<nutrientKey>": { "values": [number|null × 20], "appliesToTotal": bool, "note"?: string }, … },
  "sodiumCdrr": [number × 20], "proteinPerKg": [number × 20] }
```

Life-stage order:

| group | stages |
|---|---|
| children | `c1_3`, `c4_8` |
| male | `m9_13`, `m14_18`, `m19_30`, `m31_50`, `m51_70`, `m71` |
| female | `f9_13`, `f14_18`, `f19_30`, `f31_50`, `f51_70`, `f71` |
| pregnant | `p14_18`, `p19_30`, `p31_50` |
| lactating | `l14_18`, `l19_30`, `l31_50` |

The JSON object key order matters for display. Decode into an ordered structure, e.g. by decoding `[String: …]` and then sorting by `meta.nutrients` order. The web iterates `Object.entries`, which follows server insertion order. That is close to the nutrient order, but use the meta order with leftovers appended.

---

## 7. Risks, surprises, and suggested additive server changes

1. **The cookie overrides the Bearer token** (`auth.ts`). Any `nl_session` cookie in the request causes the Bearer token to be ignored. Use an ephemeral or cookieless `URLSession`. *(Optional server change: prefer Bearer when present. Additive and safe for the web, which never sends Bearer.)*
2. **HTTP on a bare IP** blocks ATS. Needs `NSAllowsArbitraryLoads`, or a domain + TLS (preferable, since passwords and tokens travel in clear text).
3. **Images require auth** (`/api/uploads/:id`) and are host-relative. `AsyncImage` cannot add headers, so build an authenticated image loader or cache.
4. **Do not use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`.**
   - It also rewrites **dictionary keys** (`totals["sodium_mg"]` would become `sodiumMg`).
   - The API mixes camelCase (`hasData`, `daysLogged`, `avgTotals`, `macroPct`) and snake_case (`display_name`, `per100`, `amount_per_100g`).
   - Mirror the JSON names exactly (Appendix C).
5. **Numbers:**
   - Decode every measurement as `Double`. Integers are only safe for ids and counts (`streak`, `days`, `daysLogged`, `use_count`, `hazardCount`, `available`, `windowDays`, `loggedDays`, `strengthDays`, `mepa.score`, `mepa.days`).
   - `fmt` must use zh_CN grouping, drop trailing zeros, and round with `.halfUp`.
6. **`PUT /settings` and `PUT /profile` are full-replace with silent defaults.** Omitting `share_mode` makes the user private; omitting `conditions` clears them. Always send the complete object.
7. **Server bug: the AI summary lookup** (`GET /period`, `routes/reports.ts`) is `SELECT … WHERE user_id AND start_date AND end_date AND ai_summary IS NOT NULL` with no `ORDER BY`.
   - When a month already has a scheduler-made `month` row, a user-triggered regeneration is stored as a separate `custom` row and may never show.
   - Additive fix: `ORDER BY created_at DESC LIMIT 1`. The same applies to weeks only if the kinds differ, which they do not.
8. **The Reports default asymmetry is intentional:** week → *last* week; month → *current* month. Next is disabled when `end >= today`.
9. **Quirks in the Trends math to replicate exactly:**
   - A logged day with `score == null` counts as 0 in the HEI averages (Chart A and tile 1).
   - The week bucket label is its Monday, even before `start`.
   - `/period` is clamped to 400 days while `/trends` allows 1100. For "全部" or long custom ranges, the LE8/WCRF/pass-rate sections cover only the last ~401 days, while the charts cover the full range. The subtitles show `period.start 至 period.end`, so this is visible.
10. The web nutrient explorer hides its picker in table mode (a bug). iOS should keep it.
11. Errors are swallowed on the web for Reports, Community and Settings user loading. iOS should show retryable error states.
12. **AI jobs:**
    - No client timeout. Jobs survive app suspension; persist job ids and resume polling.
    - The server-side job queue is global, with concurrency 2, so a long food lookup (30–120 s or more) can delay others.
    - The `result` of a summary job may be `null` without being an error.
13. **HEIC uploads are rejected.** Convert to JPEG (e.g. `UIImage.jpegData(compressionQuality: 0.85)`), and resize to stay under 12 MB.
14. **Timezones:**
    - `today` and all dates use the owner's profile timezone.
    - When viewing another member, the server defaults use *their* timezone, but the web always passes explicit `start`/`end` computed from the *viewer's* `me.today`. Do the same.
15. **The live OpenAPI is under-specified:** `/trends` items, `/users` and `/reports` lack fields, and `/auth/token` documents a 400 instead of the actual 401. This spec (from code) takes precedence.
16. **`/users` is expensive** (it computes 14 days of scores per member on each call). Cache it briefly on the client and avoid calling it on every tab switch.
17. **Payload size:** a 3-year `/trends` response can reach about 3 MB (≈3 KB per logged day). Consider client-side caching per range and decoding off the main thread. *(Optional additive server change: `?fields=` or gzip/`compression` middleware. Express is not compressing today.)*
18. **The theme is not synced** between web and app (each is local). This is fine.
19. **Charts on iOS:** Swift Charts needs manual null-gap segmentation (`connectNulls: false`) and custom legends and tooltips. The calendar heatmap is easier as a custom grid.
20. **The screenshots are older than the code** (tile labels and the report hero differ). Implement from this document.
21. **Community → member view:** tapping a member opens their read-only Today (`GET /day/:date?user=`; other spec), which has a `看趋势` button to this Trends screen with `user`. The trends API strips nothing, but `/period` hides `aiSummary` unless the share is full.

---

## Appendix A — `web/src/types.ts` (verbatim)

```ts
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
  nicotine?: "unknown" | "never" | "former_5y" | "former_1_5y" | "former_lt1y" | "ecig" | "current";
  secondhand_smoke?: boolean;
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
  refAmount: number; sources: string[]; advice: string;
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
  hei: { key: string; zh: string; en: string; max: number; kind: string; best: number; worst: number; unit: string; hint: string }[];
  activities: Activity[];
  activityLevels: { key: string; zh: string; pal: number; desc: string }[];
  sources: Source[];
  lifeStages: { id: string; zh: string }[];
  marNutrients: string[];
  heiUsMean: number;
  conditions: { key: string; zh: string; effect: string }[];
}

export interface ScoreItem {
  key: string; category: "hei" | "mar" | "adequacy" | "moderation" | "energy"; zh: string; value: number; unit: string; targetText: string;
  target?: number; ideal?: number; limit?: number; status: Status; score: number; points: number; maxPoints: number; message: string; sources: string[];
}

export interface HazardResult { key: string; zh: string; iarc: string; dose: number; unit: string; foods: string[]; message: string; sources: string[] }

export interface Energy {
  intake: number; resting: number; restingSource: string; active: number; activeSource: string; exerciseKcal: number;
  tef: number; tdee: number; method: string; target: number; balance: number;
}

export interface CompositePart { key: string; zh: string; weight: number; score: number | null; points: number | null; note: string }
/** 综合总分（本站自定权重） */
export interface CompositeScore { score: number | null; parts: CompositePart[]; missing: string[] }

export interface DailyScore {
  date: string;
  hasData: boolean;
  /** HEI-2020 总分 */
  score: number | null;
  total: CompositeScore;
  categories: { key: "hei" | "mar"; zh: string; score: number; source: string; note: string }[];
  items: ScoreItem[];
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  mar: { value: number; nutrients: { key: string; zh: string; intake: number; target: number; nar: number }[] } | null;
  hazards: HazardResult[];
  energy: Energy;
  totals: Vec;
  groups: Vec;
  macroPct: { protein: number; carb: number; fat: number; satFat: number; addedSugar: number; alcohol: number };
  upfPct: number;
  mealCount: number;
  itemCount: number;
  fastFoodMeals: number;
  completeness: { level: string; note: string };
  top: { issues: string[]; wins: string[] };
  weightKg: number;
  weighedToday: number | null;
}

export interface Le8Component { key: string; zh: string; points: number | null; value: string; rule: string; missing: string }
export interface WcrfComponent { key: string; zh: string; points: number | null; max: number; detail: string; rule: string }
export interface MepaItem { key: string; zh: string; criterion: string; value: number; unit: string; met: boolean }

export interface HealthIndices {
  windowDays: number;
  loggedDays: number;
  mepa: { score: number; days: number; items: MepaItem[] } | null;
  le8: { score: number | null; category: { key: string; zh: string } | null; available: number; components: Le8Component[] };
  wcrf: { score: number; max: number; components: WcrfComponent[] };
  pa: { le8MinPerWeek: number | null; mvpaMinPerWeek: number | null; strengthDays: number };
  sleepHours: number | null;
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

export interface ActivityDay { date: string; steps: number | null; active_kcal: number | null; resting_kcal: number | null; distance_km: number | null; exercise_min: number | null; sleep_hours: number | null; stand_hours: number | null; source: string }
export interface Exercise { id: number; date: string; time: string; description: string; activity_key: string | null; met: number; duration_min: number; distance_km: number | null; kcal: number; in_device: number; avg_hr: number | null; device_kcal: number | null; source: string }
export interface BodyMetric { id: number; date: string; time: string; weight_kg: number | null; body_fat_pct: number | null; waist_cm: number | null; sbp: number | null; dbp: number | null; bp_treated: number; note: string | null; source: string }

export interface DayResponse {
  date: string; score: DailyScore; targets: Targets; meals: Meal[]; activity: ActivityDay | null; exercises: Exercise[]; body: BodyMetric[]; weightTrend: number | null; full: boolean;
  indices: HealthIndices;
}

export interface TrendDay {
  date: string; hasData: boolean; score: number | null; total: number | null; categories: Record<string, number>; hazardCount: number; hei: number | null; mar: number | null;
  intake: number; tdee: number; target: number; exerciseKcal: number; energyMethod: string; weight: number | null; trend: number | null;
  steps: number | null; activeKcal: number | null; completeness: string; totals: Vec; groups: Vec; macroPct: Record<string, number>; upfPct: number;
  statuses: Record<string, Status>;
}

export interface PeriodCheck { key: string; zh: string; value: number; unit: string; targetText: string; status: Status; score: number; message: string; sources: string[] }

export interface PeriodScore {
  start: string; end: string; days: number; daysLogged: number; avgHei: number | null; avgMar: number | null;
  /** LE8 */
  score: number | null;
  total: CompositeScore;
  category: { key: string; zh: string } | null;
  indices: HealthIndices;
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  avgTotals: Vec; avgGroups: Vec;
  itemStats: { key: string; zh: string; category: string; good: number; ok: number; warn: number; bad: number; days: number }[];
  checks: PeriodCheck[];
  hazards: { key: string; zh: string; iarc: string; dose: number; unit: string; days: number }[];
  energy: { avgIntake: number | null; avgTdee: number; totalBalance: number; predictedChangeKg: number; trendStart: number | null; trendEnd: number | null; actualChangeKg: number | null; empiricalTdee: number | null; ratePerWeek: number | null };
  series: { date: string; score: number | null; total: number | null; intake: number; tdee: number; weight: number | null; trend: number | null }[];
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
```

---

## Appendix B — Server-side source types (where they extend or differ from Appendix A)

### B.1 `server/src/scoring/types.ts` (verbatim)

```ts
import type { NutrientVector } from "../standards/nutrients.ts";
import type { CompositeScore } from "./composite.ts";

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
  category?: string | null;
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
  sleep_hours?: number | null;
  stand_hours?: number | null;
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
  /** hei = HEI-2020 组分（有官方分值）；mar = MAR 计分营养素；adequacy / moderation / energy = 只标状态的检查项 */
  category: "hei" | "mar" | "adequacy" | "moderation" | "energy";
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
  /** 仅 HEI-2020 组分有：官方分值 */
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
  key: "hei" | "mar";
  zh: string;
  /** 0–100 */
  score: number;
  source: string;
  note: string;
}

export interface MarResult {
  /** 0–100 */
  value: number;
  nutrients: { key: string; zh: string; intake: number; target: number; nar: number }[];
}

export interface DailyScore {
  date: string;
  hasData: boolean;
  /** 当日膳食质量 = HEI-2020 总分（0–100） */
  score: number | null;
  /** 综合总分（本站自定权重，见 composite.ts） */
  total: CompositeScore;
  categories: CategoryResult[];
  items: ScoreItem[];
  hei: { total: number; components: { key: string; zh: string; score: number; max: number; value: number; unit: string; hint: string }[] } | null;
  mar: MarResult | null;
  hazards: HazardResult[];
  energy: EnergyResult;
  totals: NutrientVector;
  groups: NutrientVector;
  macroPct: { protein: number; carb: number; fat: number; satFat: number; addedSugar: number; alcohol: number };
  upfPct: number;
  mealCount: number;
  itemCount: number;
  fastFoodMeals: number;
  completeness: { level: "none" | "partial" | "likely"; note: string };
  top: { issues: string[]; wins: string[] };
  weightKg: number;
  weighedToday: number | null;
  version: number;
}
```

### B.2 Other server types that reach the client (verbatim excerpts)

```ts
// scoring/composite.ts
export interface CompositePart {
  key: string;            // daily: hei | mar | energy | activity ; period: hei | mar | le8 | wcrf
  zh: string;             // 膳食质量 | 微量营养素 | 能量平衡 | 身体活动 | 心血管健康 | 防癌建议
  /** 权重（满分点数），各分项之和 = 100 */
  weight: number;
  /** 分项得分 0–100；null = 缺少数据 */
  score: number | null;
  /** 折算后计入总分的点数 */
  points: number | null;
  note: string;
}
export interface CompositeScore {
  /** 0–100；没有饮食记录时为 null */
  score: number | null;
  parts: CompositePart[];
  /** 缺少数据、未计入的分项 */
  missing: string[];
}

// scoring/le8.ts
export interface Le8Component { key: string; zh: string; points: number | null; value: string; rule: string; missing: string; }
export interface Le8Result {
  score: number | null;
  category: { key: "high" | "moderate" | "low"; zh: string } | null;   // 高 ≥80 / 中 ≥50 / 低
  available: number;
  components: Le8Component[];   // keys: diet, activity, nicotine, sleep, bmi, lipids, glucose, bp
}

// scoring/wcrf.ts
export interface WcrfComponent { key: string; zh: string; points: number | null; max: number; detail: string; rule: string; }
export interface WcrfResult { score: number; max: number; components: WcrfComponent[]; }   // max = Σ max of components with points != null (≤ 6, NOT constant); keys: weight, activity, plants, upf(max 0, points null), meat, ssb, alcohol

// scoring/mepa.ts
export interface MepaItem { key: string; zh: string; criterion: string; value: number; unit: string; met: boolean; }
export interface MepaResult { score: number; days: number; items: MepaItem[]; }   // null when < 3 logged days

// scoring/indices.ts
export interface HealthIndices {
  windowDays: number;
  loggedDays: number;
  mepa: MepaResult | null;
  le8: Le8Result;
  wcrf: WcrfResult;
  pa: { le8MinPerWeek: number | null; mvpaMinPerWeek: number | null; strengthDays: number };
  sleepHours: number | null;
}

// standards/hei.ts — HEI components inside DailyScore.hei / PeriodScore.hei ALSO carry best & worst:
export interface HeiComponentResult { key: string; zh: string; max: number; score: number; value: number; best: number; worst: number; unit: string; hint: string; }
export interface HeiResult { total: number; components: HeiComponentResult[]; }

// scoring/period.ts — identical to web PeriodScore minus aiSummary/full (added by the route)
export interface PeriodCheck { key: string; zh: string; value: number; unit: string; targetText: string; status: Status; score: number; message: string; sources: string[]; }

// standards/targets.ts
export interface IntakeTarget { key: string; value: number; kind: "RDA" | "AI"; source: string; note?: string; }
export interface LimitTarget { key: string; zh: string; unit: string; ideal: number; limit: number; idealSource: string; limitSource: string; note?: string; }
// Targets.amdr on the server is Amdr = { protein: [n,n]; carb: [n,n]; fat: [n,n]; n6: [n,n]; n3: [n,n] }  (web type omits n6/n3)
// Targets.limits keys: sodium_mg, added_sugars_g, sat_fat_pct, trans_fat_g, alcohol_g, caffeine_mg, upf_pct

// standards/hazards.ts
export type HazardDose =
  | { from: "group"; key: string; unit: "g" }
  | { from: "nutrient"; key: string; unit: "g" | "mg" }
  | { from: "flag"; unit: "g" | "mg" | "ml" };
export interface HazardDef {
  key: string; zh: string; en: string;
  iarc: "1" | "2A" | "2B" | "—";
  category: "carcinogen" | "toxicant" | "lifestyle";
  risk: string; detect: string; examples: string;
  dose: HazardDose; refAmount: number; aiFlag: boolean; sources: string[]; advice: string;
}
// keys: processed_meat, red_meat, alcohol, salted_fish_cantonese, areca_nut, aflatoxin_risk, high_temp_meat, smoked_food,
//       acrylamide, pickled_vegetables, very_hot_beverage, bracken_fern, high_mercury_fish, hijiki, aspartame

// ai/service.ts
export interface WeeklySummary { headline: string; summary: string; wins: string[]; issues: string[]; actions: string[]; }
```

### B.3 Field differences vs the web types

| Type | Server extra / difference |
|---|---|
| `DailyScore` | `version: number` (3) |
| `DailyScore.hei.components[]`, `PeriodScore.hei.components[]` | also `best`, `worst` |
| `Targets.amdr` | also `n6`, `n3` |
| `HazardDef` (meta) | also `aiFlag`; `iarc` may be `"—"` |
| `Food` | also `created_at`; `aliases` is a comma string; `brand`/`serving_desc`/`ingredients`/`notes` may be `""` |
| `FoodDraft` | identical to the web type: there is **no** `model` field (the earlier claim of a non-mock `model` was wrong; keep `model: String?` in Swift harmlessly optional) |
| `User` from `/auth/token` | no `share_with` |
| `PeriodScore` | `aiSummary` and `full` are added by the route |

### B.4 Nutrient keys (43, display order) and food-group keys (22)

Nutrients (`key` · zh · unit · decimals · dv):

| key | zh | unit | decimals | dv |
|---|---|---|---|---|
| energy_kcal | 能量 | kcal | 0 | — |
| protein_g | 蛋白质 | g | 1 | 50 |
| carb_g | 碳水化合物 | g | 1 | 275 |
| fat_g | 总脂肪 | g | 1 | 78 |
| water_g | 水分(食物+饮品) | g | 0 | — |
| fiber_g | 膳食纤维 | g | 1 | 28 |
| sugars_g | 总糖 | g | 1 | — |
| added_sugars_g | 添加糖 | g | 1 | 50 |
| sat_fat_g | 饱和脂肪 | g | 1 | 20 |
| trans_fat_g | 反式脂肪 | g | 2 | — |
| mufa_g | 单不饱和脂肪 | g | 1 | — |
| pufa_g | 多不饱和脂肪 | g | 1 | — |
| linoleic_g | 亚油酸 (ω-6) | g | 1 | — |
| ala_g | α-亚麻酸 (ω-3) | g | 2 | — |
| epa_dha_g | EPA+DHA (ω-3) | g | 2 | — |
| cholesterol_mg | 胆固醇 | mg | 0 | 300 |
| sodium_mg | 钠 | mg | 0 | 2300 |
| potassium_mg | 钾 | mg | 0 | 4700 |
| calcium_mg | 钙 | mg | 0 | 1300 |
| iron_mg | 铁 | mg | 1 | 18 |
| magnesium_mg | 镁 | mg | 0 | 420 |
| phosphorus_mg | 磷 | mg | 0 | 1250 |
| zinc_mg | 锌 | mg | 1 | 11 |
| copper_mg | 铜 | mg | 2 | 0.9 |
| manganese_mg | 锰 | mg | 2 | 2.3 |
| selenium_ug | 硒 | µg | 0 | 55 |
| iodine_ug | 碘 | µg | 0 | 150 |
| vit_a_ug | 维生素 A | µg RAE | 0 | 900 |
| vit_c_mg | 维生素 C | mg | 0 | 90 |
| vit_d_ug | 维生素 D | µg | 1 | 20 |
| vit_e_mg | 维生素 E | mg | 1 | 15 |
| vit_k_ug | 维生素 K | µg | 0 | 120 |
| thiamin_mg | 维生素 B1 (硫胺素) | mg | 2 | 1.2 |
| riboflavin_mg | 维生素 B2 (核黄素) | mg | 2 | 1.3 |
| niacin_mg | 烟酸 (B3) | mg | 1 | 16 |
| pantothenic_mg | 泛酸 (B5) | mg | 1 | 5 |
| vit_b6_mg | 维生素 B6 | mg | 2 | 1.7 |
| biotin_ug | 生物素 (B7) | µg | 0 | 30 |
| folate_ug | 叶酸 (B9) | µg DFE | 0 | 400 |
| vit_b12_ug | 维生素 B12 | µg | 2 | 2.4 |
| choline_mg | 胆碱 | mg | 0 | 550 |
| caffeine_mg | 咖啡因 | mg | 0 | — |
| alcohol_g | 酒精 | g | 1 | — |

Food groups:

`fruit_total_cup, fruit_whole_cup, veg_total_cup, veg_dark_green_cup, legumes_cup, grains_whole_oz, grains_refined_oz, dairy_cup, protein_total_oz, seafood_oz, plant_protein_oz, red_meat_g, processed_meat_g, poultry_g, fruit_veg_g, berries_cup, olive_oil_g, butter_cream_g, cheese_g, nuts_g, sweets_serv, ssb_ml`

(Their zh labels and units come from `meta.foodGroups`.)

---

## Appendix C — Suggested Swift `Codable` models

Property names mirror the JSON exactly. Use **no** key-decoding strategy. Prefer `Double` for measurements.

```swift
import Foundation

typealias Vec = [String: Double]

enum ScoreStatus: String, Codable {
    case good, ok, warn, bad, info
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScoreStatus(rawValue: raw) ?? .info
    }
}

struct APIErrorBody: Decodable { let error: String }
struct OkResponse: Decodable { let ok: Bool }
struct KeyZh: Codable, Hashable { let key: String; let zh: String }

// MARK: Auth / account
struct User: Codable, Identifiable, Hashable {
    let id: Int
    let username: String
    let display_name: String
    let avatar_color: String
    let share_mode: String          // private | public | selected
    let share_detail: String        // summary | full
    let api_token_hint: String?
    let share_with: [Int]?          // only from GET /auth/me
}
struct TokenResponse: Decodable { let token: String; let expires_at: String; let user: User? }   // user absent on /auth/register
struct AIInfo: Codable { let provider: String; let model: String }   // provider: cli | api | mock
struct ConditionDef: Codable, Hashable { let key: String; let zh: String; let effect: String }
struct Me: Codable {
    let user: User
    let profile: Profile?
    let today: String
    let ai: AIInfo
    let conditions: [ConditionDef]
}
struct Profile: Codable, Equatable {
    var sex: String                 // male | female
    var birth_date: String
    var height_cm: Double
    var weight_kg: Double
    var activity_level: String      // inactive | low_active | active | very_active
    var goal: String                // lose | maintain | gain
    var goal_rate_kg_week: Double
    var target_weight_kg: Double?
    var physiology: String          // none | pregnant | lactating
    var sodium_mode: String         // cdrr | aha
    var conditions: [String]
    var timezone: String
    var nicotine: String?           // unknown | never | former_5y | former_1_5y | former_lt1y | ecig | current
    var secondhand_smoke: Bool?
}
struct SettingsBody: Encodable {
    let display_name: String; let avatar_color: String
    let share_mode: String; let share_detail: String; let share_with: [Int]
}
struct SessionRow: Decodable, Identifiable {
    let id: Int; let kind: String; let device_name: String?
    let created_at: String?; let last_used_at: String?; let expires_at: String
}

// MARK: Composite / indices
struct CompositePart: Codable { let key: String; let zh: String; let weight: Double; let score: Double?; let points: Double?; let note: String }
struct CompositeScore: Codable { let score: Double?; let parts: [CompositePart]; let missing: [String] }

struct Le8Component: Codable { let key: String; let zh: String; let points: Double?; let value: String; let rule: String; let missing: String }
struct Le8: Codable { let score: Double?; let category: KeyZh?; let available: Int; let components: [Le8Component] }
struct WcrfComponent: Codable { let key: String; let zh: String; let points: Double?; let max: Double; let detail: String; let rule: String }
struct Wcrf: Codable { let score: Double; let max: Double; let components: [WcrfComponent] }
struct MepaItem: Codable { let key: String; let zh: String; let criterion: String; let value: Double; let unit: String; let met: Bool }
struct Mepa: Codable { let score: Int; let days: Int; let items: [MepaItem] }
struct PhysicalActivitySummary: Codable { let le8MinPerWeek: Double?; let mvpaMinPerWeek: Double?; let strengthDays: Int }
struct HealthIndices: Codable {
    let windowDays: Int
    let loggedDays: Int
    let mepa: Mepa?
    let le8: Le8
    let wcrf: Wcrf
    let pa: PhysicalActivitySummary
    let sleepHours: Double?
}

// MARK: Trends
struct TrendsResponse: Codable { let start: String; let end: String; let days: [TrendDay] }
struct TrendDay: Codable {
    let date: String
    let hasData: Bool
    let score: Double?
    let total: Double?
    let categories: [String: Double]
    let hazardCount: Int
    let hei: Double?
    let mar: Double?
    let intake: Double
    let tdee: Double
    let target: Double
    let exerciseKcal: Double
    let energyMethod: String
    let weight: Double?
    let trend: Double?
    let steps: Double?
    let activeKcal: Double?
    let completeness: String
    let totals: Vec
    let groups: Vec
    let macroPct: [String: Double]
    let upfPct: Double
    let statuses: [String: ScoreStatus]
}

// MARK: Period
struct HeiComponent: Codable { let key: String; let zh: String; let score: Double; let max: Double; let value: Double; let unit: String; let hint: String; let best: Double?; let worst: Double? }
struct HeiResult: Codable { let total: Double; let components: [HeiComponent] }
struct ItemStat: Codable { let key: String; let zh: String; let category: String; let good: Int; let ok: Int; let warn: Int; let bad: Int; let days: Int }
struct PeriodCheck: Codable { let key: String; let zh: String; let value: Double; let unit: String; let targetText: String; let status: ScoreStatus; let score: Double; let message: String; let sources: [String] }
struct PeriodHazard: Codable { let key: String; let zh: String; let iarc: String; let dose: Double; let unit: String; let days: Int }
struct PeriodEnergy: Codable {
    let avgIntake: Double?; let avgTdee: Double; let totalBalance: Double; let predictedChangeKg: Double
    let trendStart: Double?; let trendEnd: Double?; let actualChangeKg: Double?; let empiricalTdee: Double?; let ratePerWeek: Double?
}
struct PeriodSeriesPoint: Codable { let date: String; let score: Double?; let total: Double?; let intake: Double; let tdee: Double; let weight: Double?; let trend: Double? }
struct AISummary: Codable { let headline: String; let summary: String; let wins: [String]; let issues: [String]; let actions: [String] }
struct PeriodScore: Codable {
    let start: String; let end: String
    let days: Int; let daysLogged: Int
    let avgHei: Double?; let avgMar: Double?
    let score: Double?                 // LE8
    let total: CompositeScore
    let category: KeyZh?
    let indices: HealthIndices
    let hei: HeiResult?
    let avgTotals: Vec; let avgGroups: Vec
    let itemStats: [ItemStat]
    let checks: [PeriodCheck]
    let hazards: [PeriodHazard]
    let energy: PeriodEnergy
    let series: [PeriodSeriesPoint]
    let aiSummary: AISummary?
    let full: Bool
}
struct ReportListItem: Decodable, Identifiable {
    let id: Int; let period: String; let start_date: String; let end_date: String
    let score: Double?; let ai_summary: AISummary?; let created_at: String
}

// MARK: Targets
struct IntakeTarget: Codable { let key: String; let value: Double; let kind: String; let source: String; let note: String? }
struct UpperTarget: Codable { let value: Double; let appliesToTotal: Bool; let note: String? }
struct LimitTarget: Codable { let key: String; let zh: String; let unit: String; let ideal: Double; let limit: Double; let idealSource: String; let limitSource: String; let note: String? }
struct ProteinTargets: Codable { let rdaG: Double; let idealLowG: Double; let idealHighG: Double; let perKgRda: Double }
struct Amdr: Codable { let protein: [Double]; let carb: [Double]; let fat: [Double]; let n6: [Double]?; let n3: [Double]? }
struct Targets: Codable {
    let date: String; let age: Int; let sex: String; let lifeStage: String; let lifeStageZh: String; let physiology: String; let sensitive: Bool
    let weightKg: Double; let heightCm: Double; let bmi: Double; let bmiCategory: KeyZh; let referenceWeightKg: Double
    let bmr: Double; let eer: Double; let eerMethod: String; let goal: String; let goalDeltaKcal: Double; let energyTarget: Double; let energyFloor: Double
    let protein: ProteinTargets
    let intake: [String: IntakeTarget]
    let upper: [String: UpperTarget]
    let limits: [String: LimitTarget]   // NOTE: dictionary order is lost — server order is sodium_mg, added_sugars_g, sat_fat_pct, trans_fat_g, alcohol_g, caffeine_mg, upf_pct
    let amdr: Amdr
    let addedSugarPerMealG: Double
    let aspartameAdiMg: Double
}

// MARK: Community
struct RecentScore: Codable { let date: String; let score: Double? }
struct CommunityUser: Codable, Identifiable {
    let id: Int; let username: String; let display_name: String; let avatar_color: String
    let is_me: Bool; let shared_with_me: Bool
    let share_detail: String          // full | summary | none
    let last_log_date: String?
    let streak: Int
    let recent: [RecentScore]
}

// MARK: Foods
struct HazardPer100: Codable { let key: String; let amount_per_100g: Double; let note: String? }
struct SourceLink: Codable, Hashable { let title: String; let url: String }
struct Food: Codable, Identifiable {
    let id: Int; let owner_id: Int; let owner_name: String?; let visibility: String
    let name: String; let brand: String?; let aliases: String
    let category: String?; let serving_g: Double?; let serving_desc: String?
    let per100: Vec; let groups100: Vec; let hazards100: [HazardPer100]
    let nova_group: Int?; let ingredients: String?; let label_fields: [String]
    let source: String; let source_urls: [SourceLink]; let notes: String?
    let use_count: Int; let mine: Bool; let created_at: String?; let updated_at: String
}
struct FoodInput: Encodable {
    var name: String; var brand: String; var aliases: [String]; var category: String
    var serving_g: Double?; var serving_desc: String
    var per100: Vec; var groups100: Vec; var hazards100: [HazardPer100]
    var nova_group: Int?; var ingredients: String; var label_fields: [String]
    var source: String; var source_urls: [SourceLink]; var notes: String; var visibility: String
}
struct FoodDraft: Codable {
    let name: String; let brand: String; let aliases: [String]; let category: String
    let serving_g: Double; let serving_desc: String; let per100: Vec; let groups100: Vec
    let hazards100: [HazardPer100]; let nova_group: Int?; let ingredients: String; let label_fields: [String]
    let confidence: String; let sources: [SourceLink]; let notes: String; let source: String; let provider: String; let model: String?
}
struct IdResponse: Decodable { let id: Int }

// MARK: Jobs / uploads
struct JobCreated: Decodable { let job_id: String }
struct Job<T: Decodable>: Decodable { let id: String; let kind: String; let status: String; let error: String?; let result: T? }
struct UploadedPhoto: Decodable { let id: String; let url: String }
struct UploadResponse: Decodable { let photos: [UploadedPhoto] }

// MARK: Standards
struct NutrientDef: Codable { let key: String; let zh: String; let en: String; let unit: String; let group: String; let decimals: Int; let dv: Double?; let note: String? }
struct FoodGroupDef: Codable { let key: String; let zh: String; let unit: String; let note: String }
struct HazardDose: Codable { let from: String; let unit: String; let key: String? }
struct HazardDef: Codable { let key: String; let zh: String; let en: String; let iarc: String; let category: String; let risk: String; let detect: String; let examples: String; let refAmount: Double; let aiFlag: Bool?; let sources: [String]; let advice: String; let dose: HazardDose }
struct HazardInfoOnly: Codable { let zh: String; let iarc: String; let examples: String; let why: String }
struct HeiDef: Codable { let key: String; let zh: String; let en: String; let max: Double; let kind: String; let best: Double; let worst: Double; let unit: String; let hint: String }
struct ActivityDef: Codable { let key: String; let zh: String; let met: Double; let speedKmh: Double?; let intensity: String; let code: String? }
struct ActivityLevel: Codable { let key: String; let zh: String; let pal: Double; let desc: String }
struct SourceDef: Codable { let id: String; let org: String; let title: String; let year: String; let url: String }
struct LifeStage: Codable { let id: String; let zh: String }
struct Meta: Codable {
    let version: Int
    let nutrients: [NutrientDef]
    let foodGroups: [FoodGroupDef]
    let hazards: [HazardDef]
    let hazardsInfoOnly: [HazardInfoOnly]
    let hei: [HeiDef]
    let activities: [ActivityDef]
    let activityLevels: [ActivityLevel]
    let sources: [SourceDef]
    let lifeStages: [LifeStage]
    let marNutrients: [String]
    let heiUsMean: Double
    let conditions: [ConditionDef]
}
struct DriIntakeRow: Codable { let kind: String; let values: [Double?] }
struct DriUpperRow: Codable { let values: [Double?]; let appliesToTotal: Bool; let note: String? }
struct DriTables: Codable {
    let lifeStages: [LifeStage]
    let intake: [String: DriIntakeRow]     // order lost → sort by meta.nutrients order
    let upper: [String: DriUpperRow]
    let sodiumCdrr: [Double]
    let proteinPerKg: [Double]
}
```

> Dictionary order: Swift dictionaries are unordered. Where the web relies on server key order (`Targets.limits`, the DRI tables), order rows by `meta.nutrients` order, or use the explicit `limits` order given above.

---

## Appendix D — Global / shared Chinese strings and server error messages

**Global UI strings**

- Loading: `加载中…`
- Empty value: `—`
- Status badges: `达标` (good/ok), `偏离` (warn), `不达标` (bad), `提示` (info)
- IARC chips: `非致癌`, `IARC ${g} 类`
- Source prefix: `依据：`
- Modal close aria: `关闭`
- Chart toggle: `表格` / `图表`
- Client job errors: `AI 任务失败`, `已取消` (abort)
- Client fallback: `请求失败（${status}）`
- Date words: `今天 · `, `昨天 · `, `周日 周一 周二 周三 周四 周五 周六`, `${M}月${D}日`
- Meal types (other spec; used in `mealZh`): `breakfast` 早餐 08:00 · `lunch` 午餐 12:30 · `dinner` 晚餐 18:30 · `snack` 加餐 15:30 · `drink` 饮品 10:00 · `other` 其他 12:00
- Toasts:
  - `已保存`
  - `密码已修改`
  - `档案已保存，评分已按新档案重新计算`
  - `已删除`
  - `已保存到食物库`

**Server messages that surface in these screens**

- Auth / transport:
  - `未登录或令牌已失效` (401)
  - `用户名或密码错误` (401)
  - `接口不存在` (404)
  - `请求格式不正确` (400)
  - `文件太大` (413)
  - `服务器内部错误` (500)
- Register:
  - `当前站点已关闭注册` (403)
  - `邀请码不正确`
  - `用户名不能为空`
  - `用户名为 2–32 位，可用中文、字母、数字、_ . -`
  - `密码不能为空`
  - `密码至少 6 位`
  - `用户名已被占用`
- Password: `原密码不正确`, `新密码不能为空`, `密码至少 6 位`
- Profile:
  - `取值必须是 male / female`
  - `出生日期不能为空`
  - `出生日期格式应为 YYYY-MM-DD`
  - `身高不能为空` / `身高格式不正确` / `身高不能小于 80` / `身高不能大于 250`
  - `体重…` (same pattern, 20–350)
  - `目标速度格式不正确` / `目标速度不能小于 0.1` / `目标速度不能大于 1`
  - `目标体重…` (20–350)
- Reports / trends:
  - `请先完善个人档案` (400)
  - `开始日期不能晚于结束日期` (400)
  - `用户不存在` (404)
  - `对方没有向你共享数据` (403)
- Jobs: `任务不存在` (404); job `error`: `服务器重启，任务中断，请重试` (or an AI provider error text)
- Uploads: `请上传 JPG/PNG/WebP 图片（HEIC 请先在手机相册中导出为 JPG）`
- AI food: `请输入食物名称或上传包装/营养成分表照片`
- Foods:
  - `名称不能为空`
  - `每份重量格式不正确` / `每份重量不能小于 0.1` / `每份重量不能大于 10000`
  - `食物不存在` (404)
  - `只能修改自己创建的食物` (403)
  - `只能删除自己创建的食物` (403)

All screen-specific strings are listed verbatim in §5.

---

## Appendix E — Icon mapping (lucide → SF Symbols)

| lucide | SF Symbol | lucide | SF Symbol |
|---|---|---|---|
| House | `house` | ChartLine | `chart.xyaxis.line` |
| FileText | `doc.text` | Scale | `scalemass` |
| Library | `books.vertical` | Users | `person.2` |
| BookOpen | `book` | Settings | `gearshape` |
| Plus | `plus` | Leaf | `leaf.fill` |
| Table2 | `tablecells` | Sparkles | `sparkles` |
| CircleCheck | `checkmark.circle` | CircleX | `xmark.circle` |
| TriangleAlert | `exclamationmark.triangle` | Info | `info.circle` |
| ArrowUpRight | `arrow.up.right` | ChevronLeft / Right | `chevron.left` / `chevron.right` |
| ChevronUp / Down | `chevron.up` / `chevron.down` | HeartPulse | `heart.text.square` (or `waveform.path.ecg`) |
| ShieldCheck | `checkmark.shield` | ShieldAlert | `exclamationmark.shield` |
| Lock | `lock` | Eye | `eye` |
| Flame | `flame` | LogOut | `rectangle.portrait.and.arrow.right` |
| Sun | `sun.max` | Moon | `moon` |
| Monitor | `circle.lefthalf.filled` | Search | `magnifyingglass` |
| Camera | `camera` | Trash2 | `trash` |
| Pencil | `pencil` | Globe | `globe` |
| Link | `link` | Inbox (empty) | `tray` |
| X (close) | `xmark` | | |
