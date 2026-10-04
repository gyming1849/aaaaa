// GET /auth/config、/auth/sessions 的 current、POST /auth/refresh、POST /account/delete、OpenAPI（DESIGN §C.10）
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { makeTestApp, api, register, newUser, todaySh, addDays, INVITE, type TestApp } from "./helpers/testApp.ts";

let app: TestApp;
let base: string;
const T = todaySh();

before(async () => {
  app = await makeTestApp();
  base = app.base;
});
after(async () => {
  await app.close();
});

const sha256 = (t: string) => crypto.createHash("sha256").update(t).digest("hex");
const count = (sql: string, ...params: (string | number)[]) => (app.db.prepare(sql).get(...params) as { n: number }).n;

test("GET /auth/config is public and never leaks the invite code", async () => {
  const r = await api(base).get("/auth/config");
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, {
    allow_registration: true, invite_required: true, min_password: 6, server_version: "1",
    features: ["health_sync", "account_delete", "token_refresh", "session_current", "ai_consent"],
  });
  assert.ok(!JSON.stringify(r.body).includes(INVITE));
  // /api 前缀同样可用
  assert.equal((await fetch(base.replace("/api/v1", "/api") + "/auth/config")).status, 200);
});

test("GET /auth/sessions marks exactly the calling token as current", async () => {
  const a = await register(base, "sess_user", "secret123", "设备 A");
  const login = await api(base).post("/auth/token", { username: "sess_user", password: "secret123", device_name: "设备 B" });
  assert.equal(login.status, 200);
  const b = login.body.token as string;

  const ra = await api(base, a).get("/auth/sessions");
  assert.equal(ra.status, 200);
  assert.equal(ra.body.length, 2);
  for (const row of ra.body) {
    assert.deepEqual(Object.keys(row), ["id", "kind", "device_name", "created_at", "last_used_at", "expires_at", "current"]);
    assert.equal(typeof row.current, "boolean");
  }
  const curA = ra.body.filter((s: { current: boolean }) => s.current);
  assert.equal(curA.length, 1);
  assert.equal(curA[0].device_name, "设备 A");

  const rb = await api(base, b).get("/auth/sessions");
  const curB = rb.body.filter((s: { current: boolean }) => s.current);
  assert.equal(curB.length, 1);
  assert.equal(curB[0].device_name, "设备 B");

  // 网页 Cookie 会话：Cookie 优先，标记的是 web 会话
  const web = await api(base).post("/auth/login", { username: "sess_user", password: "secret123" });
  const cookie = (web.headers.get("set-cookie") ?? "").split(";")[0];
  assert.match(cookie, /^nl_session=/);
  const rc = await api(base, a, { cookie }).get("/auth/sessions");
  const curC = rc.body.filter((s: { current: boolean }) => s.current);
  assert.equal(curC.length, 1);
  assert.equal(curC[0].kind, "web");
});

test("POST /auth/refresh rotates an app token and rejects web sessions", async () => {
  const old = await register(base, "refresh_user", "secret123", "小林的 iPhone");
  const r = await api(base, old).post("/auth/refresh");
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body), ["token", "expires_at"]);
  const next = r.body.token as string;
  assert.ok(next.startsWith("nla_"));
  assert.notEqual(next, old);
  assert.ok(new Date(r.body.expires_at).getTime() > Date.now() + 300 * 86400_000);

  // 旧令牌进入宽限期：仍可使用，但有效期不超过 24 小时（响应丢失时客户端可以重试续期）
  assert.equal((await api(base, old).get("/auth/me")).status, 200);
  assert.equal((await api(base, next).get("/auth/me")).status, 200);
  const oldRow = app.db.prepare("SELECT expires_at FROM sessions WHERE token_hash = ?").get(sha256(old)) as { expires_at: string };
  assert.ok(new Date(oldRow.expires_at).getTime() <= Date.now() + 24 * 3600_000, "old token expires within 24 h");
  const sessions = (await api(base, next).get("/auth/sessions")).body as { device_name: string; current: boolean; kind: string }[];
  assert.equal(sessions.length, 2);
  assert.deepEqual(sessions.filter((s) => s.current).map((s) => ({ device_name: s.device_name, kind: s.kind })), [{ device_name: "小林的 iPhone", kind: "app" }]);
  assert.ok(sessions.every((s) => s.device_name === "小林的 iPhone" && s.kind === "app"));

  // 宽限期内用旧令牌再续期一次（上一次的响应丢失）也成功，且不会延长旧令牌的有效期
  const retry = await api(base, old).post("/auth/refresh");
  assert.equal(retry.status, 200, JSON.stringify(retry.body));
  assert.notEqual(retry.body.token, next);
  const oldRow2 = app.db.prepare("SELECT expires_at FROM sessions WHERE token_hash = ?").get(sha256(old)) as { expires_at: string };
  assert.ok(oldRow2.expires_at <= oldRow.expires_at, "the grace window is never extended");
  assert.equal((await api(base, retry.body.token).get("/auth/me")).status, 200);

  // 宽限期过后旧令牌失效
  app.db.prepare("UPDATE sessions SET expires_at = ? WHERE token_hash = ?").run(new Date(Date.now() - 1000).toISOString(), sha256(old));
  assert.equal((await api(base, old).get("/auth/me")).status, 401);
  assert.equal((await api(base, next).get("/auth/me")).status, 200);

  const web = await api(base).post("/auth/login", { username: "refresh_user", password: "secret123" });
  const cookie = (web.headers.get("set-cookie") ?? "").split(";")[0];
  const w = await api(base, undefined, { cookie }).post("/auth/refresh");
  assert.equal(w.status, 400);
  assert.equal(w.body.error, "只有 App 令牌可以续期");
  assert.equal((await api(base, undefined, { cookie }).get("/auth/me")).status, 200, "web session still valid");
  assert.equal((await api(base).post("/auth/refresh")).status, 401);
});

test("POST /account/delete verifies the password and removes everything", async () => {
  const { client, uid, token } = await newUser(base, "delete_me");
  const other = await newUser(base, "delete_other");
  const D = addDays(T, -2);

  // HealthKit 数据：快照、同步样本、墓碑、同步状态
  const s = await client.post("/health/sync", {
    device_id: "dev-del", days: [{ date: D, steps: 5000 }],
    samples: [{ uuid: "DEL-1", type: "body_mass", date: D, time: "07:00", value: 70 }, { uuid: "DEL-2", type: "body_mass", date: D, time: "08:00", value: 70.2 }],
    workouts: [{ uuid: "DEL-W", date: D, time: "18:00", activity_key: "jogging", duration_min: 30, in_device: false }],
  });
  assert.equal(s.status, 200);
  const del2 = app.db.prepare("SELECT id FROM body_metrics WHERE user_id = ? AND external_id = 'DEL-2'").get(uid) as { id: number };
  await client.del(`/body/${del2.id}`);
  assert.equal(count("SELECT COUNT(*) AS n FROM health_tombstones WHERE user_id = ?", uid), 1);

  // 上传照片 → 上传目录
  const form = new FormData();
  form.append("photos", new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" }), "photo1.jpg");
  const up = await client.post("/uploads", form);
  assert.equal(up.status, 200, JSON.stringify(up.body));
  const userDir = path.join(app.uploadDir, String(uid));
  assert.ok(fs.existsSync(userDir));

  // 公开食物被另一个用户的餐食引用
  const food = await client.post("/foods", { name: "注销测试公开食物", visibility: "public", per100: { energy_kcal: 120 } });
  assert.equal(food.status, 200);
  const meal = await other.client.post("/meals", {
    date: T, time: "12:00", meal_type: "lunch",
    items: [{ name: "注销测试公开食物", amount_g: 150, food_id: food.body.id, nutrients: {}, groups: {} }],
  });
  assert.equal(meal.status, 200, JSON.stringify(meal.body));
  const itemFood = () => (app.db.prepare("SELECT food_id FROM meal_items WHERE meal_id = ?").get(meal.body.id) as { food_id: number | null }).food_id;
  assert.equal(itemFood(), food.body.id);

  const empty = await client.post("/account/delete", {});
  assert.equal(empty.status, 400);
  assert.equal(empty.body.error, "密码不能为空");
  const wrong = await client.post("/account/delete", { password: "wrong-pass" });
  assert.equal(wrong.status, 400);
  assert.equal(wrong.body.error, "密码不正确");
  assert.equal(count("SELECT COUNT(*) AS n FROM users WHERE id = ?", uid), 1);

  const ok = await client.post("/account/delete", { password: "secret123" });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(ok.body, { ok: true });
  assert.equal(count("SELECT COUNT(*) AS n FROM users WHERE id = ?", uid), 0);
  for (const t of ["sessions", "profiles", "body_metrics", "exercises", "activity_days", "health_tombstones", "health_day_snapshots", "health_sync_state", "meals", "daily_scores", "ai_consent"]) {
    assert.equal(count(`SELECT COUNT(*) AS n FROM ${t} WHERE user_id = ?`, uid), 0, t);
  }
  assert.equal(count("SELECT COUNT(*) AS n FROM foods WHERE owner_id = ?", uid), 0);
  assert.ok(!fs.existsSync(userDir), "uploads removed");
  assert.equal((await api(base, token).get("/auth/me")).status, 401);
  assert.equal(itemFood(), null, "other user's meal item keeps its data but loses the food link");
  assert.equal((await other.client.get("/auth/me")).status, 200, "other users unaffected");
});

test("cascade delete of a user with synced (external_id) rows succeeds thanks to the trigger guard", async () => {
  const { client, uid } = await newUser(base, "cascade_user");
  const D = addDays(T, -1);
  const r = await client.post("/health/sync", {
    device_id: "dev-c",
    samples: [{ uuid: "C-1", type: "waist", date: D, time: "07:00", value: 80 }],
    workouts: [{ uuid: "C-W", date: D, time: "07:30", activity_key: "yoga", duration_min: 20, in_device: false }],
  });
  assert.equal(r.status, 200);
  app.db.prepare("DELETE FROM users WHERE id = ?").run(uid);
  assert.equal(count("SELECT COUNT(*) AS n FROM body_metrics WHERE user_id = ?", uid), 0);
  assert.equal(count("SELECT COUNT(*) AS n FROM exercises WHERE user_id = ?", uid), 0);
  assert.equal(count("SELECT COUNT(*) AS n FROM health_tombstones WHERE user_id = ?", uid), 0);
});

test("AI consent: migration v4, GET/PUT /ai/consent and the scheduler gate", async () => {
  assert.equal((app.db.prepare("SELECT MAX(version) AS v FROM _migrations").get() as { v: number }).v, 4);
  const { schedulerMayUseAI } = await import("../src/services/scheduler.ts");

  // 网页用户（从未在 App 中回答、没有苹果健康同步）：自动 AI 点评保持原样
  const web = await newUser(base, "consent_web");
  assert.deepEqual((await web.client.get("/ai/consent")).body, { granted: null, updated_at: null });
  assert.equal(schedulerMayUseAI(web.uid), true);

  // 用苹果健康同步过、但没有同意：不自动发送
  const hk = await newUser(base, "consent_hk");
  const r = await hk.client.post("/health/sync", { device_id: "dev-consent", days: [{ date: addDays(T, -1), steps: 1000 }] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(schedulerMayUseAI(hk.uid), false);

  const bad = await hk.client.put("/ai/consent", { granted: "yes" });
  assert.equal(bad.status, 400);
  assert.equal((await hk.client.put("/ai/consent", { granted: true })).status, 200);
  const got = await hk.client.get("/ai/consent");
  assert.equal(got.body.granted, true);
  assert.ok(typeof got.body.updated_at === "string");
  assert.equal(schedulerMayUseAI(hk.uid), true);

  // 明确不同意：网页用户也以回答为准
  assert.equal((await web.client.put("/ai/consent", { granted: false })).status, 200);
  assert.equal((await web.client.get("/ai/consent")).body.granted, false);
  assert.equal(schedulerMayUseAI(web.uid), false);
  assert.equal((await api(base).get("/ai/consent")).status, 401);
});

test("OpenAPI documents the new routes", async () => {
  const { buildOpenApi } = await import("../src/openapi.ts");
  const doc = buildOpenApi("http://x") as { paths: Record<string, Record<string, unknown>>; components: { schemas: Record<string, unknown> } };
  for (const p of ["/health/sync", "/health/sync/state", "/health/sync/unlink", "/auth/config", "/auth/refresh", "/ai/consent", "/account/delete", "/labs/{id}", "/uploads/{id}"]) {
    assert.ok(doc.paths[p], p);
  }
  for (const s of ["HealthSyncRequest", "SyncDay", "SyncSample", "SyncWorkout", "HealthSyncResponse", "HealthSyncState"]) assert.ok(doc.components.schemas[s], s);
  const served = await api(base).get("/openapi.json");
  assert.equal(served.status, 200);
  assert.ok(served.body.paths["/health/sync"]);
});
