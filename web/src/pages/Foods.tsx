import { useEffect, useRef, useState } from "react";
import { Search, Sparkles, Plus, Camera, Trash2, Pencil, Globe, Lock, Link as LinkIcon, Library } from "lucide-react";
import { api, qs, uploadPhotos, waitJob } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { Food, FoodDraft, Vec } from "../types";
import { CATEGORY_ZH, NOVA_ZH, SOURCE_ZH, fmt } from "../lib/format";
import { Empty, Loading, Modal, Seg } from "../components/ui";

type EditState = {
  id?: number;
  name: string; brand: string; aliases: string; category: string; serving_g: number; serving_desc: string;
  per100: Vec; groups100: Vec; hazards100: { key: string; amount_per_100g: number; note?: string }[];
  nova_group: number | null; ingredients: string; label_fields: string[]; source: string; source_urls: { title: string; url: string }[];
  notes: string; visibility: "private" | "public";
};

const blank = (): EditState => ({
  name: "", brand: "", aliases: "", category: "other", serving_g: 100, serving_desc: "", per100: {}, groups100: {}, hazards100: [],
  nova_group: null, ingredients: "", label_fields: [], source: "manual", source_urls: [], notes: "", visibility: "private",
});

export default function Foods() {
  const [q, setQ] = useState("");
  const [scope, setScope] = useState<"all" | "mine">("all");
  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q), 250);
    return () => clearTimeout(t);
  }, [q]);
  const { data, loading, reload } = useLoad(() => api.get<Food[]>(`/foods${qs({ q: debounced, scope })}`), [debounced, scope]);
  const [view, setView] = useState<Food | null>(null);
  const [edit, setEdit] = useState<EditState | null>(null);
  const [aiOpen, setAiOpen] = useState(false);

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>食物库</h1>
          <div className="sub">常吃的包装食品、外卖、自制菜存下来，下次直接搜索并填克数，无需再调用 AI</div>
        </div>
        <div className="row wrap">
          <button className="btn" onClick={() => setEdit(blank())}><Plus /> 手动录入</button>
          <button className="btn primary" onClick={() => setAiOpen(true)}><Sparkles /> AI 查询 / 拍营养表</button>
        </div>
      </div>

      <div className="row wrap">
        <div className="input-affix" style={{ width: 320, maxWidth: "100%" }}>
          <input className="input" placeholder="搜索名称、品牌、别名…" value={q} onChange={(e) => setQ(e.target.value)} />
          <span className="affix"><Search size={16} /></span>
        </div>
        <Seg value={scope} onChange={setScope} options={[{ key: "all", label: "全部可用" }, { key: "mine", label: "我创建的" }]} />
      </div>

      {loading && !data && <Loading />}
      {data && data.length === 0 && (
        <div className="card"><Empty icon={<Library />}>还没有食物。记一餐时 AI 分析出的食物可以一键“存入食物库”，也可以在这里用 AI 联网查询或拍营养成分表添加。</Empty></div>
      )}
      <div className="grid g3">
        {data?.map((f) => (
          <div key={f.id} className="card food-card" onClick={() => setView(f)} role="button" tabIndex={0} onKeyDown={(e) => e.key === "Enter" && setView(f)}>
            <div className="row between">
              <b style={{ fontSize: 15.5 }}>{f.name}</b>
              {f.visibility === "public" ? <Globe size={15} color="var(--ink-3)" aria-label="公开" /> : <Lock size={15} color="var(--ink-3)" aria-label="私有" />}
            </div>
            <div className="small muted">{[f.brand, f.serving_desc || (f.serving_g ? `一份 ${fmt(f.serving_g)} g` : "")].filter(Boolean).join(" · ")}</div>
            <div className="macro-line">
              <span>每 100 g <b>{fmt(f.per100.energy_kcal)}</b> kcal</span>
              <span>蛋白 <b>{fmt(f.per100.protein_g, 1)}</b></span>
              <span>钠 <b>{fmt(f.per100.sodium_mg)}</b>mg</span>
            </div>
            <div className="row wrap" style={{ gap: 6 }}>
              <span className="chip">{SOURCE_ZH[f.source] ?? f.source}</span>
              {f.nova_group && <span className="chip">NOVA {f.nova_group}</span>}
              {f.use_count > 0 && <span className="chip">用过 {f.use_count} 次</span>}
              {!f.mine && <span className="chip accent">来自 {f.owner_name}</span>}
            </div>
          </div>
        ))}
      </div>

      {view && (
        <FoodDetail food={view} onClose={() => setView(null)}
          onEdit={() => { setEdit({ ...blank(), ...view, brand: view.brand ?? "", serving_g: view.serving_g ?? 100, serving_desc: view.serving_desc ?? "", ingredients: view.ingredients ?? "", notes: view.notes ?? "", category: view.category ?? "other" }); setView(null); }}
          onDeleted={() => { setView(null); reload(); }} />
      )}
      {aiOpen && <AiLookup onClose={() => setAiOpen(false)} onResult={(d) => {
        setAiOpen(false);
        setEdit({ ...blank(), ...d, aliases: d.aliases.join(","), source_urls: d.sources, hazards100: d.hazards100, source: d.source });
      }} />}
      {edit && <FoodEditor state={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} />}
    </div>
  );
}

function FoodDetail({ food, onClose, onEdit, onDeleted }: { food: Food; onClose: () => void; onEdit: () => void; onDeleted: () => void }) {
  const { meta, toast } = useApp();
  const s = food.serving_g ?? 100;
  return (
    <Modal wide title={<>{food.name} <span className="muted small">{food.brand}</span></>} onClose={onClose}
      footer={food.mine && (
        <>
          <button className="btn danger" onClick={async () => { if (confirm("删除这个食物？已记录的餐食不受影响。")) { await api.del(`/foods/${food.id}`); toast("已删除"); onDeleted(); } }}><Trash2 /> 删除</button>
          <button className="btn primary" onClick={onEdit}><Pencil /> 编辑</button>
        </>
      )}>
      <div className="stack">
        <div className="row wrap" style={{ gap: 6 }}>
          <span className="chip">{CATEGORY_ZH[food.category ?? "other"]}</span>
          {food.nova_group && <span className="chip">NOVA {food.nova_group} · {NOVA_ZH[food.nova_group]}</span>}
          <span className="chip">{SOURCE_ZH[food.source]}</span>
          {food.hazards100.map((h) => (
            <span key={h.key} className={`chip iarc-${meta?.hazards.find((x) => x.key === h.key)?.iarc}`}>{meta?.hazards.find((x) => x.key === h.key)?.zh ?? h.key}</span>
          ))}
        </div>
        {food.notes && <p className="small sec">{food.notes}</p>}
        {food.ingredients && <p className="small muted">配料：{food.ingredients}</p>}
        {food.source_urls.length > 0 && (
          <div className="small row wrap" style={{ gap: 6 }}><LinkIcon size={14} />{food.source_urls.map((u, i) => <a key={i} href={u.url} target="_blank" rel="noreferrer">{u.title}</a>)}</div>
        )}
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>营养素</th><th className="num">每 100 g</th><th className="num">每份 {fmt(s)} g</th><th className="num">占标签 DV</th></tr></thead>
            <tbody>
              {meta?.nutrients.map((n) => {
                const v = food.per100[n.key] ?? 0;
                return (
                  <tr key={n.key}>
                    <td>{n.zh} {food.label_fields.includes(n.key) && <span className="chip accent" style={{ padding: "0 6px", fontSize: 11 }}>标签</span>}</td>
                    <td className="num">{fmt(v, n.decimals)} <span className="muted small">{n.unit}</span></td>
                    <td className="num">{fmt((v * s) / 100, n.decimals)}</td>
                    <td className="num muted">{n.dv ? `${fmt(((v * s) / 100 / n.dv) * 100)}%` : ""}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </Modal>
  );
}

function AiLookup({ onClose, onResult }: { onClose: () => void; onResult: (d: FoodDraft) => void }) {
  const { toast, me } = useApp();
  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [note, setNote] = useState("");
  const [photos, setPhotos] = useState<{ id: string; url: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const fileRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (!busy) return;
    const t0 = Date.now();
    const iv = setInterval(() => setElapsed(Math.round((Date.now() - t0) / 1000)), 500);
    return () => clearInterval(iv);
  }, [busy]);
  async function run() {
    setBusy(true);
    try {
      const { job_id } = await api.post<{ job_id: string }>("/ai/food", { name, brand, note, photos: photos.map((p) => p.id) });
      onResult(await waitJob<FoodDraft>(job_id));
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal title="AI 查询营养信息" onClose={onClose}
      footer={<button className="btn primary" onClick={run} disabled={busy || (!name.trim() && !photos.length)}>{busy ? <><span className="spinner" /> {elapsed}s</> : <><Sparkles /> 开始</>}</button>}>
      <div className="stack">
        <p className="small sec">输入产品名称让 {me?.ai.model ?? "Claude"} 联网查找官方营养成分表；或者上传包装、配料表、营养成分表照片，直接读取标签数值（更准确）。</p>
        <div className="grid g2">
          <div className="field"><label>名称</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="如：螺蛳粉" autoFocus /></div>
          <div className="field"><label>品牌</label><input className="input" value={brand} onChange={(e) => setBrand(e.target.value)} placeholder="如：李子柒" /></div>
        </div>
        <div className="field"><label>补充说明（可选）</label><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="如：原味 335g 袋装；我一般只喝一半汤" /></div>
        <div className="field">
          <label>照片（可选）</label>
          <div className="photo-grid">
            {photos.map((p) => <img key={p.id} src={p.url} className="photo-thumb" alt="已上传" />)}
            <label className="photo-add" aria-label="添加照片">
              <Camera />
              <input ref={fileRef} type="file" accept="image/jpeg,image/png,image/webp" multiple hidden
                onChange={async (e) => { if (e.target.files?.length) { try { const up = await uploadPhotos(Array.from(e.target.files)); setPhotos((x) => [...x, ...up]); } catch (err) { toast((err as Error).message, "error"); } } }} />
            </label>
          </div>
        </div>
        {busy && <p className="small muted pulse">{photos.length ? "正在读取标签…" : "正在联网查找营养成分表…"} 一般需要 30–120 秒</p>}
      </div>
    </Modal>
  );
}

function FoodEditor({ state, onClose, onSaved }: { state: EditState; onClose: () => void; onSaved: () => void }) {
  const { meta, toast } = useApp();
  const [s, setS] = useState<EditState>(state);
  const [busy, setBusy] = useState(false);
  const [showAll, setShowAll] = useState(!!state.id || state.source !== "manual");
  const set = <K extends keyof EditState>(k: K, v: EditState[K]) => setS((x) => ({ ...x, [k]: v }));
  const MAIN = ["energy_kcal", "protein_g", "fat_g", "sat_fat_g", "trans_fat_g", "carb_g", "sugars_g", "added_sugars_g", "fiber_g", "sodium_mg"];
  const list = meta?.nutrients.filter((n) => showAll || MAIN.includes(n.key)) ?? [];
  async function save() {
    setBusy(true);
    try {
      const body = { ...s, aliases: s.aliases.split(/[,，、]+/).map((x) => x.trim()).filter(Boolean) };
      if (s.id) await api.put(`/foods/${s.id}`, body);
      else await api.post("/foods", body);
      toast("已保存到食物库");
      onSaved();
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal wide title={s.id ? "编辑食物" : "保存到食物库"} onClose={onClose} footer={<button className="btn primary" onClick={save} disabled={busy || !s.name}>保存</button>}>
      <div className="stack">
        {s.notes && s.source !== "manual" && <div className="banner accent"><Sparkles /> {s.notes}</div>}
        {s.source_urls.length > 0 && (
          <div className="small row wrap" style={{ gap: 6 }}><LinkIcon size={14} />{s.source_urls.map((u, i) => <a key={i} href={u.url} target="_blank" rel="noreferrer">{u.title}</a>)}</div>
        )}
        <div className="grid g3">
          <div className="field"><label>名称</label><input className="input" value={s.name} onChange={(e) => set("name", e.target.value)} /></div>
          <div className="field"><label>品牌</label><input className="input" value={s.brand} onChange={(e) => set("brand", e.target.value)} /></div>
          <div className="field"><label>分类</label>
            <select className="input" value={s.category} onChange={(e) => set("category", e.target.value)}>
              {Object.entries(CATEGORY_ZH).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </div>
          <div className="field"><label>一份重量</label><div className="input-affix"><input className="input" type="number" value={s.serving_g} onChange={(e) => set("serving_g", Number(e.target.value))} /><span className="affix">g</span></div></div>
          <div className="field"><label>份量描述</label><input className="input" value={s.serving_desc} onChange={(e) => set("serving_desc", e.target.value)} placeholder="1 包 335 g" /></div>
          <div className="field"><label>加工程度 (NOVA)</label>
            <select className="input" value={s.nova_group ?? ""} onChange={(e) => set("nova_group", e.target.value ? Number(e.target.value) : null)}>
              <option value="">未知</option>
              {[1, 2, 3, 4].map((n) => <option key={n} value={n}>{n} · {NOVA_ZH[n]}</option>)}
            </select>
          </div>
        </div>
        <div className="grid g2">
          <div className="field"><label>别名（逗号分隔，用于搜索和自动匹配）</label><input className="input" value={s.aliases} onChange={(e) => set("aliases", e.target.value)} /></div>
          <div className="field"><label>可见范围</label>
            <Seg value={s.visibility} onChange={(v) => set("visibility", v)} options={[{ key: "private", label: "仅自己" }, { key: "public", label: "所有成员可用" }]} />
          </div>
        </div>
        <div>
          <div className="row between" style={{ marginBottom: 8 }}>
            <h3>每 100 g 营养成分</h3>
            <label className="check small"><input type="checkbox" checked={showAll} onChange={(e) => setShowAll(e.target.checked)} />显示全部 {meta?.nutrients.length} 项</label>
          </div>
          <div className="nutrient-grid" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(190px, 1fr))", gap: 10 }}>
            {list.map((n) => (
              <div className="field" key={n.key}>
                <label style={{ fontWeight: 500 }}>{n.zh} {s.label_fields.includes(n.key) && <span className="chip accent" style={{ padding: "0 6px", fontSize: 11 }}>标签</span>}</label>
                <div className="input-affix">
                  <input className="input sm" type="number" step="any" value={s.per100[n.key] != null ? Math.round(s.per100[n.key] * 1000) / 1000 : ""}
                    onChange={(e) => set("per100", { ...s.per100, [n.key]: Number(e.target.value) })} />
                  <span className="affix">{n.unit}</span>
                </div>
              </div>
            ))}
          </div>
          {!showAll && <p className="small muted" style={{ marginTop: 8 }}>营养标签上通常只有这几项；其余营养素留空按 0 计，也可以让 AI 查询补全。</p>}
        </div>
        <div className="field"><label>配料表（可选）</label><textarea className="input" rows={2} value={s.ingredients} onChange={(e) => set("ingredients", e.target.value)} /></div>
      </div>
    </Modal>
  );
}
