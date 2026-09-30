// AHA Life's Essential 8（Lloyd-Jones DM et al., Circulation 2022;146:e18–e43 及官方补充材料）
// 8 项各 0–100 分，总分 = 已有指标的等权平均（缺失指标不计入分母，按补充材料 Appendix 2）。
// 分级：80–100 高，50–79 中，0–49 低。个人饮食分使用 MEPA 16 题问卷。

import type { MepaResult } from "./mepa.ts";

export interface Le8Inputs {
  mepa: MepaResult | null;
  /** 每周中等及以上强度活动分钟（高强度按 2 倍计） */
  paMinutesPerWeek: number | null;
  nicotine: string | undefined;
  secondhandSmoke: boolean | undefined;
  /** 平均每晚睡眠小时 */
  sleepHours: number | null;
  bmi: number | null;
  nonHdl: number | null;
  lipidTreated: boolean;
  fastingGlucose: number | null;
  hba1c: number | null;
  diabetes: boolean;
  sbp: number | null;
  dbp: number | null;
  bpTreated: boolean;
}

export interface Le8Component {
  key: string;
  zh: string;
  points: number | null;
  value: string;
  rule: string;
  missing: string;
}

export interface Le8Result {
  score: number | null;
  category: { key: "high" | "moderate" | "low"; zh: string } | null;
  available: number;
  components: Le8Component[];
}

const clamp = (v: number) => Math.max(0, Math.min(100, v));

export function mepaPoints(score: number): number {
  if (score >= 15) return 100;
  if (score >= 12) return 80;
  if (score >= 8) return 50;
  if (score >= 4) return 25;
  return 0;
}

export function paPoints(min: number): number {
  if (min >= 150) return 100;
  if (min >= 120) return 90;
  if (min >= 90) return 80;
  if (min >= 60) return 60;
  if (min >= 30) return 40;
  if (min >= 1) return 20;
  return 0;
}

export function nicotinePoints(status: string | undefined, secondhand: boolean | undefined): number | null {
  const base: Record<string, number> = { never: 100, former_5y: 75, former_1_5y: 50, former_lt1y: 25, ecig: 25, current: 0 };
  if (!status || !(status in base)) return null;
  const p = base[status];
  return secondhand && p > 0 ? Math.max(0, p - 20) : p;
}

export function sleepPoints(h: number): number {
  if (h >= 7 && h < 9) return 100;
  if (h >= 9 && h < 10) return 90;
  if (h >= 6 && h < 7) return 70;
  if ((h >= 5 && h < 6) || h >= 10) return 40;
  if (h >= 4 && h < 5) return 20;
  return 0;
}

export function bmiPoints(bmi: number): number {
  if (bmi < 25) return 100;
  if (bmi < 30) return 70;
  if (bmi < 35) return 30;
  if (bmi < 40) return 15;
  return 0;
}

export function lipidPoints(nonHdl: number, treated: boolean): number {
  const p = nonHdl < 130 ? 100 : nonHdl < 160 ? 60 : nonHdl < 190 ? 40 : nonHdl < 220 ? 20 : 0;
  return clamp(treated ? p - 20 : p);
}

export function glucosePoints(fbg: number | null, a1c: number | null, diabetes: boolean): number | null {
  if (diabetes) {
    if (a1c == null) return null;
    if (a1c < 7) return 40;
    if (a1c < 8) return 30;
    if (a1c < 9) return 20;
    if (a1c < 10) return 10;
    return 0;
  }
  if (fbg == null && a1c == null) return null;
  // 数值达到糖尿病诊断水平（空腹 ≥126 或 HbA1c ≥6.5）但未标记糖尿病：按糖尿病档计分（NHANES 分析的通行做法），并应就医确认
  if ((fbg != null && fbg >= 126) || (a1c != null && a1c >= 6.5)) return glucosePoints(null, a1c ?? 6.5, true);
  const pre = (fbg != null && fbg >= 100) || (a1c != null && a1c >= 5.7);
  return pre ? 60 : 100;
}

export function bpPoints(sbp: number, dbp: number, treated: boolean): number {
  let p: number;
  if (sbp >= 160 || dbp >= 100) p = 0;
  else if (sbp >= 140 || dbp >= 90) p = 25;
  else if (sbp >= 130 || dbp >= 80) p = 50;
  else if (sbp >= 120) p = 75;
  else p = 100;
  return clamp(treated ? p - 20 : p);
}

const NIC_ZH: Record<string, string> = { never: "从不吸烟", former_5y: "已戒烟 ≥5 年", former_1_5y: "已戒烟 1–5 年", former_lt1y: "戒烟 <1 年", ecig: "使用电子烟", current: "目前吸烟" };

export function computeLE8(x: Le8Inputs): Le8Result {
  const comps: Le8Component[] = [
    {
      key: "diet", zh: "饮食（MEPA）",
      points: x.mepa ? mepaPoints(x.mepa.score) : null,
      value: x.mepa ? `MEPA ${x.mepa.score}/16（近 ${x.mepa.days} 天记录推算）` : "—",
      rule: "MEPA 15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0",
      missing: "需要至少 3 天饮食记录",
    },
    {
      key: "activity", zh: "身体活动",
      points: x.paMinutesPerWeek != null ? paPoints(x.paMinutesPerWeek) : null,
      value: x.paMinutesPerWeek != null ? `${Math.round(x.paMinutesPerWeek)} 分钟/周` : "—",
      rule: "≥150 → 100；120–149 → 90；90–119 → 80；60–89 → 60；30–59 → 40；1–29 → 20；0 → 0（高强度 1 分钟按 2 分钟计）",
      missing: "记录运动或同步“锻炼分钟”",
    },
    {
      key: "nicotine", zh: "尼古丁暴露",
      points: nicotinePoints(x.nicotine, x.secondhandSmoke),
      value: x.nicotine && NIC_ZH[x.nicotine] ? NIC_ZH[x.nicotine] + (x.secondhandSmoke ? "，家中有人室内吸烟" : "") : "—",
      rule: "从不 100；戒 ≥5 年 75；戒 1–5 年 50；戒 <1 年或电子烟 25；吸烟 0；家中二手烟 −20",
      missing: "在设置 → 个人档案中填写吸烟情况",
    },
    {
      key: "sleep", zh: "睡眠",
      points: x.sleepHours != null ? sleepPoints(x.sleepHours) : null,
      value: x.sleepHours != null ? `平均 ${x.sleepHours.toFixed(1)} 小时/晚` : "—",
      rule: "7–<9 小时 100；9–<10 → 90；6–<7 → 70；5–<6 或 ≥10 → 40；4–<5 → 20；<4 → 0",
      missing: "填写或同步睡眠时长",
    },
    {
      key: "bmi", zh: "体重指数 BMI",
      points: x.bmi != null ? bmiPoints(x.bmi) : null,
      value: x.bmi != null ? `BMI ${x.bmi.toFixed(1)}` : "—",
      rule: "<25 → 100；25–29.9 → 70；30–34.9 → 30；35–39.9 → 15；≥40 → 0",
      missing: "记录体重",
    },
    {
      key: "lipids", zh: "血脂（非 HDL 胆固醇）",
      points: x.nonHdl != null ? lipidPoints(x.nonHdl, x.lipidTreated) : null,
      value: x.nonHdl != null ? `${Math.round(x.nonHdl)} mg/dL${x.lipidTreated ? "（服药）" : ""}` : "—",
      rule: "<130 → 100；130–159 → 60；160–189 → 40；190–219 → 20；≥220 → 0；服药 −20",
      missing: "在身体页填写体检的总胆固醇与 HDL",
    },
    {
      key: "glucose", zh: "血糖",
      points: glucosePoints(x.fastingGlucose, x.hba1c, x.diabetes),
      value: x.fastingGlucose != null || x.hba1c != null
        ? [x.fastingGlucose != null ? `空腹 ${Math.round(x.fastingGlucose)} mg/dL` : "", x.hba1c != null ? `HbA1c ${x.hba1c}%` : ""].filter(Boolean).join("，") + (x.diabetes ? "（糖尿病）" : "")
        : "—",
      rule: "无糖尿病：空腹 <100 或 HbA1c <5.7 → 100；100–125 或 5.7–6.4 → 60；糖尿病：HbA1c <7 → 40，7–7.9 → 30，8–8.9 → 20，9–9.9 → 10，≥10 → 0",
      missing: "在身体页填写体检的空腹血糖或糖化血红蛋白",
    },
    {
      key: "bp", zh: "血压",
      points: x.sbp != null && x.dbp != null ? bpPoints(x.sbp, x.dbp, x.bpTreated) : null,
      value: x.sbp != null && x.dbp != null ? `${Math.round(x.sbp)}/${Math.round(x.dbp)} mmHg${x.bpTreated ? "（服药）" : ""}` : "—",
      rule: "<120/<80 → 100；120–129/<80 → 75；130–139 或 80–89 → 50；140–159 或 90–99 → 25；≥160 或 ≥100 → 0；服药 −20",
      missing: "记录血压",
    },
  ];
  const avail = comps.filter((c) => c.points != null);
  const score = avail.length ? avail.reduce((s, c) => s + (c.points ?? 0), 0) / avail.length : null;
  return {
    score,
    category: score == null ? null : score >= 80 ? { key: "high", zh: "高" } : score >= 50 ? { key: "moderate", zh: "中" } : { key: "low", zh: "低" },
    available: avail.length,
    components: comps,
  };
}
