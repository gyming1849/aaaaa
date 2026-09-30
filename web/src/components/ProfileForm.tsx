import { useState } from "react";
import { api } from "../api";
import { useApp } from "../lib/app";
import type { Profile } from "../types";
import { Seg } from "./ui";

const TZS = ["Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Singapore", "Europe/London", "Europe/Berlin", "America/New_York", "America/Chicago", "America/Los_Angeles", "Australia/Sydney"];

export function ProfileForm({ initial, onSaved, submitText = "保存" }: { initial?: Profile | null; onSaved?: () => void; submitText?: string }) {
  const { me, meta, toast, refreshMe } = useApp();
  const guessTz = Intl.DateTimeFormat().resolvedOptions().timeZone || "Asia/Shanghai";
  const [p, setP] = useState<Profile>(
    initial ?? {
      sex: "male", birth_date: "1995-01-01", height_cm: 170, weight_kg: 65, activity_level: "low_active", goal: "maintain",
      goal_rate_kg_week: 0.5, target_weight_kg: null, physiology: "none", sodium_mode: "cdrr", conditions: [], timezone: guessTz,
    },
  );
  const [busy, setBusy] = useState(false);
  const set = <K extends keyof Profile>(k: K, v: Profile[K]) => setP((x) => ({ ...x, [k]: v }));
  const tzs = TZS.includes(p.timezone) ? TZS : [p.timezone, ...TZS];

  async function save() {
    setBusy(true);
    try {
      await api.put("/profile", p);
      await refreshMe();
      toast("档案已保存，评分已按新档案重新计算");
      onSaved?.();
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="stack">
      <div className="grid g2">
        <div className="field">
          <label>性别</label>
          <Seg value={p.sex} onChange={(v) => set("sex", v)} options={[{ key: "male", label: "男" }, { key: "female", label: "女" }]} />
        </div>
        <div className="field">
          <label>出生日期</label>
          <input className="input" type="date" value={p.birth_date} onChange={(e) => set("birth_date", e.target.value)} />
        </div>
        <div className="field">
          <label>身高</label>
          <div className="input-affix">
            <input className="input" type="number" inputMode="decimal" value={p.height_cm} onChange={(e) => set("height_cm", Number(e.target.value))} />
            <span className="affix">cm</span>
          </div>
        </div>
        <div className="field">
          <label>{initial ? "建档体重" : "当前体重"}</label>
          <div className="input-affix">
            <input className="input" type="number" inputMode="decimal" step="0.1" value={p.weight_kg} onChange={(e) => set("weight_kg", Number(e.target.value))} />
            <span className="affix">kg</span>
          </div>
          {initial && <span className="help">日常体重请在“身体与运动”中记录，评分会自动使用最近一次称重</span>}
        </div>
      </div>

      <div className="field">
        <label>日常活动水平（NASEM 2023 能量方程分档）</label>
        <div className="grid g2" style={{ gap: 8 }}>
          {(meta?.activityLevels ?? []).map((l) => (
            <label key={l.key} className="card flat tight" style={{ cursor: "pointer", borderColor: p.activity_level === l.key ? "var(--accent)" : undefined, background: p.activity_level === l.key ? "var(--accent-soft)" : undefined }}>
              <div className="row">
                <input type="radio" name="al" checked={p.activity_level === l.key} onChange={() => set("activity_level", l.key as Profile["activity_level"])} style={{ accentColor: "var(--accent)" }} />
                <b>{l.zh}</b>
              </div>
              <div className="small muted" style={{ marginTop: 2 }}>{l.desc}</div>
            </label>
          ))}
        </div>
        <span className="help">如果连接了苹果健康的步数/活动能量，每天的消耗会用实测数据，这里只作为没有数据时的基准。</span>
      </div>

      <div className="grid g2">
        <div className="field">
          <label>目标</label>
          <Seg value={p.goal} onChange={(v) => set("goal", v)} options={[{ key: "lose", label: "减重" }, { key: "maintain", label: "维持" }, { key: "gain", label: "增重" }]} />
        </div>
        {p.goal !== "maintain" && (
          <div className="field">
            <label>目标速度</label>
            <select className="input" value={p.goal_rate_kg_week} onChange={(e) => set("goal_rate_kg_week", Number(e.target.value))}>
              {[0.25, 0.5, 0.75, 1].map((r) => (
                <option key={r} value={r}>每周 {r} kg（约 {Math.round((r * 7700) / 7)} kcal/天）</option>
              ))}
            </select>
          </div>
        )}
        {p.goal !== "maintain" && (
          <div className="field">
            <label>目标体重</label>
            <div className="input-affix">
              <input className="input" type="number" step="0.1" value={p.target_weight_kg ?? ""} onChange={(e) => set("target_weight_kg", e.target.value ? Number(e.target.value) : null)} />
              <span className="affix">kg</span>
            </div>
          </div>
        )}
      </div>

      {p.sex === "female" && (
        <div className="field">
          <label>特殊生理阶段</label>
          <Seg value={p.physiology} onChange={(v) => set("physiology", v)} options={[{ key: "none", label: "无" }, { key: "pregnant", label: "孕期" }, { key: "lactating", label: "哺乳期" }]} />
          <span className="help">孕期/哺乳期会使用对应的 DRI（如铁 27 mg、叶酸 600 µg），酒精与咖啡因限值更严格，且不建议主动减重。</span>
        </div>
      )}

      <div className="field">
        <label>健康状况（会收紧相应标准）</label>
        <div className="row wrap">
          {(me?.conditions ?? meta?.conditions ?? []).map((c) => {
            const on = p.conditions.includes(c.key);
            return (
              <button key={c.key} type="button" className={`chip ${on ? "on" : ""}`} title={c.effect}
                onClick={() => set("conditions", on ? p.conditions.filter((x) => x !== c.key) : [...p.conditions, c.key])}>
                {c.zh}
              </button>
            );
          })}
        </div>
      </div>

      <div className="grid g2">
        <div className="field">
          <label>钠上限标准</label>
          <Seg value={p.sodium_mode} onChange={(v) => set("sodium_mode", v)} options={[{ key: "cdrr", label: "2300 mg（DGA/NASEM）" }, { key: "aha", label: "1500 mg（AHA 理想）" }]} />
        </div>
        <div className="field">
          <label>时区（决定“今天”从何时开始）</label>
          <select className="input" value={p.timezone} onChange={(e) => set("timezone", e.target.value)}>
            {tzs.map((t) => (
              <option key={t}>{t}</option>
            ))}
          </select>
        </div>
      </div>

      <div className="row" style={{ justifyContent: "flex-end" }}>
        <button className="btn primary lg" onClick={save} disabled={busy}>
          {busy ? <span className="spinner" /> : submitText}
        </button>
      </div>
    </div>
  );
}
