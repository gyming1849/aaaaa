import { useEffect, useState } from "react";

// 图表用色：读取 CSS 变量，使明暗主题都使用校验过的色板
export interface ChartTheme {
  dark: boolean;
  surface: string;
  ink: string;
  ink2: string;
  ink3: string;
  hair: string;
  axis: string;
  s1: string;
  s2: string;
  s3: string;
  s4: string;
  s5: string;
  good: string;
  warning: string;
  serious: string;
  critical: string;
  seq: string[];
}

const SEQ_LIGHT = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"];
const SEQ_DARK = ["#0d366b", "#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4", "#cde2fb"];

function read(): ChartTheme {
  const cs = getComputedStyle(document.documentElement);
  const v = (n: string) => cs.getPropertyValue(n).trim();
  const dark = cs.colorScheme.includes("dark") || v("--surface") === "#1a1a19";
  return {
    dark,
    surface: v("--surface"),
    ink: v("--ink"),
    ink2: v("--ink-2"),
    ink3: v("--ink-3"),
    hair: v("--hair"),
    axis: v("--axis"),
    s1: v("--series-1"),
    s2: v("--series-2"),
    s3: v("--series-3"),
    s4: v("--series-4"),
    s5: v("--series-5"),
    good: v("--good"),
    warning: v("--warning"),
    serious: v("--serious"),
    critical: v("--critical"),
    seq: dark ? SEQ_DARK : SEQ_LIGHT,
  };
}

export function applyTheme(pref: string | null) {
  if (pref === "light" || pref === "dark") document.documentElement.dataset.theme = pref;
  else delete document.documentElement.dataset.theme;
}

export function useChartTheme(): ChartTheme {
  const [t, setT] = useState<ChartTheme>(() => read());
  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => setT(read());
    mq.addEventListener("change", update);
    const obs = new MutationObserver(update);
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      mq.removeEventListener("change", update);
      obs.disconnect();
    };
  }, []);
  return t;
}
