// 图表公共样式：细线条、实线发丝网格、弱化坐标轴、十字准线 + 统一提示框（数值在前，系列名在后，线段图例）
import type { EChartsOption, LineSeriesOption } from "echarts";
import type { ChartTheme } from "./theme";
import { fmt } from "./format";

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export interface TipRow {
  color: string;
  name: string;
  value: string;
}

export function tipHtml(title: string, rows: TipRow[], t: ChartTheme): string {
  return `<div style="font-size:12px;color:${t.ink3};margin-bottom:4px">${esc(title)}</div>` +
    rows
      .map(
        (r) =>
          `<div style="display:flex;align-items:center;gap:8px;line-height:1.7">` +
          `<span style="width:12px;height:3px;border-radius:2px;background:${r.color};display:inline-block"></span>` +
          `<b style="color:${t.ink};font-weight:650;font-variant-numeric:tabular-nums">${esc(r.value)}</b>` +
          `<span style="color:${t.ink2}">${esc(r.name)}</span></div>`,
      )
      .join("");
}

export function baseOption(t: ChartTheme, opts: { yName?: string; yMin?: number | "dataMin"; yMax?: number; legend?: boolean } = {}): EChartsOption {
  return {
    animationDuration: 400,
    textStyle: { fontFamily: "system-ui, -apple-system, 'PingFang SC', 'Noto Sans SC', sans-serif", color: t.ink2 },
    grid: { left: 8, right: 16, top: opts.legend ? 36 : 16, bottom: 8, containLabel: true },
    tooltip: {
      trigger: "axis",
      backgroundColor: t.surface,
      borderColor: t.hair,
      borderWidth: 1,
      padding: [8, 12],
      textStyle: { color: t.ink, fontSize: 12 },
      extraCssText: "box-shadow:0 6px 24px rgba(0,0,0,.12);border-radius:10px;",
      axisPointer: { type: "line", lineStyle: { color: t.axis, width: 1 } },
    },
    xAxis: {
      type: "category",
      boundaryGap: false,
      axisLine: { lineStyle: { color: t.axis } },
      axisTick: { show: false },
      axisLabel: { color: t.ink3, fontSize: 11, hideOverlap: true },
    },
    yAxis: {
      type: "value",
      name: opts.legend ? undefined : opts.yName,
      nameTextStyle: { color: t.ink3, fontSize: 11, align: "left" },
      min: opts.yMin,
      max: opts.yMax,
      splitLine: { lineStyle: { color: t.hair, width: 1, type: "solid" } },
      axisLabel: { color: t.ink3, fontSize: 11, formatter: (v: number) => fmt(v, 1) },
    },
  };
}

export function lineSeries(name: string, data: (number | null)[], color: string, extra: Partial<LineSeriesOption> = {}): LineSeriesOption {
  return {
    name,
    type: "line",
    data,
    connectNulls: false,
    smooth: false,
    symbol: "circle",
    symbolSize: 7,
    showSymbol: data.length <= 45,
    lineStyle: { width: 2, color, cap: "round", join: "round" },
    itemStyle: { color, borderColor: "transparent" },
    emphasis: { scale: 1.4 },
    ...extra,
  };
}

export function legendOption(t: ChartTheme) {
  return {
    top: 0,
    left: 0,
    icon: "roundRect",
    itemWidth: 14,
    itemHeight: 3,
    textStyle: { color: t.ink2, fontSize: 12 },
  };
}
