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

/**
 * 自动 AI 点评会把用户数据（含苹果健康同步来的血压、睡眠、能量消耗、体重）发给第三方 AI 服务商。
 * App 里回答过「同意 / 不同意」的以回答为准；从未回答过的：用苹果健康直连同步过数据的用户（只有 App 能产生）不自动发送，
 * 其他用户（网页）保持原来的行为。
 */
export function schedulerMayUseAI(uid: number): boolean {
  const consent = get<{ granted: number }>("SELECT granted FROM ai_consent WHERE user_id = ?", uid);
  if (consent) return consent.granted === 1;
  return !get("SELECT 1 FROM health_sync_state WHERE user_id = ? LIMIT 1", uid);
}

async function maybeReport(uid: number, kind: "week" | "month", start: string, end: string, minDays: number) {
  if (get("SELECT id FROM reports WHERE user_id = ? AND period = ? AND start_date = ?", uid, kind, start)) return;
  const logged = get<{ n: number }>("SELECT COUNT(DISTINCT date) AS n FROM meals WHERE user_id = ? AND date BETWEEN ? AND ?", uid, start, end)?.n ?? 0;
  if (logged < minDays) return;
  try {
    if (config.weeklyAiSummary && schedulerMayUseAI(uid)) await generateAndStoreSummary(uid, start, end, kind);
  } catch (e) {
    console.error(`[scheduler] ${kind} report for user ${uid} failed:`, e instanceof Error ? e.message : e);
  }
}

export function startScheduler() {
  if (!config.scheduler) return;
  setTimeout(tick, 20_000);
  setInterval(tick, 15 * 60_000);
}
