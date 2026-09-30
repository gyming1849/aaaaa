import { useMemo, useState, type ReactNode } from "react";
import { useParams } from "react-router-dom";
import type { EChartsOption } from "echarts";
import { Table2, ChartLine } from "lucide-react";
import { api, qs } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { PeriodScore, Targets, TrendDay } from "../types";
import { addDays, diffDays, fmt, localToday, shortDate, weekStart, monthStart } from "../lib/format";
import { useChartTheme, type ChartTheme } from "../lib/theme";
import { baseOption, lineSeries, legendOption, tipHtml } from "../lib/charts";
import { EChart } from "../components/EChart";
import { Loading, Seg, StatusBadge, IarcChip, Empty } from "../components/ui";

type RangeKey = "7" | "30" | "90" | "year" | "365" | "all" | "custom";

interface Bucket {
  key: string;
  label: string;
  days: TrendDay[];
  logged: TrendDay[];
}

function bucketize(days: TrendDay[], unit: "day" | "week" | "month"): Bucket[] {
  const map = new Map<string, Bucket>();
  for (const d of days) {
    const key = unit === "day" ? d.date : unit === "week" ? weekStart(d.date) : monthStart(d.date);
    let b = map.get(key);
    if (!b) {
      b = { key, label: unit === "month" ? `${key.slice(2, 4)}/${Number(key.slice(5, 7))}月` : shortDate(key), days: [], logged: [] };
      map.set(key, b);
    }
    b.days.push(d);
    if (d.hasData) b.logged.push(d);
  }
  return [...map.values()];
}

const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const r1 = (v: number | null) => (v == null ? null : Math.round(v * 10) / 10);

export default function Trends() {
  const { username } = useParams();
  const { me } = useApp();
  const t = useChartTheme();
  const today = me?.today ?? localToday();
  const other = username && username !== me?.user.username ? username : undefined;
  const [range, setRange] = useState<RangeKey>("30");
  const [custom, setCustom] = useState({ start: addDays(today, -59), end: today });

  const { start, end } = useMemo(() => {
    if (range === "custom") return custom;
    if (range === "year") return { start: `${today.slice(0, 4)}-01-01`, end: today };
    if (range === "all") return { start: addDays(today, -1095), end: today };
    return { start: addDays(today, -(Number(range) - 1)), end: today };
  }, [range, custom, today]);

  const trends = useLoad(() => api.get<{ start: string; end: string; days: TrendDay[] }>(`/trends${qs({ start, end, user: other })}`), [start, end, other]);
  const period = useLoad(() => api.get<PeriodScore>(`/period${qs({ start: diffDays(start, end) > 400 ? addDays(end, -400) : start, end, user: other })}`), [start, end, other]);
  const targets = useLoad(() => (other ? Promise.resolve(null) : api.get<Targets>("/profile/targets")), [other]);

  let days = trends.data?.days ?? [];
  if (range === "all") {
    const first = days.findIndex((d) => d.hasData || d.weight != null);
    if (first > 0) days = days.slice(first);
  }
  const span = days.length;
  const unit: "day" | "week" | "month" = span <= 92 ? "day" : span <= 400 ? "week" : "month";
  const buckets = useMemo(() => bucketize(days, unit), [days, unit]);
  const unitZh = unit === "day" ? "每日" : unit === "week" ? "每周平均" : "每月平均";

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>{other ? `@${other} 的健康趋势` : "健康趋势"}</h1>
          <div className="sub">{start} 至 {end} · {unitZh}</div>
        </div>
      </div>

      <div className="row wrap">
        <Seg value={range} onChange={setRange} options={[
          { key: "7", label: "7 天" }, { key: "30", label: "30 天" }, { key: "90", label: "90 天" },
          { key: "year", label: "今年" }, { key: "365", label: "一年" }, { key: "all", label: "全部" }, { key: "custom", label: "自定义" },
        ]} />
        {range === "custom" && (
          <div className="row">
            <input className="input sm" type="date" value={custom.start} max={custom.end} onChange={(e) => setCustom({ ...custom, start: e.target.value })} />
            <span className="muted">至</span>
            <input className="input sm" type="date" value={custom.end} max={today} onChange={(e) => setCustom({ ...custom, end: e.target.value })} />
          </div>
        )}
      </div>

      {trends.loading && !trends.data && <Loading />}
      {trends.error && <div className="banner warn">{trends.error}</div>}
      {trends.data && (
        <div className="stack" style={{ opacity: trends.loading ? 0.55 : 1, transition: "opacity .2s" }}>
          <SummaryTiles period={period.data} days={days} />
          <div className="grid g2">
            <ScoreChart buckets={buckets} unit={unit} t={t} />
            <EnergyChart buckets={buckets} unit={unit} t={t} />
          </div>
          <div className="grid g2">
            <WeightChart buckets={buckets} unit={unit} t={t} period={period.data} />
            <CategoryChart buckets={buckets} t={t} />
          </div>
          <NutrientExplorer buckets={buckets} unit={unit} t={t} targets={targets.data} />
          {span >= 45 && <CalendarHeat days={days} t={t} />}
          {period.data && <PassRates period={period.data} t={t} />}
          {period.data && period.data.hazards.length > 0 && <HazardTable period={period.data} />}
        </div>
      )}
    </div>
  );
}

function SummaryTiles({ period, days }: { period: PeriodScore | null; days: TrendDay[] }) {
  const logged = days.filter((d) => d.hasData);
  const avgScore = avg(logged.map((d) => d.score ?? 0));
  const e = period?.energy;
  return (
    <div className="grid g4">
      <div className="card stat-card"><div className="stat"><span className="label">平均日评分</span><span className="value">{fmt(avgScore)}</span><span className="delta">{logged.length}/{days.length} 天有记录</span></div></div>
      <div className="card stat-card"><div className="stat"><span className="label">日均摄入 / 消耗</span><span className="value">{fmt(avg(logged.map((d) => d.intake)))}<small>/ {fmt(avg(days.map((d) => d.tdee)))} kcal</small></span></div></div>
      <div className="card stat-card"><div className="stat"><span className="label">趋势体重变化</span>
        <span className="value">{e?.actualChangeKg != null ? `${e.actualChangeKg > 0 ? "+" : ""}${fmt(e.actualChangeKg, 1)}` : "—"}<small>kg</small></span>
        <span className="delta">能量差预测 {e ? `${e.predictedChangeKg > 0 ? "+" : ""}${fmt(e.predictedChangeKg, 1)} kg` : "—"}</span></div></div>
      <div className="card stat-card"><div className="stat"><span className="label">按实际数据反推的日消耗</span>
        <span className="value">{e?.empiricalTdee != null ? fmt(e.empiricalTdee) : "—"}<small>kcal</small></span>
        <span className="delta">{e?.empiricalTdee != null ? `公式估算 ${fmt(e.avgTdee)}` : "需 ≥14 天体重与较完整的记录"}</span></div></div>
    </div>
  );
}

function ChartCard({ title, hint, children, table }: { title: string; hint?: ReactNode; children: ReactNode; table: { head: string[]; rows: (string | number | null)[][] } }) {
  const [asTable, setAsTable] = useState(false);
  return (
    <div className="card">
      <div className="card-head">
        <div>
          <h3>{title}</h3>
          {hint && <div className="small muted" style={{ marginTop: 2 }}>{hint}</div>}
        </div>
        <button className="btn ghost sm" onClick={() => setAsTable(!asTable)} aria-pressed={asTable}>
          {asTable ? <ChartLine /> : <Table2 />} {asTable ? "图表" : "表格"}
        </button>
      </div>
      {asTable ? (
        <div className="table-wrap" style={{ maxHeight: 300, overflowY: "auto" }}>
          <table className="table">
            <thead><tr>{table.head.map((h, i) => <th key={i} className={i ? "num" : ""}>{h}</th>)}</tr></thead>
            <tbody>
              {table.rows.map((r, i) => (
                <tr key={i}>{r.map((c, j) => <td key={j} className={j ? "num" : ""}>{c == null ? "—" : typeof c === "number" ? fmt(c, 1) : c}</td>)}</tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : children}
    </div>
  );
}

function ScoreChart({ buckets, unit, t }: { buckets: Bucket[]; unit: string; t: ChartTheme }) {
  const labels = buckets.map((b) => b.label);
  const score = buckets.map((b) => r1(avg(b.logged.map((d) => d.score ?? 0))));
  // 7 日滚动均值（仅逐日视图）
  const rolling = unit === "day" ? score.map((_, i) => r1(avg(score.slice(Math.max(0, i - 6), i + 1).filter((v): v is number => v != null)))) : null;
  const option: EChartsOption = {
    ...baseOption(t, { yMin: 0, yMax: 100, legend: !!rolling }),
    legend: rolling ? { ...legendOption(t), data: ["日评分", "7 日均值"] } : undefined,
    xAxis: { ...(baseOption(t).xAxis as object), data: labels },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; seriesName: string; value: number | null; color: string }[];
        return tipHtml(arr[0]?.axisValue ?? "", arr.map((p) => ({ color: p.color, name: p.seriesName, value: p.value == null ? "无记录" : fmt(p.value, 1) })), t);
      },
    },
    series: [
      lineSeries(unit === "day" ? "日评分" : "平均评分", score, rolling ? t.axis : t.s1, rolling ? { lineStyle: { width: 1.5, color: t.axis }, itemStyle: { color: t.ink3 } } : {}),
      ...(rolling ? [lineSeries("7 日均值", rolling, t.s1, { showSymbol: false })] : []),
    ],
  };
  return (
    <ChartCard title="健康评分" hint="0–100，≥85 优秀 · ≥70 良好 · ≥55 一般" table={{ head: ["日期", "评分", ...(rolling ? ["7 日均值"] : [])], rows: buckets.map((b, i) => [b.label, score[i], ...(rolling ? [rolling[i]] : [])]) }}>
      <EChart option={option} height={260} />
    </ChartCard>
  );
}

function EnergyChart({ buckets, t }: { buckets: Bucket[]; unit: string; t: ChartTheme }) {
  const labels = buckets.map((b) => b.label);
  const intake = buckets.map((b) => r1(avg(b.logged.map((d) => d.intake))));
  const tdee = buckets.map((b) => r1(avg(b.days.map((d) => d.tdee))));
  const target = buckets.map((b) => r1(avg(b.days.map((d) => d.target))));
  const option: EChartsOption = {
    ...baseOption(t, { legend: true, yName: "kcal" }),
    legend: { ...legendOption(t), data: ["摄入", "消耗", "目标"] },
    xAxis: { ...(baseOption(t).xAxis as object), data: labels },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; seriesName: string; value: number | null; color: string }[];
        return tipHtml(arr[0]?.axisValue ?? "", arr.map((p) => ({ color: p.color, name: p.seriesName, value: p.value == null ? "—" : `${fmt(p.value)} kcal` })), t);
      },
    },
    series: [
      lineSeries("摄入", intake, t.s1),
      lineSeries("消耗", tdee, t.s2),
      lineSeries("目标", target, t.s3, { showSymbol: false, lineStyle: { width: 1.5, color: t.s3, type: [4, 4] } }),
    ],
  };
  return (
    <ChartCard title="摄入 vs 消耗" hint="消耗 = 静息代谢 + 活动（设备/步数/运动）+ 食物热效应" table={{ head: ["日期", "摄入", "消耗", "目标"], rows: buckets.map((b, i) => [b.label, intake[i], tdee[i], target[i]]) }}>
      <EChart option={option} height={260} />
    </ChartCard>
  );
}

function WeightChart({ buckets, unit, t, period }: { buckets: Bucket[]; unit: string; t: ChartTheme; period: PeriodScore | null }) {
  const labels = buckets.map((b) => b.label);
  const raw = buckets.map((b) => r1(avg(b.days.map((d) => d.weight).filter((v): v is number => v != null))));
  const trend = buckets.map((b) => {
    const last = [...b.days].reverse().find((d) => d.trend != null);
    return last?.trend ?? null;
  });
  const has = raw.some((v) => v != null);
  const option: EChartsOption = {
    ...baseOption(t, { legend: true, yName: "kg", yMin: "dataMin" }),
    legend: { ...legendOption(t), data: [unit === "day" ? "称重" : "平均称重", "趋势（平滑）"] },
    xAxis: { ...(baseOption(t).xAxis as object), data: labels },
    yAxis: { ...(baseOption(t).yAxis as object), min: (v: { min: number }) => Math.floor(v.min - 1), max: (v: { max: number }) => Math.ceil(v.max + 1) },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; seriesName: string; value: number | null; color: string }[];
        return tipHtml(arr[0]?.axisValue ?? "", arr.map((p) => ({ color: p.color, name: p.seriesName, value: p.value == null ? "—" : `${fmt(p.value, 1)} kg` })), t);
      },
    },
    series: [
      { name: unit === "day" ? "称重" : "平均称重", type: "scatter", data: raw, symbolSize: 8, itemStyle: { color: t.ink3, borderColor: t.surface, borderWidth: 2 } },
      lineSeries("趋势（平滑）", trend, t.s1, { showSymbol: false, connectNulls: true }),
    ],
  };
  return (
    <ChartCard title="体重" hint={period?.energy.ratePerWeek != null ? `趋势每周 ${period.energy.ratePerWeek > 0 ? "+" : ""}${fmt(period.energy.ratePerWeek, 2)} kg（EMA 平滑，过滤每日水分波动）` : "建议每晚睡前固定时间称重"}
      table={{ head: ["日期", "称重", "趋势"], rows: buckets.map((b, i) => [b.label, raw[i], trend[i] == null ? null : r1(trend[i])]) }}>
      {has ? <EChart option={option} height={260} /> : <Empty>这段时间没有体重记录</Empty>}
    </ChartCard>
  );
}

function CategoryChart({ buckets, t }: { buckets: Bucket[]; t: ChartTheme }) {
  const labels = buckets.map((b) => b.label);
  const cats = [
    { key: "hei", zh: "膳食质量", color: t.s1 },
    { key: "adequacy", zh: "营养素充足", color: t.s2 },
    { key: "moderation", zh: "限量控制", color: t.s3 },
  ];
  const data = cats.map((c) => buckets.map((b) => r1(avg(b.logged.map((d) => d.categories[c.key] ?? 0)))));
  const option: EChartsOption = {
    ...baseOption(t, { legend: true, yMin: 0, yMax: 100 }),
    legend: { ...legendOption(t), data: cats.map((c) => c.zh) },
    xAxis: { ...(baseOption(t).xAxis as object), data: labels },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; seriesName: string; value: number | null; color: string }[];
        return tipHtml(arr[0]?.axisValue ?? "", arr.map((p) => ({ color: p.color, name: p.seriesName, value: p.value == null ? "—" : fmt(p.value) })), t);
      },
    },
    series: cats.map((c, i) => lineSeries(c.zh, data[i], c.color)),
  };
  return (
    <ChartCard title="分项得分" hint="各项 0–100（能量平衡见左侧图）" table={{ head: ["日期", ...cats.map((c) => c.zh)], rows: buckets.map((b, i) => [b.label, ...data.map((d) => d[i])]) }}>
      <EChart option={option} height={260} />
    </ChartCard>
  );
}

const EXTRA_METRICS = [
  { key: "macro:satFat", zh: "饱和脂肪供能比", unit: "%" },
  { key: "macro:addedSugar", zh: "添加糖供能比", unit: "%" },
  { key: "macro:protein", zh: "蛋白质供能比", unit: "%" },
  { key: "upf", zh: "超加工食品供能比", unit: "%" },
  { key: "group:processed_meat_g", zh: "加工肉", unit: "g" },
  { key: "group:red_meat_g", zh: "红肉", unit: "g" },
  { key: "group:veg_total_cup", zh: "蔬菜", unit: "杯当量" },
  { key: "group:fruit_total_cup", zh: "水果", unit: "杯当量" },
  { key: "group:grains_whole_oz", zh: "全谷物", unit: "盎司当量" },
  { key: "hei", zh: "HEI-2020 分数", unit: "分" },
  { key: "steps", zh: "步数", unit: "步" },
  { key: "hazard", zh: "风险物扣分", unit: "分" },
];

function NutrientExplorer({ buckets, unit, t, targets }: { buckets: Bucket[]; unit: string; t: ChartTheme; targets: Targets | null }) {
  const { meta } = useApp();
  const [key, setKey] = useState("sodium_mg");
  const nutrient = meta?.nutrients.find((n) => n.key === key);
  const extra = EXTRA_METRICS.find((m) => m.key === key);
  const unitStr = nutrient?.unit ?? extra?.unit ?? "";
  const zh = nutrient?.zh ?? extra?.zh ?? key;
  const pick = (d: TrendDay): number | null => {
    if (key.startsWith("macro:")) return d.macroPct[key.slice(6)] ?? 0;
    if (key.startsWith("group:")) return d.groups[key.slice(6)] ?? 0;
    if (key === "upf") return d.upfPct;
    if (key === "hei") return d.hei;
    if (key === "steps") return d.steps;
    if (key === "hazard") return d.hazardPenalty;
    return d.totals[key] ?? 0;
  };
  const values = buckets.map((b) => {
    const src = key === "steps" ? b.days.filter((d) => d.steps != null) : b.logged;
    return r1(avg(src.map(pick).filter((v): v is number => v != null)));
  });
  // 目标线 / 上限线
  const lines: { name: string; value: number; color: string }[] = [];
  if (targets) {
    const lim = targets.limits[key] ?? (key === "macro:satFat" ? targets.limits.sat_fat_pct : key === "upf" ? targets.limits.upf_pct : undefined);
    if (lim) {
      lines.push({ name: `上限 ${fmt(lim.limit, 1)}`, value: lim.limit, color: t.critical });
      if (lim.ideal > 0 && lim.ideal !== lim.limit) lines.push({ name: `理想 ${fmt(lim.ideal, 1)}`, value: lim.ideal, color: t.good });
    } else if (targets.intake[key]) {
      lines.push({ name: `${targets.intake[key].kind} ${fmt(targets.intake[key].value, 1)}`, value: targets.intake[key].value, color: t.good });
    }
    if (key === "energy_kcal") lines.push({ name: `目标 ${fmt(targets.energyTarget)}`, value: targets.energyTarget, color: t.good });
    if (key === "group:red_meat_g") lines.push({ name: "日均建议 ≤70", value: 70, color: t.critical });
  }
  const option: EChartsOption = {
    ...baseOption(t, { yName: unitStr }),
    xAxis: { ...(baseOption(t).xAxis as object), data: buckets.map((b) => b.label), boundaryGap: true },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      axisPointer: { type: "shadow", shadowStyle: { color: t.hair, opacity: 0.4 } },
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; value: number | null; color: string }[];
        return tipHtml(arr[0]?.axisValue ?? "", [{ color: t.s1, name: zh, value: arr[0]?.value == null ? "无记录" : `${fmt(arr[0].value, 1)} ${unitStr}` }], t);
      },
    },
    series: [{
      name: zh,
      type: "bar",
      data: values,
      barMaxWidth: 24,
      itemStyle: { color: t.s1, borderRadius: [4, 4, 0, 0] },
      markLine: lines.length ? {
        symbol: "none",
        silent: true,
        data: lines.map((l) => ({ yAxis: l.value, name: l.name, lineStyle: { color: l.color, width: 1.5, type: "solid" }, label: { formatter: l.name, color: t.ink2, fontSize: 11, position: "insideEndTop", backgroundColor: t.surface, padding: [1, 4], borderRadius: 4 } })),
      } : undefined,
    }],
  };
  return (
    <ChartCard title={`营养素追踪：${zh}`} hint={`${unit === "day" ? "每日" : unit === "week" ? "每周日均" : "每月日均"}（仅计有记录的天）；横线为你的个人目标/上限`}
      table={{ head: ["日期", `${zh} (${unitStr})`], rows: buckets.map((b, i) => [b.label, values[i]]) }}>
      <div className="row wrap" style={{ marginBottom: 8 }}>
        <select className="input sm" style={{ width: 240 }} value={key} onChange={(e) => setKey(e.target.value)} aria-label="选择指标">
          <optgroup label="营养素">
            {meta?.nutrients.map((n) => <option key={n.key} value={n.key}>{n.zh}（{n.unit}）</option>)}
          </optgroup>
          <optgroup label="其他指标">
            {EXTRA_METRICS.map((m) => <option key={m.key} value={m.key}>{m.zh}（{m.unit}）</option>)}
          </optgroup>
        </select>
      </div>
      <EChart option={option} height={260} />
    </ChartCard>
  );
}

function CalendarHeat({ days, t }: { days: TrendDay[]; t: ChartTheme }) {
  const years = [...new Set(days.map((d) => d.date.slice(0, 4)))].slice(-3);
  const pieces = [
    { min: 85, max: 100, label: "≥85 优秀", color: t.seq[6] },
    { min: 70, max: 85, label: "70–85 良好", color: t.seq[4] },
    { min: 55, max: 70, label: "55–70 一般", color: t.seq[2] },
    { min: 0, max: 55, label: "<55 较差", color: t.seq[0] },
  ];
  const option: EChartsOption = {
    tooltip: {
      backgroundColor: t.surface, borderColor: t.hair, textStyle: { color: t.ink, fontSize: 12 },
      formatter: (p: unknown) => {
        const v = (p as { value: [string, number] }).value;
        return tipHtml(v[0], [{ color: t.s1, name: "日评分", value: fmt(v[1]) }], t);
      },
    },
    visualMap: { type: "piecewise", show: false, pieces, dimension: 1 },
    calendar: years.map((y, i) => ({
      range: y, top: 24 + i * 150, left: 40, right: 10, cellSize: ["auto", 14],
      itemStyle: { color: t.surface, borderColor: t.surface, borderWidth: 2 },
      splitLine: { show: false },
      yearLabel: { color: t.ink3, fontSize: 12, margin: 28 },
      monthLabel: { nameMap: "ZH", color: t.ink3, fontSize: 11 },
      dayLabel: { nameMap: "ZH", color: t.ink3, fontSize: 10, firstDay: 1 },
    })),
    series: years.map((y, i) => ({
      type: "heatmap" as const,
      coordinateSystem: "calendar" as const,
      calendarIndex: i,
      data: days.filter((d) => d.date.startsWith(y) && d.score != null).map((d) => [d.date, Math.round(d.score!)]),
    })),
  };
  return (
    <div className="card">
      <div className="card-head">
        <h3>每日评分日历</h3>
        <div className="cal-legend">
          {pieces.slice().reverse().map((p) => (
            <span key={p.label} className="row" style={{ gap: 4 }}><i style={{ background: p.color }} />{p.label}</span>
          ))}
        </div>
      </div>
      <div style={{ overflowX: "auto" }}>
        <div style={{ minWidth: 720 }}>
          <EChart option={option} height={40 + years.length * 150} />
        </div>
      </div>
    </div>
  );
}

function PassRates({ period, t }: { period: PeriodScore; t: ChartTheme }) {
  const rows = period.itemStats
    .filter((s) => s.category !== "hei")
    .sort((a, b) => (b.bad + b.warn) / b.days - (a.bad + a.warn) / a.days)
    .slice(0, 18);
  return (
    <div className="grid g2">
      <div className="card">
        <div className="card-head"><h3>各项达标天数</h3><span className="hint">按未达标比例排序（{period.start} 至 {period.end}）</span></div>
        <div className="legend" style={{ marginBottom: 10 }}>
          <span><i className="box" style={{ background: t.good }} />达标</span>
          <span><i className="box" style={{ background: t.warning }} />偏离</span>
          <span><i className="box" style={{ background: t.critical }} />不达标</span>
        </div>
        <div className="col" style={{ gap: 8 }}>
          {rows.map((s) => {
            const good = s.good + s.ok;
            return (
              <div key={s.key} className="row" style={{ gap: 10 }} title={`${s.zh}：达标 ${good} 天，偏离 ${s.warn} 天，不达标 ${s.bad} 天`}>
                <span className="small" style={{ width: 128, flexShrink: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{s.zh}</span>
                <div className="stacked-bar grow" role="img" aria-label={`${s.zh} 达标 ${good} 天 偏离 ${s.warn} 天 不达标 ${s.bad} 天`}>
                  {good > 0 && <div style={{ width: `${(good / s.days) * 100}%`, background: t.good }} />}
                  {s.warn > 0 && <div style={{ width: `${(s.warn / s.days) * 100}%`, background: t.warning }} />}
                  {s.bad > 0 && <div style={{ width: `${(s.bad / s.days) * 100}%`, background: t.critical }} />}
                </div>
                <span className="small tnum muted" style={{ width: 52, textAlign: "right" }}>{good}/{s.days}</span>
              </div>
            );
          })}
        </div>
      </div>
      <div className="card">
        <div className="card-head"><h3>周期性指标</h3><span className="hint">只在按周/月看才有意义的标准</span></div>
        <div className="list">
          {period.checks.map((c) => (
            <div key={c.key} className="list-item" style={{ alignItems: "flex-start" }}>
              <StatusBadge status={c.status} />
              <div className="grow">
                <div style={{ fontWeight: 600 }}>{c.zh}</div>
                <div className="small sec">{c.message}</div>
                <div className="small muted">目标：{c.targetText}</div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function HazardTable({ period }: { period: PeriodScore }) {
  return (
    <div className="card">
      <div className="card-head"><h3>风险物暴露汇总</h3></div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>项目</th><th>分级</th><th className="num">出现天数</th><th className="num">累计量</th><th className="num">累计扣分</th></tr></thead>
          <tbody>
            {period.hazards.map((h) => (
              <tr key={h.key}>
                <td>{h.zh}</td>
                <td><IarcChip group={h.iarc} /></td>
                <td className="num">{h.days}</td>
                <td className="num">{fmt(h.dose)} {h.unit}</td>
                <td className="num">{fmt(h.penalty, 1)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
