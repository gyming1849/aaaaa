import { useEffect, useRef } from "react";
import * as echarts from "echarts/core";
import { LineChart, BarChart, ScatterChart, HeatmapChart } from "echarts/charts";
import {
  GridComponent, TooltipComponent, LegendComponent, MarkLineComponent, MarkAreaComponent, CalendarComponent, VisualMapComponent,
} from "echarts/components";
import { SVGRenderer } from "echarts/renderers";
import type { EChartsOption } from "echarts";

echarts.use([
  LineChart, BarChart, ScatterChart, HeatmapChart, GridComponent, TooltipComponent, LegendComponent,
  MarkLineComponent, MarkAreaComponent, CalendarComponent, VisualMapComponent, SVGRenderer,
]);

export function EChart({ option, height = 260, onClick }: { option: EChartsOption; height?: number; onClick?: (p: { name?: string; data?: unknown; dataIndex?: number }) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const chart = useRef<echarts.ECharts | null>(null);

  useEffect(() => {
    if (!ref.current) return;
    chart.current = echarts.init(ref.current, undefined, { renderer: "svg" });
    const ro = new ResizeObserver(() => chart.current?.resize());
    ro.observe(ref.current);
    return () => {
      ro.disconnect();
      chart.current?.dispose();
      chart.current = null;
    };
  }, []);

  useEffect(() => {
    chart.current?.setOption(option, { notMerge: true });
  }, [option]);

  useEffect(() => {
    const c = chart.current;
    if (!c || !onClick) return;
    const h = (p: unknown) => onClick(p as { name?: string; data?: unknown; dataIndex?: number });
    c.on("click", h);
    return () => {
      c.off("click", h);
    };
  }, [onClick]);

  return <div ref={ref} className="chart-box" style={{ height }} />;
}
