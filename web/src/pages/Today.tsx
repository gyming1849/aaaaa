import { Fragment, useMemo, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { Plus, Pencil, Trash2, Footprints, Flame, Scale, CircleX, CircleCheck, ShieldAlert, Utensils, ChartLine, Info, Droplets, Sparkles } from "lucide-react";
import { api, qs } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { DayResponse, DailyScore, Targets, Meal, Status } from "../types";
import { fmt, mealZh, localToday } from "../lib/format";
import { DateNav, Empty, IarcChip, Loading, Meter, ScoreRing, SourceLinks, StatusBadge, Seg, statusColor } from "../components/ui";
import { ActivityRecognizer } from "../components/ActivityRecognizer";
import { Le8Card, WcrfCard } from "../components/HealthIndices";

export default function Today() {
  const { username } = useParams();
  const { me, toast } = useApp();
  const nav = useNavigate();
  const [sp, setSp] = useSearchParams();
  const today = me?.today ?? localToday();
  const date = sp.get("date") ?? today;
  const setDate = (d: string) => setSp(d === today ? {} : { date: d });
  const other = username && username !== me?.user.username ? username : undefined;
  const { data, loading, error, reload } = useLoad(() => api.get<DayResponse>(`/day/${date}${qs({ user: other })}`), [date, other]);

  async function delMeal(m: Meal) {
    if (!confirm(`删除 ${m.time} 的${mealZh(m.meal_type)}？`)) return;
    await api.del(`/meals/${m.id}`);
    toast("已删除");
    reload();
  }

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>{other ? `@${other} 的记录` : "今日概览"}</h1>
          <div className="sub">{other ? "只读视图（对方开启了共享）" : "每一项都对照美国权威标准实时评估"}</div>
        </div>
        <div className="row wrap">
          <DateNav date={date} today={today} onChange={setDate} />
          {!other && (
            <button className="btn primary" onClick={() => nav(`/log${qs({ date: date !== today ? date : undefined })}`)}>
              <Plus /> 记一餐
            </button>
          )}
          {other && (
            <Link className="btn" to={`/u/${other}/trends`}>
              <ChartLine /> 看趋势
            </Link>
          )}
        </div>
      </div>

      {loading && !data && <Loading />}
      {error && <div className="banner warn">{error}</div>}
      {data && <DayView data={data} other={!!other} onDelMeal={delMeal} onReload={reload} />}
    </div>
  );
}

function DayView({ data, other, onDelMeal, onReload }: { data: DayResponse; other: boolean; onDelMeal: (m: Meal) => void; onReload: () => void }) {
  const s = data.score;
  const t = data.targets;
  const nav = useNavigate();
  const { toast } = useApp();
  const water = data.meals.find((m) => m.description === "饮水")?.items[0]?.amount_g ?? 0;
  async function addWater(ml: number) {
    try {
      await api.post("/water", { date: data.date, ml });
      onReload();
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }
  return (
    <>
      <div className="grid g-hero">
        <ScoreCard s={s} />
        <EnergyCard s={s} t={t} data={data} />
      </div>

      {s.hasData && (
        <div className="grid g2">
          <HighlightsCard s={s} />
          <KeyLimitsCard s={s} t={t} />
        </div>
      )}

      <div className="grid g2">
        <Le8Card ix={data.indices} />
        <WcrfCard ix={data.indices} />
      </div>

      {s.hazards.length > 0 && <HazardsCard s={s} />}

      <div className="grid g2">
        <div className="card">
          <div className="card-head">
            <h2><Utensils size={18} /> 饮食记录</h2>
            <span className="hint">{s.mealCount} 餐 · {fmt(s.energy.intake)} kcal</span>
          </div>
          {!other && (
            <div className="row" style={{ marginBottom: 12, gap: 8 }}>
              <Droplets size={16} color="var(--series-1)" />
              <span className="small sec grow">饮水 <b className="tnum">{fmt(water)}</b> ml · 总水分 {fmt(s.totals.water_g ?? 0)} / {fmt(t.intake.water_g?.value)} g（含食物）</span>
              {water > 0 && <button className="btn sm" onClick={() => addWater(-250)} aria-label="减少 250 毫升">−</button>}
              <button className="btn sm" onClick={() => addWater(250)}>+ 250 ml</button>
            </div>
          )}
          {data.meals.filter((m) => m.description !== "饮水").length === 0 ? (
            <Empty icon={<Utensils />}>
              {other ? "这一天没有记录" : (
                <>
                  还没有记录。
                  <div style={{ marginTop: 12 }}>
                    <button className="btn primary" onClick={() => nav(`/log?date=${data.date}`)}>
                      <Plus /> 记录第一餐
                    </button>
                  </div>
                </>
              )}
            </Empty>
          ) : (
            <div className="col">
              {data.meals.filter((m) => m.description !== "饮水").map((m) => {
                const kcal = m.items.reduce((a, i) => a + (i.nutrients.energy_kcal ?? 0), 0);
                return (
                  <div key={m.id} className="meal-card">
                    <div className="meal-head">
                      <span className="meal-time">{m.time}</span>
                      <span className="meal-type">{mealZh(m.meal_type)}</span>
                      <span className="muted small tnum">{fmt(kcal)} kcal</span>
                      <span className="grow" />
                      {!other && (
                        <>
                          <button className="btn ghost sm icon" onClick={() => nav(`/log?edit=${m.id}&date=${m.date}`)} aria-label="编辑">
                            <Pencil />
                          </button>
                          <button className="btn ghost sm icon danger" onClick={() => onDelMeal(m)} aria-label="删除">
                            <Trash2 />
                          </button>
                        </>
                      )}
                    </div>
                    {m.description && <div className="small muted" style={{ marginTop: 4 }}>“{m.description}”</div>}
                    <div className="meal-items">
                      {m.items.map((it, i) => (
                        <div className="meal-item" key={i}>
                          <span className="n">
                            {it.name} <span className="muted small">{it.amount_desc || `${fmt(it.amount_g)} g`}</span>
                            {it.hazards.length > 0 && <ShieldAlert size={13} color="var(--serious)" style={{ marginLeft: 4, verticalAlign: -2 }} aria-label="含风险项" />}
                          </span>
                          <span className="k">{fmt(it.nutrients.energy_kcal)} kcal</span>
                        </div>
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
        <ActivityCard data={data} other={other} onReload={onReload} />
      </div>

      {s.hasData && <DetailTabs s={s} t={t} />}
    </>
  );
}

function ScoreCard({ s }: { s: DailyScore }) {
  const { meta } = useApp();
  const mar = s.mar;
  return (
    <div className="card">
      <div className="card-head">
        <h2>今日膳食质量</h2>
        {s.hasData && <span className="hint">HEI-2020（USDA/NCI） · <Link to="/standards?tab=rules">评分依据</Link></span>}
      </div>
      <div className="hero-score">
        <ScoreRing score={s.score} grade={s.score != null ? `美国平均 ${meta?.heiUsMean ?? 58}` : "暂无记录"} />
        <div className="col grow" style={{ gap: 12, minWidth: 200 }}>
          {s.hei ? (
            <>
              <Meter name="HEI-2020 膳食质量" value={s.hei.total} unit="/ 100" max={100} decimals={1}
                status={s.hei.total >= 80 ? "good" : s.hei.total >= 51 ? "warn" : "bad"}
                foot="13 个组分按每 1000 kcal 的密度计分，分值由 USDA 规定" />
              {mar && (
                <Meter name="微量营养素充足 MAR" value={mar.value} unit="/ 100" max={100}
                  status={mar.value >= 90 ? "good" : mar.value >= 70 ? "warn" : "bad"}
                  foot={`11 种微量营养素达到 RDA 的平均比例（每种封顶 100%，等权）；最缺：${mar.nutrients.slice().sort((a, b) => a.nar - b.nar).slice(0, 2).map((n) => n.zh).join("、")}`} />
              )}
              {s.hazards.length > 0 && (
                <div className="row small" style={{ color: "var(--critical-text)" }}>
                  <ShieldAlert size={15} /> {s.hazards.length} 项致癌/风险物警示（见下方）
                </div>
              )}
            </>
          ) : (
            <p className="muted">记录饮食后，这里显示 USDA 的 HEI-2020 膳食质量分和 11 种微量营养素的充足度（MAR）。</p>
          )}
        </div>
      </div>
      {s.hasData && s.completeness.level === "partial" && (
        <div className="banner warn" style={{ marginTop: 14 }}>
          <Info /> {s.completeness.note}
        </div>
      )}
    </div>
  );
}

const ACTIVE_SRC: Record<string, string> = { device: "手机/手表活动能量", steps: "按步数估算", exercise: "手动记录的运动", none: "无活动数据" };

function EnergyCard({ s, t, data }: { s: DailyScore; t: Targets; data: DayResponse }) {
  const e = s.energy;
  const maxV = Math.max(e.intake, e.target, e.tdee) * 1.08 || 1;
  const rows = [
    { label: "摄入", v: e.intake, color: "var(--series-1)" },
    { label: "消耗", v: e.tdee, color: "var(--series-2)" },
    { label: "目标", v: e.target, color: "var(--series-3)" },
  ];
  const mp = s.macroPct;
  const bal = e.intake - e.tdee;
  return (
    <div className="card">
      <div className="card-head">
        <h2><Flame size={18} /> 能量平衡</h2>
        <span className="hint">{e.method === "eer" ? `无活动数据，按 ${t.eerMethod} 估算` : `静息 ${e.restingSource === "device" ? "来自设备" : "按 BMR"} · 活动：${ACTIVE_SRC[e.activeSource]}`}</span>
      </div>
      <div className="grid g4" style={{ gap: 10, marginBottom: 16 }}>
        <div className="stat"><span className="label">摄入</span><span className="value">{fmt(e.intake)}<small>kcal</small></span></div>
        <div className="stat"><span className="label">消耗</span><span className="value">{fmt(e.tdee)}<small>kcal</small></span></div>
        <div className="stat"><span className="label">差额</span><span className="value">{bal > 0 ? "+" : ""}{fmt(bal)}<small>kcal</small></span>
          <span className="delta">≈ {bal > 0 ? "+" : ""}{fmt((bal / 7700) * 1000)} g 体重</span></div>
        <div className="stat"><span className="label">体重</span>
          <span className="value">{data.score.weighedToday != null ? fmt(data.score.weighedToday, 1) : fmt(t.weightKg, 1)}<small>kg</small></span>
          <span className="delta">{data.weightTrend != null ? `趋势 ${fmt(data.weightTrend, 1)} kg` : ""}{data.score.weighedToday == null ? "（今日未称重）" : ""}</span>
        </div>
      </div>
      <div className="col" style={{ gap: 8 }} role="img" aria-label={`摄入 ${fmt(e.intake)}，消耗 ${fmt(e.tdee)}，目标 ${fmt(e.target)} 千卡`}>
        {rows.map((r) => (
          <div key={r.label} className="row" style={{ gap: 10 }}>
            <span className="small sec" style={{ width: 30 }}>{r.label}</span>
            <div className="grow" style={{ height: 10, background: "var(--surface-2)", borderRadius: 99 }}>
              <div style={{ width: `${(r.v / maxV) * 100}%`, height: "100%", background: r.color, borderRadius: 99 }} />
            </div>
            <span className="small tnum" style={{ width: 60, textAlign: "right" }}>{fmt(r.v)}</span>
          </div>
        ))}
      </div>
      <p className="small muted" style={{ marginTop: 8 }}>
        目标 = 当日消耗 {t.goalDeltaKcal ? `${t.goalDeltaKcal > 0 ? "+" : "−"} ${fmt(Math.abs(t.goalDeltaKcal))}（${t.goal === "lose" ? "减重" : "增重"}目标）` : "（维持体重）"}，
        不低于 {fmt(t.energyFloor)} kcal · BMR {fmt(t.bmr)} · EER {fmt(t.eer)}
      </p>
      {s.hasData && (
        <>
          <hr />
          <div className="row between small" style={{ marginBottom: 6 }}>
            <span className="sec">宏量营养素供能比</span>
            <span className="muted">可接受范围：蛋白 {t.amdr.protein.join("–")}% · 碳水 {t.amdr.carb.join("–")}% · 脂肪 {t.amdr.fat.join("–")}%</span>
          </div>
          <div className="stacked-bar" role="img" aria-label={`蛋白质 ${fmt(mp.protein)}%，碳水 ${fmt(mp.carb)}%，脂肪 ${fmt(mp.fat)}%`}>
            <div style={{ width: `${mp.protein}%`, background: "var(--series-1)" }} />
            <div style={{ width: `${mp.carb}%`, background: "var(--series-3)" }} />
            <div style={{ width: `${mp.fat}%`, background: "var(--series-2)" }} />
            {mp.alcohol > 0.5 && <div style={{ width: `${mp.alcohol}%`, background: "var(--series-5)" }} />}
          </div>
          <div className="legend" style={{ marginTop: 8 }}>
            <span><i className="box" style={{ background: "var(--series-1)" }} />蛋白质 {fmt(mp.protein)}%</span>
            <span><i className="box" style={{ background: "var(--series-3)" }} />碳水 {fmt(mp.carb)}%</span>
            <span><i className="box" style={{ background: "var(--series-2)" }} />脂肪 {fmt(mp.fat)}%</span>
            {mp.alcohol > 0.5 && <span><i className="box" style={{ background: "var(--series-5)" }} />酒精 {fmt(mp.alcohol)}%</span>}
          </div>
        </>
      )}
    </div>
  );
}

function HighlightsCard({ s }: { s: DailyScore }) {
  return (
    <div className="card">
      <div className="card-head"><h2>今日要点</h2><span className="hint">风险警示、超标项、HEI 扣分最多的组分</span></div>
      {s.top.issues.map((x, i) => (
        <div className="issue" key={`i${i}`}>
          <CircleX color="var(--critical)" aria-label="问题" />
          <span>{x}</span>
        </div>
      ))}
      {s.top.wins.map((x, i) => (
        <div className="issue" key={`w${i}`}>
          <CircleCheck color="var(--good)" aria-label="做得好" />
          <span className="sec">{x}</span>
        </div>
      ))}
      {!s.top.issues.length && !s.top.wins.length && <p className="muted">暂无</p>}
    </div>
  );
}

function KeyLimitsCard({ s, t }: { s: DailyScore; t: Targets }) {
  const item = (k: string) => s.items.find((i) => i.key === k);
  const L = t.limits;
  const tot = s.totals;
  const protein = item("protein_g");
  return (
    <div className="card">
      <div className="card-head"><h2>关键指标</h2><span className="hint">竖线 = 理想值 / 上限</span></div>
      <div className="col" style={{ gap: 14 }}>
        <Meter name="钠" value={tot.sodium_mg} unit="mg" max={L.sodium_mg.limit} status={item("sodium_mg")?.status ?? "info"}
          marks={[{ at: L.sodium_mg.ideal, label: "理想", kind: "ideal" }, { at: L.sodium_mg.limit, label: "上限" }]}
          foot={`≈ 食盐 ${fmt(tot.sodium_mg / 393, 1)} g · 上限 ${fmt(L.sodium_mg.limit)} mg，理想 ≤ ${fmt(L.sodium_mg.ideal)} mg`} />
        <Meter name="添加糖" value={tot.added_sugars_g} unit="g" max={L.added_sugars_g.limit} decimals={1} status={item("added_sugars_g")?.status ?? "info"}
          marks={[{ at: L.added_sugars_g.ideal, label: "AHA", kind: "ideal" }, { at: L.added_sugars_g.limit, label: "上限" }]}
          foot={`上限 ${fmt(L.added_sugars_g.limit)} g，AHA 建议 ≤ ${fmt(L.added_sugars_g.ideal)} g；DGA 2025：每餐 ≤ 10 g`} />
        <Meter name="饱和脂肪供能比" value={s.macroPct.satFat} unit="%" max={10} decimals={1} status={item("sat_fat_pct")?.status ?? "info"}
          marks={[{ at: L.sat_fat_pct.ideal, label: "理想", kind: "ideal" }, { at: 10, label: "上限" }]}
          foot={`${fmt(tot.sat_fat_g, 1)} g · 上限 10% 能量`} />
        <Meter name="膳食纤维" value={tot.fiber_g} unit="g" max={t.intake.fiber_g.value} decimals={1} status={item("fiber_g")?.status ?? "info"}
          marks={[{ at: t.intake.fiber_g.value, label: "AI" }]} foot={`目标 ≥ ${fmt(t.intake.fiber_g.value)} g（14 g/1000 kcal）`} />
        <Meter name="蛋白质" value={tot.protein_g} unit="g" max={t.protein.idealHighG} decimals={1} status={protein?.status ?? "info"}
          marks={[{ at: t.protein.rdaG, label: "RDA" }, { at: t.protein.idealLowG, label: "1.2 g/kg", kind: "ideal" }, { at: t.protein.idealHighG, label: "1.6 g/kg", kind: "ideal" }]}
          foot={`RDA ${fmt(t.protein.rdaG)} g；DGA 2025–2030 建议 ${fmt(t.protein.idealLowG)}–${fmt(t.protein.idealHighG)} g`} />
        {tot.alcohol_g > 0 && (
          <Meter name="酒精" value={tot.alcohol_g} unit="g" max={Math.max(L.alcohol_g.limit, 14)} decimals={1} status={item("alcohol_g")?.status ?? "info"}
            marks={L.alcohol_g.limit > 0 ? [{ at: L.alcohol_g.limit, label: "上限" }] : []} foot={`≈ ${fmt(tot.alcohol_g / 14, 1)} 标准杯；IARC 1 类致癌物，越少越好`} />
        )}
        {tot.caffeine_mg > 0 && (
          <Meter name="咖啡因" value={tot.caffeine_mg} unit="mg" max={L.caffeine_mg.limit} status={item("caffeine_mg")?.status ?? "info"}
            marks={[{ at: L.caffeine_mg.limit, label: "上限" }]} foot={`上限 ${fmt(L.caffeine_mg.limit)} mg`} />
        )}
      </div>
    </div>
  );
}

function HazardsCard({ s }: { s: DailyScore }) {
  const { meta } = useApp();
  return (
    <div className="card">
      <div className="card-head">
        <h2><ShieldAlert size={18} /> 致癌物与风险物警示</h2>
        <span className="hint">IARC 分级表示证据强度；加工肉、红肉、酒精、含糖饮料计入 WCRF 防癌评分</span>
      </div>
      <div className="list">
        {s.hazards.map((h) => {
          const def = meta?.hazards.find((x) => x.key === h.key);
          return (
            <div key={h.key} className="list-item" style={{ alignItems: "flex-start" }}>
              <div className="grow col" style={{ gap: 4 }}>
                <div className="row wrap">
                  <b>{h.zh}</b>
                  <IarcChip group={h.iarc} />
                  {h.foods.length > 0 && <span className="small muted">来自：{h.foods.join("、")}</span>}
                </div>
                <div className="small sec">{h.message}</div>
                {def && <div className="small muted">{def.risk}。建议：{def.advice}</div>}
                {meta && <SourceLinks ids={h.sources} sources={meta.sources} />}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ActivityCard({ data, other, onReload }: { data: DayResponse; other: boolean; onReload: () => void }) {
  const a = data.activity;
  const nav = useNavigate();
  const [mode, setMode] = useState<"ai" | "manual" | null>(null);
  return (
    <div className="card">
      <div className="card-head">
        <h2><Footprints size={18} /> 活动与身体</h2>
        {!other && (
          <div className="row" style={{ gap: 6 }}>
            <button className="btn sm" onClick={() => setMode("manual")}><Pencil /> 填写</button>
            <button className="btn sm primary" onClick={() => setMode("ai")}><Sparkles /> AI 识别截图</button>
          </div>
        )}
      </div>
      <div className="grid g4" style={{ gap: 10 }}>
        <div className="stat"><span className="label">步数</span><span className="value">{a?.steps != null ? fmt(a.steps) : "—"}</span></div>
        <div className="stat"><span className="label">活动能量</span><span className="value">{a?.active_kcal != null ? fmt(a.active_kcal) : "—"}<small>kcal</small></span></div>
        <div className="stat"><span className="label">运动消耗</span><span className="value">{fmt(data.score.energy.exerciseKcal)}<small>kcal</small></span></div>
        <div className="stat"><span className="label">睡眠</span><span className="value">{a?.sleep_hours != null ? fmt(a.sleep_hours, 1) : "—"}<small>小时</small></span></div>
      </div>
      {data.exercises.length > 0 && (
        <div className="list" style={{ marginTop: 10 }}>
          {data.exercises.map((e) => (
            <div className="list-item" key={e.id}>
              <Flame size={16} color="var(--series-2)" />
              <span className="grow">{e.description} <span className="small muted">{fmt(e.duration_min)} 分钟 · MET {e.met}</span></span>
              <span className="small tnum">{fmt(e.kcal)} kcal{e.in_device ? <span className="muted">（已含在设备数据中）</span> : null}</span>
            </div>
          ))}
        </div>
      )}
      {data.body.length > 0 && (
        <div className="list" style={{ marginTop: 6 }}>
          {data.body.map((b) => (
            <div className="list-item" key={b.id}>
              <Scale size={16} color="var(--series-1)" />
              <span className="grow">{b.time} 称重</span>
              <span className="tnum">{b.weight_kg != null ? `${fmt(b.weight_kg, 1)} kg` : ""}{b.body_fat_pct != null ? ` · 体脂 ${fmt(b.body_fat_pct, 1)}%` : ""}{b.sbp != null ? ` · 血压 ${fmt(b.sbp)}/${fmt(b.dbp)}` : ""}</span>
            </div>
          ))}
        </div>
      )}
      {!a && !data.exercises.length && !data.body.length && (
        <p className="muted small" style={{ marginTop: 10 }}>
          点“填写”直接录入今天的步数、活动能量、睡眠、体重；或点“AI 识别截图”上传苹果健康 / 手表截图，或者说一句“今天走了 8000 步，游泳 5km”。{!other && <> 也可以在 <a onClick={() => nav(`/body?date=${data.date}`)} style={{ cursor: "pointer" }}>身体与运动</a> 里设置 iPhone 快捷指令自动同步。</>}
        </p>
      )}
      {mode && <ActivityRecognizer date={data.date} current={a} mode={mode} onClose={() => setMode(null)} onDone={() => { setMode(null); onReload(); }} />}
    </div>
  );
}

function DetailTabs({ s, t }: { s: DailyScore; t: Targets }) {
  const [tab, setTab] = useState<"nutrients" | "hei" | "items">("nutrients");
  return (
    <div className="card">
      <div className="card-head" style={{ flexWrap: "wrap" }}>
        <h2>明细</h2>
        <Seg value={tab} onChange={setTab} options={[{ key: "nutrients", label: "全部营养素" }, { key: "hei", label: "HEI-2020" }, { key: "items", label: "评分明细" }]} />
      </div>
      {tab === "nutrients" && <NutrientTable s={s} t={t} />}
      {tab === "hei" && <HeiView s={s} />}
      {tab === "items" && <ItemsView s={s} />}
    </div>
  );
}

const GROUP_ZH: Record<string, string> = { energy: "能量", macro: "宏量营养素", carb: "碳水与糖", fat: "脂肪酸", mineral: "矿物质", vitamin: "维生素", other: "其他" };

function NutrientTable({ s, t }: { s: DailyScore; t: Targets }) {
  const { meta } = useApp();
  const rows = useMemo(() => {
    if (!meta) return [];
    const byKey = new Map(s.items.map((i) => [i.key, i]));
    return meta.nutrients.map((n) => {
      const v = s.totals[n.key] ?? 0;
      const it = byKey.get(n.key);
      const intake = t.intake[n.key];
      const upper = t.upper[n.key];
      let target = "";
      let pct: number | null = null;
      let status: Status = "info";
      if (n.key === "energy_kcal") {
        target = `目标 ${fmt(s.energy.target)}`;
        pct = v / s.energy.target;
        status = s.items.find((i) => i.key === "energy_balance")?.status ?? "info";
      } else if (it) {
        target = it.targetText;
        status = it.status;
        pct = intake ? v / intake.value : it.limit ? v / it.limit : null;
      } else if (intake) {
        target = `≥ ${fmt(intake.value, n.decimals)}（${intake.kind}）`;
        pct = v / intake.value;
        status = pct >= 1 ? "good" : pct >= 0.7 ? "warn" : "bad";
      } else if (n.key === "sat_fat_g") {
        target = `≤ 10% 能量`;
        status = s.items.find((i) => i.key === "sat_fat_pct")?.status ?? "info";
      } else if (n.dv) {
        target = `标签 DV ${fmt(n.dv, n.decimals)}`;
      }
      if (upper?.appliesToTotal && v > upper.value) status = "bad";
      return { n, v, target, pct, status, upper };
    });
  }, [meta, s, t]);
  if (!meta) return null;
  let lastGroup = "";
  return (
    <div className="table-wrap">
      <table className="table wide-mobile">
        <thead>
          <tr><th>营养素</th><th className="num">摄入</th><th>目标</th><th style={{ width: "22%" }}>完成度</th><th>状态</th></tr>
        </thead>
        <tbody>
          {rows.map(({ n, v, target, pct, status, upper }) => {
            const head = n.group !== lastGroup;
            lastGroup = n.group;
            return (
              <Fragment key={n.key}>
                {head && <tr className="group-row"><td colSpan={5}>{GROUP_ZH[n.group]}</td></tr>}
                <tr>
                  <td>{n.zh} <span className="muted small en-name">{n.en}</span></td>
                  <td className="num">{fmt(v, n.decimals)} <span className="muted small">{n.unit}</span></td>
                  <td className="small sec">{target}{upper && upper.appliesToTotal ? <span className="muted"> · UL {fmt(upper.value, n.decimals)}</span> : null}</td>
                  <td>
                    {pct != null && (
                      <div className="row" style={{ gap: 8 }}>
                        <div className="grow" style={{ height: 6, background: "var(--surface-3)", borderRadius: 99 }}>
                          <div style={{ width: `${Math.min(100, pct * 100)}%`, height: "100%", borderRadius: 99, background: statusColor(status) }} />
                        </div>
                        <span className="small tnum muted" style={{ width: 42, textAlign: "right" }}>{fmt(pct * 100)}%</span>
                      </div>
                    )}
                  </td>
                  <td>{status !== "info" && <StatusBadge status={status} />}</td>
                </tr>
              </Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function HeiView({ s }: { s: DailyScore }) {
  if (!s.hei) return <p className="muted">摄入能量不足 200 kcal，暂不计算 HEI。</p>;
  return (
    <div className="stack">
      <div className="row">
        <span className="stat"><span className="label">HEI-2020 总分</span><span className="value">{fmt(s.hei.total, 1)}<small>/ 100</small></span></span>
        <span className="small muted grow">美国农业部与国家癌症研究所的膳食质量指数，按每 1000 kcal 的密度评分；美国人平均约 58 分。</span>
      </div>
      <div className="nutrient-grid">
        {s.hei.components.map((c) => {
          const r = c.score / c.max;
          return (
            <Meter key={c.key} name={c.zh} value={c.score} unit={`/ ${c.max}`} max={c.max} decimals={1}
              status={r >= 0.999 ? "good" : r >= 0.6 ? "warn" : "bad"} foot={`${fmt(c.value, 2)} ${c.unit}${r < 0.999 ? ` · ${c.hint}` : ""}`} />
          );
        })}
      </div>
    </div>
  );
}

function ItemsView({ s }: { s: DailyScore }) {
  const { meta } = useApp();
  const cats = [
    { key: "hei", zh: "HEI-2020 膳食质量（USDA 官方分值）", withPoints: true },
    { key: "mar", zh: "MAR 计分的 11 种微量营养素（等权）", withPoints: false },
    { key: "adequacy", zh: "其他营养素（对照 RDA/AI，只标状态）", withPoints: false },
    { key: "moderation", zh: "限量与其他标准（只标状态）", withPoints: false },
    { key: "energy", zh: "能量平衡（只标状态）", withPoints: false },
  ];
  return (
    <div className="stack">
      {cats.map((c) => {
        const its = s.items.filter((i) => i.category === c.key);
        if (!its.length) return null;
        return (
          <div key={c.key}>
            <div className="row between" style={{ marginBottom: 6 }}>
              <h3>{c.zh}</h3>
              {c.key === "hei" && s.hei && <span className="small tnum sec">{fmt(s.hei.total, 1)} / 100</span>}
              {c.key === "mar" && s.mar && <span className="small tnum sec">MAR {fmt(s.mar.value)} / 100</span>}
            </div>
            <div className="table-wrap">
              <table className="table">
                <tbody>
                  {its.map((i) => (
                    <tr key={i.key}>
                      <td style={{ width: 110 }}><StatusBadge status={i.status} /></td>
                      <td>
                        <div>{i.message}</div>
                        <div className="small muted">标准：{i.targetText} {meta && <SourceLinks ids={i.sources} sources={meta.sources} />}</div>
                      </td>
                      <td className="num small">{c.withPoints ? `${fmt(i.points, 1)} / ${i.maxPoints}` : ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      })}
    </div>
  );
}
