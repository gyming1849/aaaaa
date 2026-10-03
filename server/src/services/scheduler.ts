// 定时任务：每天结算前一日评分；每周一生成上周报告（含 AI 点评），每月 1 日生成上月报告。

import { all, get } from "../db/index.ts";
import { config } from "../config.ts";
import { todayIn, addDays, weekStart, monthStart } from "../lib/dates.ts";
import { getProfile, getDailyScores } from "./userdata.ts";
import { generateAndStoreSummary } from "../routes/reports.ts";

let busy = false;

async function tick() {
  if (busy) return;
  busy = true;
  try {
    const users = all<{ user_id: number }>("SELECT user_id FROM profiles");
    for (const { user_id: uid } of users) {
      const p = getProfile(uid);
      if (!p) continue;
      const today = todayIn(p.timezone);
      const yesterday = addDays(today, -1);
      // 结算前一日（写入缓存）
      getDailyScores(uid, yesterday, yesterday, p);

      // 上周报告
      const lastWeekStart = addDays(weekStart(today), -7);
      const lastWeekEnd = addDays(lastWeekStart, 6);
      await maybeReport(uid, "week", lastWeekStart, lastWeekEnd, 3);

      // 上月报告
      const lastMonthEnd = addDays(monthStart(today), -1);
      const lastMonthStart = monthStart(lastMonthEnd);
      await maybeReport(uid, "month", lastMonthStart, lastMonthEnd, 10);
    }
  } catch (e) {
    console.error("[scheduler]", e);
  } finally {
    busy = false;
  }
}

async function maybeReport(uid: number, kind: "week" | "month", start: string, end: string, minDays: number) {
  if (get("SELECT id FROM reports WHERE user_id = ? AND period = ? AND start_date = ?", uid, kind, start)) return;
  const logged = get<{ n: number }>("SELECT COUNT(DISTINCT date) AS n FROM meals WHERE user_id = ? AND date BETWEEN ? AND ?", uid, start, end)?.n ?? 0;
  if (logged < minDays) return;
  try {
    if (config.weeklyAiSummary) await generateAndStoreSummary(uid, start, end, kind);
  } catch (e) {
    console.error(`[scheduler] ${kind} report for user ${uid} failed:`, e instanceof Error ? e.message : e);
  }
}

export function startScheduler() {
  if (!config.scheduler) return;
  setTimeout(tick, 20_000);
  setInterval(tick, 15 * 60_000);
}
