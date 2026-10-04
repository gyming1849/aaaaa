// POST /health/sync、GET /health/sync/state、POST /health/sync/unlink 以及迁移 v3 的集成测试（DESIGN §C.10）
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { makeTestApp, api, register, newUser, todaySh, addDays, type TestApp } from "./helpers/testApp.ts";

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

const q = <R = Record<string, unknown>>(sql: string, ...params: (string | number | null)[]) =>
  app.db.prepare(sql).get(...params) as R | undefined;
const qa = <R = Record<string, unknown>>(sql: string, ...params: (string | number | null)[]) =>
  app.db.prepare(sql).all(...params) as R[];

const DEV = { device_id: "4F0C2E7A-TEST-0000-0000-000000000001", device_name: "测试 iPhone", timezone: "Asia/Shanghai" };

function sync(client: ReturnType<typeof api>, body: Record<string, unknown>) {
  return client.post("/health/sync", { ...DEV, ...body });
}

const weight = (uuid: string, date: string, value: number, time = "22:31") =>
  ({ uuid, type: "body_mass", date, time, start: `${date}T${time}:05+08:00`, value, source_name: "Withings" });

// ---------------------------------------------------------------- 1. migration

test("migration v3: version, new columns, tables, indexes and triggers", () => {
  assert.ok(q<{ v: number }>("SELECT MAX(version) AS v FROM _migrations")!.v >= 3); // v4 (ai_consent) is covered in appAccount.test.ts
  const cols = (t: string) => qa<{ name: string }>(`PRAGMA table_info(${t})`).map((c) => c.name);
  for (const c of ["external_id", "source_name"]) assert.ok(cols("body_metrics").includes(c), `body_metrics.${c}`);
  for (const c of ["external_id", "source_name", "started_at", "ended_at", "hk_activity_type"]) assert.ok(cols("exercises").includes(c), `exercises.${c}`);
  const names = (type: string) => qa<{ name: string }>("SELECT name FROM sqlite_master WHERE type = ?", type).map((r) => r.name);
  for (const t of ["health_day_snapshots", "health_tombstones", "health_sync_state"]) assert.ok(names("table").includes(t), t);
  for (const i of ["idx_body_ext", "idx_ex_ext"]) assert.ok(names("index").includes(i), i);
  for (const tr of ["trg_body_tomb", "trg_ex_tomb"]) assert.ok(names("trigger").includes(tr), tr);
});

// ---------------------------------------------------------------- 2–7. days

test("days: insert writes a healthkit row + snapshot and feeds /activity and /day", async () => {
  const { client, uid } = await newUser(base, "hk_days");
  const D = addDays(T, -2);
  const day = { date: D, steps: 8532, active_kcal: 412.3, resting_kcal: 1620.4, distance_km: 6.12, exercise_min: 35, stand_hours: 11, sleep_hours: 7.25 };
  const r = await sync(client, { days: [day] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.equal(r.body.timezone, "Asia/Shanghai");
  assert.equal(r.body.server_today, T);
  assert.equal(r.body.timezone_mismatch, false);
  assert.deepEqual(r.body.days, { upserted: 1, unchanged: 0, kept_manual: [], rejected: [] });
  assert.equal(r.body.invalidated_from, D);
  assert.ok(!("samples" in r.body) && !("workouts" in r.body) && !("deleted" in r.body), "absent sections are absent");

  const row = q<Record<string, unknown>>("SELECT * FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(row.source, "healthkit");
  for (const [k, v] of Object.entries(day)) assert.equal(row[k], v, k);
  const snap = q<Record<string, unknown>>("SELECT * FROM health_day_snapshots WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(snap.steps, 8532);
  assert.equal(snap.sleep_hours, 7.25);

  const act = await client.get(`/activity?start=${D}&end=${D}`);
  assert.equal(act.body.days.length, 1);
  assert.equal(act.body.days[0].steps, 8532);
  const d = await client.get(`/day/${D}`);
  assert.equal(d.status, 200);
  assert.equal(d.body.score.energy.activeSource, "device");
  assert.equal(d.body.activity.active_kcal, 412.3);

  const mismatch = await sync(client, { timezone: "America/New_York", days: [] });
  assert.equal(mismatch.body.timezone_mismatch, true);
  assert.deepEqual(mismatch.body.days, { upserted: 0, unchanged: 0, kept_manual: [], rejected: [] });
});

test("days: identical re-post is unchanged, does not invalidate and keeps the cached score", async () => {
  const { client, uid } = await newUser(base, "hk_idem");
  const D = addDays(T, -3);
  const D2 = addDays(T, -4);
  const payload = { days: [{ date: D, steps: 7000, active_kcal: 300, sleep_hours: 7 }, { date: D2, steps: 6000 }] };
  assert.equal((await sync(client, payload)).body.days.upserted, 2);
  await client.get(`/day/${D}`); // 生成评分缓存
  assert.ok(q("SELECT 1 AS x FROM daily_scores WHERE user_id = ? AND date = ?", uid, D));
  const again = await sync(client, payload);
  assert.equal(again.status, 200);
  assert.equal(again.body.days.unchanged, 2);
  assert.equal(again.body.days.upserted, 0);
  assert.equal(again.body.invalidated_from, null);
  assert.ok(q("SELECT 1 AS x FROM daily_scores WHERE user_id = ? AND date = ?", uid, D), "cached score survives");
});

test("days: manual edits are protected (kept_manual) unless overwrite_manual", async () => {
  const { client, uid } = await newUser(base, "hk_manual");
  const D = addDays(T, -5);
  await sync(client, { days: [{ date: D, steps: 8000, sleep_hours: 7 }] });
  assert.equal((await client.put(`/activity/${D}`, { steps: 8000, sleep_hours: 6.5 })).status, 200);
  assert.equal(q<{ source: string }>("SELECT source FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!.source, "manual");

  const r = await sync(client, { days: [{ date: D, steps: 9000, sleep_hours: 7.2 }] });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.days.kept_manual, [{ date: D, fields: ["sleep_hours"] }]);
  assert.equal(r.body.days.upserted, 1);
  let row = q<{ steps: number; sleep_hours: number; source: string }>("SELECT steps, sleep_hours, source FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(row.steps, 9000, "steps was unchanged from the snapshot, so HealthKit updates it");
  assert.equal(row.sleep_hours, 6.5, "user's sleep is kept");
  assert.equal(row.source, "manual");

  const o = await sync(client, { overwrite_manual: true, days: [{ date: D, steps: 9000, sleep_hours: 7.2 }] });
  assert.deepEqual(o.body.days.kept_manual, []);
  row = q<{ steps: number; sleep_hours: number; source: string }>("SELECT steps, sleep_hours, source FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(row.sleep_hours, 7.2);
  assert.equal(row.source, "manual", "source stays manual");

  // overwrite_manual 只认真正的布尔值
  await client.put(`/activity/${D}`, { steps: 9000, sleep_hours: 6 });
  const s = await sync(client, { overwrite_manual: "true", days: [{ date: D, steps: 9000, sleep_hours: 8 }] });
  assert.deepEqual(s.body.days.kept_manual, [{ date: D, fields: ["sleep_hours"] }]);
});

test("days: a manual clear wins over the next sync", async () => {
  const { client, uid } = await newUser(base, "hk_clear_wins");
  const D = addDays(T, -6);
  await sync(client, { days: [{ date: D, steps: 5000, sleep_hours: 7 }] });
  await client.put(`/activity/${D}`, { steps: 5000 }); // 网页编辑时清空了睡眠
  const r = await sync(client, { days: [{ date: D, steps: 5000, sleep_hours: 7 }] });
  assert.deepEqual(r.body.days.kept_manual, [{ date: D, fields: ["sleep_hours"] }]);
  assert.equal(r.body.days.unchanged, 1);
  const row = q<{ steps: number; sleep_hours: number | null }>("SELECT steps, sleep_hours FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(row.sleep_hours, null);
  assert.equal(row.steps, 5000);
});

test("days: clear nulls a field on a healthkit row (unknown keys ignored)", async () => {
  const { client, uid } = await newUser(base, "hk_clear");
  const D = addDays(T, -7);
  await sync(client, { days: [{ date: D, steps: 6000, sleep_hours: 7.5 }] });
  const r = await sync(client, { days: [{ date: D, steps: 6000, clear: ["sleep_hours", "bogus"] }] });
  assert.equal(r.body.days.upserted, 1);
  const row = q<{ steps: number; sleep_hours: number | null; source: string }>("SELECT steps, sleep_hours, source FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(row.sleep_hours, null);
  assert.equal(row.steps, 6000);
  assert.equal(row.source, "healthkit");
  assert.equal(q<{ sleep_hours: number | null }>("SELECT sleep_hours FROM health_day_snapshots WHERE user_id = ? AND date = ?", uid, D)!.sleep_hours, null);
});

test("days: legacy Shortcut rows are overwritten and relabelled healthkit", async () => {
  const { client, uid } = await newUser(base, "hk_legacy");
  const D = addDays(T, -8);
  assert.equal((await client.post("/health/ingest", { date: D, steps: 5000 })).status, 200);
  assert.equal(q<{ source: string }>("SELECT source FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!.source, "apple_shortcut");
  const r = await sync(client, { days: [{ date: D, steps: 6000 }] });
  assert.equal(r.body.days.upserted, 1);
  const row = q<{ steps: number; source: string }>("SELECT steps, source FROM activity_days WHERE user_id = ? AND date = ?", uid, D)!;
  assert.equal(row.steps, 6000);
  assert.equal(row.source, "healthkit");
});

// ---------------------------------------------------------------- 8–9. samples

test("samples: insert, unchanged, update by uuid, per-item rejection", async () => {
  const { client, uid } = await newUser(base, "hk_samples");
  const D = addDays(T, -2);
  const r1 = await sync(client, { samples: [weight("W-1", D, 68.2)] });
  assert.deepEqual(r1.body.samples, { inserted: 1, updated: 0, unchanged: 0, skipped_tombstoned: 0, rejected: [] });
  assert.equal(r1.body.invalidated_from, D);
  const row = q<Record<string, unknown>>("SELECT * FROM body_metrics WHERE user_id = ? AND external_id = 'W-1'", uid)!;
  assert.equal(row.weight_kg, 68.2);
  assert.equal(row.source, "healthkit");
  assert.equal(row.source_name, "Withings");
  assert.equal(row.note, null);
  assert.equal(row.time, "22:31");

  const r2 = await sync(client, { samples: [weight("W-1", D, 68.2)] });
  assert.equal(r2.body.samples.unchanged, 1);
  assert.equal(r2.body.invalidated_from, null);

  const r3 = await sync(client, { samples: [weight("W-1", D, 68.0)] });
  assert.equal(r3.body.samples.updated, 1);
  const rows = qa<{ weight_kg: number }>("SELECT weight_kg FROM body_metrics WHERE user_id = ? AND external_id = 'W-1'", uid);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].weight_kg, 68.0);

  const r4 = await sync(client, {
    samples: [
      { uuid: "BP-1", type: "blood_pressure", date: D, time: "08:00", sbp: 118 },
      { uuid: "F-1", type: "body_fat", date: D, time: "08:00", value: 1.0 },
      { uuid: "WA-1", type: "waist", date: D, time: "08:00", value: 82 },
      { uuid: "BP-2", type: "blood_pressure", date: D, time: "08:05", sbp: 121, dbp: 79, bp_treated: true },
    ],
  });
  assert.equal(r4.status, 200);
  assert.deepEqual(r4.body.samples.rejected, [
    { uuid: "BP-1", error: "舒张压不能为空" },
    { uuid: "F-1", error: "体脂率不能小于 2" },
  ]);
  assert.equal(r4.body.samples.inserted, 2);
  assert.equal(q<{ waist_cm: number }>("SELECT waist_cm FROM body_metrics WHERE user_id = ? AND external_id = 'WA-1'", uid)!.waist_cm, 82);
  const bp = q<{ sbp: number; dbp: number; bp_treated: number }>("SELECT sbp, dbp, bp_treated FROM body_metrics WHERE user_id = ? AND external_id = 'BP-2'", uid)!;
  assert.deepEqual({ ...bp }, { sbp: 121, dbp: 79, bp_treated: 1 });
});

test("samples: a row deleted on the web is tombstoned and never re-created", async () => {
  const { client, uid } = await newUser(base, "hk_tomb");
  const D = addDays(T, -3);
  await sync(client, { samples: [weight("T-1", D, 71)] });
  const id = q<{ id: number }>("SELECT id FROM body_metrics WHERE user_id = ? AND external_id = 'T-1'", uid)!.id;
  assert.equal((await client.del(`/body/${id}`)).status, 200);
  const tomb = q<{ kind: string }>("SELECT kind FROM health_tombstones WHERE user_id = ? AND external_id = 'T-1'", uid);
  assert.equal(tomb?.kind, "body");
  const r = await sync(client, { samples: [weight("T-1", D, 71)] });
  assert.equal(r.body.samples.skipped_tombstoned, 1);
  assert.equal(r.body.samples.inserted, 0);
  assert.equal(q("SELECT 1 AS x FROM body_metrics WHERE user_id = ? AND external_id = 'T-1'", uid), undefined);
});

// ---------------------------------------------------------------- 10–11. workouts and deletions

test("workouts: kcal formula, in_device, fallback key, idempotency, possible duplicates", async () => {
  const { client, uid } = await newUser(base, "hk_workouts");
  const D = addDays(T, -3);
  await sync(client, { samples: [weight("WW-1", addDays(D, -1), 80, "07:00")] }); // 最近一次称重 80 kg
  const run1 = {
    uuid: "R-1", date: D, time: "18:05", start: `${D}T18:05:00+08:00`, end: `${D}T18:50:12+08:00`, hk_activity_type: 37,
    activity_key: "run_10kmh", description: "户外跑步", met: 9.3, duration_min: 45, distance_km: 7.4, avg_hr: 152, device_kcal: 480,
    in_device: true, source_name: "Apple Watch",
  };
  const unknown = { uuid: "U-1", date: D, time: "07:30", activity_key: "zumba_unknown", duration_min: 20, in_device: false };
  const proto = { uuid: "U-2", date: D, time: "07:45", activity_key: "constructor", duration_min: 10, in_device: false };
  const r = await sync(client, { workouts: [run1, unknown, proto] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.workouts, { inserted: 3, updated: 0, unchanged: 0, skipped_tombstoned: 0, rejected: [], possible_duplicates: [] });
  const row = q<Record<string, unknown>>("SELECT * FROM exercises WHERE user_id = ? AND external_id = 'R-1'", uid)!;
  assert.equal(row.kcal, Math.round((9.3 - 1) * 80 * 45 / 60));
  assert.equal(row.in_device, 1);
  assert.equal(row.source, "healthkit");
  assert.equal(row.time, "18:05");
  assert.equal(row.avg_hr, 152);
  assert.equal(row.device_kcal, 480);
  assert.equal(row.started_at, run1.start);
  assert.equal(row.ended_at, run1.end);
  assert.equal(row.hk_activity_type, 37);
  assert.equal(row.description, "户外跑步");
  const u = q<Record<string, unknown>>("SELECT * FROM exercises WHERE user_id = ? AND external_id = 'U-1'", uid)!;
  assert.equal(u.activity_key, "other_moderate");
  assert.equal(u.met, 4.5);
  assert.equal(u.description, "其他中等强度活动");
  assert.equal(u.in_device, 0);
  assert.equal(q<{ activity_key: string }>("SELECT activity_key FROM exercises WHERE user_id = ? AND external_id = 'U-2'", uid)!.activity_key, "other_moderate");

  const again = await sync(client, { workouts: [run1, unknown, proto] });
  assert.equal(again.body.workouts.unchanged, 3);
  assert.equal(again.body.invalidated_from, null);
  const upd = await sync(client, { workouts: [{ ...run1, duration_min: 50 }] });
  assert.equal(upd.body.workouts.updated, 1);
  assert.equal(q<{ kcal: number }>("SELECT kcal FROM exercises WHERE user_id = ? AND external_id = 'R-1'", uid)!.kcal, Math.round((9.3 - 1) * 80 * 50 / 60));
  assert.equal(qa("SELECT id FROM exercises WHERE user_id = ? AND external_id = 'R-1'", uid).length, 1);

  // 手动记录的跑步 + 同日同家族、时长相差 ≤20% 的 HealthKit 跑步 → 提示可能重复，两条都保留
  const D2 = addDays(T, -4);
  const manual = await client.post("/exercises", { date: D2, time: "19:00", activity_key: "run_10kmh", duration_min: 40 });
  assert.equal(manual.status, 200);
  await client.post("/exercises", { date: D2, time: "20:00", activity_key: "swim_leisure", duration_min: 40 }); // 不同家族
  const dup = await sync(client, { workouts: [{ uuid: "R-2", date: D2, time: "19:05", activity_key: "run_13kmh", duration_min: 45, in_device: false }] });
  assert.deepEqual(dup.body.workouts.possible_duplicates, [{ uuid: "R-2", exercise_id: manual.body.id, description: "跑步 (约 10 km/h)" }]);
  const day = await client.get(`/activity?start=${D2}&end=${D2}`);
  assert.equal(day.body.exercises.length, 3);

  const bad = await sync(client, {
    workouts: [
      { uuid: "B-1", date: D, time: "10:00", activity_key: "run_10kmh", duration_min: 0.5 },
      { uuid: "B-2", date: D, time: "10:00", activity_key: "run_10kmh", duration_min: 30, met: 30 },
      { uuid: "B-3", date: D, time: "10:00", activity_key: "run_10kmh", duration_min: 30, avg_hr: 20 },
    ],
  });
  assert.deepEqual(bad.body.workouts.rejected.map((x: { error: string }) => x.error), ["时长不能小于 1", "MET不能大于 25", "平均心率不能小于 30"]);
});

test("workouts: a re-sent workout keeps the in_device value toggled on the web (only set on insert)", async () => {
  const { client, uid } = await newUser(base, "hk_indevice");
  const D = addDays(T, -2);
  const w = { uuid: "ID-1", date: D, time: "08:00", activity_key: "run_10kmh", duration_min: 30, device_kcal: 300, in_device: true };
  const first = await sync(client, { workouts: [w] });
  assert.equal(first.body.workouts.inserted, 1);
  const row = () => q<{ id: number; in_device: number; duration_min: number }>("SELECT id, in_device, duration_min FROM exercises WHERE user_id = ? AND external_id = 'ID-1'", uid)!;
  assert.equal(row().in_device, 1);

  // 用户在网页上把它改成「不计入设备」
  const patched = await client.patch(`/exercises/${row().id}`, { in_device: false });
  assert.equal(patched.status, 200);
  assert.equal(row().in_device, 0);

  // 重试 / 重新同步全部：同样的数据 → unchanged，手动切换保留
  const retry = await sync(client, { workouts: [w] });
  assert.equal(retry.body.workouts.unchanged, 1);
  assert.equal(retry.body.invalidated_from, null);
  assert.equal(row().in_device, 0);

  // 其他字段变化 → updated，in_device 仍保留
  const changed = await sync(client, { workouts: [{ ...w, duration_min: 35 }] });
  assert.equal(changed.body.workouts.updated, 1);
  assert.equal(row().duration_min, 35);
  assert.equal(row().in_device, 0);

  // 反方向：插入时为 false、网页改成 true，再同步也不会被改回
  const w2 = { ...w, uuid: "ID-2", time: "19:00", in_device: false };
  await sync(client, { workouts: [w2] });
  const id2 = q<{ id: number }>("SELECT id FROM exercises WHERE user_id = ? AND external_id = 'ID-2'", uid)!.id;
  await client.patch(`/exercises/${id2}`, { in_device: true });
  await sync(client, { workouts: [{ ...w2, duration_min: 40 }] });
  assert.equal(q<{ in_device: number }>("SELECT in_device FROM exercises WHERE id = ?", id2)!.in_device, 1);
});

test("deleted: removes synced rows by uuid, records tombstones, counts not_found", async () => {
  const { client, uid } = await newUser(base, "hk_deleted");
  const D = addDays(T, -2);
  await sync(client, {
    samples: [weight("DS-1", D, 70)],
    workouts: [{ uuid: "DX-1", date: D, time: "09:00", activity_key: "walk_brisk", duration_min: 30, in_device: false }],
  });
  const r = await sync(client, { deleted: ["DS-1", "DX-1", "nope-1", "nope-2"] });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.deleted, { body: 1, exercises: 1, not_found: 2 });
  assert.equal(r.body.invalidated_from, D);
  assert.equal(q("SELECT 1 AS x FROM body_metrics WHERE user_id = ? AND external_id = 'DS-1'", uid), undefined);
  assert.equal(q("SELECT 1 AS x FROM exercises WHERE user_id = ? AND external_id = 'DX-1'", uid), undefined);
  const tombs = qa<{ external_id: string; kind: string }>("SELECT external_id, kind FROM health_tombstones WHERE user_id = ? ORDER BY external_id", uid);
  assert.deepEqual(tombs.map((t) => ({ ...t })), [{ external_id: "DS-1", kind: "body" }, { external_id: "DX-1", kind: "exercise" }]);
});

// ---------------------------------------------------------------- 12. scoring

test("scoring: synced activity, workouts, weight and BP flow into /day", async () => {
  const { client } = await newUser(base, "hk_scoring");
  const D = addDays(T, -2);
  const r = await sync(client, {
    days: [{ date: D, active_kcal: 500, steps: 9000 }],
    workouts: [{ uuid: "SW-1", date: D, time: "18:00", activity_key: "run_10kmh", duration_min: 30, device_kcal: 300, in_device: true }],
  });
  assert.equal(r.status, 200);
  let d = await client.get(`/day/${D}`);
  assert.equal(d.body.score.energy.activeSource, "device");
  assert.equal(d.body.score.energy.active, 500, "in_device workout is not double-counted");
  const kcal = d.body.exercises[0].kcal;
  assert.ok(kcal > 0);
  assert.equal(d.body.score.energy.exerciseKcal, kcal);

  await sync(client, { samples: [weight("SWW-1", D, 77.7, "07:00")] });
  d = await client.get(`/day/${D}`);
  assert.equal(d.body.targets.weightKg, 77.7);

  const bpOf = (le8: { components: { key: string; points: number | null }[] }) => le8.components.find((c) => c.key === "bp")!.points;
  assert.equal(bpOf(d.body.indices.le8), null);
  await sync(client, {
    samples: [0, 1, 2].map((i) => ({ uuid: `SBP-${i}`, type: "blood_pressure", date: addDays(D, -i), time: "08:00", sbp: 118, dbp: 76, bp_treated: false })),
  });
  d = await client.get(`/day/${D}`);
  assert.notEqual(bpOf(d.body.indices.le8), null);
});

// ---------------------------------------------------------------- 13. errors

test("errors: whole-request 400s, 401 for personal tokens, per-item rejections", async () => {
  const noProfile = api(base, await register(base, "hk_noprofile"));
  const np = await noProfile.post("/health/sync", { device_id: "x" });
  assert.equal(np.status, 400);
  assert.equal(np.body.error, "请先完善个人档案");

  const { client, token } = await newUser(base, "hk_errors");
  assert.deepEqual((await client.post("/health/sync", {})).body, { error: "device_id 不能为空" });
  assert.equal((await client.post("/health/sync", { device_id: "   " })).status, 400);
  const many = await sync(client, { days: Array.from({ length: 401 }, (_, i) => ({ date: addDays(T, -i) })) });
  assert.equal(many.status, 400);
  assert.equal(many.body.error, "单次同步数据过多，请分批上传");
  const notArray = await sync(client, { samples: { uuid: "x" } });
  assert.equal(notArray.status, 400);
  assert.equal(notArray.body.error, "请求格式不正确");
  const malformed = await fetch(`${base}/health/sync`, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: "{" });
  assert.equal(malformed.status, 400);

  const personal = (await client.post("/settings/token")).body.token as string;
  assert.ok(personal.startsWith("nl_"));
  const p = await api(base, personal).post("/health/sync", { ...DEV, days: [] });
  assert.equal(p.status, 401);

  const r = await sync(client, {
    days: [
      { date: "2026-13-01", steps: 1 },
      { date: addDays(T, 2), steps: 1 },
      { date: addDays(T, 1), steps: 1 },
      { date: addDays(T, -1), steps: 300000 },
    ],
    samples: [
      { uuid: "", type: "body_mass", date: T, time: "08:00", value: 70 },
      { uuid: "x".repeat(65), type: "body_mass", date: T, time: "08:00", value: 70 },
      { uuid: "E-1", type: "body_mass", date: T, time: "8:00", value: 70 },
      { uuid: "E-2", type: "steps", date: T, time: "08:00", value: 70 },
      { uuid: "E-3", type: "body_mass", date: T, time: "08:00", value: 351 },
    ],
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.days.rejected, [
    { date: "2026-13-01", error: "日期格式不正确" },
    { date: addDays(T, 2), error: "日期不能晚于今天" },
    { date: addDays(T, -1), error: "steps不能大于 200000" },
  ]);
  assert.equal(r.body.days.upserted, 1, "tomorrow (profile tz) is still accepted");
  assert.deepEqual(r.body.samples.rejected.map((x: { error: string }) => x.error), ["uuid 不能为空", "uuid 不能为空", "时间格式不正确", "类型不正确", "体重不能大于 350"]);
});

// ---------------------------------------------------------------- 14. state

test("state: devices, ranges, cursors, counts and legacy sources", async () => {
  const empty = await api(base, await register(base, "hk_state_np")).get("/health/sync/state");
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body, {
    timezone: "Asia/Shanghai", server_today: T, devices: [],
    counts: { days: 0, body: 0, workouts: 0 }, legacy_sources: { apple_shortcut_days: 0, apple_export_days: 0 },
  });

  const { client } = await newUser(base, "hk_state");
  await client.post("/health/ingest", { date: addDays(T, -20), steps: 3000 });
  const D1 = addDays(T, -10);
  const D2 = addDays(T, -9);
  await sync(client, {
    device_id: "dev-A", device_name: "A 的 iPhone",
    days: [{ date: D1, steps: 1000 }, { date: D2, steps: 2000 }],
    samples: [weight("ST-1", D2, 70)],
    workouts: [{ uuid: "STW-1", date: D2, time: "10:00", activity_key: "yoga", duration_min: 30, in_device: false }],
    cursors: { samples: "anchor-1", workouts: "w".repeat(5000) },
  });
  // 第二批（更早的日期）扩展已同步范围；cursor 未给出时保留
  await sync(client, { device_id: "dev-A", device_name: undefined, days: [{ date: addDays(T, -15), steps: 500 }] });
  const s = await client.get("/health/sync/state");
  assert.equal(s.status, 200);
  assert.equal(s.body.timezone, "Asia/Shanghai");
  assert.equal(s.body.server_today, T);
  assert.equal(s.body.devices.length, 1);
  const dev = s.body.devices[0];
  assert.equal(dev.device_id, "dev-A");
  assert.equal(dev.device_name, "A 的 iPhone");
  assert.deepEqual(Object.keys(dev.kinds).sort(), ["days", "samples", "workouts"]);
  assert.equal(dev.kinds.days.min_date, addDays(T, -15));
  assert.equal(dev.kinds.days.max_date, D2);
  assert.match(dev.kinds.days.last_synced_at, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);
  assert.equal(dev.kinds.samples.cursor, "anchor-1");
  assert.equal(dev.kinds.samples.min_date, D2);
  assert.equal(dev.kinds.workouts.cursor, null, "cursor over 4096 chars is not stored");
  assert.deepEqual(s.body.counts, { days: 3, body: 1, workouts: 1 });
  assert.deepEqual(s.body.legacy_sources, { apple_shortcut_days: 1, apple_export_days: 0 });
});

// ---------------------------------------------------------------- 15. unlink

test("unlink: delete_data=false drops one device's state; true removes all HealthKit data and allows re-import", async () => {
  const { client, uid } = await newUser(base, "hk_unlink");
  const D1 = addDays(T, -6);
  const D2 = addDays(T, -5);
  const D3 = addDays(T, -4);
  await client.put(`/activity/${D3}`, { steps: 4321 }); // 用户自己的手动记录，与 HealthKit 无关
  await sync(client, {
    device_id: "dev-U",
    days: [{ date: D1, steps: 7000, sleep_hours: 7 }, { date: D2, steps: 8000, sleep_hours: 6 }],
    samples: [weight("UW-1", D1, 70), weight("UW-2", D2, 71)],
    workouts: [{ uuid: "UX-1", date: D2, time: "10:00", activity_key: "walk_brisk", duration_min: 30, in_device: false }],
  });
  await sync(client, { device_id: "dev-V", days: [] });
  await client.put(`/activity/${D2}`, { steps: 8000, sleep_hours: 5 }); // 改了睡眠
  const tombId = q<{ id: number }>("SELECT id FROM body_metrics WHERE user_id = ? AND external_id = 'UW-2'", uid)!.id;
  await client.del(`/body/${tombId}`);
  assert.ok(q("SELECT 1 AS x FROM health_tombstones WHERE user_id = ? AND external_id = 'UW-2'", uid));

  assert.deepEqual((await client.post("/health/sync/unlink", { delete_data: true })).body, { error: "device_id 不能为空" });

  const soft = await client.post("/health/sync/unlink", { device_id: "dev-U", delete_data: false });
  assert.deepEqual(soft.body, { ok: true, deleted: { body: 0, exercises: 0, days: 0 } });
  assert.deepEqual(qa<{ device_id: string }>("SELECT DISTINCT device_id FROM health_sync_state WHERE user_id = ?", uid).map((r) => r.device_id), ["dev-V"]);
  assert.equal(qa("SELECT 1 FROM body_metrics WHERE user_id = ? AND source = 'healthkit'", uid).length, 1);

  const hard = await client.post("/health/sync/unlink", { device_id: "dev-U", delete_data: true });
  assert.equal(hard.status, 200);
  assert.deepEqual(hard.body, { ok: true, deleted: { body: 1, exercises: 1, days: 2 } });
  assert.equal(qa("SELECT 1 FROM body_metrics WHERE user_id = ? AND source = 'healthkit'", uid).length, 0);
  assert.equal(qa("SELECT 1 FROM exercises WHERE user_id = ? AND source = 'healthkit'", uid).length, 0);
  assert.equal(qa("SELECT 1 FROM health_tombstones WHERE user_id = ?", uid).length, 0);
  assert.equal(qa("SELECT 1 FROM health_day_snapshots WHERE user_id = ?", uid).length, 0);
  assert.equal(qa("SELECT 1 FROM health_sync_state WHERE user_id = ?", uid).length, 0);
  assert.equal(q("SELECT 1 AS x FROM activity_days WHERE user_id = ? AND date = ?", uid, D1), undefined, "pure healthkit day removed");
  const d2 = q<{ steps: number | null; sleep_hours: number | null; source: string }>("SELECT steps, sleep_hours, source FROM activity_days WHERE user_id = ? AND date = ?", uid, D2)!;
  assert.deepEqual({ ...d2 }, { steps: null, sleep_hours: 5, source: "manual" }, "only fields matching the snapshot are nulled");
  assert.equal(q<{ steps: number }>("SELECT steps FROM activity_days WHERE user_id = ? AND date = ?", uid, D3)!.steps, 4321);
  assert.ok(q("SELECT 1 AS x FROM body_metrics WHERE user_id = ? AND source = 'profile'", uid), "non-HealthKit rows untouched");

  const re = await sync(client, { device_id: "dev-U", samples: [weight("UW-2", D2, 71)], days: [{ date: D1, steps: 7000 }] });
  assert.equal(re.body.samples.inserted, 1, "previously tombstoned sample re-imports after unlink");
  assert.equal(re.body.days.upserted, 1);
});

// ---------------------------------------------------------------- 16. web regression

test("web regression: existing endpoints keep their behaviour; rows only gain null keys", async () => {
  const { client, uid } = await newUser(base, "hk_web");
  const D = addDays(T, -1);
  const add = await client.post("/body", { date: D, time: "22:00", weight_kg: 70.5, waist_cm: 85, sbp: 125, dbp: 80, bp_treated: true, note: "睡前" });
  assert.equal(add.status, 200);
  assert.deepEqual(Object.keys(add.body), ["id"]);
  const rows = (await client.get(`/body?start=${D}&end=${D}`)).body as Record<string, unknown>[];
  assert.equal(rows.length, 1);
  assert.deepEqual(Object.keys(rows[0]), [
    "id", "user_id", "date", "time", "weight_kg", "body_fat_pct", "waist_cm", "note", "source", "created_at", "sbp", "dbp", "bp_treated",
    "external_id", "source_name",
  ]);
  assert.deepEqual(
    { ...rows[0], created_at: undefined },
    { id: add.body.id, user_id: uid, date: D, time: "22:00", weight_kg: 70.5, body_fat_pct: null, waist_cm: 85, note: "睡前", source: "manual", created_at: undefined, sbp: 125, dbp: 80, bp_treated: 1, external_id: null, source_name: null },
  );
  assert.deepEqual((await client.post("/body", {})).body, { error: "请至少填写一项" });

  const commit = await client.post("/activity/commit", {
    date: D, source: "manual", activity: { steps: 1234, sleep_hours: 7 }, body: { weight_kg: 71 },
    workouts: [{ activity_key: "walk_brisk", duration_min: 30, in_device: false }],
  });
  assert.deepEqual(commit.body, { ok: true, date: D, workouts: 1 });
  const act = (await client.get(`/activity?start=${D}&end=${D}`)).body;
  assert.equal(act.days[0].source, "manual");
  assert.equal(act.days[0].steps, 1234);
  const ex = act.exercises[0] as Record<string, unknown>;
  assert.equal(ex.source, "manual");
  for (const k of ["external_id", "source_name", "started_at", "ended_at", "hk_activity_type"]) assert.equal(ex[k], null, k);
  assert.deepEqual(Object.keys(ex).slice(0, 15), [
    "id", "user_id", "date", "time", "description", "activity_key", "met", "duration_min", "distance_km", "kcal", "in_device", "source", "created_at", "avg_hr", "device_kcal",
  ]);

  const D2 = addDays(T, -2);
  const ingest = await client.post("/health/ingest", { date: D2, steps: "8,532", active_energy: "512 kcal", weight_kg: 69, body_fat_pct: 0.2 });
  assert.equal(ingest.status, 200);
  assert.equal(ingest.body.ok, true);
  assert.equal(ingest.body.weight_kg, 69);
  assert.equal(ingest.body.activity.steps, 8532);
  const shortcut = q<{ source: string; body_fat_pct: number }>("SELECT source, body_fat_pct FROM body_metrics WHERE user_id = ? AND date = ?", uid, D2)!;
  assert.equal(shortcut.source, "apple_shortcut");
  assert.equal(shortcut.body_fat_pct, 20);
  assert.equal(q<{ source: string }>("SELECT source FROM activity_days WHERE user_id = ? AND date = ?", uid, D2)!.source, "apple_shortcut");

  const D3 = addDays(T, -3);
  const xml = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<HealthData>",
    ` <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="${D3} 08:30:00 +0800" endDate="${D3} 08:40:00 +0800" value="1200"/>`,
    ` <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="${D3} 09:30:00 +0800" endDate="${D3} 09:40:00 +0800" value="800"/>`,
    ` <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Scale" unit="kg" startDate="${D3} 07:10:00 +0800" endDate="${D3} 07:10:00 +0800" value="70.26"/>`,
    "</HealthData>",
  ].join("\n");
  const form = new FormData();
  form.append("file", new Blob([xml], { type: "text/xml" }), "export.xml");
  const imp = await client.post("/health/import", form);
  assert.equal(imp.status, 200, JSON.stringify(imp.body));
  assert.deepEqual(imp.body, { ok: true, records: 3, days: 1, weights: 1, since: addDays(T, -365) });
  assert.equal(q<{ steps: number; source: string }>("SELECT steps, source FROM activity_days WHERE user_id = ? AND date = ?", uid, D3)!.steps, 2000);
  assert.equal(q<{ weight_kg: number }>("SELECT weight_kg FROM body_metrics WHERE user_id = ? AND date = ? AND source = 'apple_export'", uid, D3)!.weight_kg, 70.3);

  // 未知路径：登录后仍是 404 接口不存在；未登录仍是 401（logRouter 的 requireAuth）
  assert.deepEqual((await client.get("/no-such-route")).body, { error: "接口不存在" });
  assert.equal((await api(base).get("/no-such-route")).status, 401);
});
