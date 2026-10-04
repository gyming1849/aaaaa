// 苹果健康（HealthKit）直连同步：批量、幂等上传每日汇总、身体数据样本、体能训练与删除。
// 手动修改优先：用户在网页 / App 改过的当天字段不会被同步覆盖（除非 overwrite_manual）；
// 网页删除的同步记录写入墓碑，不会被再次同步回来。

import { all, get, run, tx } from "../db/index.ts";
import { HttpError, bad, num, str } from "../lib/http.ts";
import { isDate, TIME_RE, todayIn, addDays } from "../lib/dates.ts";
import { getProfile, getWeights, weightOn, invalidateFrom } from "./userdata.ts";
import { ACTIVITY_MAP, netKcal, type Activity } from "../standards/met.ts";

// ---------------------------------------------------------------- 类型

/** 与 PUT /activity 相同的取值范围 */
const DAY_FIELDS = [
  ["steps", 0, 200000],
  ["active_kcal", 0, 10000],
  ["resting_kcal", 0, 5000],
  ["distance_km", 0, 500],
  ["exercise_min", 0, 1440],
  ["sleep_hours", 0, 24],
  ["stand_hours", 0, 24],
] as const;
type DayField = (typeof DAY_FIELDS)[number][0];
const DAY_KEYS: DayField[] = DAY_FIELDS.map((f) => f[0]);
type DayValues = Record<DayField, number | null>;

const LIMITS = { days: 400, samples: 2000, workouts: 500, deleted: 2000 } as const;
const STATE_KINDS = ["days", "samples", "workouts"] as const;
type StateKind = (typeof STATE_KINDS)[number];

export interface SyncRejected { date?: string | null; uuid?: string | null; error: string }
export interface SyncKeptManual { date: string; fields: string[] }
export interface SyncDaysResult { upserted: number; unchanged: number; kept_manual: SyncKeptManual[]; rejected: SyncRejected[] }
export interface SyncSamplesResult { inserted: number; updated: number; unchanged: number; skipped_tombstoned: number; rejected: SyncRejected[] }
export interface SyncPossibleDuplicate { uuid: string; exercise_id: number; description: string }
export interface SyncWorkoutsResult extends SyncSamplesResult { possible_duplicates: SyncPossibleDuplicate[] }
export interface SyncDeletedResult { body: number; exercises: number; not_found: number }

export interface SyncResult {
  ok: true;
  timezone: string;
  server_today: string;
  /** 请求带 timezone 且与档案时区不同 */
  timezone_mismatch: boolean;
  days?: SyncDaysResult;
  samples?: SyncSamplesResult;
  workouts?: SyncWorkoutsResult;
  deleted?: SyncDeletedResult;
  invalidated_from: string | null;
}

export interface SyncKindState { last_synced_at: string; min_date: string | null; max_date: string | null; cursor: string | null }
export interface SyncDeviceState { device_id: string; device_name: string | null; kinds: Record<string, SyncKindState> }
export interface HealthSyncStateResponse {
  timezone: string;
  server_today: string;
  devices: SyncDeviceState[];
  counts: { days: number; body: number; workouts: number };
  legacy_sources: { apple_shortcut_days: number; apple_export_days: number };
}

export interface UnlinkResult { ok: true; deleted: { body: number; exercises: number; days: number } }

interface ActivityRow extends DayValues { source: string }
type SnapshotRow = DayValues;
interface BodyRow {
  date: string; time: string; weight_kg: number | null; body_fat_pct: number | null; waist_cm: number | null;
  sbp: number | null; dbp: number | null; bp_treated: number;
}
interface ExerciseRow {
  date: string; time: string; description: string; activity_key: string | null; met: number; duration_min: number;
  distance_km: number | null; in_device: number; avg_hr: number | null; device_kcal: number | null;
  started_at: string | null; ended_at: string | null; hk_activity_type: number | null;
}

// ---------------------------------------------------------------- 小工具

const EPS = 1e-6;
const approxEq = (a: number | null | undefined, b: number | null | undefined) => a != null && b != null && Math.abs(a - b) < EPS;
/** 两个值是否相同（数字按 1e-6 容差比较，null 与 undefined 视为相同） */
function same(a: unknown, b: unknown): boolean {
  if (a == null || b == null) return a == null && b == null;
  if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) < EPS;
  return a === b;
}

const asObj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
/** 只认真正的 JSON 布尔值（以及 1），避免字符串 "false" 被当成 true */
const flag = (v: unknown) => v === true || v === 1;

/** 单项校验失败 → 进入 rejected；其他异常照常抛出 */
function rejection(e: unknown): string {
  if (e instanceof HttpError && e.status === 400) return e.message;
  throw e;
}

function validDate(v: unknown, maxDate: string): string {
  if (!isDate(v)) throw bad("日期格式不正确");
  if (v > maxDate) throw bad("日期不能晚于今天");
  return v;
}

function validTime(v: unknown): string {
  if (typeof v !== "string" || !TIME_RE.test(v)) throw bad("时间格式不正确");
  return v;
}

function validUuid(v: unknown): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s || s.length > 64) throw bad("uuid 不能为空");
  return s;
}

const rawString = (v: unknown): string | null => (typeof v === "string" ? v : null);

/** 可选数组段：缺省 → undefined；不是数组 → 400；超过上限 → 400 */
function section(v: unknown, max: number): unknown[] | undefined {
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v)) throw bad("请求格式不正确");
  if (v.length > max) throw bad("单次同步数据过多，请分批上传");
  return v;
}

class ChangeTracker {
  min: string | null = null;
  touch(date: string) {
    if (this.min === null || date < this.min) this.min = date;
  }
}

class DateRange {
  min: string | null = null;
  max: string | null = null;
  add(date: string) {
    if (this.min === null || date < this.min) this.min = date;
    if (this.max === null || date > this.max) this.max = date;
  }
}

const isTombstoned = (uid: number, uuid: string) => !!get("SELECT 1 FROM health_tombstones WHERE user_id = ? AND external_id = ?", uid, uuid);

/** 运动“家族”：activity_key 第一个下划线之前的部分（run、swim、walk、cycle…），没有下划线则为整个 key */
const family = (key: string) => (key.includes("_") ? key.slice(0, key.indexOf("_")) : key);

// ---------------------------------------------------------------- days

interface ParsedDay { date: string; values: Partial<DayValues>; clear: Set<DayField> }

function parseDay(raw: unknown, maxDate: string): ParsedDay {
  const item = asObj(raw);
  const date = validDate(item.date, maxDate);
  const values: Partial<DayValues> = {};
  for (const [k, min, max] of DAY_FIELDS) {
    const v = num(item[k], { min, max, optional: true, name: k });
    if (v != null) values[k] = v;
  }
  const clear = new Set<DayField>(
    (Array.isArray(item.clear) ? item.clear : []).filter((k): k is DayField => DAY_KEYS.includes(k as DayField)),
  );
  return { date, values, clear };
}

function syncDays(uid: number, list: unknown[], maxDate: string, overwrite: boolean, changes: ChangeTracker, range: DateRange): SyncDaysResult {
  const res: SyncDaysResult = { upserted: 0, unchanged: 0, kept_manual: [], rejected: [] };
  for (const raw of list) {
    let d: ParsedDay;
    try {
      d = parseDay(raw, maxDate);
    } catch (e) {
      res.rejected.push({ date: rawString(asObj(raw).date), error: rejection(e) });
      continue;
    }
    range.add(d.date);
    const row = get<ActivityRow>("SELECT * FROM activity_days WHERE user_id = ? AND date = ?", uid, d.date);
    const snap = get<SnapshotRow>("SELECT * FROM health_day_snapshots WHERE user_id = ? AND date = ?", uid, d.date);
    const current = Object.fromEntries(DAY_KEYS.map((k) => [k, row?.[k] ?? null])) as DayValues;
    const merged: DayValues = { ...current };
    const nextSnap = Object.fromEntries(DAY_KEYS.map((k) => [k, snap?.[k] ?? null])) as DayValues;
    const kept: DayField[] = [];
    for (const k of DAY_KEYS) {
      let v: number | null;
      if (d.values[k] != null) v = d.values[k]!;
      else if (d.clear.has(k)) v = null;
      else continue;
      nextSnap[k] = v;
      if (!row || row.source !== "manual" || overwrite) {
        merged[k] = v;
        continue;
      }
      // 手动记录：只有用户没改过 HealthKit 上次写入的值（或原本为空）时才更新
      const s = snap?.[k] ?? null;
      const untouched = s != null ? approxEq(current[k], s) : current[k] == null;
      if (untouched) merged[k] = v;
      else if (!same(current[k], v)) kept.push(k);
    }
    if (DAY_KEYS.some((k) => !same(current[k], merged[k]))) {
      run(
        `INSERT INTO activity_days (user_id, date, steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours, stand_hours, source, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
         ON CONFLICT(user_id, date) DO UPDATE SET steps = excluded.steps, active_kcal = excluded.active_kcal, resting_kcal = excluded.resting_kcal,
           distance_km = excluded.distance_km, exercise_min = excluded.exercise_min, sleep_hours = excluded.sleep_hours, stand_hours = excluded.stand_hours,
           source = excluded.source, updated_at = excluded.updated_at`,
        uid, d.date, merged.steps, merged.active_kcal, merged.resting_kcal, merged.distance_km, merged.exercise_min, merged.sleep_hours, merged.stand_hours,
        row?.source === "manual" ? "manual" : "healthkit",
      );
      res.upserted++;
      changes.touch(d.date);
    } else {
      res.unchanged++;
    }
    run(
      `INSERT INTO health_day_snapshots (user_id, date, steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours, stand_hours, synced_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
       ON CONFLICT(user_id, date) DO UPDATE SET steps = excluded.steps, active_kcal = excluded.active_kcal, resting_kcal = excluded.resting_kcal,
         distance_km = excluded.distance_km, exercise_min = excluded.exercise_min, sleep_hours = excluded.sleep_hours, stand_hours = excluded.stand_hours,
         synced_at = excluded.synced_at`,
      uid, d.date, nextSnap.steps, nextSnap.active_kcal, nextSnap.resting_kcal, nextSnap.distance_km, nextSnap.exercise_min, nextSnap.sleep_hours,
      nextSnap.stand_hours,
    );
    if (kept.length) res.kept_manual.push({ date: d.date, fields: kept });
  }
  return res;
}

// ---------------------------------------------------------------- samples

interface ParsedSample {
  uuid: string; date: string; time: string; source_name: string | null;
  weight_kg: number | null; body_fat_pct: number | null; waist_cm: number | null; sbp: number | null; dbp: number | null; bp_treated: number;
}

function parseSample(raw: unknown, maxDate: string): ParsedSample {
  const item = asObj(raw);
  const s: ParsedSample = {
    uuid: validUuid(item.uuid),
    date: validDate(item.date, maxDate),
    time: validTime(item.time),
    source_name: str(item.source_name, { optional: true, max: 60 }) || null,
    weight_kg: null, body_fat_pct: null, waist_cm: null, sbp: null, dbp: null, bp_treated: 0,
  };
  switch (item.type) {
    case "body_mass":
      s.weight_kg = num(item.value, { min: 20, max: 350, name: "体重" });
      break;
    case "body_fat":
      s.body_fat_pct = num(item.value, { min: 2, max: 70, name: "体脂率" });
      break;
    case "waist":
      s.waist_cm = num(item.value, { min: 30, max: 250, name: "腰围" });
      break;
    case "blood_pressure":
      s.sbp = num(item.sbp, { min: 60, max: 260, name: "收缩压" });
      s.dbp = num(item.dbp, { min: 30, max: 160, name: "舒张压" });
      s.bp_treated = flag(item.bp_treated) ? 1 : 0;
      break;
    default:
      throw bad("类型不正确");
  }
  return s;
}

const BODY_COMPARE = ["date", "time", "weight_kg", "body_fat_pct", "waist_cm", "sbp", "dbp", "bp_treated"] as const;

function syncSamples(uid: number, list: unknown[], maxDate: string, changes: ChangeTracker, range: DateRange): SyncSamplesResult {
  const res: SyncSamplesResult = { inserted: 0, updated: 0, unchanged: 0, skipped_tombstoned: 0, rejected: [] };
  for (const raw of list) {
    let s: ParsedSample;
    try {
      s = parseSample(raw, maxDate);
    } catch (e) {
      res.rejected.push({ uuid: rawString(asObj(raw).uuid), error: rejection(e) });
      continue;
    }
    range.add(s.date);
    if (isTombstoned(uid, s.uuid)) {
      res.skipped_tombstoned++;
      continue;
    }
    const old = get<BodyRow>("SELECT * FROM body_metrics WHERE user_id = ? AND external_id = ?", uid, s.uuid);
    if (old && BODY_COMPARE.every((k) => same(old[k], s[k]))) {
      res.unchanged++;
      continue;
    }
    run(
      `INSERT INTO body_metrics (user_id, date, time, weight_kg, body_fat_pct, waist_cm, sbp, dbp, bp_treated, note, source, external_id, source_name)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'healthkit', ?, ?)
       ON CONFLICT(user_id, external_id) WHERE external_id IS NOT NULL DO UPDATE SET
         date = excluded.date, time = excluded.time, weight_kg = excluded.weight_kg, body_fat_pct = excluded.body_fat_pct, waist_cm = excluded.waist_cm,
         sbp = excluded.sbp, dbp = excluded.dbp, bp_treated = excluded.bp_treated, source = excluded.source, source_name = excluded.source_name`,
      uid, s.date, s.time, s.weight_kg, s.body_fat_pct, s.waist_cm, s.sbp, s.dbp, s.bp_treated, s.uuid, s.source_name,
    );
    if (old) {
      res.updated++;
      changes.touch(old.date);
    } else {
      res.inserted++;
    }
    changes.touch(s.date);
  }
  return res;
}

// ---------------------------------------------------------------- workouts

interface ParsedWorkout {
  uuid: string; date: string; time: string; act: Activity; met: number; duration_min: number; distance_km: number | null;
  avg_hr: number | null; device_kcal: number | null; description: string; in_device: number;
  started_at: string | null; ended_at: string | null; hk_activity_type: number | null; source_name: string | null;
}

function parseWorkout(raw: unknown, maxDate: string): ParsedWorkout {
  const item = asObj(raw);
  const uuid = validUuid(item.uuid);
  const date = validDate(item.date, maxDate);
  const time = validTime(item.time);
  const key = String(item.activity_key);
  const act = Object.hasOwn(ACTIVITY_MAP, key) ? ACTIVITY_MAP[key] : ACTIVITY_MAP.other_moderate;
  return {
    uuid, date, time, act,
    duration_min: num(item.duration_min, { min: 1, max: 1440, name: "时长" })!,
    met: num(item.met, { min: 1, max: 25, optional: true, name: "MET" }) ?? act.met,
    distance_km: num(item.distance_km, { min: 0, max: 1000, optional: true, name: "距离" }) || null,
    avg_hr: num(item.avg_hr, { min: 30, max: 230, optional: true, name: "平均心率" }),
    device_kcal: num(item.device_kcal, { min: 0, max: 10000, optional: true, name: "设备消耗" }),
    description: str(item.description, { optional: true, max: 80 }) || act.zh,
    in_device: flag(item.in_device) ? 1 : 0,
    started_at: str(item.start, { optional: true, max: 40 }) || null,
    ended_at: str(item.end, { optional: true, max: 40 }) || null,
    hk_activity_type: Number.isInteger(item.hk_activity_type) ? (item.hk_activity_type as number) : null,
    source_name: str(item.source_name, { optional: true, max: 60 }) || null,
  };
}

function syncWorkouts(
  uid: number, list: unknown[], maxDate: string, fallbackWeight: number, changes: ChangeTracker, range: DateRange,
): SyncWorkoutsResult {
  const res: SyncWorkoutsResult = { inserted: 0, updated: 0, unchanged: 0, skipped_tombstoned: 0, rejected: [], possible_duplicates: [] };
  // 与 POST /exercises 相同：当天或之前最近一次称重（含本批刚同步的体重），否则用建档体重
  const weights = getWeights(uid, "9999-12-31");
  for (const raw of list) {
    let w: ParsedWorkout;
    try {
      w = parseWorkout(raw, maxDate);
    } catch (e) {
      res.rejected.push({ uuid: rawString(asObj(raw).uuid), error: rejection(e) });
      continue;
    }
    range.add(w.date);
    if (isTombstoned(uid, w.uuid)) {
      res.skipped_tombstoned++;
      continue;
    }
    const old = get<ExerciseRow>("SELECT * FROM exercises WHERE user_id = ? AND external_id = ?", uid, w.uuid);
    // in_device 只在插入时取客户端的值：已有的行保留现值（用户可能在网页上用 PATCH /exercises/{id} 手动切换过，
    // 重新同步 / 重试不能把它改回去）
    const inDevice = old ? old.in_device : w.in_device;
    const next = {
      date: w.date, time: w.time, description: w.description, activity_key: w.act.key, met: w.met, duration_min: w.duration_min,
      distance_km: w.distance_km, in_device: inDevice, avg_hr: w.avg_hr, device_kcal: w.device_kcal,
      started_at: w.started_at, ended_at: w.ended_at, hk_activity_type: w.hk_activity_type,
    };
    // kcal 由服务器按体重推算（插入时固定）；输入没有变化就视为未变化
    if (old && (Object.keys(next) as (keyof typeof next)[]).every((k) => same(old[k], next[k]))) {
      res.unchanged++;
      continue;
    }
    const kcal = Math.round(netKcal(w.met, weightOn(weights, w.date, fallbackWeight), w.duration_min));
    run(
      `INSERT INTO exercises (user_id, date, time, description, activity_key, met, duration_min, distance_km, kcal, in_device, avg_hr, device_kcal, source,
         external_id, source_name, started_at, ended_at, hk_activity_type)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'healthkit', ?, ?, ?, ?, ?)
       ON CONFLICT(user_id, external_id) WHERE external_id IS NOT NULL DO UPDATE SET
         date = excluded.date, time = excluded.time, description = excluded.description, activity_key = excluded.activity_key, met = excluded.met,
         duration_min = excluded.duration_min, distance_km = excluded.distance_km, kcal = excluded.kcal,
         avg_hr = excluded.avg_hr, device_kcal = excluded.device_kcal, source = excluded.source, source_name = excluded.source_name,
         started_at = excluded.started_at, ended_at = excluded.ended_at, hk_activity_type = excluded.hk_activity_type`,
      uid, w.date, w.time, w.description, w.act.key, w.met, w.duration_min, w.distance_km, kcal, inDevice, w.avg_hr, w.device_kcal,
      w.uuid, w.source_name, w.started_at, w.ended_at, w.hk_activity_type,
    );
    changes.touch(w.date);
    if (old) {
      res.updated++;
      changes.touch(old.date);
      continue;
    }
    res.inserted++;
    // 可能与手动 / AI 记录重复：同一天、同一运动家族、时长相差 ≤20%。只提示，不自动删除
    const fam = family(w.act.key);
    const candidates = all<{ id: number; description: string; activity_key: string | null; duration_min: number }>(
      "SELECT id, description, activity_key, duration_min FROM exercises WHERE user_id = ? AND date = ? AND source != 'healthkit' ORDER BY time, id",
      uid, w.date,
    );
    for (const c of candidates) {
      if (c.activity_key && family(c.activity_key) === fam && Math.abs(c.duration_min - w.duration_min) <= 0.2 * w.duration_min) {
        res.possible_duplicates.push({ uuid: w.uuid, exercise_id: c.id, description: c.description });
      }
    }
  }
  return res;
}

// ---------------------------------------------------------------- deleted

function syncDeleted(uid: number, list: unknown[], changes: ChangeTracker): SyncDeletedResult {
  const res: SyncDeletedResult = { body: 0, exercises: 0, not_found: 0 };
  const key = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  const ids = [...new Set(list.map(key).filter((s) => s && s.length <= 64))];
  const matched = new Set<string>();
  for (let i = 0; i < ids.length; i += 500) {
    const chunk = ids.slice(i, i + 500);
    const ph = chunk.map(() => "?").join(", ");
    for (const table of ["body_metrics", "exercises"] as const) {
      const rows = all<{ date: string; external_id: string }>(
        `SELECT date, external_id FROM ${table} WHERE user_id = ? AND external_id IN (${ph})`, uid, ...chunk,
      );
      if (!rows.length) continue;
      // 触发器 trg_body_tomb / trg_ex_tomb 会写入墓碑
      run(`DELETE FROM ${table} WHERE user_id = ? AND external_id IN (${ph})`, uid, ...chunk);
      if (table === "body_metrics") res.body += rows.length;
      else res.exercises += rows.length;
      for (const r of rows) {
        matched.add(r.external_id);
        changes.touch(r.date);
      }
    }
  }
  res.not_found = list.filter((v) => !matched.has(key(v))).length;
  return res;
}

// ---------------------------------------------------------------- state

function upsertState(uid: number, deviceId: string, deviceName: string | null, kind: StateKind, range: DateRange, cursor: string | undefined) {
  const old = get<{ device_name: string | null; min_date: string | null; max_date: string | null; cursor: string | null }>(
    "SELECT device_name, min_date, max_date, cursor FROM health_sync_state WHERE user_id = ? AND device_id = ? AND kind = ?",
    uid, deviceId, kind,
  );
  // 已同步的日期范围：与已有范围取并集（本批没有有效数据时保持不变）
  const min = [old?.min_date, range.min].filter((d): d is string => !!d).sort()[0] ?? null;
  const max = [old?.max_date, range.max].filter((d): d is string => !!d).sort().pop() ?? null;
  run(
    `INSERT INTO health_sync_state (user_id, device_id, device_name, kind, last_synced_at, min_date, max_date, cursor)
     VALUES (?, ?, ?, ?, datetime('now'), ?, ?, ?)
     ON CONFLICT(user_id, device_id, kind) DO UPDATE SET device_name = excluded.device_name, last_synced_at = excluded.last_synced_at,
       min_date = excluded.min_date, max_date = excluded.max_date, cursor = excluded.cursor`,
    uid, deviceId, deviceName ?? old?.device_name ?? null, kind, min, max, cursor ?? old?.cursor ?? null,
  );
}

// ---------------------------------------------------------------- 入口

/** POST /health/sync。只有整个请求有问题时才抛 400；单项错误进入对应段的 rejected */
export function applyHealthSync(uid: number, body: unknown): SyncResult {
  const p = getProfile(uid);
  if (!p) throw bad("请先完善个人档案");
  if (!body || typeof body !== "object" || Array.isArray(body)) throw bad("请求格式不正确");
  const b = body as Record<string, unknown>;
  const deviceId = typeof b.device_id === "string" ? b.device_id.trim().slice(0, 64) : "";
  if (!deviceId) throw bad("device_id 不能为空");
  const lists = {
    days: section(b.days, LIMITS.days),
    samples: section(b.samples, LIMITS.samples),
    workouts: section(b.workouts, LIMITS.workouts),
    deleted: section(b.deleted, LIMITS.deleted),
  };
  const deviceName = str(b.device_name, { optional: true, max: 60 }) || null;
  const cursors = asObj(b.cursors);
  const cursorOf = (kind: StateKind) => {
    const c = cursors[kind];
    return typeof c === "string" && c.length <= 4096 ? c : undefined;
  };
  const overwrite = b.overwrite_manual === true;
  const clientTz = typeof b.timezone === "string" ? b.timezone.trim() : "";
  const tz = p.timezone;
  const today = todayIn(tz);
  const maxDate = addDays(today, 1);

  const changes = new ChangeTracker();
  const ranges: Record<StateKind, DateRange> = { days: new DateRange(), samples: new DateRange(), workouts: new DateRange() };
  const out: Pick<SyncResult, "days" | "samples" | "workouts" | "deleted"> = {};
  tx(() => {
    if (lists.days) out.days = syncDays(uid, lists.days, maxDate, overwrite, changes, ranges.days);
    if (lists.samples) out.samples = syncSamples(uid, lists.samples, maxDate, changes, ranges.samples);
    if (lists.workouts) out.workouts = syncWorkouts(uid, lists.workouts, maxDate, p.weight_kg, changes, ranges.workouts);
    if (lists.deleted) out.deleted = syncDeleted(uid, lists.deleted, changes);
    for (const kind of STATE_KINDS) {
      if (lists[kind]) upsertState(uid, deviceId, deviceName, kind, ranges[kind], cursorOf(kind));
    }
  });
  if (changes.min) invalidateFrom(uid, changes.min);

  return {
    ok: true,
    timezone: tz,
    server_today: today,
    timezone_mismatch: !!clientTz && clientTz !== tz,
    ...out,
    invalidated_from: changes.min,
  };
}

/** GET /health/sync/state */
export function healthSyncState(uid: number): HealthSyncStateResponse {
  const tz = getProfile(uid)?.timezone ?? "Asia/Shanghai";
  const rows = all<{ device_id: string; device_name: string | null; kind: string } & SyncKindState>(
    `SELECT device_id, device_name, kind, last_synced_at, min_date, max_date, cursor FROM health_sync_state
     WHERE user_id = ? ORDER BY last_synced_at DESC, device_id, kind`,
    uid,
  );
  const devices = new Map<string, SyncDeviceState>();
  for (const r of rows) {
    let d = devices.get(r.device_id);
    if (!d) {
      d = { device_id: r.device_id, device_name: r.device_name, kinds: {} };
      devices.set(r.device_id, d);
    }
    d.device_name ??= r.device_name;
    d.kinds[r.kind] = { last_synced_at: r.last_synced_at, min_date: r.min_date, max_date: r.max_date, cursor: r.cursor };
  }
  const count = (sql: string) => get<{ n: number }>(sql, uid)?.n ?? 0;
  const legacy = all<{ source: string; n: number }>(
    "SELECT source, COUNT(*) AS n FROM activity_days WHERE user_id = ? AND source IN ('apple_shortcut', 'apple_export') GROUP BY source",
    uid,
  );
  return {
    timezone: tz,
    server_today: todayIn(tz),
    devices: [...devices.values()],
    counts: {
      days: count("SELECT COUNT(*) AS n FROM health_day_snapshots WHERE user_id = ?"),
      body: count("SELECT COUNT(*) AS n FROM body_metrics WHERE user_id = ? AND source = 'healthkit'"),
      workouts: count("SELECT COUNT(*) AS n FROM exercises WHERE user_id = ? AND source = 'healthkit'"),
    },
    legacy_sources: {
      apple_shortcut_days: legacy.find((r) => r.source === "apple_shortcut")?.n ?? 0,
      apple_export_days: legacy.find((r) => r.source === "apple_export")?.n ?? 0,
    },
  };
}

/**
 * POST /health/sync/unlink。
 * delete_data=false：只删除该设备的同步状态。
 * delete_data=true：删除该用户全部 HealthKit 数据（不分设备）：同步的身体记录与运动、墓碑、
 * 与快照一致的每日字段（全部为空且来源为 healthkit 的行整行删除）、快照与全部同步状态。
 */
export function unlinkHealthDevice(uid: number, deviceId: string, deleteData: boolean): UnlinkResult {
  const id = deviceId.trim().slice(0, 64);
  if (!id) throw bad("device_id 不能为空");
  if (!deleteData) {
    run("DELETE FROM health_sync_state WHERE user_id = ? AND device_id = ?", uid, id);
    return { ok: true, deleted: { body: 0, exercises: 0, days: 0 } };
  }
  const changes = new ChangeTracker();
  const deleted = tx(() => {
    const minOf = (table: string) => get<{ d: string | null }>(`SELECT MIN(date) AS d FROM ${table} WHERE user_id = ? AND source = 'healthkit'`, uid)?.d;
    for (const table of ["body_metrics", "exercises"]) {
      const d = minOf(table);
      if (d) changes.touch(d);
    }
    const body = Number(run("DELETE FROM body_metrics WHERE user_id = ? AND source = 'healthkit'", uid).changes);
    const exercises = Number(run("DELETE FROM exercises WHERE user_id = ? AND source = 'healthkit'", uid).changes);
    // 上面的删除由触发器写了墓碑；断开后应允许重新导入，因此清空墓碑
    run("DELETE FROM health_tombstones WHERE user_id = ?", uid);
    let days = 0;
    const snaps = all<SnapshotRow & { date: string }>("SELECT * FROM health_day_snapshots WHERE user_id = ?", uid);
    for (const snap of snaps) {
      const row = get<ActivityRow>("SELECT * FROM activity_days WHERE user_id = ? AND date = ?", uid, snap.date);
      if (!row) continue;
      const next = Object.fromEntries(DAY_KEYS.map((k) => [k, approxEq(row[k], snap[k]) ? null : (row[k] ?? null)])) as DayValues;
      if (DAY_KEYS.every((k) => same(row[k], next[k]))) continue;
      if (row.source === "healthkit" && DAY_KEYS.every((k) => next[k] == null)) {
        run("DELETE FROM activity_days WHERE user_id = ? AND date = ?", uid, snap.date);
      } else {
        run(
          `UPDATE activity_days SET steps = ?, active_kcal = ?, resting_kcal = ?, distance_km = ?, exercise_min = ?, sleep_hours = ?, stand_hours = ?,
             updated_at = datetime('now') WHERE user_id = ? AND date = ?`,
          next.steps, next.active_kcal, next.resting_kcal, next.distance_km, next.exercise_min, next.sleep_hours, next.stand_hours, uid, snap.date,
        );
      }
      days++;
      changes.touch(snap.date);
    }
    run("DELETE FROM health_day_snapshots WHERE user_id = ?", uid);
    run("DELETE FROM health_sync_state WHERE user_id = ?", uid);
    return { body, exercises, days };
  });
  if (changes.min) invalidateFrom(uid, changes.min);
  return { ok: true, deleted };
}
