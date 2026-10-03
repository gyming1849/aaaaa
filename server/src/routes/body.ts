// 体重、步数/活动能量、运动、苹果健康导入

import { Router } from "express";
import multer from "multer";
import fs from "node:fs";
import os from "node:os";
import readline from "node:readline";
import { spawn, spawnSync } from "node:child_process";
import { all, get, run, tx } from "../db/index.ts";
import { requireAuth, requireAuthOrToken } from "../auth.ts";
import { ah, bad, notFound, num, str } from "../lib/http.ts";
import { isDate, TIME_RE, todayIn, nowTimeIn, addDays } from "../lib/dates.ts";
import { getProfile, invalidateFrom, invalidateDay, getWeights, weightOn, previewDay, itemFromRow } from "../services/userdata.ts";
import { enqueue } from "../ai/jobs.ts";
import { recognizeActivity } from "../ai/service.ts";
import { sanitizeVector, NUTRIENT_KEYS, FOOD_GROUP_KEYS } from "../standards/nutrients.ts";
import { HAZARD_MAP } from "../standards/hazards.ts";
import { ACTIVITY_MAP, netKcal } from "../standards/met.ts";

export const bodyRouter = Router();

// ---------------------------------------------------------------- 体重

bodyRouter.get(
  "/body",
  requireAuth,
  ah((req) => {
    const start = isDate(req.query.start) ? (req.query.start as string) : "1900-01-01";
    const end = isDate(req.query.end) ? (req.query.end as string) : "2999-12-31";
    return all("SELECT * FROM body_metrics WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date DESC, time DESC, id DESC", req.user!.id, start, end);
  }),
);

bodyRouter.post(
  "/body",
  requireAuth,
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    const date = isDate(req.body.date) ? req.body.date : todayIn(p?.timezone ?? "Asia/Shanghai");
    const time = TIME_RE.test(req.body.time) ? req.body.time : nowTimeIn(p?.timezone ?? "Asia/Shanghai");
    const weight = num(req.body.weight_kg, { min: 20, max: 350, optional: true, name: "体重" });
    const fat = num(req.body.body_fat_pct, { min: 2, max: 70, optional: true, name: "体脂率" });
    const waist = num(req.body.waist_cm, { min: 30, max: 250, optional: true, name: "腰围" });
    const sbp = num(req.body.sbp, { min: 60, max: 260, optional: true, name: "收缩压" });
    const dbp = num(req.body.dbp, { min: 30, max: 160, optional: true, name: "舒张压" });
    if (weight == null && fat == null && waist == null && sbp == null) throw bad("请至少填写一项");
    const r = run(
      "INSERT INTO body_metrics (user_id, date, time, weight_kg, body_fat_pct, waist_cm, sbp, dbp, bp_treated, note, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual')",
      uid, date, time, weight, fat, waist, sbp, dbp, req.body.bp_treated ? 1 : 0, str(req.body.note, { optional: true, max: 200 }),
    );
    invalidateFrom(uid, date);
    return { id: Number(r.lastInsertRowid) };
  }),
);

bodyRouter.delete(
  "/body/:id",
  requireAuth,
  ah((req) => {
    const row = get<{ date: string }>("SELECT date FROM body_metrics WHERE id = ? AND user_id = ?", Number(req.params.id), req.user!.id);
    if (!row) throw notFound();
    run("DELETE FROM body_metrics WHERE id = ?", Number(req.params.id));
    invalidateFrom(req.user!.id, row.date);
    return { ok: true };
  }),
);

// ---------------------------------------------------------------- 化验指标（用于 AHA Life's Essential 8：血脂、血糖）

bodyRouter.get(
  "/labs",
  requireAuth,
  ah((req) => all("SELECT * FROM lab_results WHERE user_id = ? ORDER BY date DESC, id DESC", req.user!.id)),
);

bodyRouter.post(
  "/labs",
  requireAuth,
  ah((req) => {
    const uid = req.user!.id;
    const b = req.body ?? {};
    const p = getProfile(uid);
    const date = isDate(b.date) ? b.date : todayIn(p?.timezone ?? "Asia/Shanghai");
    const total = num(b.total_chol, { min: 50, max: 600, optional: true, name: "总胆固醇" });
    const hdl = num(b.hdl, { min: 5, max: 200, optional: true, name: "HDL" });
    let nonHdl = num(b.non_hdl, { min: 20, max: 600, optional: true, name: "非 HDL 胆固醇" });
    if (nonHdl == null && total != null && hdl != null) nonHdl = total - hdl;
    const glucose = num(b.fasting_glucose, { min: 30, max: 600, optional: true, name: "空腹血糖" });
    const a1c = num(b.hba1c, { min: 3, max: 20, optional: true, name: "糖化血红蛋白" });
    if (total == null && nonHdl == null && glucose == null && a1c == null) throw bad("请至少填写一项");
    const r = run(
      `INSERT INTO lab_results (user_id, date, total_chol, hdl, non_hdl, ldl, lipid_treated, fasting_glucose, hba1c, diabetes, note)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      uid, date, total, hdl, nonHdl, num(b.ldl, { min: 10, max: 500, optional: true, name: "LDL" }), b.lipid_treated ? 1 : 0,
      glucose, a1c, b.diabetes ? 1 : 0, str(b.note, { optional: true, max: 200 }),
    );
    invalidateFrom(uid, date);
    return { id: Number(r.lastInsertRowid) };
  }),
);

bodyRouter.delete(
  "/labs/:id",
  requireAuth,
  ah((req) => {
    run("DELETE FROM lab_results WHERE id = ? AND user_id = ?", Number(req.params.id), req.user!.id);
    return { ok: true };
  }),
);

// ---------------------------------------------------------------- 每日活动（步数/活动能量）

function upsertActivity(uid: number, date: string, v: Record<string, number | null>, source: string) {
  run(
    `INSERT INTO activity_days (user_id, date, steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours, stand_hours, source, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
     ON CONFLICT(user_id, date) DO UPDATE SET
       steps = COALESCE(excluded.steps, steps), active_kcal = COALESCE(excluded.active_kcal, active_kcal),
       resting_kcal = COALESCE(excluded.resting_kcal, resting_kcal), distance_km = COALESCE(excluded.distance_km, distance_km),
       exercise_min = COALESCE(excluded.exercise_min, exercise_min), sleep_hours = COALESCE(excluded.sleep_hours, sleep_hours),
       stand_hours = COALESCE(excluded.stand_hours, stand_hours), source = excluded.source, updated_at = excluded.updated_at`,
    uid, date, v.steps ?? null, v.active_kcal ?? null, v.resting_kcal ?? null, v.distance_km ?? null, v.exercise_min ?? null,
    v.sleep_hours ?? null, v.stand_hours ?? null, source,
  );
  invalidateDay(uid, date);
}

bodyRouter.get(
  "/activity",
  requireAuth,
  ah((req) => {
    const start = isDate(req.query.start) ? (req.query.start as string) : "1900-01-01";
    const end = isDate(req.query.end) ? (req.query.end as string) : "2999-12-31";
    const uid = req.user!.id;
    return {
      days: all("SELECT * FROM activity_days WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date DESC", uid, start, end),
      exercises: all("SELECT * FROM exercises WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date DESC, time DESC", uid, start, end),
    };
  }),
);

bodyRouter.put(
  "/activity/:date",
  requireAuth,
  ah((req) => {
    const date = String(req.params.date);
    if (!isDate(date)) throw bad("日期格式不正确");
    const b = req.body ?? {};
    // 手动编辑：允许清空字段，因此直接覆盖
    run(
      `INSERT INTO activity_days (user_id, date, steps, active_kcal, resting_kcal, distance_km, exercise_min, sleep_hours, stand_hours, source, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual', datetime('now'))
       ON CONFLICT(user_id, date) DO UPDATE SET steps=excluded.steps, active_kcal=excluded.active_kcal, resting_kcal=excluded.resting_kcal,
       distance_km=excluded.distance_km, exercise_min=excluded.exercise_min, sleep_hours=excluded.sleep_hours, stand_hours=excluded.stand_hours,
       source='manual', updated_at=excluded.updated_at`,
      req.user!.id, date,
      num(b.steps, { min: 0, max: 200000, optional: true, name: "步数" }),
      num(b.active_kcal, { min: 0, max: 10000, optional: true, name: "活动能量" }),
      num(b.resting_kcal, { min: 0, max: 5000, optional: true, name: "静息能量" }),
      num(b.distance_km, { min: 0, max: 500, optional: true, name: "距离" }),
      num(b.exercise_min, { min: 0, max: 1440, optional: true, name: "锻炼分钟" }),
      num(b.sleep_hours, { min: 0, max: 24, optional: true, name: "睡眠时长" }),
      num(b.stand_hours, { min: 0, max: 24, optional: true, name: "站立小时" }),
    );
    invalidateDay(req.user!.id, date);
    return { ok: true };
  }),
);

// ---------------------------------------------------------------- 运动记录

bodyRouter.post(
  "/exercises",
  requireAuth,
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    if (!p) throw bad("请先完善个人档案");
    const b = req.body ?? {};
    const date = isDate(b.date) ? b.date : todayIn(p.timezone);
    const act = ACTIVITY_MAP[String(b.activity_key)] ?? null;
    const met = num(b.met ?? act?.met, { min: 1, max: 25, name: "MET" })!;
    const duration = num(b.duration_min, { min: 1, max: 1440, name: "时长" })!;
    const weight = weightOn(getWeights(uid, date), date, p.weight_kg);
    const kcal = Math.round(netKcal(met, weight, duration));
    const r = run(
      `INSERT INTO exercises (user_id, date, time, description, activity_key, met, duration_min, distance_km, kcal, in_device, source)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      uid, date, TIME_RE.test(b.time) ? b.time : nowTimeIn(p.timezone), str(b.description, { max: 80, optional: true }) || act?.zh || "运动",
      act?.key ?? null, met, duration, num(b.distance_km, { min: 0, max: 1000, optional: true }), kcal, b.in_device ? 1 : 0, b.source === "ai" ? "ai" : "manual",
    );
    invalidateDay(uid, date);
    return { id: Number(r.lastInsertRowid), kcal };
  }),
);

bodyRouter.patch(
  "/exercises/:id",
  requireAuth,
  ah((req) => {
    const row = get<{ date: string }>("SELECT date FROM exercises WHERE id = ? AND user_id = ?", Number(req.params.id), req.user!.id);
    if (!row) throw notFound();
    run("UPDATE exercises SET in_device = ? WHERE id = ?", req.body.in_device ? 1 : 0, Number(req.params.id));
    invalidateDay(req.user!.id, row.date);
    return { ok: true };
  }),
);

bodyRouter.delete(
  "/exercises/:id",
  requireAuth,
  ah((req) => {
    const row = get<{ date: string }>("SELECT date FROM exercises WHERE id = ? AND user_id = ?", Number(req.params.id), req.user!.id);
    if (!row) throw notFound();
    run("DELETE FROM exercises WHERE id = ?", Number(req.params.id));
    invalidateDay(req.user!.id, row.date);
    return { ok: true };
  }),
);

// ---------------------------------------------------------------- AI 识别身体与活动（文字 / 截图）→ 预览 → 合并

bodyRouter.post(
  "/ai/activity",
  requireAuth,
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    if (!p) throw bad("请先完善个人档案");
    const text = str(req.body.text, { optional: true, max: 1000 });
    const photos = Array.isArray(req.body.photos) ? req.body.photos : [];
    if (!text && !photos.length) throw bad("请描述今天的活动，或上传健康 App / 手表截图");
    const today = todayIn(p.timezone);
    const date = isDate(req.body.date) ? req.body.date : today;
    const weight = weightOn(getWeights(uid, date), date, p.weight_kg);
    const id = enqueue(uid, "activity", { text, date, photos }, () => recognizeActivity(uid, { date, today, text, photos }, weight));
    return { job_id: id };
  }),
);

interface WorkoutIn { description?: string; activity_key?: string; met?: number; duration_min?: number; distance_km?: number; in_device?: boolean; avg_hr?: number; device_kcal?: number }

function cleanWorkouts(list: unknown, weight: number) {
  return (Array.isArray(list) ? (list as WorkoutIn[]) : []).slice(0, 20).map((w) => {
    const act = ACTIVITY_MAP[String(w.activity_key)] ?? ACTIVITY_MAP.other_moderate;
    const met = num(w.met ?? act.met, { min: 1, max: 25, name: "MET" })!;
    const duration = num(w.duration_min, { min: 1, max: 1440, name: "时长" })!;
    return {
      description: String(w.description ?? act.zh).slice(0, 80) || act.zh,
      activity_key: act.key,
      met,
      duration_min: duration,
      distance_km: num(w.distance_km, { min: 0, max: 1000, optional: true }) || null,
      kcal: Math.round(netKcal(met, weight, duration)),
      in_device: !!w.in_device,
      avg_hr: num(w.avg_hr, { min: 30, max: 230, optional: true }),
      device_kcal: num(w.device_kcal, { min: 0, max: 10000, optional: true }),
    };
  });
}

const ACT_FIELDS: [string, number, number][] = [
  ["steps", 0, 200000], ["distance_km", 0, 500], ["active_kcal", 0, 10000], ["resting_kcal", 0, 5000],
  ["exercise_min", 0, 1440], ["stand_hours", 0, 24], ["sleep_hours", 0, 24],
];

function cleanActivity(a: unknown): Record<string, number | null> {
  const out: Record<string, number | null> = {};
  const src = (a && typeof a === "object" ? a : {}) as Record<string, unknown>;
  for (const [k, min, max] of ACT_FIELDS) out[k] = num(src[k], { min, max, optional: true, name: k });
  return out;
}

/** 预览：把尚未保存的一餐 / 活动 / 称重 / 运动加入当天后重新评分，返回合并前后的完整评分，供用户审核 */
bodyRouter.post(
  "/preview",
  requireAuth,
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    if (!p) throw bad("请先完善个人档案");
    const b = req.body ?? {};
    const date = isDate(b.date) ? b.date : todayIn(p.timezone);
    const weight = weightOn(getWeights(uid, date), date, p.weight_kg);
    const items = Array.isArray(b.meal?.items)
      ? (b.meal.items as Record<string, unknown>[]).map((it) =>
          itemFromRow({
            id: 0, meal_id: -1, date, name: String(it.name ?? ""), amount_g: Number(it.amount_g) || 0,
            nutrients: JSON.stringify(sanitizeVector(it.nutrients, NUTRIENT_KEYS)),
            groups: JSON.stringify(sanitizeVector(it.groups, FOOD_GROUP_KEYS)),
            hazards: JSON.stringify((Array.isArray(it.hazards) ? it.hazards : []).filter((h: Record<string, unknown>) => HAZARD_MAP[String(h?.key)])),
            nova_group: [1, 2, 3, 4].includes(Number(it.nova_group)) ? Number(it.nova_group) : null,
          }),
        )
      : null;
    const bodyWeight = num(b.body?.weight_kg, { min: 20, max: 350, optional: true });
    const sbp = num(b.body?.sbp, { min: 60, max: 260, optional: true });
    const dbp = num(b.body?.dbp, { min: 30, max: 160, optional: true });
    const r = previewDay(uid, date, {
      bp: sbp != null && dbp != null ? { sbp, dbp, treated: !!b.body?.bp_treated } : null,
      meal: items ? { meal_type: String(b.meal.meal_type ?? "other"), time: String(b.meal.time ?? "12:00"), items, replace_meal_id: Number(b.meal.replace_meal_id) || null } : undefined,
      activity: b.activity ? cleanActivity(b.activity) : undefined,
      weight_kg: bodyWeight,
      workouts: cleanWorkouts(b.workouts, bodyWeight ?? weight).map((w) => ({ ...w, distance_km: w.distance_km ?? null })),
    });
    return { date, ...r };
  }),
);

/** 确认合并 AI 识别（或手动修改）后的活动数据 */
bodyRouter.post(
  "/activity/commit",
  requireAuth,
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    if (!p) throw bad("请先完善个人档案");
    const b = req.body ?? {};
    const date = isDate(b.date) ? b.date : todayIn(p.timezone);
    const act = cleanActivity(b.activity);
    const body = (b.body ?? {}) as Record<string, unknown>;
    const w = num(body.weight_kg, { min: 20, max: 350, optional: true, name: "体重" });
    const fat = num(body.body_fat_pct, { min: 2, max: 70, optional: true, name: "体脂率" });
    const sbp = num(body.sbp, { min: 60, max: 260, optional: true, name: "收缩压" });
    const dbp = num(body.dbp, { min: 30, max: 160, optional: true, name: "舒张压" });
    const weight = w ?? weightOn(getWeights(uid, date), date, p.weight_kg);
    const workouts = cleanWorkouts(b.workouts, weight);
    const source = b.source === "manual" ? "manual" : "ai";
    tx(() => {
      if (Object.values(act).some((v) => v != null)) upsertActivity(uid, date, act, source === "ai" ? "ai_screenshot" : "manual");
      for (const x of workouts) {
        run(
          `INSERT INTO exercises (user_id, date, time, description, activity_key, met, duration_min, distance_km, kcal, in_device, avg_hr, device_kcal, source)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          uid, date, nowTimeIn(p.timezone), x.description, x.activity_key, x.met, x.duration_min, x.distance_km, x.kcal, x.in_device ? 1 : 0,
          x.avg_hr, x.device_kcal, source,
        );
      }
      if (w != null || fat != null || sbp != null) {
        run(
          "INSERT INTO body_metrics (user_id, date, time, weight_kg, body_fat_pct, sbp, dbp, bp_treated, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
          uid, date, str(body.time, { optional: true }) || "22:00", w, fat, sbp, dbp, body.bp_treated ? 1 : 0, source,
        );
        invalidateFrom(uid, date);
      }
      invalidateDay(uid, date);
    });
    return { ok: true, date, workouts: workouts.length };
  }),
);

// ---------------------------------------------------------------- iPhone 快捷指令上传

/** 快捷指令里的数值可能带千分位或单位，如 "8,532" 或 "512 kcal" */
function loose(v: unknown): number | null {
  if (v === undefined || v === null || v === "") return null;
  const n = Number(String(v).replace(/,/g, "").match(/-?\d+(\.\d+)?/)?.[0]);
  return Number.isFinite(n) ? n : null;
}

bodyRouter.post(
  "/health/ingest",
  requireAuthOrToken,
  ah((req) => {
    const uid = req.user!.id;
    const p = getProfile(uid);
    const tz = p?.timezone ?? "Asia/Shanghai";
    const b = req.body ?? {};
    const date = isDate(b.date) ? b.date : todayIn(tz);
    const vals = {
      steps: loose(b.steps),
      active_kcal: loose(b.active_kcal ?? b.active_energy),
      resting_kcal: loose(b.resting_kcal ?? b.resting_energy),
      distance_km: loose(b.distance_km),
      exercise_min: loose(b.exercise_min),
      sleep_hours: loose(b.sleep_hours),
    };
    const result: Record<string, unknown> = { date };
    if (Object.values(vals).some((v) => v != null)) {
      upsertActivity(uid, date, vals, "apple_shortcut");
      result.activity = vals;
    }
    const weight = loose(b.weight_kg);
    if (weight != null && weight >= 20 && weight <= 350) {
      const fat = loose(b.body_fat_pct);
      run(
        "INSERT INTO body_metrics (user_id, date, time, weight_kg, body_fat_pct, source) VALUES (?, ?, ?, ?, ?, 'apple_shortcut')",
        uid, date, nowTimeIn(tz), weight, fat != null ? (fat <= 1 ? fat * 100 : fat) : null,
      );
      invalidateFrom(uid, date);
      result.weight_kg = weight;
    }
    return { ok: true, ...result };
  }),
);

// ---------------------------------------------------------------- 苹果健康导出文件 (export.xml / export.zip)

const importUpload = multer({ dest: os.tmpdir(), limits: { fileSize: 4 * 1024 * 1024 * 1024 } });

interface DayAgg {
  steps: Map<string, number>;
  active: Map<string, number>;
  resting: Map<string, number>;
  distance: Map<string, number>;
  exercise: Map<string, number>;
}

const TYPES: Record<string, keyof DayAgg | "weight" | "fat"> = {
  HKQuantityTypeIdentifierStepCount: "steps",
  HKQuantityTypeIdentifierActiveEnergyBurned: "active",
  HKQuantityTypeIdentifierBasalEnergyBurned: "resting",
  HKQuantityTypeIdentifierDistanceWalkingRunning: "distance",
  HKQuantityTypeIdentifierAppleExerciseTime: "exercise",
  HKQuantityTypeIdentifierBodyMass: "weight",
  HKQuantityTypeIdentifierBodyFatPercentage: "fat",
};

function toUnit(kind: string, value: number, unit: string): number {
  if (kind === "active" || kind === "resting") return unit === "kJ" ? value / 4.184 : value;
  if (kind === "distance") return unit === "mi" ? value * 1.60934 : unit === "m" ? value / 1000 : value;
  if (kind === "weight") return unit === "lb" ? value * 0.453592 : unit === "g" ? value / 1000 : value;
  if (kind === "fat") return value <= 1 ? value * 100 : value;
  return value;
}

async function parseHealthExport(stream: NodeJS.ReadableStream, since: string) {
  const days = new Map<string, DayAgg>();
  const weights = new Map<string, { time: string; kg: number; fat: number | null }>();
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  let records = 0;
  for await (const line of rl) {
    if (!line.includes("<Record ")) continue;
    const type = line.match(/type="([^"]+)"/)?.[1];
    if (!type || !TYPES[type]) continue;
    const start = line.match(/startDate="([^"]+)"/)?.[1];
    const value = Number(line.match(/value="([^"]+)"/)?.[1]);
    if (!start || !Number.isFinite(value)) continue;
    const date = start.slice(0, 10);
    if (date < since) continue;
    const unit = line.match(/unit="([^"]+)"/)?.[1] ?? "";
    const source = line.match(/sourceName="([^"]+)"/)?.[1] ?? "unknown";
    const kind = TYPES[type];
    const v = toUnit(kind, value, unit);
    records++;
    if (kind === "weight" || kind === "fat") {
      const prev = weights.get(date);
      const time = start.slice(11, 16);
      if (kind === "weight") weights.set(date, { time, kg: v, fat: prev?.fat ?? null });
      else if (prev) prev.fat = v;
      else weights.set(date, { time, kg: NaN, fat: v });
      continue;
    }
    let d = days.get(date);
    if (!d) {
      d = { steps: new Map(), active: new Map(), resting: new Map(), distance: new Map(), exercise: new Map() };
      days.set(date, d);
    }
    const m = d[kind];
    m.set(source, (m.get(source) ?? 0) + v);
  }
  return { days, weights, records };
}

/** iPhone 与 Apple Watch 会重复记录步数/能量：同一天取各数据源中的最大值作为去重近似 */
const maxOf = (m: Map<string, number>) => (m.size ? Math.max(...m.values()) : null);

bodyRouter.post(
  "/health/import",
  requireAuth,
  importUpload.single("file"),
  ah(async (req) => {
    const uid = req.user!.id;
    const file = req.file;
    if (!file) throw bad("请上传苹果健康导出的 export.xml 或 export.zip");
    const since = isDate(req.body.since) ? req.body.since : addDays(todayIn(getProfile(uid)?.timezone ?? "Asia/Shanghai"), -365);
    try {
      let stream: NodeJS.ReadableStream;
      const isZip = file.originalname.toLowerCase().endsWith(".zip");
      if (isZip) {
        if (spawnSync("unzip", ["-v"]).status !== 0) throw bad("服务器没有 unzip 命令，请解压后上传 export.xml");
        const list = spawnSync("unzip", ["-Z1", file.path], { encoding: "utf8" }).stdout.split("\n");
        const entry = list.find((n) => /(^|\/)export\.xml$/.test(n));
        if (!entry) throw bad("压缩包中没有找到 export.xml");
        stream = spawn("unzip", ["-p", file.path, entry]).stdout;
      } else {
        stream = fs.createReadStream(file.path);
      }
      const { days, weights, records } = await parseHealthExport(stream, since);
      let dayCount = 0;
      let weightCount = 0;
      tx(() => {
        for (const [date, d] of days) {
          upsertActivity(uid, date, {
            steps: maxOf(d.steps) != null ? Math.round(maxOf(d.steps)!) : null,
            active_kcal: maxOf(d.active),
            resting_kcal: maxOf(d.resting),
            distance_km: maxOf(d.distance),
            exercise_min: maxOf(d.exercise),
          }, "apple_export");
          dayCount++;
        }
        for (const [date, w] of weights) {
          if (!Number.isFinite(w.kg)) continue;
          run("DELETE FROM body_metrics WHERE user_id = ? AND date = ? AND source = 'apple_export'", uid, date);
          run(
            "INSERT INTO body_metrics (user_id, date, time, weight_kg, body_fat_pct, source) VALUES (?, ?, ?, ?, ?, 'apple_export')",
            uid, date, w.time || "07:00", Math.round(w.kg * 10) / 10, w.fat,
          );
          weightCount++;
        }
        const first = [...days.keys(), ...weights.keys()].sort()[0];
        if (first) invalidateFrom(uid, first);
      });
      return { ok: true, records, days: dayCount, weights: weightCount, since };
    } finally {
      fs.rm(file.path, { force: true }, () => {});
    }
  }),
);
