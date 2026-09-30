import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import type { EChartsOption } from "echarts";
import { Scale, Flame, Sparkles, Trash2, Smartphone, Upload, Footprints, Copy, Check } from "lucide-react";
import { api, qs, waitJob } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { ActivityDay, BodyMetric, Exercise, TrendDay } from "../types";
import { addDays, fmt, localToday, nowTime } from "../lib/format";
import { useChartTheme } from "../lib/theme";
import { baseOption, lineSeries, legendOption, tipHtml } from "../lib/charts";
import { EChart } from "../components/EChart";
import { Empty, Modal } from "../components/ui";

interface ExDraft { description: string; activity_key: string; met: number; duration_min: number; distance_km: number; kcal: number; notes: string; in_device?: boolean }

export default function Body() {
  const { me, meta, toast } = useApp();
  const [sp] = useSearchParams();
  const today = me?.today ?? localToday();
  const [date, setDate] = useState(sp.get("date") ?? today);
  const t = useChartTheme();

  const body = useLoad(() => api.get<BodyMetric[]>(`/body${qs({ start: addDays(today, -365) })}`), []);
  const act = useLoad(() => api.get<{ days: ActivityDay[]; exercises: Exercise[] }>(`/activity${qs({ start: addDays(date, -30), end: date })}`), [date]);
  const trend = useLoad(() => api.get<{ days: TrendDay[] }>(`/trends${qs({ start: addDays(today, -89), end: today })}`), [body.data]);

  // 体重
  const [w, setW] = useState({ weight_kg: "", body_fat_pct: "", waist_cm: "", time: "22:00" });
  async function addWeight() {
    try {
      await api.post("/body", { date, time: w.time, weight_kg: w.weight_kg || null, body_fat_pct: w.body_fat_pct || null, waist_cm: w.waist_cm || null });
      toast("已记录");
      setW({ ...w, weight_kg: "", body_fat_pct: "", waist_cm: "" });
      body.reload();
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }

  // 当日活动
  const day = act.data?.days.find((d) => d.date === date);
  const [ad, setAd] = useState<Record<string, string>>({});
  const adv = (k: keyof ActivityDay) => ad[k] ?? (day?.[k] != null ? String(day[k]) : "");
  async function saveActivity() {
    try {
      await api.put(`/activity/${date}`, { steps: adv("steps") || null, active_kcal: adv("active_kcal") || null, resting_kcal: adv("resting_kcal") || null, distance_km: adv("distance_km") || null, exercise_min: adv("exercise_min") || null });
      toast("已保存");
      setAd({});
      act.reload();
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }

  // 运动：AI 解析
  const [exText, setExText] = useState("");
  const [exBusy, setExBusy] = useState(false);
  const [drafts, setDrafts] = useState<ExDraft[]>([]);
  async function parseEx() {
    if (!exText.trim()) return;
    setExBusy(true);
    try {
      const { job_id } = await api.post<{ job_id: string }>("/ai/exercise", { text: exText, date });
      const r = await waitJob<{ items: ExDraft[] }>(job_id);
      setDrafts(r.items.map((x) => ({ ...x, in_device: !!day?.active_kcal })));
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setExBusy(false);
    }
  }
  async function saveEx() {
    for (const d of drafts) {
      await api.post("/exercises", { date, time: nowTime(), description: d.description, activity_key: d.activity_key, met: d.met, duration_min: d.duration_min, distance_km: d.distance_km || null, in_device: d.in_device, source: "ai" });
    }
    toast("已记录运动");
    setDrafts([]);
    setExText("");
    act.reload();
  }
  const [manual, setManual] = useState({ activity_key: "walk_brisk", duration_min: "30" });

  const todaysEx = act.data?.exercises.filter((e) => e.date === date) ?? [];

  const days = trend.data?.days ?? [];
  const weightOpt: EChartsOption = {
    ...baseOption(t, { legend: true, yName: "kg" }),
    legend: { ...legendOption(t), data: ["称重", "趋势（平滑）"] },
    xAxis: { ...(baseOption(t).xAxis as object), data: days.map((d) => d.date.slice(5)) },
    yAxis: { ...(baseOption(t).yAxis as object), min: (v: { min: number }) => Math.floor(v.min - 1), max: (v: { max: number }) => Math.ceil(v.max + 1) },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; seriesName: string; value: number | null; color: string }[];
        return tipHtml(arr[0]?.axisValue ?? "", arr.map((p) => ({ color: p.color, name: p.seriesName, value: p.value == null ? "—" : `${fmt(p.value, 1)} kg` })), t);
      },
    },
    series: [
      { name: "称重", type: "scatter", data: days.map((d) => d.weight), symbolSize: 8, itemStyle: { color: t.ink3, borderColor: t.surface, borderWidth: 2 } },
      lineSeries("趋势（平滑）", days.map((d) => d.trend), t.s1, { showSymbol: false, connectNulls: true }),
    ],
  };
  const stepsOpt: EChartsOption = {
    ...baseOption(t, { yName: "步" }),
    xAxis: { ...(baseOption(t).xAxis as object), data: days.slice(-30).map((d) => d.date.slice(5)), boundaryGap: true },
    tooltip: {
      ...(baseOption(t).tooltip as object),
      axisPointer: { type: "shadow", shadowStyle: { color: t.hair, opacity: 0.4 } },
      formatter: (ps: unknown) => {
        const arr = ps as { axisValue: string; value: number | null }[];
        return tipHtml(arr[0]?.axisValue ?? "", [{ color: t.s1, name: "步数", value: arr[0]?.value == null ? "—" : fmt(arr[0].value) }], t);
      },
    },
    series: [{ name: "步数", type: "bar", data: days.slice(-30).map((d) => d.steps), barMaxWidth: 20, itemStyle: { color: t.s1, borderRadius: [4, 4, 0, 0] } }],
  };

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>身体与运动</h1>
          <div className="sub">睡前称重 + 步数/活动能量 + 运动记录，和饮食摄入交叉对照</div>
        </div>
        <input className="input" style={{ width: 170 }} type="date" value={date} max={today} onChange={(e) => setDate(e.target.value)} aria-label="日期" />
      </div>

      <div className="grid g2">
        <div className="card stack">
          <div className="card-head" style={{ marginBottom: 0 }}><h2><Scale size={18} /> 记录体重</h2><span className="hint">建议每晚睡前、同一时间称</span></div>
          <div className="grid g2">
            <div className="field"><label>体重</label><div className="input-affix"><input className="input" type="number" step="0.1" inputMode="decimal" value={w.weight_kg} onChange={(e) => setW({ ...w, weight_kg: e.target.value })} /><span className="affix">kg</span></div></div>
            <div className="field"><label>时间</label><input className="input" type="time" value={w.time} onChange={(e) => setW({ ...w, time: e.target.value })} /></div>
            <div className="field"><label>体脂率（可选）</label><div className="input-affix"><input className="input" type="number" step="0.1" value={w.body_fat_pct} onChange={(e) => setW({ ...w, body_fat_pct: e.target.value })} /><span className="affix">%</span></div></div>
            <div className="field"><label>腰围（可选）</label><div className="input-affix"><input className="input" type="number" step="0.5" value={w.waist_cm} onChange={(e) => setW({ ...w, waist_cm: e.target.value })} /><span className="affix">cm</span></div></div>
          </div>
          <button className="btn primary" onClick={addWeight} disabled={!w.weight_kg && !w.body_fat_pct && !w.waist_cm}>保存</button>
          <div className="list" style={{ maxHeight: 220, overflowY: "auto" }}>
            {(body.data ?? []).slice(0, 30).map((b) => (
              <div className="list-item" key={b.id}>
                <span className="tnum small muted" style={{ width: 92 }}>{b.date.slice(5)} {b.time}</span>
                <span className="grow tnum">{b.weight_kg != null && <b>{fmt(b.weight_kg, 1)} kg</b>}{b.body_fat_pct != null && ` · 体脂 ${fmt(b.body_fat_pct, 1)}%`}{b.waist_cm != null && ` · 腰围 ${fmt(b.waist_cm, 1)} cm`}</span>
                <span className="small muted">{b.source === "manual" ? "" : b.source === "profile" ? "建档" : "苹果健康"}</span>
                <button className="btn ghost sm icon danger" aria-label="删除" onClick={async () => { await api.del(`/body/${b.id}`); body.reload(); }}><Trash2 /></button>
              </div>
            ))}
          </div>
        </div>
        <div className="card">
          <div className="card-head"><h2>近 90 天体重</h2></div>
          {days.some((d) => d.weight != null) ? <EChart option={weightOpt} height={320} /> : <Empty icon={<Scale />}>还没有体重记录</Empty>}
        </div>
      </div>

      <div className="grid g2">
        <div className="card stack">
          <div className="card-head" style={{ marginBottom: 0 }}><h2><Flame size={18} /> 记录运动</h2><span className="hint">{date}</span></div>
          <div className="field">
            <label>用一句话描述（AI 按 2024 运动代谢当量表换算）</label>
            <div className="row">
              <input className="input grow" value={exText} onChange={(e) => setExText(e.target.value)} placeholder="例：游泳 5km；晚上快走 40 分钟；打了两小时羽毛球" onKeyDown={(e) => e.key === "Enter" && parseEx()} />
              <button className="btn primary" onClick={parseEx} disabled={exBusy || !exText.trim()}>{exBusy ? <span className="spinner" /> : <Sparkles />} 解析</button>
            </div>
          </div>
          {drafts.length > 0 && (
            <div className="col">
              {drafts.map((d, i) => (
                <div key={i} className="item-edit">
                  <div className="row wrap">
                    <b className="grow">{d.description}</b>
                    <span className="chip">{meta?.activities.find((a) => a.key === d.activity_key)?.zh}</span>
                    <span className="chip">MET {d.met}</span>
                  </div>
                  <div className="row wrap small">
                    <label className="row">时长 <input className="input sm" style={{ width: 80 }} type="number" value={d.duration_min}
                      onChange={(e) => setDrafts((x) => x.map((y, j) => (j === i ? { ...y, duration_min: Number(e.target.value), kcal: Math.round(((y.met - 1) * (me?.profile?.weight_kg ?? 65) * Number(e.target.value)) / 60) } : y)))} /> 分钟</label>
                    {d.distance_km > 0 && <span className="muted">{fmt(d.distance_km, 1)} km</span>}
                    <span>净消耗约 <b>{fmt(d.kcal)}</b> kcal</span>
                  </div>
                  <label className="check small"><input type="checkbox" checked={!!d.in_device} onChange={(e) => setDrafts((x) => x.map((y, j) => (j === i ? { ...y, in_device: e.target.checked } : y)))} />手表/手机已记录这次运动（已含在活动能量中，避免重复计算）</label>
                  {d.notes && <span className="small muted">{d.notes}</span>}
                </div>
              ))}
              <button className="btn primary" onClick={saveEx}>保存运动</button>
            </div>
          )}
          <details>
            <summary className="small sec" style={{ cursor: "pointer" }}>手动选择运动类型</summary>
            <div className="row wrap" style={{ marginTop: 8 }}>
              <select className="input sm" style={{ width: 200 }} value={manual.activity_key} onChange={(e) => setManual({ ...manual, activity_key: e.target.value })}>
                {meta?.activities.map((a) => <option key={a.key} value={a.key}>{a.zh}（MET {a.met}）</option>)}
              </select>
              <input className="input sm" style={{ width: 90 }} type="number" value={manual.duration_min} onChange={(e) => setManual({ ...manual, duration_min: e.target.value })} aria-label="分钟" />
              <span className="small muted">分钟</span>
              <button className="btn sm" onClick={async () => { await api.post("/exercises", { date, ...manual, in_device: !!day?.active_kcal }); act.reload(); toast("已记录"); }}>添加</button>
            </div>
          </details>
          <div className="list">
            {todaysEx.map((e) => (
              <div className="list-item" key={e.id}>
                <Flame size={16} color="var(--series-2)" />
                <div className="grow">
                  <div>{e.description} <span className="small muted">{fmt(e.duration_min)} 分钟 · MET {e.met}{e.distance_km ? ` · ${fmt(e.distance_km, 1)} km` : ""}</span></div>
                  <label className="check small muted"><input type="checkbox" checked={!!e.in_device} onChange={async (ev) => { await api.patch(`/exercises/${e.id}`, { in_device: ev.target.checked }); act.reload(); }} />已含在设备活动能量中</label>
                </div>
                <span className="tnum">{fmt(e.kcal)} kcal</span>
                <button className="btn ghost sm icon danger" aria-label="删除" onClick={async () => { await api.del(`/exercises/${e.id}`); act.reload(); }}><Trash2 /></button>
              </div>
            ))}
            {!todaysEx.length && <p className="small muted">这一天还没有运动记录</p>}
          </div>
        </div>

        <div className="card stack">
          <div className="card-head" style={{ marginBottom: 0 }}><h2><Footprints size={18} /> 步数与活动能量</h2><span className="hint">{day ? `来源：${day.source === "manual" ? "手动" : day.source === "apple_shortcut" ? "iPhone 快捷指令" : "苹果健康导出"}` : "未记录"}</span></div>
          <div className="grid g2">
            <div className="field"><label>步数</label><input className="input" type="number" value={adv("steps")} onChange={(e) => setAd({ ...ad, steps: e.target.value })} /></div>
            <div className="field"><label>活动能量</label><div className="input-affix"><input className="input" type="number" value={adv("active_kcal")} onChange={(e) => setAd({ ...ad, active_kcal: e.target.value })} /><span className="affix">kcal</span></div></div>
            <div className="field"><label>静息能量（可选）</label><div className="input-affix"><input className="input" type="number" value={adv("resting_kcal")} onChange={(e) => setAd({ ...ad, resting_kcal: e.target.value })} /><span className="affix">kcal</span></div></div>
            <div className="field"><label>锻炼分钟（可选）</label><input className="input" type="number" value={adv("exercise_min")} onChange={(e) => setAd({ ...ad, exercise_min: e.target.value })} /></div>
          </div>
          <button className="btn" onClick={saveActivity}>保存 {date} 的活动数据</button>
          <p className="small muted">有“活动能量”时，消耗 = 静息 + 活动能量 + 未被设备记录的运动；只有步数时按步长与体重估算。</p>
          {days.some((d) => d.steps != null) && <EChart option={stepsOpt} height={180} />}
        </div>
      </div>

      <AppleHealth />
    </div>
  );
}

function AppleHealth() {
  const { me, toast, refreshMe } = useApp();
  const [token, setToken] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [since, setSince] = useState(addDays(localToday(), -365));
  const [busy, setBusy] = useState(false);
  const [guide, setGuide] = useState(false);
  const url = `${window.location.origin}/api/health/ingest`;

  async function genToken() {
    if (me?.user.api_token_hint && !confirm("重新生成后旧 Token 立即失效，快捷指令需要更新。继续？")) return;
    const r = await api.post<{ token: string }>("/settings/token");
    setToken(r.token);
    refreshMe();
  }
  async function importFile() {
    if (!file) return;
    setBusy(true);
    try {
      const fd = new FormData();
      fd.append("file", file);
      fd.append("since", since);
      const r = await api.post<{ records: number; days: number; weights: number }>("/health/import", fd);
      toast(`导入完成：${r.days} 天活动数据、${r.weights} 条体重（共解析 ${r.records} 条记录）`);
      setFile(null);
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }
  const sample = `{"steps": 8532, "active_kcal": 412, "resting_kcal": 1620, "distance_km": 6.1, "exercise_min": 35, "weight_kg": 68.2}`;
  return (
    <div className="card">
      <div className="card-head"><h2><Smartphone size={18} /> 连接苹果健康</h2></div>
      <div className="grid g2">
        <div className="stack" style={{ gap: 10 }}>
          <h3>方式一：iPhone 快捷指令每天自动同步</h3>
          <p className="small sec">网页无法直接读取 HealthKit。用“快捷指令 → 自动化”每晚定时读取当天的步数、活动能量、静息能量、体重，POST 到下面的地址即可。</p>
          <div className="field"><label>接口地址</label><input className="input sm" readOnly value={url} onFocus={(e) => e.target.select()} /></div>
          <div className="row wrap">
            <button className="btn sm" onClick={genToken}>{me?.user.api_token_hint ? "重新生成 Token" : "生成个人 Token"}</button>
            {me?.user.api_token_hint && !token && <span className="small muted">当前：{me.user.api_token_hint}</span>}
            <button className="btn ghost sm" onClick={() => setGuide(true)}>查看设置步骤</button>
          </div>
          {token && (
            <div className="banner accent" style={{ flexDirection: "column", alignItems: "stretch" }}>
              <span className="small">只显示这一次，请复制保存：</span>
              <div className="row">
                <code className="grow" style={{ wordBreak: "break-all", fontSize: 13 }}>{token}</code>
                <button className="btn sm" onClick={() => { navigator.clipboard?.writeText(token); setCopied(true); }}>{copied ? <Check /> : <Copy />}</button>
              </div>
            </div>
          )}
        </div>
        <div className="stack" style={{ gap: 10 }}>
          <h3>方式二：导入“健康”App 的导出文件</h3>
          <p className="small sec">健康 App → 右上角头像 → 导出所有健康数据，得到 export.zip（或解压后的 export.xml）。会导入每日步数、活动/静息能量、步行距离、锻炼分钟、体重和体脂；iPhone 与 Apple Watch 的重复数据会自动去重。</p>
          <div className="row wrap">
            <input type="file" accept=".xml,.zip" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
          </div>
          <div className="row wrap">
            <span className="small sec">导入起始日期</span>
            <input className="input sm" type="date" style={{ width: 160 }} value={since} onChange={(e) => setSince(e.target.value)} />
            <button className="btn primary sm" disabled={!file || busy} onClick={importFile}>{busy ? <span className="spinner" /> : <Upload />} 导入</button>
          </div>
        </div>
      </div>
      {guide && (
        <Modal title="iPhone 快捷指令设置步骤" onClose={() => setGuide(false)}>
          <ol className="sec" style={{ paddingLeft: 20, margin: 0, lineHeight: 1.9 }}>
            <li>打开“快捷指令” App → 新建快捷指令。</li>
            <li>添加“查找健康样本”：类型选<b>步数</b>，开始日期“今天”，分组“按天”，计算“总和”。再分别为<b>活动能量</b>、<b>静息能量</b>、<b>体重</b>（取最新 1 条）各添加一次。</li>
            <li>添加“字典”，键为 <code>steps</code>、<code>active_kcal</code>、<code>resting_kcal</code>、<code>weight_kg</code>（可选 <code>distance_km</code>、<code>exercise_min</code>、<code>date</code>），值选上一步的结果。</li>
            <li>添加“获取 URL 内容”：URL 填 <code>{url}</code>，方法 POST，请求体 JSON 选择上面的字典；头部添加 <code>Authorization</code> = <code>Bearer 你的Token</code>。</li>
            <li>在“自动化”里设定每天 23:30 运行（关闭“运行前询问”）。</li>
          </ol>
          <p className="small muted" style={{ marginTop: 10 }}>请求体示例：</p>
          <pre style={{ background: "var(--surface-2)", padding: 10, borderRadius: 8, fontSize: 12, whiteSpace: "pre-wrap" }}>{sample}</pre>
          <p className="small muted">数值带千分位或单位（如 “8,532”、“412 kcal”）也能识别；不传 date 时按你的时区记为今天。</p>
        </Modal>
      )}
    </div>
  );
}
