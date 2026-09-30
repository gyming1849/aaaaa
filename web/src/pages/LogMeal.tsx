import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Camera, Sparkles, Trash2, BookmarkPlus, Library, Search, Plus, Check, ShieldAlert, Info, Link as LinkIcon, RefreshCw } from "lucide-react";
import { api, qs, uploadPhotos, waitJob } from "../api";
import { useApp } from "../lib/app";
import type { DayResponse, DraftItem, Food, MealDraft, MealItem, Vec } from "../types";
import { CATEGORY_ZH, MEAL_TYPES, NOVA_ZH, fmt, guessMealType, nowTime, localToday } from "../lib/format";
import { Modal, Seg, Empty } from "../components/ui";

const scale = (v: Vec, f: number): Vec => Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x * f]));

function toDraft(it: MealItem): DraftItem {
  const f = it.amount_g > 0 ? 100 / it.amount_g : 1;
  return {
    ...it,
    per100: { nutrients: scale(it.nutrients, f), groups: scale(it.groups, f), hazards: it.hazards.map((h) => ({ key: h.key, amount_per_100g: h.amount * f })) },
    save_suggested: false,
  };
}

function rescale(it: DraftItem, grams: number): DraftItem {
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

export default function LogMeal() {
  const { me, meta, toast } = useApp();
  const nav = useNavigate();
  const [sp] = useSearchParams();
  const editId = sp.get("edit") ? Number(sp.get("edit")) : null;
  const today = me?.today ?? localToday();
  const [date, setDate] = useState(sp.get("date") ?? today);
  const [time, setTime] = useState(nowTime());
  const [mealType, setMealType] = useState(guessMealType(nowTime()));
  const [text, setText] = useState("");
  const [photos, setPhotos] = useState<{ id: string; url: string }[]>([]);
  const [uploading, setUploading] = useState(false);
  const [phase, setPhase] = useState<"input" | "analyzing" | "review">("input");
  const [elapsed, setElapsed] = useState(0);
  const [jobStatus, setJobStatus] = useState("");
  const [draft, setDraft] = useState<Omit<MealDraft, "items"> | null>(null);
  const [items, setItems] = useState<DraftItem[]>([]);
  const [picker, setPicker] = useState(false);
  const [saveItem, setSaveItem] = useState<number | null>(null);
  const [saving, setSaving] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  // 编辑已有餐食
  useEffect(() => {
    if (!editId) return;
    api.get<DayResponse>(`/day/${sp.get("date") ?? today}`).then((d) => {
      const m = d.meals.find((x) => x.id === editId);
      if (!m) return;
      setDate(m.date);
      setTime(m.time);
      setMealType(m.meal_type);
      setText(m.description);
      setItems(m.items.map(toDraft));
      setPhase("review");
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editId]);

  useEffect(() => {
    if (phase !== "analyzing") return;
    const t0 = Date.now();
    const iv = setInterval(() => setElapsed(Math.round((Date.now() - t0) / 1000)), 500);
    return () => clearInterval(iv);
  }, [phase]);

  async function onFiles(files: FileList | null) {
    if (!files?.length) return;
    setUploading(true);
    try {
      const up = await uploadPhotos(Array.from(files).slice(0, 6 - photos.length));
      setPhotos((p) => [...p, ...up]);
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  async function analyze(extra = "") {
    const fullText = extra ? `${text}\n补充：${extra}` : text;
    if (!fullText.trim() && !photos.length) {
      toast("请描述吃了什么，或上传照片", "error");
      return;
    }
    setPhase("analyzing");
    setElapsed(0);
    try {
      const { job_id } = await api.post<{ job_id: string }>("/ai/meal", { text: fullText, date, time, meal_type: mealType, photos: photos.map((p) => p.id) });
      const r = await waitJob<MealDraft>(job_id, (j) => setJobStatus(j.status));
      const { items: newItems, ...rest } = r;
      setDraft(rest);
      setItems((old) => [...old.filter((i) => i.food_id && !extra), ...newItems]);
      if (extra) setText(fullText);
      setPhase("review");
    } catch (e) {
      toast((e as Error).message, "error");
      setPhase(items.length ? "review" : "input");
    }
  }

  async function saveMeal() {
    if (!items.length) {
      toast("至少需要一种食物", "error");
      return;
    }
    setSaving(true);
    const body = {
      date, time, meal_type: mealType, description: text, photos: photos.map((p) => p.id),
      ai_summary: draft?.summary ?? "", ai_model: draft?.model ?? "", items,
    };
    try {
      if (editId) await api.put(`/meals/${editId}`, body);
      else await api.post("/meals", body);
      toast("已保存，评分已更新");
      nav(date === today ? "/" : `/?date=${date}`);
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setSaving(false);
    }
  }

  const totals = useMemo(() => {
    const t: Vec = {};
    for (const it of items) for (const [k, v] of Object.entries(it.nutrients)) t[k] = (t[k] ?? 0) + v;
    return t;
  }, [items]);

  const hazardName = (k: string) => meta?.hazards.find((h) => h.key === k)?.zh ?? k;

  return (
    <div className="stack" style={{ maxWidth: 900 }}>
      <div className="page-head">
        <div>
          <h1>{editId ? "编辑这一餐" : "记一餐"}</h1>
          <div className="sub">用自然语言描述即可，比如“中午一碗牛肉面加一个卤蛋，喝了杯无糖豆浆”</div>
        </div>
      </div>

      <div className="card stack">
        <div className="grid g3 compact">
          <div className="field">
            <label>日期</label>
            <input className="input" type="date" value={date} max={today} onChange={(e) => setDate(e.target.value)} />
          </div>
          <div className="field">
            <label>时间</label>
            <input className="input" type="time" value={time} onChange={(e) => setTime(e.target.value)} />
          </div>
          <div className="field">
            <label>餐次</label>
            <select className="input" value={mealType} onChange={(e) => setMealType(e.target.value)}>
              {MEAL_TYPES.map((m) => (
                <option key={m.key} value={m.key}>{m.zh}</option>
              ))}
            </select>
          </div>
        </div>

        <div className="field">
          <label>吃了什么</label>
          <textarea className="input" value={text} onChange={(e) => setText(e.target.value)} rows={3}
            placeholder="例：早上两个水煮蛋、一杯燕麦牛奶、半个苹果；中午一包李子柒螺蛳粉…（写上品牌、份量、做法会更准）" />
        </div>

        <div className="field">
          <label>照片（可选：食物照片、包装、配料表、营养成分表）</label>
          <div className="photo-grid">
            {photos.map((p) => (
              <div key={p.id} style={{ position: "relative" }}>
                <img src={p.url} className="photo-thumb" alt="已上传的照片" />
                <button className="btn sm icon" style={{ position: "absolute", top: -8, right: -8, borderRadius: 99, width: 24, height: 24 }}
                  onClick={() => setPhotos((x) => x.filter((y) => y.id !== p.id))} aria-label="移除照片">×</button>
              </div>
            ))}
            {photos.length < 6 && (
              <label className="photo-add" aria-label="添加照片">
                {uploading ? <span className="spinner" /> : <Camera />}
                <input ref={fileRef} type="file" accept="image/jpeg,image/png,image/webp" multiple hidden onChange={(e) => onFiles(e.target.files)} />
              </label>
            )}
          </div>
        </div>

        <div className="row wrap">
          <button className="btn primary lg" onClick={() => analyze()} disabled={phase === "analyzing"}>
            <Sparkles /> {items.length && phase === "review" ? "重新分析文字描述" : "AI 分析"}
          </button>
          <button className="btn lg" onClick={() => setPicker(true)}>
            <Library /> 从食物库添加
          </button>
          <span className="small muted">
            {me?.ai.provider === "mock" ? "当前为离线估算模式（未配置 AI）" : `由 ${me?.ai.model} 分析${me?.ai.provider === "cli" ? "（claude -p）" : ""}，包装食品会自动联网查询`}
          </span>
        </div>
      </div>

      {phase === "analyzing" && (
        <div className="card">
          <div className="row" style={{ gap: 14 }}>
            <span className="spinner" />
            <div className="grow">
              <div style={{ fontWeight: 600 }}>{jobStatus === "queued" ? "排队中…" : "Claude 正在分析"} <span className="muted tnum">{elapsed}s</span></div>
              <div className="small muted pulse">
                {elapsed < 8 ? "识别食物与份量…" : elapsed < 30 ? "估算 40+ 种营养素、食物组与加工程度…" : elapsed < 70 ? "查询品牌产品的营养成分表…" : "快好了，正在核对致癌物与风险项…"}
              </div>
            </div>
          </div>
        </div>
      )}

      {phase === "review" && (
        <>
          {draft && (draft.summary || draft.questions.length > 0) && (
            <div className="card stack" style={{ gap: 10 }}>
              {draft.summary && <div className="banner accent"><Sparkles /> {draft.summary}</div>}
              {draft.questions.length > 0 && <FollowUp questions={draft.questions} onSubmit={(x) => analyze(x)} />}
              {draft.assumptions.length > 0 && (
                <details>
                  <summary className="small sec" style={{ cursor: "pointer" }}>估算假设（{draft.assumptions.length}）</summary>
                  <ul className="small sec" style={{ margin: "6px 0 0", paddingLeft: 18 }}>
                    {draft.assumptions.map((a, i) => <li key={i}>{a}</li>)}
                  </ul>
                </details>
              )}
              {draft.sources.length > 0 && (
                <div className="small sec row wrap" style={{ gap: 6 }}>
                  <LinkIcon size={14} /> 参考来源：
                  {draft.sources.map((s, i) => <a key={i} href={s.url} target="_blank" rel="noreferrer">{s.title}</a>)}
                </div>
              )}
            </div>
          )}

          <div className="card">
            <div className="card-head">
              <h2>确认食物与份量</h2>
              <span className="hint">改克数会按比例重算全部营养素</span>
            </div>
            {items.length === 0 && <Empty>没有食物，重新分析或从食物库添加</Empty>}
            <div className="col">
              {items.map((it, idx) => (
                <div className="item-edit" key={idx}>
                  <div className="row wrap">
                    <input className="input sm grow" style={{ minWidth: 160, fontWeight: 600 }} value={it.name}
                      onChange={(e) => setItems((x) => x.map((y, i) => (i === idx ? { ...y, name: e.target.value } : y)))} aria-label="食物名称" />
                    <div className="input-affix" style={{ width: 120 }}>
                      <input className="input sm" type="number" inputMode="decimal" value={Math.round(it.amount_g * 10) / 10}
                        onChange={(e) => {
                          const g = Number(e.target.value);
                          if (g > 0) setItems((x) => x.map((y, i) => (i === idx ? rescale(y, g) : y)));
                        }} aria-label="克数" />
                      <span className="affix">g</span>
                    </div>
                    <button className="btn ghost sm icon danger" onClick={() => setItems((x) => x.filter((_, i) => i !== idx))} aria-label="移除">
                      <Trash2 />
                    </button>
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
                      <span key={i} className={`chip iarc-${meta?.hazards.find((x) => x.key === h.key)?.iarc ?? "2B"}`}>
                        <ShieldAlert size={12} /> {hazardName(h.key)}
                      </span>
                    ))}
                    {(it.groups.processed_meat_g ?? 0) > 0 && <span className="chip iarc-1"><ShieldAlert size={12} /> 加工肉 {fmt(it.groups.processed_meat_g)} g</span>}
                    {(it.groups.red_meat_g ?? 0) > 0 && <span className="chip iarc-2A">红肉 {fmt(it.groups.red_meat_g)} g</span>}
                    <span className="grow" />
                    {!it.food_id && !it.saved_food_id && (
                      <button className={`btn sm ${it.save_suggested ? "primary" : ""}`} onClick={() => setSaveItem(idx)}>
                        <BookmarkPlus /> {it.save_suggested ? "存入食物库（推荐）" : "存入食物库"}
                      </button>
                    )}
                    {it.saved_food_id && <span className="chip accent"><Check size={12} /> 已存入食物库</span>}
                  </div>
                  {it.notes && <div className="small muted">{it.notes}</div>}
                </div>
              ))}
            </div>
            {items.length > 0 && (
              <>
                <hr />
                <div className="row wrap between">
                  <div className="macro-line" style={{ fontSize: 14 }}>
                    <span>合计 <b>{fmt(totals.energy_kcal)}</b> kcal</span>
                    <span>蛋白 <b>{fmt(totals.protein_g, 1)}</b>g</span>
                    <span>钠 <b>{fmt(totals.sodium_mg)}</b>mg</span>
                    <span>添加糖 <b>{fmt(totals.added_sugars_g, 1)}</b>g</span>
                    <span>饱和脂肪 <b>{fmt(totals.sat_fat_g, 1)}</b>g</span>
                  </div>
                  <div className="row">
                    <button className="btn" onClick={() => setPicker(true)}><Plus /> 添加</button>
                    <button className="btn primary lg" onClick={saveMeal} disabled={saving}>
                      {saving ? <span className="spinner" /> : <Check />} 保存这一餐
                    </button>
                  </div>
                </div>
              </>
            )}
          </div>
        </>
      )}

      {phase === "input" && items.length === 0 && <QuickFoods onPick={(it) => { setItems([it]); setPhase("review"); }} />}

      {picker && (
        <FoodPicker onClose={() => setPicker(false)} onPick={(it) => { setItems((x) => [...x, it]); setPhase("review"); setPicker(false); }} />
      )}
      {saveItem != null && items[saveItem] && (
        <SaveFoodModal item={items[saveItem]} sources={draft?.sources ?? []} onClose={() => setSaveItem(null)}
          onSaved={(id) => { setItems((x) => x.map((y, i) => (i === saveItem ? { ...y, saved_food_id: id } : y))); setSaveItem(null); }} />
      )}
    </div>
  );
}

function FollowUp({ questions, onSubmit }: { questions: string[]; onSubmit: (x: string) => void }) {
  const [x, setX] = useState("");
  return (
    <div className="banner" style={{ flexDirection: "column", alignItems: "stretch" }}>
      <div className="row"><Info size={16} /> <b>AI 想确认：</b></div>
      <ul style={{ margin: "0 0 4px", paddingLeft: 20 }}>{questions.map((q, i) => <li key={i}>{q}</li>)}</ul>
      <div className="row">
        <input className="input sm grow" value={x} onChange={(e) => setX(e.target.value)} placeholder="补充说明后重新分析（可选）" />
        <button className="btn sm" disabled={!x.trim()} onClick={() => onSubmit(x)}><RefreshCw /> 补充并重新分析</button>
      </div>
    </div>
  );
}

function QuickFoods({ onPick }: { onPick: (it: DraftItem) => void }) {
  const [foods, setFoods] = useState<Food[]>([]);
  useEffect(() => {
    api.get<Food[]>("/foods?scope=all").then((f) => setFoods(f.slice(0, 12)));
  }, []);
  if (!foods.length) return null;
  return (
    <div className="card">
      <div className="card-head"><h3>常用食物（一键添加 1 份）</h3></div>
      <div className="row wrap">
        {foods.map((f) => (
          <button key={f.id} className="chip" onClick={async () => onPick(await api.post<DraftItem>(`/foods/${f.id}/item`, { grams: f.serving_g ?? 100 }))}>
            {f.name}{f.serving_g ? ` · ${fmt(f.serving_g)}g` : ""}
          </button>
        ))}
      </div>
    </div>
  );
}

export function FoodPicker({ onClose, onPick }: { onClose: () => void; onPick: (it: DraftItem) => void }) {
  const [q, setQ] = useState("");
  const [foods, setFoods] = useState<Food[] | null>(null);
  const [sel, setSel] = useState<Food | null>(null);
  const [grams, setGrams] = useState(100);
  useEffect(() => {
    const t = setTimeout(() => api.get<Food[]>(`/foods${qs({ q, scope: "all" })}`).then(setFoods), 200);
    return () => clearTimeout(t);
  }, [q]);
  return (
    <Modal title="从食物库添加" onClose={onClose}
      footer={sel && (
        <button className="btn primary" onClick={async () => onPick(await api.post<DraftItem>(`/foods/${sel.id}/item`, { grams }))}>
          <Plus /> 添加 {fmt(grams)} g
        </button>
      )}>
      {!sel ? (
        <div className="stack">
          <div className="input-affix">
            <input className="input" autoFocus placeholder="搜索名称、品牌、别名…" value={q} onChange={(e) => setQ(e.target.value)} />
            <span className="affix"><Search size={16} /></span>
          </div>
          {foods && foods.length === 0 && <Empty>食物库里没有匹配项。可以在“食物库”里用 AI 联网查询或拍营养成分表来添加。</Empty>}
          <div className="list">
            {foods?.map((f) => (
              <button key={f.id} className="list-item" style={{ background: "none", border: "none", borderBottom: "1px solid var(--hair)", textAlign: "left", cursor: "pointer", font: "inherit", color: "inherit" }}
                onClick={() => { setSel(f); setGrams(f.serving_g ?? 100); }}>
                <div className="grow">
                  <div style={{ fontWeight: 600 }}>{f.name} {f.brand && <span className="muted small">{f.brand}</span>}</div>
                  <div className="small muted">每 100 g {fmt(f.per100.energy_kcal)} kcal · 钠 {fmt(f.per100.sodium_mg)} mg{f.serving_g ? ` · 一份 ${fmt(f.serving_g)} g` : ""}{!f.mine ? ` · 来自 ${f.owner_name}` : ""}</div>
                </div>
              </button>
            ))}
          </div>
        </div>
      ) : (
        <div className="stack">
          <div>
            <h3>{sel.name}</h3>
            <div className="small muted">{sel.brand} {sel.serving_desc}</div>
          </div>
          <div className="field">
            <label>吃了多少</label>
            <div className="row wrap">
              <div className="input-affix" style={{ width: 140 }}>
                <input className="input" type="number" value={grams} onChange={(e) => setGrams(Number(e.target.value))} autoFocus />
                <span className="affix">g</span>
              </div>
              {sel.serving_g && [0.5, 1, 1.5, 2].map((m) => (
                <button key={m} className={`chip ${grams === sel.serving_g! * m ? "on" : ""}`} onClick={() => setGrams(sel.serving_g! * m)}>{m} 份</button>
              ))}
            </div>
          </div>
          <div className="macro-line">
            <span><b>{fmt((sel.per100.energy_kcal * grams) / 100)}</b> kcal</span>
            <span>蛋白 <b>{fmt((sel.per100.protein_g * grams) / 100, 1)}</b>g</span>
            <span>钠 <b>{fmt((sel.per100.sodium_mg * grams) / 100)}</b>mg</span>
            <span>添加糖 <b>{fmt((sel.per100.added_sugars_g * grams) / 100, 1)}</b>g</span>
          </div>
          <button className="btn ghost sm" style={{ alignSelf: "flex-start" }} onClick={() => setSel(null)}>← 返回搜索</button>
        </div>
      )}
    </Modal>
  );
}

function SaveFoodModal({ item, sources, onClose, onSaved }: { item: DraftItem; sources: { title: string; url: string }[]; onClose: () => void; onSaved: (id: number) => void }) {
  const { toast } = useApp();
  const [name, setName] = useState(item.name);
  const [brand, setBrand] = useState("");
  const [serving, setServing] = useState(Math.round(item.amount_g));
  const [aliases, setAliases] = useState("");
  const [visibility, setVisibility] = useState<"private" | "public">("private");
  const [busy, setBusy] = useState(false);
  async function save() {
    setBusy(true);
    try {
      const r = await api.post<{ id: number }>("/foods/from-item", {
        item, name, brand, serving_g: serving, serving_desc: item.amount_desc, aliases: aliases.split(/[,，、\s]+/).filter(Boolean), visibility, source_urls: sources,
      });
      toast("已存入食物库，下次可直接搜索选择");
      onSaved(r.id);
    } catch (e) {
      toast((e as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal title="存入食物库" onClose={onClose} footer={<button className="btn primary" onClick={save} disabled={busy}><BookmarkPlus /> 保存</button>}>
      <div className="stack">
        <p className="small sec">按每 100 g 的营养数据保存。下次记录时说出名称会自动匹配，也可以在“从食物库添加”里直接选择克数。</p>
        <div className="grid g2">
          <div className="field"><label>名称</label><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></div>
          <div className="field"><label>品牌（可选）</label><input className="input" value={brand} onChange={(e) => setBrand(e.target.value)} /></div>
          <div className="field">
            <label>一份的重量</label>
            <div className="input-affix"><input className="input" type="number" value={serving} onChange={(e) => setServing(Number(e.target.value))} /><span className="affix">g</span></div>
          </div>
          <div className="field"><label>别名（逗号分隔）</label><input className="input" value={aliases} onChange={(e) => setAliases(e.target.value)} placeholder="如：螺狮粉, luosifen" /></div>
        </div>
        <div className="field">
          <label>可见范围</label>
          <Seg value={visibility} onChange={setVisibility} options={[{ key: "private", label: "仅自己" }, { key: "public", label: "所有成员可用" }]} />
        </div>
        <div className="macro-line">
          <span>每 100 g：<b>{fmt(item.per100.nutrients.energy_kcal)}</b> kcal</span>
          <span>蛋白 <b>{fmt(item.per100.nutrients.protein_g, 1)}</b>g</span>
          <span>钠 <b>{fmt(item.per100.nutrients.sodium_mg)}</b>mg</span>
        </div>
      </div>
    </Modal>
  );
}
