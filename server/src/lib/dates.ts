// 日期工具：所有日期均为用户本地日期字符串 YYYY-MM-DD，按 UTC 计算避免时区漂移。

export const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export const TIME_RE = /^\d{2}:\d{2}$/;

export function isDate(s: unknown): s is string {
  return typeof s === "string" && DATE_RE.test(s) && !Number.isNaN(Date.parse(s + "T00:00:00Z"));
}

export function todayIn(timeZone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

export function nowTimeIn(timeZone: string): string {
  try {
    return new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date());
  } catch {
    return new Date().toISOString().slice(11, 16);
  }
}

const toUtc = (d: string) => new Date(d + "T00:00:00Z");
const fmt = (d: Date) => d.toISOString().slice(0, 10);

export function addDays(date: string, n: number): string {
  const d = toUtc(date);
  d.setUTCDate(d.getUTCDate() + n);
  return fmt(d);
}

export function diffDays(a: string, b: string): number {
  return Math.round((toUtc(b).getTime() - toUtc(a).getTime()) / 86400_000);
}

export function rangeDays(start: string, end: string): string[] {
  const out: string[] = [];
  for (let d = start; d <= end; d = addDays(d, 1)) out.push(d);
  return out;
}

/** 周一为一周开始 */
export function weekStart(date: string): string {
  const dow = toUtc(date).getUTCDay(); // 0=周日
  return addDays(date, -((dow + 6) % 7));
}

export function monthStart(date: string): string {
  return date.slice(0, 8) + "01";
}

export function monthEnd(date: string): string {
  const d = toUtc(monthStart(date));
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return fmt(d);
}

export function ageOn(birthDate: string, date: string): number {
  const b = toUtc(birthDate);
  const d = toUtc(date);
  let age = d.getUTCFullYear() - b.getUTCFullYear();
  const m = d.getUTCMonth() - b.getUTCMonth();
  if (m < 0 || (m === 0 && d.getUTCDate() < b.getUTCDate())) age--;
  return age;
}
