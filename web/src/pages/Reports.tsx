import { useState } from "react";
import { ChevronLeft, ChevronRight, Sparkles, CircleCheck, CircleX, ArrowUpRight } from "lucide-react";
import { api, waitJob } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { PeriodScore } from "../types";
import { addDays, fmt, localToday, monthEnd, monthStart, weekStart } from "../lib/format";
import { Loading, Meter, Seg, StatusBadge, IarcChip } from "../components/ui";
import { Le8Card, WcrfCard } from "../components/HealthIndices";

export default function Reports() {
  const { me, toast } = useApp();
  const today = me?.today ?? localToday();
  const [kind, setKind] = useState<"week" | "month">("week");
  const [anchor, setAnchor] = useState(addDays(weekStart(today), -7));
  const start = kind === "week" ? weekStart(anchor) : monthStart(anchor);
  const end = kind === "week" ? addDays(start, 6) : monthEnd(anchor);
  const { data, loading, reload } = useLoad(() => api.get<PeriodScore>(`/period?start=${start}&end=${end}`), [start, end]);
  const [gen, setGen] = useState(false);

  const shift = (dir: number) => {
    if (kind === "week") setAnchor(addDays(start, dir * 7));
    else {
      const d = new Date(start + "T00:00:00Z");
      d.setUTCMonth(d.getUTCMonth() + dir);
      setAnchor(d.toISOString().slice(0, 10));
    }
  };

  async function generate() {
    setGen(true);
    try {
      const { job_id } = await api.post<{ job_id: string }>("/period/summary", { start, end });
      await waitJob(job_id);
      reload();
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setGen(false);
    }
  }

  const label = kind === "week" ? `${start} ~ ${end.slice(5)}` : `${start.slice(0, 4)} 年 ${Number(start.slice(5, 7))} 月`;

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>周期报告</h1>
          <div className="sub">总分采用美国心脏协会 Life's Essential 8；每周一自动生成上周报告，每月 1 日生成上月报告（含 AI 点评）</div>
        </div>
        <div className="row wrap">
          <Seg value={kind} onChange={(k) => { setKind(k); setAnchor(k === "week" ? addDays(weekStart(today), -7) : today); }} options={[{ key: "week", label: "周报" }, { key: "month", label: "月报" }]} />
          <div className="date-nav">
            <button className="btn ghost sm icon" onClick={() => shift(-1)} aria-label="上一期"><ChevronLeft /></button>
            <span className="d">{label}</span>
            <button className="btn ghost sm icon" onClick={() => shift(1)} disabled={end >= today} aria-label="下一期"><ChevronRight /></button>
          </div>
        </div>
      </div>

      {loading && !data && <Loading />}
      {data && (
        <div className="stack" style={{ opacity: loading ? 0.55 : 1 }}>
          <div className="grid g-hero">
            <Le8Card ix={data.indices} title="周期总分：心血管健康 LE8" subtitle={`AHA Life's Essential 8 · ${data.daysLogged}/${data.days} 天有记录`} />
            <AiSummary data={data} gen={gen} onGenerate={generate} provider={me?.ai.provider ?? "mock"} />
          </div>

          <div className="grid g4">
            <div className="card stat-card"><div className="stat"><span className="label">HEI-2020（按周期总摄入）</span><span className="value">{fmt(data.hei?.total, 1)}<small>/ 100</small></span><span className="delta">美国人平均 58</span></div></div>
            <div className="card stat-card"><div className="stat"><span className="label">HEI-2020 日均</span><span className="value">{fmt(data.avgHei, 1)}<small>/ 100</small></span></div></div>
            <div className="card stat-card"><div className="stat"><span className="label">微量营养素 MAR 日均</span><span className="value">{fmt(data.avgMar)}<small>/ 100</small></span></div></div>
            <div className="card stat-card"><div className="stat"><span className="label">防癌建议 WCRF/AICR</span><span className="value">{fmt(data.indices.wcrf.score, 2)}<small>/ {data.indices.wcrf.max}</small></span></div></div>
          </div>

          <WcrfCard ix={data.indices} subtitle={`${data.start} 至 ${data.end}`} />

          <div className="grid g2">
            <div className="card">
              <div className="card-head"><h3>其他按周评估的指标</h3><span className="hint">只标状态，不加权</span></div>
              <div className="list">
                {data.checks.map((c) => (
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
            <div className="card">
              <div className="card-head"><h3>能量与体重</h3></div>
              <dl className="kv">
                <dt>日均摄入</dt><dd>{fmt(data.energy.avgIntake)} kcal</dd>
                <dt>日均消耗</dt><dd>{fmt(data.energy.avgTdee)} kcal</dd>
                <dt>累计能量差</dt><dd>{data.energy.totalBalance > 0 ? "+" : ""}{fmt(data.energy.totalBalance)} kcal（≈ {fmt(data.energy.predictedChangeKg, 2)} kg）</dd>
                <dt>趋势体重变化</dt><dd>{data.energy.actualChangeKg != null ? `${data.energy.actualChangeKg > 0 ? "+" : ""}${fmt(data.energy.actualChangeKg, 2)} kg` : "称重数据不足"}</dd>
                <dt>反推日消耗</dt><dd>{data.energy.empiricalTdee != null ? `${fmt(data.energy.empiricalTdee)} kcal` : "需 ≥14 天完整数据"}</dd>
              </dl>
              <hr />
              <h3 style={{ marginBottom: 8 }}>日均关键营养</h3>
              <dl className="kv">
                <dt>钠</dt><dd>{fmt(data.avgTotals.sodium_mg)} mg</dd>
                <dt>添加糖</dt><dd>{fmt(data.avgTotals.added_sugars_g, 1)} g</dd>
                <dt>饱和脂肪</dt><dd>{fmt(data.avgTotals.sat_fat_g, 1)} g</dd>
                <dt>膳食纤维</dt><dd>{fmt(data.avgTotals.fiber_g, 1)} g</dd>
                <dt>蛋白质</dt><dd>{fmt(data.avgTotals.protein_g, 1)} g</dd>
                <dt>钙 / 钾 / 维生素 D</dt><dd>{fmt(data.avgTotals.calcium_mg)} mg / {fmt(data.avgTotals.potassium_mg)} mg / {fmt(data.avgTotals.vit_d_ug, 1)} µg</dd>
              </dl>
            </div>
          </div>

          {data.hazards.length > 0 && (
            <div className="card">
              <div className="card-head"><h3>致癌物与风险物警示</h3><span className="hint">只作警示；加工肉、红肉、酒精、含糖饮料已计入 WCRF 评分</span></div>
              <div className="row wrap">
                {data.hazards.map((h) => (
                  <span key={h.key} className="chip" style={{ padding: "6px 12px" }}>
                    <b>{h.zh}</b> <IarcChip group={h.iarc} /> {h.days} 天 · {fmt(h.dose)} {h.unit}
                  </span>
                ))}
              </div>
            </div>
          )}

          {data.hei && (
            <div className="card">
              <div className="card-head"><h3>HEI-2020 各组分（按周期总量计算）</h3></div>
              <div className="nutrient-grid">
                {data.hei.components.map((c) => {
                  const r = c.score / c.max;
                  return <Meter key={c.key} name={c.zh} value={c.score} unit={`/ ${c.max}`} max={c.max} decimals={1} status={r >= 0.999 ? "good" : r >= 0.6 ? "warn" : "bad"} foot={r < 0.999 ? c.hint : undefined} />;
                })}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function AiSummary({ data, gen, onGenerate, provider }: { data: PeriodScore; gen: boolean; onGenerate: () => void; provider: string }) {
  const s = data.aiSummary;
  return (
    <div className="card">
      <div className="card-head">
        <h2><Sparkles size={18} /> AI 点评</h2>
        {data.daysLogged > 0 && provider !== "mock" && (
          <button className="btn sm" onClick={onGenerate} disabled={gen}>{gen ? <span className="spinner" /> : <Sparkles />} {s ? "重新生成" : "生成点评"}</button>
        )}
      </div>
      {gen && <p className="muted pulse">Claude 正在阅读本期评分数据并撰写点评…</p>}
      {!gen && !s && (
        <p className="muted">
          {provider === "mock" ? "未配置 AI，无法生成点评。离线评分结果仍然完整可用。" : data.daysLogged ? "点击“生成点评”，让 Claude 根据离线评分结果给出下期最值得改进的 3–5 件事。" : "这一期没有记录。"}
        </p>
      )}
      {!gen && s && (
        <div className="stack" style={{ gap: 12 }}>
          <h3 style={{ fontSize: 17 }}>{s.headline}</h3>
          <p className="sec">{s.summary}</p>
          {s.wins.length > 0 && <div>{s.wins.map((w, i) => <div className="issue" key={i}><CircleCheck color="var(--good)" /><span>{w}</span></div>)}</div>}
          {s.issues.length > 0 && <div>{s.issues.map((w, i) => <div className="issue" key={i}><CircleX color="var(--critical)" /><span>{w}</span></div>)}</div>}
          {s.actions.length > 0 && (
            <div className="banner accent" style={{ flexDirection: "column", alignItems: "stretch", gap: 4 }}>
              <b>下期行动</b>
              {s.actions.map((a, i) => <div key={i} className="row" style={{ alignItems: "flex-start" }}><ArrowUpRight size={15} style={{ marginTop: 3 }} />{a}</div>)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
