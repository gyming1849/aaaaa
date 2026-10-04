# 食迹 NutriLog: Auth, Account, Profile, Sharing, and Routing API Spec (for the native iOS client)

Sources analysed (read-only): `server/src/auth.ts`, `server/src/routes/account.ts`, `server/src/config.ts`,
`server/src/index.ts`, `server/src/lib/http.ts`, `server/src/lib/dates.ts`, `server/src/db/index.ts`,
`server/src/services/userdata.ts`, `server/src/standards/{targets,dri,energy}.ts`,
`server/src/routes/reports.ts` (`/users`, `?user=` access control), `server/src/routes/docs.ts`, `server/src/openapi.ts`,
web: `web/src/{api.ts,types.ts,App.tsx,lib/app.tsx}`, `pages/{Login,Onboarding,Settings,Community,Body}.tsx`,
`components/ProfileForm.tsx`.

The live OpenAPI (`openapi.live.json`) matches the source `openapi.ts` path for path. **The OpenAPI schemas are incomplete:**
`User` omits `api_token_hint` and `share_with`, `/auth/me` omits `conditions`, `Targets` is an empty object, and `/users`
omits most fields. **This document is authoritative where it disagrees with the OpenAPI.**

A probe of the live server (`http://45.63.23.52:8787`, 2026-10-03, read-only or invalid requests only, no account created)
confirmed this:

| Probe | Result |
|---|---|
| `GET /api/v1/health` | `200 {"ok":true,"version":"1"}` |
| `GET /api/v1/auth/me` (no auth) | `401 {"error":"未登录或令牌已失效"}` |
| `GET /api/v1/nonexistent` (no auth) | `401 {"error":"未登录或令牌已失效"}` (**not 404**, see section 1.4) |
| `POST /api/v1/auth/register` `{}` | `400 {"error":"邀请码不正确"}`. **The production server has `INVITE_CODE` set, so registration needs the invite code.** |
| `POST /api/v1/auth/token` with wrong credentials | `401 {"error":"用户名或密码错误"}` |
| `POST /api/v1/auth/token` with `Content-Type: text/plain` and a JSON body | `500 {"error":"服务器内部错误"}` (the body was not parsed) |
| `POST /api/v1/auth/token` with malformed JSON | `400 {"error":"请求格式不正确"}` |
| `GET /api/v1/auth/me` with `Bearer nl_junk` | `401 {"error":"未登录或令牌已失效"}` |
| `OPTIONS /api/v1/auth/me` | `204`, empty body |

---

## 0. Conventions (apply to every endpoint)

| Topic | Rule |
|---|---|
| Base URL | `http://45.63.23.52:8787/api/v1` (production, **plain HTTP, no TLS**). `/api/...` is an exact alias. The iOS app should use `/api/v1`. |
| Request body | JSON. **Always send `Content-Type: application/json`, and send a body (at least `{}`) on every POST/PUT/PATCH.** Express 5 / body-parser 2 leaves `req.body` **undefined** when the content type is not JSON or the body is empty. Handlers that do `req.body.x` then throw a TypeError, and the response is `500 服务器内部错误`. The web client always sends `{}` for bodiless POSTs. |
| Body size | JSON body limit is **2 MB**. A larger body raises a body-parser 413 error, which the error handler does not map, so it surfaces as **`500 服务器内部错误`**. Never send base64 images as JSON. Upload them with multipart `/uploads`. |
| URL-encoded | `application/x-www-form-urlencoded` is also parsed (`extended:false`). Don't use it. |
| Success status | Always **200** with a JSON body. No endpoint in scope returns 201 or 204, except the CORS preflight `OPTIONS`, which returns 204. |
| Success shapes | Mutations usually return `{"ok": true}` or `{"ok": true, ...}`. |
| Error shape | **Always** `{"error": "<Simplified Chinese message>"}` with a non-2xx status. There is no error code field. Show `error` to the user verbatim, as the web does in a toast. If the body is not JSON (for example a proxy 502 HTML page), the web uses the raw text as the message, or falls back to `请求失败（{status}）`. |
| 401 signalling | HTTP **401** + `{"error":"未登录或令牌已失效"}`, with no `WWW-Authenticate` header. On `/health/ingest` the message is `未登录或 Token 无效`. **Exception:** `POST /auth/token` and `/auth/login` return 401 `用户名或密码错误` for bad credentials. That is not "session expired". The web sends its global "unauthorized" event only for 401s on paths that do **not** start with `/auth/`. |
| JSON key naming | Mixed. DB-backed objects use `snake_case` (`display_name`, `birth_date`). Computed objects use `camelCase` (`lifeStageZh`, `energyTarget`). **Do not use `.convertFromSnakeCase`.** Map keys verbatim, for example with explicit `CodingKeys`. |
| Numbers | JS numbers. Fields described as ints (ids, streak) are always integral. "Float" fields may arrive as `70` or `70.5`. Decode as `Double`. Computed target values are **not rounded** (for example `"bmi": 22.857142857142858`). |
| Calendar dates | `"YYYY-MM-DD"` strings, which are **user-local dates in the profile's `timezone`** (default `Asia/Shanghai`), not UTC. |
| Timestamps | Two formats, both UTC. (a) `expires_at`: JS ISO-8601 with milliseconds, e.g. `"2027-10-03T21:38:50.123Z"`; use `ISO8601DateFormatter` with `.withFractionalSeconds`. (b) `created_at` / `last_used_at`: SQLite `"YYYY-MM-DD HH:MM:SS"` with **no zone marker**, which is UTC; parse with `DateFormatter("yyyy-MM-dd HH:mm:ss")`, `en_US_POSIX` locale, UTC time zone. Either may be `null` (see section 3.6). |
| Rate limiting | None. Login has no lockout. |
| Case | Usernames are `COLLATE NOCASE`. Login, the uniqueness check and the `?user=` lookup are all **case-insensitive**. The username is returned exactly as it was registered. |

---

## 1. Server routing (`server/src/index.ts`)

### 1.1 Middleware order (top to bottom)
1. `x-powered-by` is disabled. `trust proxy = true`, so `req.protocol` honours `X-Forwarded-Proto`.
2. `express.json({ limit: "2mb" })`, then `express.urlencoded({ extended: false })`.
3. **CORS** on `/api/*`: if the `Origin` header is in `CORS_ORIGINS` (comma list, or `*`), the server sets `Access-Control-Allow-Origin` (to `*` or the echoed origin), `Vary: Origin`, `Access-Control-Allow-Headers: Authorization, Content-Type`, `Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS` and `Access-Control-Max-Age: 86400`. **Any `OPTIONS` under `/api` returns 204 immediately**, whatever the origin. Native iOS is not subject to CORS, so this is irrelevant to the app.
4. For each prefix in `["/api/v1", "/api"]` (in that order), the server mounts:
   - `GET {prefix}/health` → `{"ok": true, "version": "1"}` (public; "health" means server liveness, **not** HealthKit)
   - `docsRouter` (public): `GET {prefix}/openapi.json` (OpenAPI 3.1, `servers` built from the request host), `GET {prefix}/docs` (Swagger UI HTML)
   - `accountRouter` (this document)
   - `bodyRouter` (body metrics, labs, activity, exercises, `/health/ingest`, `/health/import`)
   - `logRouter`: **router-level `requireAuth` on every request that reaches it**
   - `reportsRouter`: router-level `requireAuth` (day, trends, period, reports, users, standards)
5. `app.use("/api", ...)` → `404 {"error":"接口不存在"}`
6. Static web SPA from `web/dist`, plus a fallback that sends `index.html` for every non-`/api` GET. This never applies to `/api` paths.
7. Error handler (section 1.3).

### 1.2 `/api` and `/api/v1`
- Every endpoint exists identically under both prefixes. Responses are identical.
- Some server-generated URLs are **unversioned**. For example, photo upload returns `url: "/api/uploads/<id>"`. Resolve them against the host root (`http://host:8787` + url), not against the `/api/v1` base. They still work because of the alias.

### 1.3 Error handler mapping (applies to everything)

| Condition | Status | Body |
|---|---|---|
| `HttpError(status, msg)` thrown by a handler (`bad()` = 400, `notFound()` = 404 default `不存在`, `forbidden()` = 403 default `无权访问`) | that status | `{"error": msg}` |
| Malformed JSON, or JSON top-level not an object/array (body-parser `entity.parse.failed`) | 400 | `{"error":"请求格式不正确"}` |
| multer `LIMIT_FILE_SIZE` (uploads) | 413 | `{"error":"文件太大"}` |
| Anything else: JSON body > 2 MB, a missing body causing a TypeError, other multer errors, and so on | 500 | `{"error":"服务器内部错误"}` |

### 1.4 Quirk: unknown API paths return 401 when unauthenticated
`logRouter.use(requireAuth)` runs for **every** request that falls through `accountRouter` and `bodyRouter`. An unknown path such
as `/api/v1/typo` therefore returns **401 `未登录或令牌已失效`** without auth, and **404 `接口不存在`** only with valid auth.
The iOS client must not assume a 401 on a never-before-called path means "token revoked". During development, check the URL first.
(A side effect: authenticated reports routes run the auth lookup twice. This is harmless.)

---

## 2. Authentication model (`server/src/auth.ts`)

### 2.1 Three credential types

| | Web session | **App token (use this)** | Personal API token |
|---|---|---|---|
| Format | 43-char base64url, no prefix (32 random bytes) | `nla_` + 43-char base64url (47 chars total) | `nl_` + 32-char base64url (35 chars total, 24 random bytes) |
| Obtained via | `POST /auth/login`, or `POST /auth/register` **without** `device_name` | `POST /auth/token`, or `POST /auth/register` **with** a non-empty `device_name` | `POST /settings/token` (requires a session or app token) |
| Transport | Cookie `nl_session` (HttpOnly, SameSite=Lax, Path=/, Secure only if `COOKIE_SECURE=true`) | Header `Authorization: Bearer nla_…` | Header `Authorization: Bearer nl_…`, or query `?token=nl_…` |
| Stored | `sessions` row, `kind='web'` (hash = SHA-256 hex of the token) | `sessions` row, `kind='app'`, `device_name` (≤ 60 chars) | `users.api_token_hash` (one per user) plus `users.api_token_hint` |
| Lifetime | `SESSION_DAYS` (default **30** days) from creation, fixed | `APP_TOKEN_DAYS` (default **365** days) from creation, **fixed, not sliding** | Never expires. Valid until regenerated. |
| `last_used_at` | Set at creation, **never updated** | Updated on **every** authenticated request | n/a |
| Accepted by | All authenticated endpoints | All authenticated endpoints, including `/health/ingest` | **Only** `POST /health/ingest` (any other endpoint returns 401) |
| Revocation | `POST /auth/logout`, `DELETE /auth/sessions/:id` | Same | Only by regenerating (`POST /settings/token`). There is no delete endpoint. |

There is **no refresh endpoint** and no sliding renewal. An `nla_` token dies 365 days after issue, even if it is used daily. The app must handle the
401 and send the user to login again. (A web-session token sent as `Bearer <token>` also works, because any bearer token not starting with `nl_` goes through the session table.)

### 2.2 Exact resolution algorithm

```
bearer = Authorization header starts with "Bearer " ? header[7...].trim() : nil
cookie = value of cookie "nl_session" (URL-decoded), if present

userFromSession():                              // used by requireAuth and requireAuthOrToken
  token = cookie ?? (bearer != nil && !bearer.hasPrefix("nl_") ? bearer : nil)
  // !! COOKIE WINS over Bearer when both are present !!
  if token == nil → nil
  row = sessions JOIN users WHERE token_hash = sha256hex(token)
  if row == nil → nil
  if Date(row.expires_at) < now → DELETE that row; → nil      (lazy expiry)
  if row.kind == "app" → UPDATE last_used_at = now
  → {id, username, display_name}

userFromApiToken():                             // only in requireAuthOrToken (/health/ingest)
  token = bearer?.hasPrefix("nl_") ? bearer : query["token"]    // query token: any string, no prefix check
  → users WHERE api_token_hash = sha256hex(token)

requireAuth          = userFromSession()                       else 401 "未登录或令牌已失效"
requireAuthOrToken   = userFromSession() ?? userFromApiToken() else 401 "未登录或 Token 无效"
```

> **iOS pitfall: cookie precedence.** `URLSession.shared` stores `Set-Cookie` responses automatically. If the app ever calls
> `/auth/login` or `/auth/register` without `device_name`, an `nl_session` cookie is stored and then sent on every later request.
> **The cookie overrides the Bearer token**, so a stale cookie gives 401 even with a valid `nla_` token. Use a dedicated session:
> ```swift
> let cfg = URLSessionConfiguration.default
> cfg.httpCookieAcceptPolicy = .never
> cfg.httpShouldSetCookies = false
> cfg.httpCookieStorage = nil
> ```

### 2.3 Password hashing (informational)
`scrypt$<salt b64>$<hash b64>`, N=16384, r=8, p=1, 64-byte key, 16-byte salt. Verification is constant-time. The server **trims**
passwords (see section 3.2), so a password can never begin or end with whitespace.

---

## 3. Endpoints

Notation: **Auth**: `none` = public; `user` = `requireAuth` (app token or cookie); `user|nl` = `requireAuthOrToken`.
The "Errors" lists are in the **order the server checks them**. The first failing check wins.

### 3.1 `GET /health`  (Auth: none)
Response: `{"ok": true, "version": "1"}`. Use it as a reachability check.

### 3.2 `POST /auth/register`  (Auth: none)

Request body:

| Field | Type | Required | Rules |
|---|---|---|---|
| `username` | string | yes | Trimmed, then **silently truncated to 32 chars**, then must match `^[\w一-龥.-]{2,32}$`. `\w` is ASCII only (`A-Z a-z 0-9 _`). `一-龥` is CJK U+4E00–U+9FA5. Also allowed: `.` and `-`. No spaces, kana or accented letters. Uniqueness is case-insensitive. |
| `password` | string | yes | Trimmed. Length ≥ 6 (JS UTF-16 length). No maximum. |
| `display_name` | string | no | Trimmed, truncated to 32. Empty or missing → falls back to `username`. |
| `invite_code` | string | when the server has `INVITE_CODE` set (**production does**) | **Strict equality** with the configured code. Not trimmed, so trim on the client. Ignored when the server has no invite code. |
| `device_name` | string | **iOS: always send it, non-empty** | If truthy, the server returns an app token instead of setting a cookie. Not trimmed here, truncated to 60. Suggest `UIDevice.current.name` or `"iPhone · NutriLog iOS"`. An empty string counts as falsy, which **sets a cookie and returns no token**. |

Responses:
- With `device_name`: `{"ok": true, "token": "nla_…", "expires_at": "2027-10-03T21:38:50.123Z"}`. **No `user` object.** Call `GET /auth/me` next.
- Without `device_name` (web): `{"ok": true}` plus a `Set-Cookie: nl_session=…`. **Never use this from iOS.**

Side effects: creates the user with `share_mode='private'`, `share_detail='summary'`, no profile, and a random `avatar_color` from the palette
`["#2f7d5b","#3b6fb6","#b5523b","#7a5bb5","#b58a2f","#2f8c93","#b53b72","#5b7a2f"]`.

Errors (in order):
1. `403 当前站点已关闭注册` (when `ALLOW_REGISTRATION=false`)
2. `400 邀请码不正确` (when the server has an invite code and the body value doesn't match exactly)
3. `400 用户名不能为空`
4. `400 用户名为 2–32 位，可用中文、字母、数字、_ . -`
5. `400 密码不能为空`
6. `400 密码至少 6 位`
7. `400 用户名已被占用`

There is no endpoint that tells the client whether an invite code is required or registration is open. The web always shows an
optional invite field labelled `邀请码（站点设置了才需要）`, and the iOS app should do the same.

### 3.3 `POST /auth/token`  (Auth: none). **This is the iOS login.**

Request: `{"username": string, "password": string, "device_name"?: string}`
- `username` and `password` are trimmed and must not be empty. Username lookup is case-insensitive.
- `device_name` is trimmed and truncated to 60. Empty or missing → `"App"`.

Response 200:
```json
{
  "token": "nla_3q2-7wEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXA",
  "expires_at": "2027-10-03T21:38:50.123Z",
  "user": {
    "id": 3,
    "username": "demo",
    "display_name": "小林",
    "avatar_color": "#2f7d5b",
    "share_mode": "private",
    "share_detail": "summary",
    "api_token_hint": "nl_AbCd…wxyz"
  }
}
```
`user` here is `PublicUser` (section 4.1). It **lacks `share_with`**. After login, call `GET /auth/me` for the full state.

Errors: `400 用户名不能为空`, `400 密码不能为空`, `401 用户名或密码错误` (unknown user or wrong password, deliberately the same message).

Each call creates a **new** session row. Repeated logins pile up device rows, which the user can prune in the device list.

### 3.4 `POST /auth/login`  (Auth: none). Web only, do not use from iOS.
Same input and errors as `/auth/token`, minus `device_name`. Response `{"ok":true}` plus a cookie (`kind='web'`, 30 days).

### 3.5 `POST /auth/logout`  (Auth: none required, never returns 401)
Body: none needed (send `{}`). Deletes the session row of `cookie ?? bearer` (an `nl_` bearer matches nothing, so nothing happens), and
sends `Set-Cookie` clearing `nl_session`. Always `{"ok": true}`, even with no or invalid credentials.
iOS: call it best-effort, then **always** delete the token from Keychain and clear cached user data, whatever the result.

### 3.6 `GET /auth/sessions`  (Auth: user)
All `sessions` rows for the current user, ordered by `last_used_at DESC` (NULLs last). Response: array of

| Field | Type | Notes |
|---|---|---|
| `id` | int | SQLite `rowid` of the session row. Use it for DELETE. (`sessions` has a TEXT primary key, so in theory `rowid` can change after a `VACUUM`. Treat ids as short-lived and refetch before deleting.) |
| `kind` | `"web"` \| `"app"` | |
| `device_name` | string \| null | `null` for web sessions |
| `created_at` | string \| null | `"YYYY-MM-DD HH:MM:SS"` UTC. `null` for sessions created before DB migration v2. |
| `last_used_at` | string \| null | Same format. Web: equals the creation time (never updated). App: last authenticated request. |
| `expires_at` | string | ISO-8601 with ms, `Z` |

Notes:
- **There is no `current` flag and no token hint**, so the app cannot reliably mark "this device". Heuristic: the newest `kind=="app"` row
  whose `device_name` equals the one the app sent. It will usually be first, because the app's own request just bumped `last_used_at`.
  A proper fix is listed in section 8.
- Expired rows are only purged when that token is used, so the list can contain expired entries. Grey them out client-side
  (`expires_at < now`).
- The web UI has **no** device list. This would be a new iOS-only screen.

### 3.7 `DELETE /auth/sessions/:id`  (Auth: user)
Deletes the row `rowid = Number(id) AND user_id = me`. **Always `{"ok": true}`**, even when the id doesn't exist, belongs to someone else, or is NaN.
Deleting the app's own session makes the next request return 401. Confirm with the user first and treat it as logout.

### 3.8 `GET /auth/me`  (Auth: user). App bootstrap call.
Response 200 (`Me`):
```json
{
  "user": {
    "id": 3, "username": "demo", "display_name": "小林", "avatar_color": "#2f7d5b",
    "share_mode": "selected", "share_detail": "full",
    "api_token_hint": "nl_AbCd…wxyz",
    "share_with": [5, 7]
  },
  "profile": { /* Profile (section 4.2) */ } ,
  "today": "2026-10-04",
  "ai": { "provider": "api", "model": "claude-opus-5-5" },
  "conditions": [
    { "key": "hypertension", "zh": "高血压", "effect": "钠上限收紧到 1500 mg（AHA）" },
    { "key": "high_ldl", "zh": "高胆固醇 / 高 LDL", "effect": "饱和脂肪理想值收紧到 6% 能量（AHA）" },
    { "key": "diabetes", "zh": "糖尿病 / 糖尿病前期", "effect": "添加糖上限收紧到 AHA 建议值" },
    { "key": "kidney", "zh": "慢性肾病", "effect": "仅提示：蛋白质、钾、磷目标请遵医嘱，本系统不据此加分" },
    { "key": "gout", "zh": "痛风 / 高尿酸", "effect": "仅提示：注意红肉、海鲜、酒精与含糖饮料" }
  ]
}
```
- `profile` is **`null` until the user saves a profile**. The web then shows only the Onboarding screen (`App.tsx`: `if (!me.profile) return <Onboarding/>`).
- `today` is today's date in the **profile timezone**, or the UTC date when there is no profile. **Use this, not the device date, as "today" for
  every date-keyed call.** The server buckets everything by the profile timezone.
- `ai.provider` ∈ `"cli" | "api" | "mock"`. `ai.model` is `"offline"` when the provider is `mock`, otherwise the configured model id.
- `user.api_token_hint` is `null` until a personal token has been generated.
- `user.share_with` lists the viewer user ids granted in `selected` mode. It may also contain stale grants while the mode is not `selected`, because they are kept.

Web boot flow (mirror it): `GET /auth/me` → on 401/error, show Login; on 200 with `profile == null`, show Onboarding; otherwise show the main shell. The web
also loads `GET /standards/meta` once after the first successful `/auth/me`, for activity-level labels and conditions (see the standards spec).

### 3.9 `POST /auth/password`  (Auth: user)
Request: `{"old_password": string, "new_password": string}`.
- `old_password` is **not trimmed** (`String(x ?? "")`), unlike login, so **trim it on the client** before sending. Otherwise a stray
  trailing space fails.
- `new_password` is trimmed and must be ≥ 6.

Response `{"ok": true}`. **Existing sessions, app tokens and the `nl_` token are NOT revoked.**
Errors: `400 原密码不正确` (checked first), `400 新密码不能为空`, `400 密码至少 6 位`.
Web UI: the button is disabled unless `old_password != ""` and `new_password.length >= 6`. On success it clears the fields and toasts `密码已修改`.

### 3.10 `PUT /profile`  (Auth: user). Create or **fully replace** the profile.

> **Full-replace semantics.** The server upserts all fields. Any optional field you omit resets to its default
> (`activity_level→low_active`, `goal→maintain`, `goal_rate_kg_week→0.5`, `target_weight_kg→null`, `physiology→none`,
> `sodium_mode→cdrr`, `conditions→[]`, `nicotine→unknown`, `secondhand_smoke→false`, `timezone→Asia/Shanghai`).
> **Always send the complete Profile object** (start from `me.profile`).

Request body (`Profile`). The units are fixed, so convert any imperial HealthKit values first:

| Field | Type | Required | Validation and coercion (exact) |
|---|---|---|---|
| `sex` | `"male"`\|`"female"` | yes | Not in enum → `400 取值必须是 male / female` |
| `birth_date` | `"YYYY-MM-DD"` | yes | Missing → `400 出生日期不能为空`. Bad format → `400 出生日期格式应为 YYYY-MM-DD`. Only a regex plus JS `Date.parse` check: impossible days like `02-30` may pass (V8 rolls them over), and **future dates are not rejected** (age is clamped to ≥ 1, giving the "child 1–3" stage). Validate on the client: past date, plausible age. |
| `height_cm` | number (cm) | yes | Numeric strings accepted. Missing → `400 身高不能为空`. Not numeric → `400 身高格式不正确`. Range **80–250** → `400 身高不能小于 80` / `400 身高不能大于 250` |
| `weight_kg` | number (kg) | yes | Range **20–350**, messages `体重不能为空/格式不正确/不能小于 20/不能大于 350`. This is the **baseline weight (建档体重)**. Daily weights live in `body_metrics` (see the body spec). |
| `activity_level` | `"inactive"`\|`"low_active"`\|`"active"`\|`"very_active"` | no | Invalid or missing → `"low_active"` (silent) |
| `goal` | `"lose"`\|`"maintain"`\|`"gain"` | no | Invalid → `"maintain"` |
| `goal_rate_kg_week` | number (kg/week) | no | Missing, null or `""` → `0.5`. Otherwise **0.1–1**, messages `目标速度不能小于 0.1 / 不能大于 1 / 格式不正确`. Web offers 0.25 / 0.5 / 0.75 / 1. |
| `target_weight_kg` | number \| null (kg) | no | Missing, null or `""` → `null`. Otherwise **20–350**, messages `目标体重…` |
| `physiology` | `"none"`\|`"pregnant"`\|`"lactating"` | no | Kept only when `sex=="female"` (invalid → `none`). **Forced to `"none"` for males.** |
| `sodium_mode` | `"cdrr"`\|`"aha"` | no | Invalid → `"cdrr"` |
| `conditions` | string[] | no | Non-array → `[]`. Unknown keys are dropped silently. Valid keys: `hypertension, high_ldl, diabetes, kidney, gout`. **Duplicates are not removed**, so de-duplicate on the client. |
| `nicotine` | `"unknown"`\|`"never"`\|`"former_5y"`\|`"former_1_5y"`\|`"former_lt1y"`\|`"ecig"`\|`"current"` | no | Invalid → `"unknown"` |
| `secondhand_smoke` | boolean | no | JS truthiness: **the string `"false"` counts as true**. Send a real JSON boolean. |
| `timezone` | IANA tz string | no | Trimmed, truncated to 64. Empty, missing or unknown to the server's ICU → **silently `"Asia/Shanghai"`**. Send `TimeZone.current.identifier`. |

Response: `{"ok": true, "profile": Profile}` (the stored, normalised profile; compare it with what you sent to detect silent coercions).

Side effects:
- **First creation only:** inserts a `body_metrics` row `{date: today in tz, time: "08:00", weight_kg, note: "建档体重", source: "profile"}`.
- Every save deletes **all** cached daily scores for the user (`invalidateAll`). Later day, trend and report calls recompute on demand,
  so the first call after a save may be slower. Toast text: `档案已保存，评分已按新档案重新计算`.
- Changing `timezone` changes what "today" means for every later request.

### 3.11 `GET /profile/targets?date=YYYY-MM-DD`  (Auth: user)
- `date` is optional. Invalid or missing → today in the profile tz.
- Weight used = the latest `body_metrics.weight_kg` on or before `date`, else `profile.weight_kg`.
- No profile → `400 请先完善个人档案`.
- Response: **`Targets`** (section 4.6). The same object is embedded as `targets` in `GET /day/:date`.

### 3.12 `PUT /settings`  (Auth: user). Nickname, avatar colour, sharing.

> **Partial for name and colour, full-replace for the sharing mode.** Omitting `share_mode` resets it to `"private"`, and omitting
> `share_detail` resets it to `"summary"`. **Always send all five fields**, as the web does.

| Field | Type | Behaviour |
|---|---|---|
| `display_name` | string | Trimmed, truncated to 32. Empty or missing → **unchanged** (`COALESCE(NULLIF(?,''), display_name)`). |
| `avatar_color` | string `#rrggbb` | Must match `/^#[0-9a-f]{6}$/i`, otherwise **unchanged**. Any colour is accepted; the web offers the 8-colour palette from section 3.2. |
| `share_mode` | `"private"`\|`"public"`\|`"selected"` | Invalid or missing → `"private"` |
| `share_detail` | `"summary"`\|`"full"` | Invalid or missing → `"summary"` |
| `share_with` | int[] (user ids) | **Only if it is an array:** replaces all grants. Each entry must be an integer, not self, and an existing user; others are skipped silently. Missing or non-array → grants **unchanged**. Grants persist even when the mode is not `selected`; they only take effect in `selected` mode. |

Response `{"ok": true}` (no user echoed, so refetch `/auth/me`). Toast: `已保存`. No validation errors are possible apart from auth.
**Hazard:** the handler uses `req.body ?? {}`. A request sent **without** `Content-Type: application/json` is therefore treated as `{}`, still
returns `{"ok":true}`, and **silently resets the user to `private`/`summary`**.

Access semantics enforced elsewhere (`reports.ts canView`):

| Owner setting | Viewer can see summary | Viewer can see full |
|---|---|---|
| viewer == owner | yes | yes |
| `private` | no | no |
| `public` | yes | `share_detail=="full"` |
| `selected` | yes, if the viewer id is in the grants | yes, if granted **and** `share_detail=="full"` |

### 3.13 `POST /settings/token`  (Auth: user; an `nl_` token cannot call this)
Generates a new personal token and **immediately invalidates the previous one**. Response: `{"token": "nl_…"}`.
The plaintext is shown **once**. Afterwards only `user.api_token_hint` is available, formatted as `token[0..<7] + "…" + last 4`, e.g. `"nl_AbCd…wxyz"` (12 chars, U+2026 ellipsis).
Web UI (on the Body page): button `生成个人 Token` (no hint yet) or `重新生成 Token`. When regenerating, the web confirms first with
`重新生成后旧 Token 立即失效，快捷指令需要更新。继续？`. After success it shows `只显示这一次，请复制保存：` with a copy button, and calls `refreshMe()`.
**The native app does not need an `nl_` token for itself:** `POST /health/ingest` accepts the `nla_` app token. Keep this screen only so that
users of the iPhone Shortcuts automation can still manage their token.

### 3.14 `GET /users`  (Auth: user). Members / community list
Returns **every user on the server**, ordered by `id`, including the caller. There is no pagination. Each element is a `CommunityUser` (section 4.5).
For each user the caller may view who has a profile, the server computes 14 days of scores (cached), so the call can be slow on large servers.

Per-element derivation:
- `is_me`: `id == me`.
- `shared_with_me`: `canView(...).summary` (always `true` for self).
- `share_detail`: `"full"` / `"summary"` / `"none"`, the **caller's effective access**, not the owner's raw setting (self → `"full"`).
- `last_log_date`: `MAX(meals.date)` (meals only, not activity), or `null` if not shared or the user has no meals.
- `recent`: if shared **and** the owner has a profile, exactly **14** entries, oldest first, from `today−13` to `today` in the **owner's** tz.
  `score` = `round(HEI-2020 daily score)` as an int, or `null` for no data. Otherwise `[]`.
- `streak`: count of consecutive days with data, walking back from today. **An empty today does not break it** (counting starts at yesterday).
  Maximum 14. `0` when not shared.

Used by: the Community page and the Settings member picker (`users.filter(!is_me)`; when the list has ≤ 1 element, show `还没有其他成员`).

### 3.15 Viewing another member (cross-reference: reports spec)
`GET /day/:date?user=<username>`, `GET /trends?...&user=<username>` and `GET /period?...&user=<username>` accept `user`
(username, case-insensitive). Omitted, or equal to the caller → own data. Errors: `404 用户不存在`, `403 对方没有向你共享数据`,
`400 请先完善个人档案` (the owner has no profile). With summary-only access, `/day` returns `full:false`, `meals: []`,
`exercises: []`, `score.items[].message = ""`, `score.hazards[].foods = []`, and `score.top = {issues:[],wins:[]}`; `/period` returns `aiSummary: null`.
The web shows `@{username} 的记录` / `只读视图（对方开启了共享）`, hides the "记一餐" button, and offers `看趋势`.

### 3.16 `POST /health/ingest` auth note (full spec in the body/health spec)
Uses `requireAuthOrToken`: the **`nla_` app token works**, as do the cookie, `Bearer nl_…` and `?token=nl_…`. The 401 message here is
`未登录或 Token 无效`. It is the only endpoint an `nl_` token can reach.

### 3.17 AI job mechanism (cross-reference, shared by `/ai/*` and `/period/summary`)
An async endpoint returns `{"job_id": "<uuid>"}`. Poll `GET /ai/jobs/{id}` (scoped to the owner, else `404 任务不存在`). The poll returns
`{"id","kind","status":"queued"|"running"|"done"|"error","error":string|null,"result":<parsed JSON>|null}`.
The web polls every **1.5 s**. On server restart all queued and running jobs become `error` with `服务器重启，任务中断，请重试`. Jobs older than 7 days
are deleted at startup. Default timeout is `AI_TIMEOUT_MS` = 480 s, with concurrency 2 server-wide, so jobs can sit in `queued` for minutes. See the AI/log spec.

---

## 4. Types (verbatim field names)

### 4.1 `PublicUser` (in `/auth/token` → `user`)
| Field | Type |
|---|---|
| `id` | int |
| `username` | string |
| `display_name` | string |
| `avatar_color` | string `#rrggbb` |
| `share_mode` | `"private"`\|`"public"`\|`"selected"` |
| `share_detail` | `"summary"`\|`"full"` |
| `api_token_hint` | string \| null |

### 4.2 `MeUser` (in `/auth/me` → `user`) = `PublicUser` + `share_with: int[]`
Matches web `types.ts` `User`. In Swift, make `share_with` optional or use two types, because `/auth/token` omits it.

### 4.3 `Profile`
Returned by `/auth/me` and `PUT /profile`. **All keys are always present in responses** (nicotine and secondhand_smoke too).
```ts
interface Profile {
  sex: "male" | "female";
  birth_date: string;            // YYYY-MM-DD
  height_cm: number;             // cm, 80–250
  weight_kg: number;             // kg, baseline weight at profile creation (建档体重), 20–350
  activity_level: "inactive" | "low_active" | "active" | "very_active";
  goal: "lose" | "maintain" | "gain";
  goal_rate_kg_week: number;     // kg/week, 0.1–1 (default 0.5)
  target_weight_kg: number | null; // kg
  physiology: "none" | "pregnant" | "lactating";   // always "none" for male
  sodium_mode: "cdrr" | "aha";   // cdrr = 2300 mg limit, aha = 1500 mg
  conditions: string[];          // subset of hypertension | high_ldl | diabetes | kidney | gout
  timezone: string;              // IANA
  nicotine?: "unknown" | "never" | "former_5y" | "former_1_5y" | "former_lt1y" | "ecig" | "current"; // always present in responses
  secondhand_smoke?: boolean;    // always present in responses (real JSON boolean)
}
```

### 4.4 `Me`
`{ user: MeUser; profile: Profile | null; today: string; ai: { provider: "cli"|"api"|"mock"; model: string }; conditions: Condition[] }`
`Condition = { key: string; zh: string; effect: string }`

### 4.5 `CommunityUser` (`/users`)
```ts
interface CommunityUser {
  id: number;
  username: string;
  display_name: string;
  avatar_color: string;
  is_me: boolean;
  shared_with_me: boolean;
  share_detail: "full" | "summary" | "none";     // caller's effective access
  last_log_date: string | null;                  // YYYY-MM-DD
  streak: number;                                // int 0–14
  recent: { date: string; score: number | null }[]; // 14 items or []
}
```
(The server also selects `created_at` internally but does **not** return it.)

### 4.6 `Targets` (`/profile/targets`, and `targets` in `/day/:date`)
The server type is a superset of the web `types.ts`. **`amdr` also has `n6` and `n3`.** Units are fixed per key (see the key tables).
```ts
interface Targets {
  date: string;                 // YYYY-MM-DD the targets were computed for
  age: number;                  // int, years on `date`, clamped to ≥ 1
  sex: "male" | "female";
  lifeStage: LifeStageId;       // see table
  lifeStageZh: string;          // e.g. "男 19–30 岁"
  physiology: "none" | "pregnant" | "lactating"; // effective (male → none)
  sensitive: boolean;           // physiology != none || age < 18
  weightKg: number;             // weight used (latest weigh-in ≤ date, else profile baseline)
  heightCm: number;
  bmi: number;                  // unrounded float
  bmiCategory: { key: "under" | "normal" | "over" | "obese"; zh: "偏瘦" | "正常" | "超重" | "肥胖" }; // <18.5 / <25 / <30 / ≥30
  referenceWeightKg: number;    // if BMI ≥ 30: ideal(22.5·h²) + 0.4·(w − ideal), else weightKg; unrounded
  bmr: number;                  // kcal/day, Mifflin-St Jeor, unrounded
  eer: number;                  // kcal/day, unrounded
  eerMethod: string;            // "NASEM 2023 EER" | "Mifflin-St Jeor × PAL（未成年人近似）", optionally + " + 孕期增量" / " + 哺乳期增量"
  goal: "lose" | "maintain" | "gain"; // EFFECTIVE goal: becomes "maintain" if target weight reached, or if pregnant/lactating and goal=lose
  goalDeltaKcal: number;        // kcal/day: lose → −rate·7700/7; gain → min(rate·7700/7, 500); else 0 (unrounded)
  energyTarget: number;         // int kcal/day = max(energyFloor, round(eer + goalDeltaKcal))
  energyFloor: number;          // int kcal/day = max(male 1500 | female 1200, round(bmr))
  protein: { rdaG: number; idealLowG: number; idealHighG: number; perKgRda: number }; // g; ideal = 1.2 / 1.6 × referenceWeightKg; perKgRda g/kg
  intake: Record<string, { key: string; value: number; kind: "RDA" | "AI"; source: string; note?: string }>;
  upper: Record<string, { value: number; appliesToTotal: boolean; note?: string }>;
  limits: Record<string, { key: string; zh: string; unit: string; ideal: number; limit: number; idealSource: string; limitSource: string; note?: string }>;
  amdr: { protein: [number, number]; carb: [number, number]; fat: [number, number]; n6: [number, number]; n3: [number, number] }; // % energy
  addedSugarPerMealG: number;   // always 10
  aspartameAdiMg: number;       // 40 mg/kg × weightKg
}
```
`note` keys are **omitted** from the JSON when undefined, so decode them as optional.

`LifeStageId` / `lifeStageZh`: `c1_3` 儿童 1–3 岁, `c4_8` 儿童 4–8 岁, `m9_13` 男 9–13 岁, `m14_18` 男 14–18 岁, `m19_30` 男 19–30 岁,
`m31_50` 男 31–50 岁, `m51_70` 男 51–70 岁, `m71` 男 >70 岁, `f9_13` 女 9–13 岁, `f14_18` 女 14–18 岁, `f19_30` 女 19–30 岁,
`f31_50` 女 31–50 岁, `f51_70` 女 51–70 岁, `f71` 女 >70 岁, `p14_18` 孕期 ≤18 岁, `p19_30` 孕期 19–30 岁, `p31_50` 孕期 31–50 岁,
`l14_18` 哺乳期 ≤18 岁, `l19_30` 哺乳期 19–30 岁, `l31_50` 哺乳期 31–50 岁. (Pregnant or lactating stages apply only when female and age ≥ 14. Older pregnant or lactating women use the `*31_50` stages.)

`intake` keys (all always present; the unit is the key suffix): `protein_g, carb_g, fiber_g, linoleic_g, ala_g, water_g, vit_a_ug, vit_c_mg,
vit_d_ug, vit_e_mg, vit_k_ug, thiamin_mg, riboflavin_mg, niacin_mg, vit_b6_mg, folate_ug, vit_b12_ug, pantothenic_mg, biotin_ug,
choline_mg, calcium_mg, copper_mg, iodine_ug, iron_mg, magnesium_mg, manganese_mg, phosphorus_mg, selenium_ug, zinc_mg, potassium_mg,
sodium_mg`. `source` is `"nasem_na_k"` for sodium and potassium, otherwise `"nasem_dri"`. Overrides:
`protein_g.value = max(stage RDA, perKgRda × referenceWeightKg)` with note `RDA {perKgRda} g/kg；DGA 2025–2030 建议 1.2–1.6 g/kg`.
`fiber_g.value = round(14 × energyTarget / 1000)` with note `14 g / 1000 kcal × 你的能量目标`. `water_g` is total water in grams (1 L = 1000 g).

`upper` keys: `vit_a_ug, vit_c_mg, vit_d_ug, vit_e_mg, niacin_mg, vit_b6_mg, folate_ug, choline_mg, calcium_mg, copper_mg, iodine_ug,
iron_mg, magnesium_mg, manganese_mg, phosphorus_mg, selenium_ug, zinc_mg`. When `appliesToTotal == false`, the UL concerns only supplements or fortificants, not total food intake.
The notes that exist are: vit_a `UL 仅针对预制维生素 A（视黄醇），不含 β-胡萝卜素`; vit_e `UL 仅针对补充剂/强化食品中的 α-生育酚`;
niacin `UL 仅针对补充剂/强化食品`; folate `UL 仅针对合成叶酸（补充剂/强化食品）`; magnesium `UL 仅针对补充剂/药物中的镁`.

`limits` keys (exact logic):

| key | zh | unit | ideal | limit | sources (ideal / limit) | note |
|---|---|---|---|---|---|---|
| `sodium_mg` | 钠 | mg | adult(≥19): 1500, else intake.sodium_mg | strict(adult && (sodium_mode=aha \|\| hypertension)): 1500, else stage CDRR (2300 adults) | adult? aha_sodium : nasem_na_k / strict? aha_sodium : nasem_na_k | strict? `已按高血压/AHA 模式收紧` : `上限为 CDRR，与 DGA 一致` |
| `added_sugars_g` | 添加糖 | g | age<4: 0, else AHA (male ≥19: 36, else 25) | age<4: 5; diabetes: AHA; else max(round(energyTarget·0.1/4), AHA) | aha_sugar / diabetes? aha_sugar : dga_2020 | `DGA 2025–2030：不推荐任何添加糖，每餐不超过 10 g` |
| `sat_fat_pct` | 饱和脂肪供能比 | % 能量 | high_ldl? 6 : 8 | 10 | high_ldl? aha_satfat : hei_2020 / dga_2025 | (none) |
| `trans_fat_g` | 反式脂肪 | g | 0 | round1(energyTarget·0.01/9) | dga_2020 / who_trans | `WHO：< 1% 总能量` |
| `alcohol_g` | 酒精 | g | 0 | (pregnant/lactating or age<21)? 0 : male 28 / female 14 | iarc_list / dga_2020 | `孕期/哺乳期/未满 21 岁应完全避免` or `DGA 2020–2025：男 ≤2 杯、女 ≤1 杯；DGA 2025–2030：越少越好` |
| `caffeine_mg` | 咖啡因 | mg | = limit | pregnant/lactating 200; age<18 round(2.5·weightKg); else 400 | acog_caffeine / hc_caffeine / fda_caffeine (both) | age<18: `未成年人按 2.5 mg/kg 体重`, else omitted |
| `upf_pct` | 超加工食品供能比 | % 能量 | 20 | 50 | dga_2025 / system | `DGA 2025–2030 要求限制高度加工食品但未给数值；按 NOVA 4 类估算，阈值为本系统设定` |

Source ids resolve via `GET /standards/meta` → `sources[]` (ids include `nasem_dri, nasem_na_k, aha_sodium, aha_sugar, aha_satfat,
dga_2020, dga_2025, hei_2020, who_trans, iarc_list, acog_caffeine, hc_caffeine, fda_caffeine, system`, …).

`amdr` by age: <4 → protein [5,20], carb [45,65], fat [30,40]; 4–18 → [10,30], [45,65], [25,35]; ≥19 → [10,35], [45,65], [20,35].
`n6` is always [5,10] and `n3` always [0.6,1.2].

Illustrative values (male, 30 y, 175 cm, 70 kg, low_active, maintain): `bmr≈1648.75`, `eer≈2754.87`, `energyFloor=1649`,
`energyTarget=2755`, `bmi≈22.857`, `lifeStage="m19_30"`, `protein.rdaG≈56`, `intake.fiber_g.value=39`, `limits.sodium_mg={ideal:1500,limit:2300}`,
`limits.added_sugars_g={ideal:36,limit:69}`, `limits.trans_fat_g.limit=3.1`, `limits.alcohol_g.limit=28`, `aspartameAdiMg=2800`.

### 4.7 `Session` (`/auth/sessions`)
`{ id: number; kind: "web"|"app"; device_name: string|null; created_at: string|null; last_used_at: string|null; expires_at: string }`

### 4.8 Token responses
- `/auth/token`: `{ token: string; expires_at: string; user: PublicUser }`
- `/auth/register` + `device_name`: `{ ok: true; token: string; expires_at: string }`
- `/settings/token`: `{ token: string }`

---

## 5. Enums with web display labels (reuse verbatim)

| Field | value → label |
|---|---|
| `sex` | male → 男, female → 女 |
| `activity_level` (label `zh` plus description `desc`; also served by `/standards/meta` `activityLevels`, which carries `pal`) | inactive → 久坐 (pal 1.4) `办公室工作，几乎不运动（PAL 1.0–1.53）`; low_active → 轻度活动 (1.6) `每天步行约 30–60 分钟或少量运动（PAL 1.53–1.68）`; active → 活跃 (1.75) `每天中等强度运动约 1 小时（PAL 1.68–1.85）`; very_active → 非常活跃 (2.05) `体力劳动或每天高强度训练（PAL 1.85–2.5）` |
| `goal` | lose → 减重, maintain → 维持, gain → 增重 |
| `goal_rate_kg_week` options | `每周 {r} kg（约 {round(r*7700/7)} kcal/天）` → 0.25 → 275, 0.5 → 550, 0.75 → 825, 1 → 1100 |
| `physiology` (female only) | none → 无, pregnant → 孕期, lactating → 哺乳期 |
| `sodium_mode` | cdrr → `2300 mg（DGA/NASEM）`, aha → `1500 mg（AHA 理想）` |
| `conditions` | from `me.conditions` (`zh` as the chip text, `effect` as the tooltip) |
| `nicotine` | unknown → `不填写（LE8 不计这一项）`, never → 从不吸烟, former_5y → 已戒烟 5 年以上, former_1_5y → 已戒烟 1–5 年, former_lt1y → 戒烟不到 1 年, ecig → 使用电子烟, current → 目前吸烟 |
| `secondhand_smoke` | checkbox `家中有人在室内吸烟` |
| `timezone` picker list | Asia/Shanghai, Asia/Hong_Kong, Asia/Taipei, Asia/Tokyo, Asia/Singapore, Europe/London, Europe/Berlin, America/New_York, America/Chicago, America/Los_Angeles, Australia/Sydney (the current value is prepended if it is not in the list) |
| `share_mode` | private → 仅自己, public → 所有成员, selected → 指定成员 |
| `share_detail` | summary → 仅评分与趋势, full → `完整记录（含吃了什么）` |
| `CommunityUser.share_detail` chip | (is_me) → 这是你, full → 共享了完整记录, summary → 只共享评分摘要; not shared → `未向你共享每日数据` |
| `ai.provider` | mock → `未配置 AI：使用离线关键词估算。在服务器上安装并登录 Claude Code（claude -p），或设置 ANTHROPIC_API_KEY 后重启即可启用。`; else `当前使用 {model}（{cli ? "claude -p 命令行" : "Anthropic API"}）` |

Web new-profile defaults (Onboarding): `sex male, birth_date 1995-01-01, height_cm 170, weight_kg 65, activity_level low_active,
goal maintain, goal_rate_kg_week 0.5, target_weight_kg null, physiology none, sodium_mode cdrr, conditions [], timezone <device tz>,
nicotine unknown, secondhand_smoke false`. Rate and target-weight fields are shown only when `goal != maintain`. Physiology is shown only for female.
The weight label is `当前体重` (new profile) or `建档体重` (editing), with help text `日常体重请在“身体与运动”中记录，评分会自动使用最近一次称重` when editing.
Avatar = first character of `display_name`, uppercased, on an `avatar_color` circle.

---

## 6. Chinese UI strings used by the web (for identical wording)

**Brand and navigation:** `食迹 NutriLog`, `食迹`, `NUTRILOG`, `记一餐`. Side nav: `今日`, `趋势`, `报告`, `身体与运动`, `食物库`, `社区`, `标准库`, `设置`.
Mobile bottom bar: `今日`, `趋势`, (+), `身体`, `更多`. Loading: `加载中…`. Generic error: `请求失败（{status}）`.

**Login / Register (`Login.tsx`):**
- Hero: `把每一餐，变成看得见的健康趋势`. Feature lines: `用一句话描述吃了什么，Claude 自动拆解成 40+ 种营养素与食物组` /
  `对照美国 DRI、膳食指南、HEI-2020 与 IARC 致癌物分级逐项打分` / `摄入、消耗、体重交叉对照，按日 / 周 / 月 / 年追踪` /
  `和家人朋友一起记录，自己决定分享哪些数据`. Disclaimer: `评分仅用于自我管理参考，不构成医疗建议。`
- Titles: `欢迎回来` / `创建账号`. Subtitles: `登录以继续记录` / `注册后先建立个人档案`
- Fields: `用户名`, `昵称（其他成员看到的名字）` (register), `密码` (register `minLength 6`), `邀请码（站点设置了才需要）` (register)
- Buttons: `登录` / `注册`. Toggle: `还没有账号？注册` / `已有账号？登录`

**Onboarding:** `你好，{display_name}！先建立个人档案`;
`身高、体重、年龄和性别决定你的营养目标（DRI 分人群）、能量需求（NASEM 2023 方程）和按体重计算的限量（如蛋白质、咖啡因、阿斯巴甜 ADI）。`; submit `开始记录`.

**Profile form (`ProfileForm.tsx`):** labels `性别`, `出生日期`, `身高` (suffix `cm`), `当前体重`/`建档体重` (suffix `kg`),
`日常活动水平（NASEM 2023 能量方程分档）` + help `如果连接了苹果健康的步数/活动能量，每天的消耗会用实测数据，这里只作为没有数据时的基准。`,
`目标`, `目标速度`, `目标体重`, `特殊生理阶段` + help `孕期/哺乳期会使用对应的 DRI（如铁 27 mg、叶酸 600 µg），酒精与咖啡因限值更严格，且不建议主动减重。`,
`健康状况（会收紧相应标准）`, `吸烟情况（AHA Life's Essential 8 的“尼古丁暴露”）`, `二手烟`, `钠上限标准`, `时区（决定“今天”从何时开始）`;
submit `保存`; success toast `档案已保存，评分已按新档案重新计算`.

**Settings (`Settings.tsx`):** title `设置`, sub `@{username}`, `退出登录`; quick links `周期报告`, `食物库`, `社区`, `标准库`;
card `个人档案` + hint `修改后所有历史评分会按新档案重新计算`; card `资料与分享`: `昵称`, `头像颜色`,
`谁能看到我的每日数据（所有人都能看到你的用户名）`, `共享内容` (shown when mode ≠ private), `选择成员` (shown when mode = selected),
`还没有其他成员`, `保存` → toast `已保存`; card `外观`: `跟随系统` / `浅色` / `深色`; `AI` banner (section 5); card `修改密码`:
`原密码`, `新密码`, button `修改` → toast `密码已修改`.

**Community (`Community.tsx`):** title `社区`; sub `所有成员都能看到彼此的用户名；每日数据是否共享、共享给谁、共享多少由每个人自己决定（我的分享设置）`
(the parenthesised part links to the Settings share card); chip `我`; `近 14 天膳食质量（HEI-2020）`; `均分 {avg}` (mean of non-null `recent.score`,
0 decimals, `—` if none); sparkline bar height `max(6, score)%`, tooltip `{date}：{score|无记录}`, a11y `近 14 天平均 {avg} 分`;
`连续记录 {streak} 天`; `最近记录 {last_log_date|—}`; access chips per section 5; tapping a shared card opens `/u/{username}` (self → home).

**Viewing another member:** `@{username} 的记录`, `只读视图（对方开启了共享）`, `看趋势`.

**Personal token / Shortcuts (`Body.tsx` AppleHealth card):** `连接苹果健康`; `方式一：iPhone 快捷指令每天自动同步`;
`网页无法直接读取 HealthKit。用“快捷指令 → 自动化”每晚定时读取当天的步数、活动能量、静息能量、体重，POST 到下面的地址即可。`;
`接口地址` (value `{origin}/api/health/ingest`); `生成个人 Token` / `重新生成 Token`; `当前：{api_token_hint}`; `查看设置步骤`;
confirm `重新生成后旧 Token 立即失效，快捷指令需要更新。继续？`; `只显示这一次，请复制保存：`; modal title `iPhone 快捷指令设置步骤`.

---

## 7. Error message catalogue (scope of this document)

| Status | Message | Where |
|---|---|---|
| 400 | `请求格式不正确` | any malformed JSON |
| 400 | `邀请码不正确` | register |
| 400 | `用户名不能为空` | register, token, login |
| 400 | `用户名为 2–32 位，可用中文、字母、数字、_ . -` | register |
| 400 | `密码不能为空` | register, token, login |
| 400 | `密码至少 6 位` | register, password |
| 400 | `用户名已被占用` | register |
| 400 | `原密码不正确` | password |
| 400 | `新密码不能为空` | password |
| 400 | `取值必须是 male / female` | profile (`sex`) |
| 400 | `出生日期不能为空` / `出生日期格式应为 YYYY-MM-DD` | profile |
| 400 | `身高不能为空` / `身高格式不正确` / `身高不能小于 80` / `身高不能大于 250` | profile |
| 400 | `体重不能为空` / `体重格式不正确` / `体重不能小于 20` / `体重不能大于 350` | profile |
| 400 | `目标速度格式不正确` / `目标速度不能小于 0.1` / `目标速度不能大于 1` | profile |
| 400 | `目标体重格式不正确` / `目标体重不能小于 20` / `目标体重不能大于 350` | profile |
| 400 | `请先完善个人档案` | profile/targets, day, trends, period |
| 401 | `未登录或令牌已失效` | every `requireAuth` endpoint, plus unknown `/api` paths when unauthenticated |
| 401 | `未登录或 Token 无效` | /health/ingest |
| 401 | `用户名或密码错误` | token, login (**not a session expiry**) |
| 403 | `当前站点已关闭注册` | register |
| 403 | `对方没有向你共享数据` | `?user=` on day, trends, period |
| 404 | `用户不存在` | `?user=` |
| 404 | `接口不存在` | unknown `/api` path (authenticated) |
| 413 | `文件太大` | multipart uploads |
| 500 | `服务器内部错误` | unhandled errors (missing JSON content type, body > 2 MB, …) |

---

## 8. Gaps and recommended ADDITIVE server changes (the web UI is unaffected)

1. **Account deletion (App Store blocker).** No endpoint exists. Apple guideline 5.1.1(v) requires in-app deletion for apps that
   offer account creation. Proposal: `DELETE /api/v1/account` with body `{"password": string}` → `{"ok": true}`. Implementation: verify the password, then
   `DELETE FROM users WHERE id=?`. All tables have `ON DELETE CASCADE` with `PRAGMA foreign_keys=ON`; `meal_items.food_id` becomes NULL for
   other users' references to the user's public foods. Also `rm -rf data/uploads/<uid>`. Errors: `400 密码不正确`.
2. **`current` flag in `GET /auth/sessions`.** Add `current: boolean` (row hash == hash of the request's token), so the device list can label
   and protect "本机". The field is additive, so existing clients ignore it.
3. **Registration capability discovery (optional).** `GET /api/v1/auth/config` (public) → `{"allow_registration": bool, "invite_required": bool}`,
   so the app can hide the invite field or show "注册已关闭". Without it, always show the optional invite field as the web does.
4. **Token lifetime (optional).** A sliding renewal, or `POST /api/v1/auth/refresh` (returns a new `nla_` token).
   Without it, users must log in again every 365 days. **Implemented (DESIGN §C.8):** the old token stays valid for ≤ 24 h after the rotation
   (its expiry is only shortened, never extended), so a lost response can be retried with it instead of forcing a logout.
5. **Optional:** a `revoke_others: true` flag on `POST /auth/password` that deletes the user's other sessions.
6. **Optional robustness:** prefer the Bearer token over the cookie when the `Authorization` header is present. The web never sends Authorization, so this is safe.
   Not needed if iOS disables cookies (section 2.2).
7. **Transport:** production is `http://<IP>:8787`, so passwords and 365-day bearer tokens travel in cleartext. iOS ATS blocks plain HTTP by default.
   `NSExceptionDomains` is documented for domain names, not IP literals, so a debug build may need `NSAllowsArbitraryLoads` (an App Review flag).
   ATS handling of raw IP literals has varied between OS versions, so test on a device. Strongly recommended: a domain plus HTTPS reverse proxy (the README already suggests Nginx/Caddy plus `COOKIE_SECURE=true`).
8. Not in this scope but related: `GET /api/uploads/:id` requires auth (so `AsyncImage` cannot load it; fetch with the Bearer header) and
   resolves the file under the **viewer's** upload directory. A shared member's meal photos therefore return 404 for other viewers.

Absent features (do not build UI for them): password reset / forgot password, username change, email, avatar images (colour only),
per-device naming after login, `nl_` token revocation without replacement.

---

## 9. iOS implementation checklist

- A dedicated `URLSession` with cookies disabled (section 2.2). Headers: `Authorization: Bearer <nla_>`, `Content-Type: application/json`
  (with `{}` for bodiless POST/PUT), `Accept: application/json`.
- Login: `POST /auth/token {username, password, device_name}`, then store `token` and `expires_at` in the **Keychain**
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background HealthKit sync can read it after first unlock), then `GET /auth/me`.
- Register: `POST /auth/register {username, password, display_name?, invite_code, device_name}`, then token, then `/auth/me`, then Onboarding (`profile == null`)
  and `PUT /profile` with `timezone: TimeZone.current.identifier`.
- Global 401 handling: for any request **other than** `/auth/token`, `/auth/register`, `/auth/login`, `/auth/logout`, wipe the token and show
  Login. Show the `error` string. Optionally pre-empt expiry using `expires_at`.
- Client-side validation mirroring the server: username regex, password ≥ 6 (trim), height 80–250, weight 20–350, rate 0.1–1,
  target weight 20–350, birth date in the past, de-duplicated conditions. Always send the **full** Profile and the **full** settings object.
- Treat `me.today` and `profile.timezone` as the source of "today". If `TimeZone.current.identifier != profile.timezone`, offer to update the profile.
- Date decoding: two strategies (ISO-8601 with fractional seconds for `expires_at`, `yyyy-MM-dd HH:mm:ss` UTC for `created_at` and `last_used_at`), plus
  `YYYY-MM-DD` strings kept as `String` or a custom `LocalDate` type (not `Date`, to avoid time-zone drift).
- HealthKit uploads to `/health/ingest` should use the same `nla_` token (no `nl_` needed).
