// AI 解析结果的逐项编辑：名称、克数、分类、加工程度、全部营养素与食物组、风险标记
import { useState } from "react";
import { Trash2, ShieldAlert, BookmarkPlus, Check, Library, X, SlidersHorizontal } from "lucide-react";
import { useApp } from "../lib/app";
import type { DraftItem, Vec } from "../types";
import { CATEGORY_ZH, NOVA_ZH, fmt } from "../lib/format";

const scale = (v: Vec, f: number): Vec => Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x * f]));

export function rescale(it: DraftItem, grams: number): DraftItem {
  const f = grams / 100;
  return {
    ...it,
    amount_g: grams,
    amount_desc: `${fmt(grams)} g`,
    nutrients: scale(it.per100.nutrients, f),
    groups: scale(it.per100.groups, f),
    hazards: it.per100.hazards.map((h) => ({ key: h.key, amount: h.amount_per_100g * f })),
  };
}

const MAIN = ["energy_kcal", "protein_g", "carb_g", "fat_g", "sat_fat_g", "trans_fat_g", "sugars_g", "added_sugars_g", "fiber_g", "sodium_mg", "cholesterol_mg", "caffeine_mg", "alcohol_g"];

export function ItemEditor({ item, onChange, onRemove, onSave }: {
  item: DraftItem;
  onChange: (it: DraftItem) => void;
  onRemove: () => void;
  onSave: () => void;
}) {
  const { meta } = useApp();
  const [open, setOpen] = useState(false);
  const [all, setAll] = useState(false);
  const it = item;
  const g = it.amount_g || 1;
  const hazardDef = (k: string) => meta?.hazards.find((h) => h.key === k);

  // 编辑具体数值：同步更新“每 100 g”，之后改克数仍按新数值缩放；与食物库解除关联
  const setNutrient = (k: string, v: number) =>
    onChange({ ...it, food_id: null, nutrients: { ...it.nutrients, [k]: v }, per100: { ...it.per100, nutrients: { ...it.per100.nutrients, [k]: (v * 100) / g } } });
  const setGroup = (k: string, v: number) =>
    onChange({ ...it, food_id: null, groups: { ...it.groups, [k]: v }, per100: { ...it.per100, groups: { ...it.per100.groups, [k]: (v * 100) / g } } });
  const removeHazard = (i: number) =>
    onChange({ ...it, food_id: null, hazards: it.hazards.filter((_, j) => j !== i), per100: { ...it.per100, hazards: it.per100.hazards.filter((_, j) => j !== i) } });
  const addHazard = (key: string) =>
    onChange({ ...it, food_id: null, hazards: [...it.hazards, { key, amount: g }], per100: { ...it.per100, hazards: [...it.per100.hazards, { key, amount_per_100g: 100 }] } });

  const nutrients = meta?.nutrients.filter((n) => all || MAIN.includes(n.key)) ?? [];
  const flaggable = meta?.hazards.filter((h) => h.dose.from === "flag" && !it.hazards.some((x) => x.key === h.key)) ?? [];

  return (
    <div className="item-edit">
      <div className="row wrap">
        <input className="input sm grow" style={{ minWidth: 160, fontWeight: 600 }} value={it.name} onChange={(e) => onChange({ ...it, name: e.target.value })} aria-label="食物名称" />
        <div className="input-affix" style={{ width: 120 }}>
          <input className="input sm" type="number" inputMode="decimal" value={Math.round(it.amount_g * 10) / 10}
            onChange={(e) => {
              const v = Number(e.target.value);
              if (v > 0) onChange(rescale(it, v));
            }} aria-label="克数" />
          <span className="affix">g</span>
        </div>
        <button className={`btn sm ${open ? "primary" : ""}`} onClick={() => setOpen(!open)} aria-expanded={open}><SlidersHorizontal /> 调整</button>
        <button className="btn ghost sm icon danger" onClick={onRemove} aria-label="删除这一项"><Trash2 /></button>
      </div>
      <div className="macro-line">
        <span><b>{fmt(it.nutrients.energy_kcal)}</b> kcal</span>
        <span>蛋白 <b>{fmt(it.nutrients.protein_g, 1)}</b>g</span>
        <span>碳水 <b>{fmt(it.nutrients.carb_g, 1)}</b>g</span>
        <span>脂肪 <b>{fmt(it.nutrients.fat_g, 1)}</b>g</span>
        <span>钠 <b>{fmt(it.nutrients.sodium_mg)}</b>mg</span>
        <span>添加糖 <b>{fmt(it.nutrients.added_sugars_g, 1)}</b>g</span>
        <span>纤维 <b>{fmt(it.nutrients.fiber_g, 1)}</b>g</span>
      </div>
      <div className="row wrap" style={{ gap: 6 }}>
        {it.amount_desc && <span className="chip">{it.amount_desc}</span>}
        {it.category && <span className="chip">{CATEGORY_ZH[it.category] ?? it.category}</span>}
        {it.nova_group && <span className="chip">NOVA {it.nova_group} · {NOVA_ZH[it.nova_group]}</span>}
        {it.food_id && <span className="chip accent"><Library size={12} /> 食物库</span>}
        {it.confidence === "low" && <span className="chip">置信度低</span>}
        {it.hazards.map((h, i) => (
          <span key={i} className={`chip iarc-${hazardDef(h.key)?.iarc ?? "2B"}`}>
            <ShieldAlert size={12} /> {hazardDef(h.key)?.zh ?? h.key}
            <button onClick={() => removeHazard(i)} aria-label="移除该风险标记" style={{ border: "none", background: "none", padding: 0, cursor: "pointer", color: "inherit", display: "inline-flex" }}><X size={12} /></button>
          </span>
        ))}
        {(it.groups.processed_meat_g ?? 0) > 0 && <span className="chip iarc-1"><ShieldAlert size={12} /> 加工肉 {fmt(it.groups.processed_meat_g)} g</span>}
        {(it.groups.red_meat_g ?? 0) > 0 && <span className="chip iarc-2A">红肉 {fmt(it.groups.red_meat_g)} g</span>}
        <span className="grow" />
        {!it.food_id && !it.saved_food_id && (
          <button className={`btn sm ${it.save_suggested ? "primary" : ""}`} onClick={onSave}>
            <BookmarkPlus /> {it.save_suggested ? "存入食物库（推荐）" : "存入食物库"}
          </button>
        )}
        {it.saved_food_id && <span className="chip accent"><Check size={12} /> 已存入食物库</span>}
      </div>
      {it.notes && <div className="small muted">{it.notes}</div>}

      {open && (
        <div className="stack" style={{ borderTop: "1px solid var(--hair)", paddingTop: 12, gap: 12 }}>
          {it.food_id && <div className="banner small">这一项来自食物库。修改具体数值后将按你填写的数值保存，不再与食物库条目关联。</div>}
          <div className="grid g3">
            <div className="field">
              <label>分类</label>
              <select className="input sm" value={it.category ?? "other"} onChange={(e) => onChange({ ...it, category: e.target.value })}>
                {Object.entries(CATEGORY_ZH).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
            </div>
            <div className="field">
              <label>加工程度（NOVA）</label>
              <select className="input sm" value={it.nova_group ?? ""} onChange={(e) => onChange({ ...it, nova_group: e.target.value ? Number(e.target.value) : null })}>
                <option value="">未知</option>
                {[1, 2, 3, 4].map((n) => <option key={n} value={n}>{n} · {NOVA_ZH[n]}</option>)}
              </select>
            </div>
            <div className="field">
              <label>份量描述</label>
              <input className="input sm" value={it.amount_desc ?? ""} onChange={(e) => onChange({ ...it, amount_desc: e.target.value })} />
            </div>
          </div>
          <div>
            <div className="row between" style={{ marginBottom: 6 }}>
              <b className="small">营养素（这一份的总量）</b>
              <label className="check small"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} />显示全部 {meta?.nutrients.length} 项</label>
            </div>
            <div className="nutrient-grid" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))", gap: 8 }}>
              {nutrients.map((n) => (
                <div className="field" key={n.key}>
                  <label style={{ fontWeight: 500, fontSize: 12 }}>{n.zh}</label>
                  <div className="input-affix">
                    <input className="input sm" type="number" step="any" value={Math.round((it.nutrients[n.key] ?? 0) * 100) / 100}
                      onChange={(e) => setNutrient(n.key, Math.max(0, Number(e.target.value) || 0))} />
                    <span className="affix">{n.unit}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
          <div>
            <b className="small">食物组（影响 HEI-2020 与红肉/加工肉判断）</b>
            <div className="nutrient-grid" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))", gap: 8, marginTop: 6 }}>
              {meta?.foodGroups.map((fg) => (
                <div className="field" key={fg.key}>
                  <label style={{ fontWeight: 500, fontSize: 12 }} title={fg.note}>{fg.zh}</label>
                  <div className="input-affix">
                    <input className="input sm" type="number" step="any" value={Math.round((it.groups[fg.key] ?? 0) * 100) / 100}
                      onChange={(e) => setGroup(fg.key, Math.max(0, Number(e.target.value) || 0))} />
                    <span className="affix" style={{ fontSize: 11 }}>{fg.unit === "g" ? "g" : fg.unit.slice(0, 1)}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
          {flaggable.length > 0 && (
            <div className="row wrap">
              <span className="small sec">补充风险标记：</span>
              <select className="input sm" style={{ width: 220 }} value="" onChange={(e) => e.target.value && addHazard(e.target.value)} aria-label="添加风险标记">
                <option value="">选择…</option>
                {flaggable.map((h) => <option key={h.key} value={h.key}>{h.zh}（IARC {h.iarc}）</option>)}
              </select>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
