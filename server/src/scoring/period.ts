// 周期（周/月/任意区间）评估，全部使用已发表的评分体系：
// - 总分：AHA Life's Essential 8（8 项等权平均，缺失项不计入分母）
// - WCRF/AICR 癌症预防建议标准化评分
// - 按周期总摄入计算的 HEI-2020，日均 MAR
// - 其他按周才有意义的指标（红肉/海产/饮酒/运动/力量训练/体重速度）只标“达标 / 不达标”，不加权

import { NUTRIENT_KEYS, FOOD_GROUP_KEYS, emptyVector, addVectors, scaleVector, type NutrientVector } from "../standards/nutrients.ts";
import { computeHei } from "../standards/hei.ts";
import { ACTIVITY_MAP } from "../standards/met.ts";
import { KCAL_PER_KG } from "../standards/energy.ts";
import type { Profile, Targets } from "../standards/targets.ts";
import { limitCurve } from "./daily.ts";
import type { HealthIndices } from "./indices.ts";
import type { DailyScore, ExerciseRecord, ActivityRecord, Status } from "./types.ts";
import { diffDays } from "../lib/dates.ts";

export interface WeightPoint { date: string; weight_kg: number }

export interface TrendPoint {
  date: string;
  weight: number | null;
  trend: number | null;
}

/** 体重趋势：指数移动平均（α = 0.1，Hacker's Diet 方法），过滤每日水分波动 */
export function weightTrend(weights: WeightPoint[], dates: string[], alpha = 0.1): TrendPoint[] {
  const byDate = new Map<string, number>();
  for (const w of weights) byDate.set(w.date, w.weight_kg); // 同日取最后一次
  const sorted = [...weights].sort((a, b) => a.date.localeCompare(b.date));
  let trend: number | null = null;
  // 用区间开始前的历史数据预热
  for (const w of sorted) {
    if (w.date >= dates[0]) break;
    trend = trend == null ? w.weight_kg : trend + alpha * (w.weight_kg - trend);
  }
  return dates.map((d) => {
    const w = byDate.get(d) ?? null;
    if (w != null) trend = trend == null ? w : trend + alpha * (w - trend);
    return { date: d, weight: w, trend };
  });
}

export interface PeriodCheck {
  key: string;
  zh: string;
  value: number;
  unit: string;
  targetText: string;
  status: Status;
  score: number;
  message: string;
  sources: string[];
}

export interface PeriodScore {
  start: string;
  end: string;
  days: number;
  daysLogged: number;
  /** 有记录日的 HEI-2020 日均分 */
  avgHei: number | null;
  /** 日均 MAR */
  avgMar: number | null;
  /** 周期总分 = LE8 */
  score: number | null;
  category: { key: string; zh: string } | null;
  indices: HealthIndices;
  hei: ReturnType<typeof computeHei>;
  avgTotals: NutrientVector;
  avgGroups: NutrientVector;
  itemStats: { key: string; zh: string; category: string; good: number; ok: number; warn: number; bad: number; days: number }[];
  checks: PeriodCheck[];
  hazards: { key: string; zh: string; iarc: string; dose: number; unit: string; days: number }[];
  energy: {
    avgIntake: number | null;
    avgTdee: number;
    totalBalance: number;
    predictedChangeKg: number;
    trendStart: number | null;
    trendEnd: number | null;
    actualChangeKg: number | null;
    empiricalTdee: number | null;
    ratePerWeek: number | null;
  };
  series: { date: string; score: number | null; intake: number; tdee: number; weight: number | null; trend: number | null }[];
}

export function scorePeriod(args: {
  start: string;
  end: string;
  days: DailyScore[];
  exercises: Map<string, ExerciseRecord[]>;
  activity: Map<string, ActivityRecord>;
  trend: TrendPoint[];
  profile: Profile;
  targets: Targets;
  indices: HealthIndices;
}): PeriodScore {
  const { start, end, days, exercises, activity, trend, profile, targets: t, indices } = args;
  const n = days.length;
  const f = n / 7;
  const logged = days.filter((d) => d.hasData);
  const scored = logged.filter((d) => d.score != null);
  const avgHei = scored.length ? scored.reduce((s, d) => s + (d.score ?? 0), 0) / scored.length : null;
  const withMar = logged.filter((d) => d.mar);
  const avgMar = withMar.length ? withMar.reduce((s, d) => s + (d.mar?.value ?? 0), 0) / withMar.length : null;

  let totals = emptyVector(NUTRIENT_KEYS);
  let groups = emptyVector(FOOD_GROUP_KEYS);
  for (const d of logged) {
    totals = addVectors(totals, d.totals);
    groups = addVectors(groups, d.groups);
  }
  const avgTotals = logged.length ? scaleVector(totals, 1 / logged.length) : totals;
  const avgGroups = logged.length ? scaleVector(groups, 1 / logged.length) : groups;
  const hei = computeHei(totals, groups);

  // 每个评分项在多少天达标
  const stats = new Map<string, PeriodScore["itemStats"][number]>();
  for (const d of logged) {
    for (const it of d.items) {
      if (it.status === "info") continue;
      let s = stats.get(it.key);
      if (!s) {
        s = { key: it.key, zh: it.zh, category: it.category, good: 0, ok: 0, warn: 0, bad: 0, days: 0 };
        stats.set(it.key, s);
      }
      s[it.status as "good" | "ok" | "warn" | "bad"]++;
      s.days++;
    }
  }

  // 风险物汇总
  const hz = new Map<string, PeriodScore["hazards"][number]>();
  for (const d of logged) {
    for (const h of d.hazards) {
      let s = hz.get(h.key);
      if (!s) {
        s = { key: h.key, zh: h.zh, iarc: h.iarc, dose: 0, unit: h.unit, days: 0 };
        hz.set(h.key, s);
      }
      s.dose += h.dose;
      s.days++;
    }
  }

  const checks: PeriodCheck[] = [];
  const fmt = (v: number, d = 0) => (Math.round(v * 10 ** d) / 10 ** d).toString();

  // 红肉（WCRF：每周 350–500 g 熟重）
  {
    const v = groups.red_meat_g ?? 0;
    const ideal = 350 * f;
    const limit = 500 * f;
    const { score, status } = limitCurve(v, ideal, limit);
    checks.push({
      key: "red_meat_week", zh: "红肉总量", value: v, unit: "g", targetText: `≤ ${fmt(limit)} g（理想 ≤ ${fmt(ideal)} g）`,
      status, score, message: `期间红肉约 ${fmt(v)} g`, sources: ["wcrf", "iarc_114"],
    });
  }
  // 加工肉（仅提示，日评分已扣分）
  {
    const v = groups.processed_meat_g ?? 0;
    checks.push({
      key: "processed_meat_week", zh: "加工肉总量", value: v, unit: "g", targetText: "越少越好（WCRF：很少或不吃）",
      status: v <= 0 ? "good" : v <= 100 * f ? "warn" : "bad", score: 1,
      message: v > 0 ? `期间加工肉约 ${fmt(v)} g（已在每日评分中扣分）` : "没有吃加工肉", sources: ["wcrf", "iarc_114"],
    });
  }
  // 海产（DGA：每周约 8 盎司；FDA/EPA：每周 2–3 份低汞鱼）
  {
    const v = groups.seafood_oz ?? 0;
    const target = 8 * f;
    const s = Math.min(1, v / target);
    checks.push({
      key: "seafood_week", zh: "海产品", value: v * 28.35, unit: "g", targetText: `≥ ${fmt(target * 28.35)} g（约 ${fmt(8 * f, 1)} 盎司）`,
      status: s >= 1 ? "good" : s >= 0.5 ? "warn" : "bad", score: s,
      message: `期间海产约 ${fmt(v * 28.35)} g`, sources: ["dga_2020", "fda_fish"],
    });
  }
  // 酒精（NIAAA 大量饮酒阈值：男 ≥15 杯/周，女 ≥8 杯/周）
  {
    const drinks = (totals.alcohol_g ?? 0) / 14;
    const heavy = (profile.sex === "male" ? 15 : 8) * f;
    const limit = t.limits.alcohol_g.limit === 0 ? 0 : heavy - f;
    const { score, status } = limitCurve(drinks, 0, limit);
    checks.push({
      key: "alcohol_week", zh: "饮酒量", value: drinks, unit: "标准杯", targetText: limit === 0 ? "0（应避免）" : `< ${fmt(heavy, 1)} 杯（大量饮酒阈值）`,
      status, score, message: `期间约 ${fmt(drinks, 1)} 标准杯`, sources: ["niaaa_drink", "dga_2025"],
    });
  }
  // 身体活动（PAG 第 2 版：每周 150–300 分钟中等强度，高强度按 2 倍计）
  let modMin = 0;
  let strengthDays = 0;
  let stepsSum = 0;
  let stepsDays = 0;
  for (const d of days) {
    const ex = exercises.get(d.date) ?? [];
    let dayMin = 0;
    let strength = false;
    for (const e of ex) {
      const act = e.activity_key ? ACTIVITY_MAP[e.activity_key] : undefined;
      const met = e.met;
      if (met >= 6) dayMin += 2 * e.duration_min;
      else if (met >= 3) dayMin += e.duration_min;
      if (act && /strength|circuit|hiit/.test(act.key)) strength = true;
    }
    const a = activity.get(d.date);
    if (a?.exercise_min) dayMin = Math.max(dayMin, a.exercise_min);
    if (a?.steps) {
      stepsSum += a.steps;
      stepsDays++;
    }
    modMin += dayMin;
    if (strength) strengthDays++;
  }
  {
    const target = 150 * f;
    const ideal = 300 * f;
    const s = Math.min(1, modMin / target);
    checks.push({
      key: "activity_week", zh: "中高强度运动", value: modMin, unit: "分钟", targetText: `≥ ${fmt(target)} 分钟（理想 ${fmt(ideal)}）`,
      status: modMin >= ideal ? "good" : s >= 1 ? "ok" : s >= 0.5 ? "warn" : "bad", score: s,
      message: `中等强度当量约 ${fmt(modMin)} 分钟（高强度按 2 倍计）`, sources: ["pag_2018"],
    });
    const sTarget = Math.max(1, Math.round(2 * f));
    const ss = Math.min(1, strengthDays / sTarget);
    checks.push({
      key: "strength_week", zh: "力量训练天数", value: strengthDays, unit: "天", targetText: `≥ ${sTarget} 天`,
      status: ss >= 1 ? "good" : ss > 0 ? "warn" : "bad", score: ss,
      message: `力量训练 ${strengthDays} 天`, sources: ["pag_2018"],
    });
  }
  if (stepsDays) {
    const avg = stepsSum / stepsDays;
    checks.push({
      key: "steps_avg", zh: "日均步数（参考）", value: avg, unit: "步", targetText: "参考 ≥ 7000 步",
      status: avg >= 7000 ? "good" : avg >= 5000 ? "warn" : "bad", score: 1,
      message: `日均 ${fmt(avg)} 步（非官方标准，仅作参考）`, sources: ["system"],
    });
  }
  // 记录完整度
  {
    const s = n ? Math.min(1, logged.length / Math.max(1, n * (6 / 7))) : 0;
    checks.push({
      key: "logging", zh: "记录天数", value: logged.length, unit: `/${n} 天`, targetText: "每周至少 6 天",
      status: s >= 1 ? "good" : s >= 0.5 ? "warn" : "bad", score: s,
      message: `${n} 天中记录了 ${logged.length} 天`, sources: ["system"],
    });
  }

  // 能量与体重
  const trendPts = trend.filter((p) => p.trend != null);
  const trendStart = trendPts.length ? trendPts[0].trend : null;
  const trendEnd = trendPts.length ? trendPts[trendPts.length - 1].trend : null;
  const spanDays = trendPts.length >= 2 ? diffDays(trendPts[0].date, trendPts[trendPts.length - 1].date) : 0;
  const actualChangeKg = trendStart != null && trendEnd != null && spanDays >= 3 ? trendEnd - trendStart : null;
  const ratePerWeek = actualChangeKg != null && spanDays >= 7 ? (actualChangeKg / spanDays) * 7 : null;
  const avgIntake = logged.length ? logged.reduce((s, d) => s + d.energy.intake, 0) / logged.length : null;
  const avgTdee = days.reduce((s, d) => s + d.energy.tdee, 0) / Math.max(1, n);
  const totalBalance = logged.reduce((s, d) => s + d.energy.balance, 0);
  const completeLogged = logged.filter((d) => d.completeness.level === "likely").length;
  const empiricalTdee = avgIntake != null && actualChangeKg != null && spanDays >= 14 && completeLogged >= n * 0.7
    ? avgIntake - (actualChangeKg * KCAL_PER_KG) / spanDays
    : null;

  if (ratePerWeek != null && t.goal !== "maintain") {
    let status: Status;
    let score: number;
    if (t.goal === "lose") {
      if (ratePerWeek <= -0.2 && ratePerWeek >= -1.0) { status = "good"; score = 1; }
      else if (ratePerWeek < -1.0) { status = "warn"; score = 0.6; }
      else if (ratePerWeek < 0) { status = "ok"; score = 0.7; }
      else { status = "bad"; score = 0.2; }
    } else {
      if (ratePerWeek >= 0.1 && ratePerWeek <= 0.5) { status = "good"; score = 1; }
      else if (ratePerWeek > 0.5) { status = "warn"; score = 0.6; }
      else { status = "bad"; score = 0.3; }
    }
    checks.push({
      key: "weight_rate", zh: "体重变化速度", value: ratePerWeek, unit: "kg/周",
      targetText: t.goal === "lose" ? "每周 −0.2 至 −1.0 kg" : "每周 +0.1 至 +0.5 kg",
      status, score, message: `趋势体重每周 ${ratePerWeek > 0 ? "+" : ""}${fmt(ratePerWeek, 2)} kg`, sources: ["cdc_weight"],
    });
  }


  return {
    start,
    end,
    days: n,
    daysLogged: logged.length,
    avgHei,
    avgMar,
    score: indices.le8.score,
    category: indices.le8.category,
    indices,
    hei,
    avgTotals,
    avgGroups,
    itemStats: [...stats.values()],
    checks,
    hazards: [...hz.values()].sort((a, b) => b.days - a.days),
    energy: {
      avgIntake,
      avgTdee,
      totalBalance,
      predictedChangeKg: totalBalance / KCAL_PER_KG,
      trendStart,
      trendEnd,
      actualChangeKg,
      empiricalTdee,
      ratePerWeek,
    },
    series: days.map((d, i) => ({
      date: d.date,
      score: d.score,
      intake: d.energy.intake,
      tdee: d.energy.tdee,
      weight: trend[i]?.weight ?? null,
      trend: trend[i]?.trend ?? null,
    })),
  };
}
