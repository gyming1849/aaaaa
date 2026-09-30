import { useEffect, type ReactNode } from "react";
import { CircleCheck, TriangleAlert, CircleX, Info, ChevronLeft, ChevronRight, X, Inbox } from "lucide-react";
import type { Status, Source } from "../types";
import { fmt, addDays, dateLabel } from "../lib/format";

const STATUS_TEXT: Record<Status, string> = { good: "达标", ok: "达标", warn: "偏离", bad: "不达标", info: "提示" };

export function StatusBadge({ status, text }: { status: Status; text?: string }) {
  const Icon = status === "good" || status === "ok" ? CircleCheck : status === "warn" ? TriangleAlert : status === "bad" ? CircleX : Info;
  return (
    <span className={`status ${status}`}>
      <Icon aria-hidden />
      {text ?? STATUS_TEXT[status]}
    </span>
  );
}

export function statusColor(s: Status): string {
  return s === "good" || s === "ok" ? "var(--good)" : s === "warn" ? "var(--warning)" : s === "bad" ? "var(--critical)" : "var(--axis)";
}

/** 进度/限量条：填充色表示状态，刻度线标出理想值与上限 */
export function Meter({
  name, value, unit, max, marks = [], status, foot, decimals = 0,
}: {
  name: string; value: number; unit: string; max: number; marks?: { at: number; label: string; kind?: "ideal" | "limit" }[];
  status: Status; foot?: ReactNode; decimals?: number;
}) {
  const scale = Math.max(max, value, ...marks.map((m) => m.at)) * 1.08 || 1;
  const pct = Math.min(100, (value / scale) * 100);
  return (
    <div className="meter">
      <div className="meter-top">
        <span className="name">{name}</span>
        <span className="val tnum">
          <b style={{ color: "var(--ink)" }}>{fmt(value, decimals)}</b> {unit}
        </span>
      </div>
      <div className="meter-track" role="img" aria-label={`${name} ${fmt(value, decimals)} ${unit}`}>
        <div className="meter-fill" style={{ width: `${pct}%`, background: statusColor(status) }} />
        {marks.map((m, i) => (
          <div key={i} className={`meter-mark ${m.kind ?? "limit"}`} style={{ left: `calc(${(m.at / scale) * 100}% - 1px)` }} title={m.label} />
        ))}
      </div>
      {foot && <div className="meter-foot">{foot}</div>}
    </div>
  );
}

export function ScoreRing({ score, grade, size = 148 }: { score: number | null; grade?: string; size?: number }) {
  const r = size / 2 - 9;
  const c = 2 * Math.PI * r;
  const v = score ?? 0;
  const color = score == null ? "var(--axis)" : v >= 70 ? "var(--good)" : v >= 55 ? "var(--warning)" : v >= 40 ? "var(--serious)" : "var(--critical)";
  return (
    <div className="ring-wrap" style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--surface-3)" strokeWidth={10} />
        <circle
          cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={10} strokeLinecap="round"
          strokeDasharray={`${(c * v) / 100} ${c}`} transform={`rotate(-90 ${size / 2} ${size / 2})`}
          style={{ transition: "stroke-dasharray .6s ease" }}
        />
      </svg>
      <div className="center">
        <div className="num" style={{ fontSize: size < 120 ? 32 : 48 }}>{score == null ? "—" : Math.round(v)}</div>
        {grade && <div className="grade">{grade}</div>}
      </div>
    </div>
  );
}

export function Modal({ title, onClose, children, footer, wide }: { title: ReactNode; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [onClose]);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${wide ? "wide" : ""}`} role="dialog" aria-modal>
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="btn ghost icon sm" onClick={onClose} aria-label="关闭">
            <X />
          </button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  );
}

export function Avatar({ name, color, size }: { name: string; color: string; size?: "lg" }) {
  return (
    <div className={`avatar ${size ?? ""}`} style={{ background: color }} aria-hidden>
      {name.slice(0, 1).toUpperCase()}
    </div>
  );
}

export function Loading({ text = "加载中…" }: { text?: string }) {
  return (
    <div className="loading-block">
      <span className="spinner" /> {text}
    </div>
  );
}

export function Empty({ children, icon }: { children: ReactNode; icon?: ReactNode }) {
  return (
    <div className="empty">
      {icon ?? <Inbox />}
      <div>{children}</div>
    </div>
  );
}

export function DateNav({ date, today, onChange }: { date: string; today: string; onChange: (d: string) => void }) {
  return (
    <div className="date-nav">
      <button className="btn ghost sm icon" onClick={() => onChange(addDays(date, -1))} aria-label="前一天">
        <ChevronLeft />
      </button>
      <label className="d" style={{ cursor: "pointer", position: "relative" }}>
        {dateLabel(date, today)}
        <input
          type="date" value={date} max={today} onChange={(e) => e.target.value && onChange(e.target.value)}
          style={{ position: "absolute", inset: 0, opacity: 0, cursor: "pointer" }}
        />
      </label>
      <button className="btn ghost sm icon" onClick={() => onChange(addDays(date, 1))} disabled={date >= today} aria-label="后一天">
        <ChevronRight />
      </button>
    </div>
  );
}

export function Seg<T extends string>({ value, options, onChange }: { value: T; options: { key: T; label: ReactNode }[]; onChange: (v: T) => void }) {
  return (
    <div className="seg" role="tablist">
      {options.map((o) => (
        <button key={o.key} className={o.key === value ? "on" : ""} onClick={() => onChange(o.key)} role="tab" aria-selected={o.key === value}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function IarcChip({ group }: { group: string }) {
  if (group === "—") return <span className="chip">非致癌</span>;
  return <span className={`chip iarc-${group}`}>IARC {group} 类</span>;
}

export function SourceLinks({ ids, sources }: { ids: string[]; sources: Source[] }) {
  const list = ids.map((id) => sources.find((s) => s.id === id)).filter(Boolean) as Source[];
  if (!list.length) return null;
  return (
    <span className="small muted">
      依据：
      {list.map((s, i) => (
        <span key={s.id}>
          {i > 0 && "、"}
          {s.url ? (
            <a href={s.url} target="_blank" rel="noreferrer">
              {s.org}
            </a>
          ) : (
            s.org
          )}
        </span>
      ))}
    </span>
  );
}

export function StatTile({ label, value, unit, delta }: { label: string; value: ReactNode; unit?: string; delta?: ReactNode }) {
  return (
    <div className="card stat-card">
      <div className="stat">
        <span className="label">{label}</span>
        <span className="value">
          {value}
          {unit && <small>{unit}</small>}
        </span>
        {delta && <span className="delta">{delta}</span>}
      </div>
    </div>
  );
}
