export function fmt(v: number | null | undefined, d = 0): string {
  if (v == null || !Number.isFinite(v)) return "—";
  return v.toLocaleString("zh-CN", { maximumFractionDigits: d, minimumFractionDigits: 0 });
}

export function compact(v: number): string {
  if (Math.abs(v) >= 10000) return `${fmt(v / 10000, 1)}万`;
  return fmt(v);
}

export const pad = (n: number) => String(n).padStart(2, "0");

export function localToday(): string {
  const d = new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function nowTime(): string {
  const d = new Date();
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function addDays(date: string, n: number): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function diffDays(a: string, b: string): number {
  return Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);
}

export function weekStart(date: string): string {
  const dow = new Date(date + "T00:00:00Z").getUTCDay();
  return addDays(date, -((dow + 6) % 7));
}

export function monthStart(date: string) {
  return date.slice(0, 8) + "01";
}

export function monthEnd(date: string) {
  const d = new Date(monthStart(date) + "T00:00:00Z");
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(0);
  return d.toISOString().slice(0, 10);
}

const WEEK = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

export function dateLabel(date: string, today?: string): string {
  const d = new Date(date + "T00:00:00Z");
  const base = `${d.getUTCMonth() + 1}月${d.getUTCDate()}日 ${WEEK[d.getUTCDay()]}`;
  if (today) {
    const diff = diffDays(date, today);
    if (diff === 0) return `今天 · ${base}`;
    if (diff === 1) return `昨天 · ${base}`;
  }
  return base;
}

export const shortDate = (date: string) => `${Number(date.slice(5, 7))}/${Number(date.slice(8, 10))}`;

export const MEAL_TYPES: { key: string; zh: string; time: string }[] = [
  { key: "breakfast", zh: "早餐", time: "08:00" },
  { key: "lunch", zh: "午餐", time: "12:30" },
  { key: "dinner", zh: "晚餐", time: "18:30" },
  { key: "snack", zh: "加餐", time: "15:30" },
  { key: "drink", zh: "饮品", time: "10:00" },
  { key: "other", zh: "其他", time: "12:00" },
];
export const mealZh = (k: string) => MEAL_TYPES.find((m) => m.key === k)?.zh ?? k;

export function guessMealType(time: string): string {
  const h = Number(time.slice(0, 2));
  if (h < 10) return "breakfast";
  if (h < 14) return "lunch";
  if (h < 17) return "snack";
  if (h < 21) return "dinner";
  return "snack";
}

export const CATEGORY_ZH: Record<string, string> = {
  staple: "主食", vegetable: "蔬菜", fruit: "水果", meat: "肉类", poultry: "禽肉", seafood: "水产", egg: "蛋类", dairy: "奶制品",
  soy_legume: "豆制品/豆类", nut_seed: "坚果种子", snack: "零食", dessert: "甜点", beverage: "饮品", alcohol: "酒类",
  condiment: "调味品", fast_food: "速食/快餐", dish: "菜肴", supplement: "补充剂", other: "其他",
};

export const NOVA_ZH: Record<number, string> = { 1: "未加工", 2: "烹饪原料", 3: "加工食品", 4: "超加工" };

export const SOURCE_ZH: Record<string, string> = { label: "营养标签", ai_search: "AI 联网查询", ai_estimate: "AI 估算", manual: "手动录入" };
