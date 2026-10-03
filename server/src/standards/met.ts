// 运动代谢当量（MET），取自 2024 Adult Compendium of Physical Activities。
// 净消耗 kcal = (MET − 1) × 体重(kg) × 小时 —— 扣除静息部分，避免与基础代谢重复计算。

export interface Activity {
  key: string;
  zh: string;
  met: number;
  /** 典型速度 km/h，用于只给距离时推算时长 */
  speedKmh?: number;
  code?: string;
  intensity: "light" | "moderate" | "vigorous";
}

const intensityOf = (met: number): Activity["intensity"] => (met >= 6 ? "vigorous" : met >= 3 ? "moderate" : "light");

const RAW: Omit<Activity, "intensity">[] = [
  { key: "walk_slow", zh: "散步 (约 4 km/h)", met: 3.0, speedKmh: 4.0, code: "17170" },
  { key: "walk_moderate", zh: "步行 (约 5 km/h)", met: 3.8, speedKmh: 5.0, code: "17190" },
  { key: "walk_brisk", zh: "快走 (约 6 km/h)", met: 4.8, speedKmh: 6.0, code: "17200" },
  { key: "walk_very_brisk", zh: "疾走 (约 6.8 km/h)", met: 5.5, speedKmh: 6.8, code: "17220" },
  { key: "hiking", zh: "徒步/爬山", met: 6.0, speedKmh: 4.0 },
  { key: "stairs", zh: "爬楼梯", met: 6.8 },
  { key: "jogging", zh: "慢跑", met: 7.5, speedKmh: 8.0, code: "12020" },
  { key: "run_10kmh", zh: "跑步 (约 10 km/h)", met: 9.3, speedKmh: 10.0, code: "12050" },
  { key: "run_13kmh", zh: "跑步 (约 13 km/h)", met: 12.0, speedKmh: 12.9, code: "12090" },
  { key: "run_16kmh", zh: "跑步 (约 16 km/h)", met: 14.8, speedKmh: 16.1, code: "12120" },
  { key: "cycle_leisure", zh: "骑行 (休闲 17–19 km/h)", met: 6.8, speedKmh: 18 },
  { key: "cycle_moderate", zh: "骑行 (中速 19–22 km/h)", met: 8.0, speedKmh: 21, code: "01030" },
  { key: "cycle_vigorous", zh: "骑行 (快速 22–26 km/h)", met: 10.0, speedKmh: 24, code: "01040" },
  { key: "cycle_stationary", zh: "动感单车/固定自行车", met: 6.8 },
  { key: "swim_leisure", zh: "游泳 (休闲，不计圈)", met: 6.0, speedKmh: 1.8, code: "18310" },
  { key: "swim_freestyle_slow", zh: "自由泳 (慢速)", met: 5.8, speedKmh: 2.1, code: "18240" },
  { key: "swim_freestyle_medium", zh: "自由泳 (中速 ~46 m/min)", met: 8.0, speedKmh: 2.75 },
  { key: "swim_freestyle_fast", zh: "自由泳 (快速 ~69 m/min)", met: 10.5, speedKmh: 4.1 },
  { key: "swim_breaststroke", zh: "蛙泳 (休闲)", met: 5.3, speedKmh: 2.0 },
  { key: "swim_breaststroke_training", zh: "蛙泳 (训练)", met: 10.3, speedKmh: 3.0 },
  { key: "swim_backstroke", zh: "仰泳 (休闲)", met: 4.8, speedKmh: 1.9 },
  { key: "swim_butterfly", zh: "蝶泳", met: 13.8, speedKmh: 3.2 },
  { key: "swim_open_water", zh: "公开水域游泳", met: 10.5, speedKmh: 3.0, code: "18285" },
  { key: "jump_rope", zh: "跳绳 (中速)", met: 11.8 },
  { key: "basketball", zh: "篮球 (比赛)", met: 8.0 },
  { key: "soccer", zh: "足球 (休闲)", met: 7.0 },
  { key: "soccer_competitive", zh: "足球 (比赛)", met: 9.5 },
  { key: "badminton", zh: "羽毛球 (休闲)", met: 5.5 },
  { key: "badminton_competitive", zh: "羽毛球 (比赛)", met: 7.0 },
  { key: "tennis_singles", zh: "网球单打", met: 8.0 },
  { key: "table_tennis", zh: "乒乓球", met: 4.0 },
  { key: "yoga", zh: "瑜伽 (哈他)", met: 2.3 },
  { key: "pilates", zh: "普拉提", met: 3.0 },
  { key: "strength_moderate", zh: "力量训练 (中等)", met: 3.5 },
  { key: "strength_vigorous", zh: "力量训练 (大强度)", met: 6.0 },
  { key: "circuit", zh: "循环训练", met: 5.0 },
  { key: "hiit", zh: "HIIT 高强度间歇", met: 7.0 },
  { key: "hiit_vigorous", zh: "HIIT (极高强度)", met: 11.0 },
  { key: "elliptical", zh: "椭圆机", met: 5.0 },
  { key: "rowing_machine", zh: "划船机 (中等)", met: 5.0 },
  { key: "aerobic_dance", zh: "有氧操/健身舞", met: 7.3 },
  { key: "dance_social", zh: "跳舞 (广场舞/社交舞)", met: 4.8 },
  { key: "housework", zh: "家务 (打扫)", met: 3.3 },
  { key: "other_light", zh: "其他轻度活动", met: 2.5 },
  { key: "other_moderate", zh: "其他中等强度活动", met: 4.5 },
  { key: "other_vigorous", zh: "其他高强度活动", met: 7.5 },
];

export const ACTIVITIES: Activity[] = RAW.map((a) => ({ ...a, intensity: intensityOf(a.met) }));
export const ACTIVITY_MAP: Record<string, Activity> = Object.fromEntries(ACTIVITIES.map((a) => [a.key, a]));

export function netKcal(met: number, weightKg: number, minutes: number): number {
  return Math.max(0, (met - 1) * weightKg * (minutes / 60));
}
