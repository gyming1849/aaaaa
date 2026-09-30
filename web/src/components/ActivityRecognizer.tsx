// 身体与活动：手动填写或 AI 识别（文字 / 健康 App 截图）→ 可编辑预览（含合并前后对比）→ 确认合并
import { useEffect, useRef, useState } from "react";
import { Camera, Sparkles, Trash2, Plus, Check, ArrowRight } from "lucide-react";
import { api, uploadPhotos, waitJob } from "../api";
import { useApp } from "../lib/app";
import type { ActivityDay, DailyScore, HealthIndices } from "../types";
import { fmt } from "../lib/format";
import { Modal } from "./ui";

export interface Workout {
  description: string;
  activity_key: string;
  met: number;
  duration_min: number;
  distance_km: number;
  kcal?: number;
  notes?: string;
  avg_hr?: number | null;
  device_kcal?: number | null;
  in_device: boolean;
}

interface Draft {
  date: string;
  date_from_image?: boolean;
  activity: Record<string, number | null>;
  body: Record<string, number | null>;
  workouts: Workout[];
  notes?: string;
  provider?: string;
  model?: string;
}

const ACT_FIELDS: { key: string; label: string; unit: string; step?: string }[] = [
  { key: "steps", label: "步数", unit: "步" },
  { key: "active_kcal", label: "活动能量", unit: "kcal" },
  { key: "resting_kcal", label: "静息能量", unit: "kcal" },
  { key: "distance_km", label: "步行+跑步距离", unit: "km", step: "0.1" },
  { key: "exercise_min", label: "锻炼分钟", unit: "分钟" },
  { key: "sleep_hours", label: "睡眠", unit: "小时", step: "0.1" },
];
const BODY_FIELDS: { key: string; label: string; unit: string; step?: string }[] = [
  { key: "weight_kg", label: "体重", unit: "kg", step: "0.1" },
  { key: "body_fat_pct", label: "体脂率", unit: "%", step: "0.1" },
  { key: "sbp", label: "收缩压", unit: "mmHg" },
  { key: "dbp", label: "舒张压", unit: "mmHg" },
];

export function ActivityRecognizer({ date, current, mode, onClose, onDone }: {
  date: string;
  current?: ActivityDay | null;
  mode: "ai" | "manual";
  onClose: () => void;
  onDone: () => void;
}) {
  const { me, meta, toast } = useApp();
  const [text, setText] = useState("");
  const [photos, setPhotos] = useState<{ id: string; url: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [draft, setDraft] = useState<Draft | null>(
    mode === "manual"
      ? {
          date,
          activity: Object.fromEntries(ACT_FIELDS.map((f) => [f.key, (current as unknown as Record<string, number | null> | null)?.[f.key] ?? null])),
          body: Object.fromEntries(BODY_FIELDS.map((f) => [f.key, null])),
          workouts: [],
        }
      : null,
  );
  const [preview, setPreview] = useState<DayPreview | null>(null);
  const [saving, setSaving] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!busy) return;
    const t0 = Date.now();
    const iv = setInterval(() => setElapsed(Math.round((Date.now() - t0) / 1000)), 500);
    return () => clearInterval(iv);
  }, [busy]);

  // 草稿变化时重新计算合并预览
  useEffect(() => {
    if (!draft) return;
    const t = setTimeout(() => {
      api.post<DayPreview>("/preview", { date: draft.date, activity: draft.activity, body: draft.body, workouts: draft.workouts })
        .then(setPreview)
        .catch(() => setPreview(null));
    }, 350);
    return () => clearTimeout(t);
  }, [draft]);

  async function recognize() {
    setBusy(true);
    setElapsed(0);
    try {
      const { job_id } = await api.post<{ job_id: string }>("/ai/activity", { date, text, photos: photos.map((p) => p.id) });
      setDraft(await waitJob<Draft>(job_id));
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function commit() {
    if (!draft) return;
    setSaving(true);
    try {
      await api.post("/activity/commit", { ...draft, source: mode === "manual" ? "manual" : "ai" });
      toast("已合并到当天记录");
      onDone();
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setSaving(false);
    }
  }

  const setAct = (k: string, v: string) => setDraft((d) => d && { ...d, activity: { ...d.activity, [k]: v === "" ? null : Number(v) } });
  const setBody = (k: string, v: string) => setDraft((d) => d && { ...d, body: { ...d.body, [k]: v === "" ? null : Number(v) } });
  const setW = (i: number, patch: Partial<Workout>) => setDraft((d) => d && { ...d, workouts: d.workouts.map((w, j) => (j === i ? { ...w, ...patch } : w)) });
  const weight = me?.profile?.weight_kg ?? 65;
  const kcalOf = (w: Workout) => Math.round(Math.max(0, (w.met - 1) * weight * (w.duration_min / 60)));

  const footer = draft ? (
    <>
      <button className="btn" onClick={onClose}>取消</button>
      <button className="btn primary" onClick={commit} disabled={saving}>{saving ? <span className="spinner" /> : <Check />} 确认合并到 {draft.date}</button>
    </>
  ) : (
    <button className="btn primary" onClick={recognize} disabled={busy || (!text.trim() && !photos.length)}>
      {busy ? <><span className="spinner" /> {elapsed}s</> : <><Sparkles /> AI 识别</>}
    </button>
  );

  return (
    <Modal wide title={mode === "manual" ? `填写 ${date} 的活动与身体数据` : "AI 识别活动与身体数据"} onClose={onClose} footer={footer}>
      {!draft && (
        <div className="stack">
          <p className="small sec">
            用一句话描述，或上传苹果健康 / 健身圆环 / 手表运动记录 / 体脂秤 / 血压计的截图，由 {me?.ai.provider === "mock" ? "离线规则（未配置 AI，无法读图）" : me?.ai.model} 识别步数、能量、睡眠、体重和每次运动。识别结果会先给你预览，确认后才合并。
          </p>
          <textarea className="input" rows={3} value={text} onChange={(e) => setText(e.target.value)}
            placeholder="例：今天走了 8500 步，下午游泳 5km，昨晚睡了 7 个半小时，睡前体重 70.2" />
          <div className="photo-grid">
            {photos.map((p) => <img key={p.id} src={p.url} className="photo-thumb" alt="已上传的截图" />)}
            <label className="photo-add" aria-label="上传截图">
              <Camera />
              <input ref={fileRef} type="file" accept="image/jpeg,image/png,image/webp" multiple hidden
                onChange={async (e) => {
                  if (!e.target.files?.length) return;
                  try {
                    const up = await uploadPhotos(Array.from(e.target.files));
                    setPhotos((x) => [...x, ...up]);
                  } catch (err) {
                    toast((err as Error).message, "error");
                  }
                }} />
            </label>
          </div>
          {busy && <p className="small muted pulse">正在识别… 读取截图通常需要 20–60 秒</p>}
        </div>
      )}

      {draft && (
        <div className="stack">
          {draft.notes && <div className="banner accent"><Sparkles /> {draft.notes}</div>}
          {draft.date_from_image && <div className="banner warn">截图显示的日期是 {draft.date}，将合并到这一天。</div>}
          <div>
            <h3 style={{ marginBottom: 8 }}>活动</h3>
            <div className="grid g3">
              {ACT_FIELDS.map((f) => (
                <div className="field" key={f.key}>
                  <label>{f.label}</label>
                  <div className="input-affix">
                    <input className="input sm" type="number" step={f.step ?? "1"} value={draft.activity[f.key] ?? ""} onChange={(e) => setAct(f.key, e.target.value)} />
                    <span className="affix">{f.unit}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div>
            <h3 style={{ marginBottom: 8 }}>身体</h3>
            <div className="grid g4">
              {BODY_FIELDS.map((f) => (
                <div className="field" key={f.key}>
                  <label>{f.label}</label>
                  <div className="input-affix">
                    <input className="input sm" type="number" step={f.step ?? "1"} value={draft.body[f.key] ?? ""} onChange={(e) => setBody(f.key, e.target.value)} />
                    <span className="affix">{f.unit}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div>
            <div className="row between" style={{ marginBottom: 8 }}>
              <h3>运动</h3>
              <button className="btn sm" onClick={() => setDraft((d) => d && { ...d, workouts: [...d.workouts, { description: "快走", activity_key: "walk_brisk", met: 4.8, duration_min: 30, distance_km: 0, in_device: false }] })}>
                <Plus /> 添加一项
              </button>
            </div>
            {draft.workouts.length === 0 && <p className="small muted">没有运动</p>}
            <div className="col">
              {draft.workouts.map((w, i) => (
                <div className="item-edit" key={i}>
                  <div className="row wrap">
                    <input className="input sm grow" style={{ minWidth: 140 }} value={w.description} onChange={(e) => setW(i, { description: e.target.value })} aria-label="描述" />
                    <select className="input sm" style={{ width: 190 }} value={w.activity_key}
                      onChange={(e) => {
                        const a = meta?.activities.find((x) => x.key === e.target.value);
                        setW(i, { activity_key: e.target.value, met: a?.met ?? w.met });
                      }} aria-label="运动类型">
                      {meta?.activities.map((a) => <option key={a.key} value={a.key}>{a.zh}</option>)}
                    </select>
                    <button className="btn ghost sm icon danger" onClick={() => setDraft((d) => d && { ...d, workouts: d.workouts.filter((_, j) => j !== i) })} aria-label="删除"><Trash2 /></button>
                  </div>
                  <div className="row wrap small">
                    <label className="row">时长 <input className="input sm" style={{ width: 76 }} type="number" value={w.duration_min} onChange={(e) => setW(i, { duration_min: Number(e.target.value) })} /> 分钟</label>
                    <label className="row">MET <input className="input sm" style={{ width: 66 }} type="number" step="0.1" value={w.met} onChange={(e) => setW(i, { met: Number(e.target.value) })} /></label>
                    <label className="row">距离 <input className="input sm" style={{ width: 70 }} type="number" step="0.1" value={w.distance_km || ""} onChange={(e) => setW(i, { distance_km: Number(e.target.value) })} /> km</label>
                    {w.avg_hr ? <span className="muted">平均心率 {w.avg_hr}</span> : null}
                    <span>净消耗约 <b>{fmt(kcalOf(w))}</b> kcal{w.device_kcal ? <span className="muted">（设备显示 {fmt(w.device_kcal)}）</span> : null}</span>
                  </div>
                  <label className="check small"><input type="checkbox" checked={w.in_device} onChange={(e) => setW(i, { in_device: e.target.checked })} />已含在设备活动能量中（避免重复计算）</label>
                  {w.notes && <span className="small muted">{w.notes}</span>}
                </div>
              ))}
            </div>
          </div>
          {preview && <ImpactPreview before={preview.before} after={preview.after} indices={preview.indices} />}
        </div>
      )}
    </Modal>
  );
}

/** 合并前后对比：评分、能量、关键营养与状态变化 */
export function ImpactPreview({ before, after, indices }: { before: DailyScore; after: DailyScore; indices?: PreviewIndices }) {
  type Row = { label: string; b: number | null; a: number | null; unit: string; d?: number; better?: "up" | "down"; always?: boolean };
  const ib = indices?.before;
  const ia = indices?.after;
  const all: Row[] = [
    { label: "膳食质量 HEI-2020", b: before.score, a: after.score, unit: "", d: 1, better: "up", always: true },
    { label: "微量营养素 MAR", b: before.mar?.value ?? null, a: after.mar?.value ?? null, unit: "", d: 0, better: "up" },
    ...(ib && ia
      ? [
          { label: "心血管健康 LE8（近 7 天）", b: ib.le8.score, a: ia.le8.score, unit: "", d: 0, better: "up", always: true } as Row,
          { label: "防癌 WCRF/AICR（近 7 天）", b: ib.wcrf.score, a: ia.wcrf.score, unit: `/ ${ia.wcrf.max}`, d: 2, better: "up" } as Row,
        ]
      : []),
    { label: "摄入能量", b: before.energy.intake, a: after.energy.intake, unit: "kcal" },
    { label: "当日消耗", b: before.energy.tdee, a: after.energy.tdee, unit: "kcal" },
    { label: "能量差额", b: before.energy.intake - before.energy.tdee, a: after.energy.intake - after.energy.tdee, unit: "kcal" },
    { label: "钠", b: before.totals.sodium_mg, a: after.totals.sodium_mg, unit: "mg", better: "down" },
    { label: "添加糖", b: before.totals.added_sugars_g, a: after.totals.added_sugars_g, unit: "g", d: 1, better: "down" },
    { label: "饱和脂肪", b: before.totals.sat_fat_g, a: after.totals.sat_fat_g, unit: "g", d: 1, better: "down" },
    { label: "蛋白质", b: before.totals.protein_g, a: after.totals.protein_g, unit: "g", d: 1, better: "up" },
    { label: "膳食纤维", b: before.totals.fiber_g, a: after.totals.fiber_g, unit: "g", d: 1, better: "up" },
  ];
  const rows = all.filter((r) => Math.abs((r.a ?? 0) - (r.b ?? 0)) > 0.05 || r.always);
  const beforeStatus = new Map(before.items.map((i) => [i.key, i.status]));
  const flips = after.items.filter((i) => i.status !== "info" && beforeStatus.get(i.key) && statusZh(beforeStatus.get(i.key)!) !== statusZh(i.status));
  const le8Changes = ib && ia
    ? ia.le8.components.filter((c) => {
        const old = ib.le8.components.find((x) => x.key === c.key)?.points ?? null;
        return old !== c.points;
      }).map((c) => `${c.zh} ${ib.le8.components.find((x) => x.key === c.key)?.points ?? "—"} → ${c.points ?? "—"}`)
    : [];
  const newHazards = after.hazards.filter((h) => !before.hazards.some((x) => x.key === h.key));
  const tone = (r: Row) => {
    if (r.a == null || r.b == null || !r.better || Math.abs(r.a - r.b) <= 0.05) return "var(--ink)";
    const up = r.a > r.b;
    return (r.better === "up") === up ? "var(--good-text)" : "var(--critical-text)";
  };
  return (
    <div className="card flat" style={{ background: "var(--surface-2)" }}>
      <div className="card-head"><h3>合并预览</h3><span className="hint">确认前不会写入；数值随修改实时更新</span></div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>指标</th><th className="num">合并前</th><th></th><th className="num">合并后</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.label}>
                <td>{r.label}</td>
                <td className="num muted">{r.b == null ? "—" : `${fmt(r.b, r.d ?? 0)} ${r.unit}`}</td>
                <td style={{ width: 24 }}><ArrowRight size={14} color="var(--ink-3)" /></td>
                <td className="num" style={{ color: tone(r), fontWeight: 650 }}>{r.a == null ? "—" : `${fmt(r.a, r.d ?? 0)} ${r.unit}`}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {flips.length > 0 && (
        <div className="small" style={{ marginTop: 10 }}>
          <b>状态变化：</b>
          {flips.map((i) => `${i.category === "hei" ? "HEI·" : ""}${i.zh}（${statusZh(beforeStatus.get(i.key)!)} → ${statusZh(i.status)}）`).join("；")}
        </div>
      )}
      {le8Changes.length > 0 && (
        <div className="small" style={{ marginTop: 6 }}>
          <b>LE8 分项：</b>{le8Changes.join("；")}
        </div>
      )}
      {newHazards.length > 0 && (
        <div className="small" style={{ marginTop: 6, color: "var(--critical-text)" }}>
          <b>新增风险物：</b>{newHazards.map((h) => `${h.zh}（IARC ${h.iarc}）`).join("、")}
        </div>
      )}
    </div>
  );
}

export type PreviewIndices = { before: HealthIndices; after: HealthIndices };
export type DayPreview = { before: DailyScore; after: DailyScore; indices?: PreviewIndices };

const statusZh = (s: string) => ({ good: "达标", ok: "达标", warn: "偏离", bad: "不达标", info: "提示" })[s] ?? s;
