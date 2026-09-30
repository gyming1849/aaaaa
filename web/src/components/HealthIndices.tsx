// AHA Life's Essential 8、WCRF/AICR 防癌评分与 MEPA 饮食问卷的展示
import { useState } from "react";
import { HeartPulse, ShieldCheck, ChevronDown, ChevronUp } from "lucide-react";
import type { HealthIndices } from "../types";
import { fmt } from "../lib/format";
import { Meter, ScoreRing, Modal } from "./ui";

const le8Status = (p: number) => (p >= 80 ? "good" : p >= 50 ? "warn" : "bad") as "good" | "warn" | "bad";

export function Le8Card({ ix, title = "心血管健康 Life's Essential 8", subtitle }: { ix: HealthIndices; title?: string; subtitle?: string }) {
  const le8 = ix.le8;
  const [mepaOpen, setMepaOpen] = useState(false);
  return (
    <div className="card">
      <div className="card-head">
        <h2><HeartPulse size={18} /> {title}</h2>
        <span className="hint">{subtitle ?? `美国心脏协会 2022 · 近 ${ix.windowDays} 天`}</span>
      </div>
      <div className="hero-score">
        <ScoreRing score={le8.score} grade={le8.category ? `${le8.category.zh}（${le8.available}/8 项）` : "数据不足"} size={132} />
        <div className="col grow" style={{ gap: 10, minWidth: 220 }}>
          {le8.components.map((c) =>
            c.points != null ? (
              <Meter key={c.key} name={c.zh} value={c.points} unit="/ 100" max={100} status={le8Status(c.points)}
                foot={<>{c.value}{c.key === "diet" && ix.mepa && <> · <a style={{ cursor: "pointer" }} onClick={() => setMepaOpen(true)}>查看 16 题</a></>}</>} />
            ) : (
              <div key={c.key} className="row between small">
                <span className="sec">{c.zh}</span>
                <span className="muted">缺数据：{c.missing}</span>
              </div>
            ),
          )}
        </div>
      </div>
      <p className="small muted" style={{ marginTop: 10 }}>总分 = 已有指标的等权平均（缺失指标不计入分母）；80–100 高，50–79 中，0–49 低。</p>
      {mepaOpen && ix.mepa && <MepaModal ix={ix} onClose={() => setMepaOpen(false)} />}
    </div>
  );
}

function MepaModal({ ix, onClose }: { ix: HealthIndices; onClose: () => void }) {
  const m = ix.mepa!;
  return (
    <Modal title={`MEPA 饮食问卷：${m.score}/16`} onClose={onClose}>
      <p className="small sec" style={{ marginBottom: 10 }}>
        AHA Life's Essential 8 规定的个人饮食评分工具（Cerwinske 2017）。由你近 {m.days} 天的饮食记录自动推算每周 / 每天份数，每满足一题得 1 分。
        15–16 分 → 100，12–14 → 80，8–11 → 50，4–7 → 25，0–3 → 0。
      </p>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>题目</th><th>标准</th><th className="num">你的记录</th><th></th></tr></thead>
          <tbody>
            {m.items.map((i) => (
              <tr key={i.key}>
                <td>{i.zh}</td>
                <td className="small sec">{i.criterion}</td>
                <td className="num">{fmt(i.value, 1)} {i.unit}</td>
                <td>{i.met ? <span className="status good">✓ 1 分</span> : <span className="status info">0 分</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}

export function WcrfCard({ ix, subtitle }: { ix: HealthIndices; subtitle?: string }) {
  const w = ix.wcrf;
  const [open, setOpen] = useState(true);
  return (
    <div className="card">
      <div className="card-head">
        <h2><ShieldCheck size={18} /> 防癌建议 WCRF/AICR</h2>
        <span className="hint">{subtitle ?? `2018 标准化评分 · 近 ${ix.windowDays} 天`}</span>
      </div>
      <div className="row" style={{ gap: 16, alignItems: "baseline" }}>
        <span className="stat"><span className="value" style={{ fontSize: 34 }}>{fmt(w.score, 2)}<small>/ {w.max}</small></span></span>
        <span className="small muted grow">7 条建议各 1 分、等权（Shams-White 2019）。“超加工食品”一条原文按研究人群三分位评分、没有绝对切点，此处只展示不计分。</span>
        <button className="btn ghost sm icon" onClick={() => setOpen(!open)} aria-label="展开">{open ? <ChevronUp /> : <ChevronDown />}</button>
      </div>
      {open && (
        <div className="list" style={{ marginTop: 8 }}>
          {w.components.map((c) => (
            <div className="list-item" key={c.key} style={{ alignItems: "flex-start" }}>
              <span className="tnum" style={{ width: 56, fontWeight: 650, color: c.points == null ? "var(--ink-3)" : c.points >= c.max ? "var(--good-text)" : c.points > 0 ? "var(--warning-text)" : "var(--critical-text)" }}>
                {c.points == null ? "—" : `${fmt(c.points, 2)}/${c.max}`}
              </span>
              <div className="grow">
                <div style={{ fontWeight: 600 }}>{c.zh}</div>
                <div className="small sec">{c.detail}</div>
                <div className="small muted">{c.rule}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
