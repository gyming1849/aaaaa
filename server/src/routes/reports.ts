// 每日详情、趋势数据、周期报告、社交分享、标准库

import { Router } from "express";
import { all, get, run, parseJson } from "../db/index.ts";
import { requireAuth } from "../auth.ts";
import { ah, bad, notFound, forbidden } from "../lib/http.ts";
import { isDate, todayIn, addDays, diffDays, rangeDays, weekStart } from "../lib/dates.ts";
import { getProfile, getDailyScores, getPeriod, getWeights, weightOn, targetsFor } from "../services/userdata.ts";
import { weightTrend } from "../scoring/period.ts";
import { mealsForDay } from "./log.ts";
import { enqueue } from "../ai/jobs.ts";
import { weeklySummary } from "../ai/service.ts";
import { NUTRIENTS, FOOD_GROUPS } from "../standards/nutrients.ts";
import { HAZARDS, HAZARDS_INFO_ONLY, HAZARD_TOTAL_CAP } from "../standards/hazards.ts";
import { HEI_COMPONENTS } from "../standards/hei.ts";
import { ACTIVITIES } from "../standards/met.ts";
import { SOURCES } from "../standards/sources.ts";
import { LIFE_STAGES, INTAKE, UPPER, SODIUM_CDRR, PROTEIN_G_PER_KG } from "../standards/dri.ts";
import { ACTIVITY_LEVELS } from "../standards/energy.ts";
import { CONDITIONS } from "../standards/targets.ts";
import { CATEGORY_WEIGHTS, ADEQUACY_WEIGHTS, SCORING_VERSION } from "../scoring/daily.ts";
import type { DailyScore } from "../scoring/types.ts";

export const reportsRouter = Router();
reportsRouter.use(requireAuth);

function needProfile(uid: number) {
  const p = getProfile(uid);
  if (!p) throw bad("请先完善个人档案");
  return p;
}

function range(q: Record<string, unknown>, tz: string, maxDays = 1100) {
  const end = isDate(q.end) ? (q.end as string) : todayIn(tz);
  let start = isDate(q.start) ? (q.start as string) : addDays(end, -29);
  if (start > end) throw bad("开始日期不能晚于结束日期");
  if (diffDays(start, end) > maxDays) start = addDays(end, -maxDays);
  return { start, end };
}

// ---------------------------------------------------------------- 访问控制

interface ShareRow { id: number; username: string; display_name: string; avatar_color: string; share_mode: string; share_detail: string }

function canView(owner: ShareRow, viewerId: number): { summary: boolean; full: boolean } {
  if (owner.id === viewerId) return { summary: true, full: true };
  let ok = owner.share_mode === "public";
  if (owner.share_mode === "selected") ok = !!get("SELECT 1 FROM share_grants WHERE owner_id = ? AND viewer_id = ?", owner.id, viewerId);
  return { summary: ok, full: ok && owner.share_detail === "full" };
}

function resolveOwner(req: { user?: { id: number }; query: Record<string, unknown> }): { uid: number; full: boolean } {
  const viewer = req.user!.id;
  const username = req.query.user as string | undefined;
  if (!username) return { uid: viewer, full: true };
  const owner = get<ShareRow>("SELECT id, username, display_name, avatar_color, share_mode, share_detail FROM users WHERE username = ?", username);
  if (!owner) throw notFound("用户不存在");
  const access = canView(owner, viewer);
  if (!access.summary) throw forbidden("对方没有向你共享数据");
  return { uid: owner.id, full: access.full };
}

function stripDetail(s: DailyScore) {
  // 仅共享摘要时隐藏逐项营养与食物名称
  return {
    ...s,
    items: s.items.map((i) => ({ ...i, message: "" })),
    hazards: s.hazards.map((h) => ({ ...h, foods: [] })),
    top: { issues: [], wins: [] },
  };
}

// ---------------------------------------------------------------- 单日

reportsRouter.get(
  "/day/:date",
  ah((req) => {
    const { uid, full } = resolveOwner(req);
    const p = needProfile(uid);
    const date = String(req.params.date);
    if (!isDate(date)) throw bad("日期格式不正确");
    const [score] = getDailyScores(uid, date, date, p);
    const weights = getWeights(uid, date);
    const targets = targetsFor(p, date, weightOn(weights, date, p.weight_kg));
    const trend = weightTrend(weights.filter((w) => w.date >= addDays(date, -60)), [date])[0];
    return {
      date,
      score: full ? score : stripDetail(score),
      targets,
      meals: full ? mealsForDay(uid, date) : [],
      activity: get("SELECT * FROM activity_days WHERE user_id = ? AND date = ?", uid, date) ?? null,
      exercises: full ? all("SELECT * FROM exercises WHERE user_id = ? AND date = ? ORDER BY time", uid, date) : [],
      body: all("SELECT * FROM body_metrics WHERE user_id = ? AND date = ? ORDER BY time", uid, date),
      weightTrend: trend?.trend ?? null,
      full,
    };
  }),
);

// ---------------------------------------------------------------- 趋势（逐日序列）

reportsRouter.get(
  "/trends",
  ah((req) => {
    const { uid } = resolveOwner(req);
    const p = needProfile(uid);
    const { start, end } = range(req.query, p.timezone);
    const days = getDailyScores(uid, start, end, p);
    const weights = getWeights(uid, end).filter((w) => w.date >= addDays(start, -60));
    const trend = weightTrend(weights, rangeDays(start, end));
    const acts = new Map(
      all<{ date: string; steps: number | null; active_kcal: number | null; exercise_min: number | null }>(
        "SELECT date, steps, active_kcal, exercise_min FROM activity_days WHERE user_id = ? AND date BETWEEN ? AND ?", uid, start, end,
      ).map((a) => [a.date, a]),
    );
    const round = (v: number, d = 1) => Math.round(v * 10 ** d) / 10 ** d;
    return {
      start,
      end,
      days: days.map((d, i) => ({
        date: d.date,
        hasData: d.hasData,
        score: d.score == null ? null : round(d.score),
        grade: d.grade?.key ?? null,
        categories: Object.fromEntries(d.categories.map((c) => [c.key, round(c.score)])),
        hazardPenalty: round(d.hazardPenalty),
        hei: d.hei ? round(d.hei.total) : null,
        intake: Math.round(d.energy.intake),
        tdee: Math.round(d.energy.tdee),
        target: Math.round(d.energy.target),
        exerciseKcal: Math.round(d.energy.exerciseKcal),
        energyMethod: d.energy.method,
        weight: trend[i].weight,
        trend: trend[i].trend == null ? null : round(trend[i].trend!, 2),
        steps: acts.get(d.date)?.steps ?? null,
        activeKcal: acts.get(d.date)?.active_kcal ?? null,
        completeness: d.completeness.level,
        totals: Object.fromEntries(Object.entries(d.totals).map(([k, v]) => [k, round(v, 2)])),
        groups: Object.fromEntries(Object.entries(d.groups).map(([k, v]) => [k, round(v, 2)])),
        macroPct: Object.fromEntries(Object.entries(d.macroPct).map(([k, v]) => [k, round(v)])),
        upfPct: round(d.upfPct),
        statuses: Object.fromEntries(d.items.filter((it) => it.status !== "info").map((it) => [it.key, it.status])),
      })),
    };
  }),
);

// ---------------------------------------------------------------- 周期报告

reportsRouter.get(
  "/period",
  ah((req) => {
    const { uid, full } = resolveOwner(req);
    const p = needProfile(uid);
    const { start, end } = range(req.query, p.timezone, 400);
    const period = getPeriod(uid, start, end)!;
    const stored = get<{ ai_summary: string | null; created_at: string }>(
      "SELECT ai_summary, created_at FROM reports WHERE user_id = ? AND start_date = ? AND end_date = ? AND ai_summary IS NOT NULL",
      uid, start, end,
    );
    return { ...period, aiSummary: full && stored?.ai_summary ? JSON.parse(stored.ai_summary) : null, full };
  }),
);

export function topFoods(uid: number, start: string, end: string) {
  return all<{ name: string; count: number }>(
    "SELECT name, COUNT(*) AS count FROM meal_items WHERE user_id = ? AND date BETWEEN ? AND ? GROUP BY name ORDER BY count DESC LIMIT 20",
    uid, start, end,
  );
}

export async function generateAndStoreSummary(uid: number, start: string, end: string, periodKind: "week" | "month" | "custom") {
  const period = getPeriod(uid, start, end);
  if (!period) return null;
  const summary = await weeklySummary(period, topFoods(uid, start, end));
  run(
    `INSERT INTO reports (user_id, period, start_date, end_date, score, detail, ai_summary) VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id, period, start_date) DO UPDATE SET end_date = excluded.end_date, score = excluded.score, detail = excluded.detail,
       ai_summary = excluded.ai_summary, created_at = datetime('now')`,
    uid, periodKind, start, end, period.score, JSON.stringify({ score: period.score, avgScore: period.avgScore, daysLogged: period.daysLogged }),
    summary ? JSON.stringify(summary) : null,
  );
  return summary;
}

reportsRouter.post(
  "/period/summary",
  ah((req) => {
    const uid = req.user!.id;
    const p = needProfile(uid);
    const { start, end } = range(req.body ?? {}, p.timezone, 400);
    const kind = diffDays(start, end) === 6 && weekStart(start) === start ? "week" : "custom";
    const id = enqueue(uid, "summary", { start, end }, () => generateAndStoreSummary(uid, start, end, kind));
    return { job_id: id };
  }),
);

reportsRouter.get(
  "/reports",
  ah((req) =>
    all<{ id: number; period: string; start_date: string; end_date: string; score: number | null; ai_summary: string | null; created_at: string }>(
      "SELECT id, period, start_date, end_date, score, ai_summary, created_at FROM reports WHERE user_id = ? ORDER BY start_date DESC LIMIT 60",
      req.user!.id,
    ).map((r) => ({ ...r, ai_summary: parseJson(r.ai_summary, null) })),
  ),
);

// ---------------------------------------------------------------- 社交：用户列表

reportsRouter.get(
  "/users",
  ah((req) => {
    const me = req.user!.id;
    const users = all<ShareRow & { created_at: string }>(
      "SELECT id, username, display_name, avatar_color, share_mode, share_detail, created_at FROM users ORDER BY id",
    );
    return users.map((u) => {
      const access = canView(u, me);
      const p = access.summary ? getProfile(u.id) : null;
      let recent: { date: string; score: number | null }[] = [];
      let streak = 0;
      if (p) {
        const today = todayIn(p.timezone);
        const days = getDailyScores(u.id, addDays(today, -13), today, p);
        recent = days.map((d) => ({ date: d.date, score: d.score == null ? null : Math.round(d.score) }));
        for (let i = days.length - 1; i >= 0; i--) {
          if (days[i].hasData) streak++;
          else if (i !== days.length - 1) break;
        }
      }
      const last = get<{ d: string | null }>("SELECT MAX(date) AS d FROM meals WHERE user_id = ?", u.id)?.d ?? null;
      return {
        id: u.id,
        username: u.username,
        display_name: u.display_name,
        avatar_color: u.avatar_color,
        is_me: u.id === me,
        shared_with_me: access.summary,
        share_detail: access.full ? "full" : access.summary ? "summary" : "none",
        last_log_date: access.summary ? last : null,
        streak,
        recent,
      };
    });
  }),
);

// ---------------------------------------------------------------- 标准库（营养标准数据库）

reportsRouter.get(
  "/standards/meta",
  ah(() => ({
    version: SCORING_VERSION,
    nutrients: NUTRIENTS,
    foodGroups: FOOD_GROUPS,
    hazards: HAZARDS,
    hazardsInfoOnly: HAZARDS_INFO_ONLY,
    hazardTotalCap: HAZARD_TOTAL_CAP,
    hei: HEI_COMPONENTS,
    activities: ACTIVITIES,
    activityLevels: ACTIVITY_LEVELS,
    sources: SOURCES,
    lifeStages: LIFE_STAGES,
    categoryWeights: CATEGORY_WEIGHTS,
    adequacyWeights: ADEQUACY_WEIGHTS,
    conditions: CONDITIONS,
  })),
);

reportsRouter.get(
  "/standards/dri",
  ah(() => ({ lifeStages: LIFE_STAGES, intake: INTAKE, upper: UPPER, sodiumCdrr: SODIUM_CDRR, proteinPerKg: PROTEIN_G_PER_KG })),
);
