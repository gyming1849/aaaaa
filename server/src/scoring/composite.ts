// 综合总分（满分 100）：本站自定权重，把已发表的评分合成一个数字，方便每天 / 每周看一眼。
//
// 与其他分数不同，这里的权重没有权威出处，是本系统的设定；各分项本身仍是 HEI-2020、MAR、LE8、WCRF/AICR。
// 缺少某个分项（例如没有任何运动数据）时，按已有分项的权重重新折算到 100，并在 missing 中列出。
//
//   每日总分 = 膳食质量 HEI-2020 × 50% + 微量营养素 MAR × 15% + 能量平衡 × 15% + 身体活动 × 20%
//   每周总分 = 膳食质量 HEI-2020（周期总摄入）× 40% + MAR 日均 × 10% + 心血管健康 LE8 × 35% + 防癌 WCRF/AICR × 15%

import type { DayData, EnergyResult } from "./types.ts";

export interface CompositePart {
  key: string;
  zh: string;
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

const clamp100 = (v: number) => Math.max(0, Math.min(100, v));

function combine(parts: Omit<CompositePart, "points">[]): CompositeScore {
  const avail = parts.filter((p) => p.score != null);
  const wSum = avail.reduce((s, p) => s + p.weight, 0);
  const scale = wSum > 0 ? 100 / wSum : 0;
  const withPoints = parts.map((p) => ({ ...p, points: p.score == null ? null : (p.score / 100) * p.weight * scale }));
  return {
    score: wSum > 0 ? withPoints.reduce((s, p) => s + (p.points ?? 0), 0) : null,
    parts: withPoints,
    missing: parts.filter((p) => p.score == null).map((p) => p.zh),
  };
}

/** 能量平衡分：与今日目标偏差 ≤ 10% 满分，偏差 50% 及以上 0 分，中间线性 */
export function energyBalancePoints(intake: number, target: number): number {
  if (target <= 0) return 100;
  const dev = Math.abs(intake / target - 1);
  if (dev <= 0.1 + 1e-9) return 100;
  return clamp100(((0.5 - dev) / 0.4) * 100);
}

/** 当日中高强度活动分钟（高强度按 2 倍计，与手表锻炼分钟取较大值）；没有任何活动数据时为 null */
export function dayActiveMinutes(day: DayData): number | null {
  let min = 0;
  for (const e of day.exercises) {
    if (e.met >= 6) min += 2 * e.duration_min;
    else if (e.met >= 3) min += e.duration_min;
  }
  const dev = day.activity?.exercise_min;
  if (dev != null) min = Math.max(min, dev);
  if (!day.exercises.length && dev == null && !day.activity?.steps) return null;
  return min;
}

/** 身体活动分：每天 30 分钟中高强度（≈ 每周 150 分钟）或 8000 步即满分，取两者较高 */
export function activityPoints(minutes: number, steps: number | null): number {
  return clamp100(Math.max(minutes / 30, (steps ?? 0) / 8000) * 100);
}

export function dailyComposite(args: {
  hasData: boolean;
  hei: number | null;
  mar: number | null;
  energy: EnergyResult;
  day: DayData;
}): CompositeScore {
  const { hasData, hei, mar, energy, day } = args;
  const minutes = dayActiveMinutes(day);
  const steps = day.activity?.steps ?? null;
  const parts: Omit<CompositePart, "points">[] = [
    { key: "hei", zh: "膳食质量", weight: 50, score: hasData ? hei : null, note: "HEI-2020 总分" },
    { key: "mar", zh: "微量营养素", weight: 15, score: hasData ? mar : null, note: "MAR：11 种微量营养素达到 RDA 的平均比例" },
    {
      key: "energy", zh: "能量平衡", weight: 15,
      score: hasData ? energyBalancePoints(energy.intake, energy.target) : null,
      note: "摄入与今日目标偏差 ≤ 10% 满分，≥ 50% 为 0",
    },
    {
      key: "activity", zh: "身体活动", weight: 20,
      score: minutes == null ? null : activityPoints(minutes, steps),
      note: minutes == null
        ? "没有运动或步数记录"
        : `中高强度 ${Math.round(minutes)} 分钟${steps ? `、${steps} 步` : ""}；30 分钟或 8000 步满分`,
    },
  ];
  // 没有饮食记录的日子不出总分（只有运动不算完整的一天）
  if (!hasData) return { score: null, parts: parts.map((p) => ({ ...p, points: null })), missing: parts.map((p) => p.zh) };
  return combine(parts);
}

export function periodComposite(args: {
  daysLogged: number;
  hei: number | null;
  avgMar: number | null;
  le8: number | null;
  wcrf: { score: number | null; max: number };
}): CompositeScore {
  const { daysLogged, hei, avgMar, le8, wcrf } = args;
  const parts: Omit<CompositePart, "points">[] = [
    { key: "hei", zh: "膳食质量", weight: 40, score: daysLogged ? hei : null, note: "按整个周期总摄入计算的 HEI-2020" },
    { key: "mar", zh: "微量营养素", weight: 10, score: daysLogged ? avgMar : null, note: "MAR 日均" },
    { key: "le8", zh: "心血管健康", weight: 35, score: le8, note: "AHA Life's Essential 8" },
    {
      key: "wcrf", zh: "防癌建议", weight: 15,
      score: wcrf.score == null || wcrf.max <= 0 ? null : clamp100((wcrf.score / wcrf.max) * 100),
      note: `WCRF/AICR 评分折算为百分制（满分 ${wcrf.max}）`,
    },
  ];
  if (!daysLogged) return { score: null, parts: parts.map((p) => ({ ...p, points: null })), missing: parts.map((p) => p.zh) };
  return combine(parts);
}
