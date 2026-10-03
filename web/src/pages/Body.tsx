import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import type { EChartsOption } from "echarts";
import { Scale, Flame, Sparkles, Trash2, Smartphone, Upload, Footprints, Copy, Check, Camera } from "lucide-react";
import { ActivityRecognizer } from "../components/ActivityRecognizer";
import { api, qs } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { ActivityDay, BodyMetric, Exercise, TrendDay } from "../types";
import { addDays, fmt, localToday } from "../lib/format";
import { useChartTheme } from "../lib/theme";
import { baseOption, lineSeries, legendOption, tipHtml } from "../lib/charts";
import { EChart } from "../components/EChart";
import { Empty, Modal, Seg } from "../components/ui";

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
  const [w, setW] = useState({ weight_kg: "", body_fat_pct: "", waist_cm: "", sbp: "", dbp: "", bp_treated: false, time: "22:00" });
  async function addWeight() {
    try {
      await api.post("/body", { date, time: w.time, weight_kg: w.weight_kg || null, body_fat_pct: w.body_fat_pct || null, waist_cm: w.waist_cm || null, sbp: w.sbp || null, dbp: w.dbp || null, bp_treated: w.bp_treated });
      toast("已记录");
      setW({ ...w, weight_kg: "", body_fat_pct: "", waist_cm: "", sbp: "", dbp: "" });
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
      await api.put(`/activity/${date}`, {
        steps: adv("steps") || null, active_kcal: adv("active_kcal") || null, resting_kcal: adv("resting_kcal") || null,
        distance_km: adv("distance_km") || null, exercise_min: adv("exercise_min") || null, sleep_hours: adv("sleep_hours") || null, stand_hours: adv("stand_hours") || null,
      });
      toast("已保存");
      setAd({});
      act.reload();
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }

  // 运动 / 活动：统一走 AI 识别（文字或截图）→ 预览 → 合并
  const [recog, setRecog] = useState<"ai" | "manual" | null>(null);
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
            <div className="field"><label>血压（可选）</label>
              <div className="row">
                <input className="input" type="number" placeholder="收缩压" value={w.sbp} onChange={(e) => setW({ ...w, sbp: e.target.value })} aria-label="收缩压" />
                <span className="muted">/</span>
                <input className="input" type="number" placeholder="舒张压" value={w.dbp} onChange={(e) => setW({ ...w, dbp: e.target.value })} aria-label="舒张压" />
              </div>
              {w.sbp && <label className="check small"><input type="checkbox" checked={w.bp_treated} onChange={(e) => setW({ ...w, bp_treated: e.target.checked })} />正在服用降压药</label>}
            </div>
          </div>
          <button className="btn primary" onClick={addWeight} disabled={!w.weight_kg && !w.body_fat_pct && !w.waist_cm && !w.sbp}>保存</button>
          <div className="list" style={{ maxHeight: 220, overflowY: "auto" }}>
            {(body.data ?? []).slice(0, 30).map((b) => (
              <div className="list-item" key={b.id}>
                <span className="tnum small muted" style={{ width: 92 }}>{b.date.slice(5)} {b.time}</span>
                <span className="grow tnum">{b.weight_kg != null && <b>{fmt(b.weight_kg, 1)} kg</b>}{b.body_fat_pct != null && ` · 体脂 ${fmt(b.body_fat_pct, 1)}%`}{b.waist_cm != null && ` · 腰围 ${fmt(b.waist_cm, 1)} cm`}{b.sbp != null && ` · 血压 ${fmt(b.sbp)}/${fmt(b.dbp)}`}</span>
                <span className="small muted">{b.source === "manual" ? "" : b.source === "profile" ? "建档" : b.source === "ai" ? "AI 识别" : "苹果健康"}</span>
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
          <div className="banner accent" style={{ flexDirection: "column", alignItems: "stretch", gap: 8 }}>
            <span>说一句“游泳 5km”“打了两小时羽毛球”，或上传手表的运动记录截图，由 {me?.ai.provider === "mock" ? "离线规则" : me?.ai.model} 按 2024 运动代谢当量表识别，先预览再合并。</span>
            <div className="row">
              <button className="btn primary sm" onClick={() => setRecog("ai")}><Sparkles /> AI 识别运动 / 截图</button>
            </div>
          </div>
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
            <div className="field"><label>睡眠（小时）</label><input className="input" type="number" step="0.1" value={adv("sleep_hours")} onChange={(e) => setAd({ ...ad, sleep_hours: e.target.value })} /></div>
            <div className="field"><label>站立（小时，可选）</label><input className="input" type="number" value={adv("stand_hours")} onChange={(e) => setAd({ ...ad, stand_hours: e.target.value })} /></div>
          </div>
          <div className="row wrap">
            <button className="btn" onClick={saveActivity}>保存 {date} 的活动数据</button>
            <button className="btn primary" onClick={() => setRecog("ai")}><Camera /> 上传健康截图识别</button>
          </div>
          <p className="small muted">有“活动能量”时，消耗 = 静息 + 活动能量 + 未被设备记录的运动；只有步数时按步长与体重估算。</p>
          {days.some((d) => d.steps != null) && <EChart option={stepsOpt} height={180} />}
        </div>
      </div>

      <Labs date={date} />
      <AppleHealth />
      {recog && <ActivityRecognizer date={date} current={day} mode={recog} onClose={() => setRecog(null)} onDone={() => { setRecog(null); act.reload(); body.reload(); }} />}
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

interface Lab { id: number; date: string; total_chol: number | null; hdl: number | null; non_hdl: number | null; ldl: number | null; lipid_treated: number; fasting_glucose: number | null; hba1c: number | null; diabetes: number }

/** 体检化验指标：用于 AHA Life's Essential 8 的血脂与血糖两项 */
function Labs({ date }: { date: string }) {
  const { toast } = useApp();
  const labs = useLoad(() => api.get<Lab[]>("/labs"), []);
  const [f, setF] = useState({ date, total_chol: "", hdl: "", ldl: "", fasting_glucose: "", hba1c: "", lipid_treated: false, diabetes: false, unit: "mgdl" as "mgdl" | "mmol" });
  // 国内化验单常用 mmol/L：胆固醇 × 38.67，血糖 × 18 换算为 mg/dL
  const conv = (v: string, factor: number) => (v === "" ? null : f.unit === "mmol" ? Math.round(Number(v) * factor) : Number(v));
  async function save() {
    try {
      await api.post("/labs", {
        date: f.date, total_chol: conv(f.total_chol, 38.67), hdl: conv(f.hdl, 38.67), ldl: conv(f.ldl, 38.67),
        fasting_glucose: conv(f.fasting_glucose, 18), hba1c: f.hba1c === "" ? null : Number(f.hba1c), lipid_treated: f.lipid_treated, diabetes: f.diabetes,
      });
      toast("已保存化验结果");
      setF({ ...f, total_chol: "", hdl: "", ldl: "", fasting_glucose: "", hba1c: "" });
      labs.reload();
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }
  const u = f.unit === "mmol" ? "mmol/L" : "mg/dL";
  return (
    <div className="card stack">
      <div className="card-head" style={{ marginBottom: 0 }}>
        <h2>体检化验指标</h2>
        <span className="hint">用于美国心脏协会 LE8 的血脂、血糖两项；不填则这两项不计入</span>
      </div>
      <div className="row wrap">
        <input className="input sm" type="date" style={{ width: 160 }} value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} aria-label="化验日期" />
        <Seg value={f.unit} onChange={(v) => setF({ ...f, unit: v })} options={[{ key: "mmol", label: "mmol/L（国内常用）" }, { key: "mgdl", label: "mg/dL" }]} />
      </div>
      <div className="grid g3">
        <div className="field"><label>总胆固醇</label><div className="input-affix"><input className="input" type="number" step="any" value={f.total_chol} onChange={(e) => setF({ ...f, total_chol: e.target.value })} /><span className="affix">{u}</span></div></div>
        <div className="field"><label>高密度脂蛋白 HDL</label><div className="input-affix"><input className="input" type="number" step="any" value={f.hdl} onChange={(e) => setF({ ...f, hdl: e.target.value })} /><span className="affix">{u}</span></div></div>
        <div className="field"><label>低密度脂蛋白 LDL（可选）</label><div className="input-affix"><input className="input" type="number" step="any" value={f.ldl} onChange={(e) => setF({ ...f, ldl: e.target.value })} /><span className="affix">{u}</span></div></div>
        <div className="field"><label>空腹血糖</label><div className="input-affix"><input className="input" type="number" step="any" value={f.fasting_glucose} onChange={(e) => setF({ ...f, fasting_glucose: e.target.value })} /><span className="affix">{u}</span></div></div>
        <div className="field"><label>糖化血红蛋白 HbA1c</label><div className="input-affix"><input className="input" type="number" step="0.1" value={f.hba1c} onChange={(e) => setF({ ...f, hba1c: e.target.value })} /><span className="affix">%</span></div></div>
        <div className="field">
          <label>用药 / 诊断</label>
          <label className="check small"><input type="checkbox" checked={f.lipid_treated} onChange={(e) => setF({ ...f, lipid_treated: e.target.checked })} />服用降脂药</label>
          <label className="check small"><input type="checkbox" checked={f.diabetes} onChange={(e) => setF({ ...f, diabetes: e.target.checked })} />已诊断糖尿病</label>
        </div>
      </div>
      <button className="btn" style={{ alignSelf: "flex-start" }} onClick={save}>保存化验结果</button>
      {labs.data && labs.data.length > 0 && (
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>日期</th><th className="num">非 HDL 胆固醇</th><th className="num">空腹血糖</th><th className="num">HbA1c</th><th></th></tr></thead>
            <tbody>
              {labs.data.map((l) => (
                <tr key={l.id}>
                  <td>{l.date}</td>
                  <td className="num">{l.non_hdl != null ? `${fmt(l.non_hdl)} mg/dL` : "—"}{l.lipid_treated ? "（服药）" : ""}</td>
                  <td className="num">{l.fasting_glucose != null ? `${fmt(l.fasting_glucose)} mg/dL` : "—"}</td>
                  <td className="num">{l.hba1c != null ? `${l.hba1c}%` : "—"}{l.diabetes ? "（糖尿病）" : ""}</td>
                  <td><button className="btn ghost sm icon danger" aria-label="删除" onClick={async () => { await api.del(`/labs/${l.id}`); labs.reload(); }}><Trash2 /></button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
