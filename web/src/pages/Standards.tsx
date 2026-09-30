import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { Targets } from "../types";
import { fmt } from "../lib/format";
import { IarcChip, Loading, Seg, SourceLinks } from "../components/ui";

type Tab = "mine" | "dri" | "hazards" | "hei" | "met" | "rules" | "sources";

export default function Standards() {
  const [sp, setSp] = useSearchParams();
  const tab = (sp.get("tab") as Tab) ?? "mine";
  const setTab = (t: Tab) => setSp({ tab: t });
  const TABS: { key: Tab; label: string }[] = [
    { key: "mine", label: "我的个性化目标" }, { key: "dri", label: "DRI 总表" }, { key: "hazards", label: "致癌物与风险物" },
    { key: "hei", label: "HEI-2020" }, { key: "met", label: "运动 MET" }, { key: "rules", label: "评分规则" }, { key: "sources", label: "资料来源" },
  ];
  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>标准库</h1>
          <div className="sub">本站离线评分使用的全部标准：美国 NASEM DRI、膳食指南 DGA 2020–2025 / 2025–2030、HEI-2020、FDA、AHA、IARC、WCRF、体力活动指南</div>
        </div>
      </div>
      <div className="tabs">
        {TABS.map((t) => <button key={t.key} className={tab === t.key ? "on" : ""} onClick={() => setTab(t.key)}>{t.label}</button>)}
      </div>
      {tab === "mine" && <MyTargets />}
      {tab === "dri" && <DriTable />}
      {tab === "hazards" && <HazardList />}
      {tab === "hei" && <HeiTable />}
      {tab === "met" && <MetTable />}
      {tab === "rules" && <Rules />}
      {tab === "sources" && <Sources />}
    </div>
  );
}

function MyTargets() {
  const { meta } = useApp();
  const { data: t } = useLoad(() => api.get<Targets>("/profile/targets"), []);
  if (!t || !meta) return <Loading />;
  return (
    <div className="stack">
      <div className="grid g4">
        <div className="card stat-card"><div className="stat"><span className="label">适用人群</span><span className="value" style={{ fontSize: 20 }}>{t.lifeStageZh}</span><span className="delta">{t.age} 岁{t.sensitive ? " · 敏感人群" : ""}</span></div></div>
        <div className="card stat-card"><div className="stat"><span className="label">BMI</span><span className="value">{fmt(t.bmi, 1)}</span><span className="delta">{t.bmiCategory.zh}{t.referenceWeightKg !== t.weightKg ? ` · 按体重的目标使用校正体重 ${fmt(t.referenceWeightKg, 1)} kg` : ""}</span></div></div>
        <div className="card stat-card"><div className="stat"><span className="label">基础代谢 / 能量需求</span><span className="value">{fmt(t.bmr)}<small>/ {fmt(t.eer)} kcal</small></span><span className="delta">{t.eerMethod}</span></div></div>
        <div className="card stat-card"><div className="stat"><span className="label">每日能量目标（无活动数据时）</span><span className="value">{fmt(t.energyTarget)}<small>kcal</small></span><span className="delta">{t.goalDeltaKcal ? `含目标调整 ${t.goalDeltaKcal > 0 ? "+" : ""}${fmt(t.goalDeltaKcal)}` : "维持"}</span></div></div>
      </div>
      <div className="grid g2">
        <div className="card">
          <div className="card-head"><h3>推荐摄入量（下限，越接近越好）</h3><span className="hint">RDA = 推荐膳食供给量；AI = 适宜摄入量</span></div>
          <div className="table-wrap">
            <table className="table">
              <thead><tr><th>营养素</th><th className="num">目标</th><th>类型</th><th className="num">UL 上限</th></tr></thead>
              <tbody>
                {meta.nutrients.filter((n) => t.intake[n.key]).map((n) => (
                  <tr key={n.key}>
                    <td>{n.zh}{t.intake[n.key].note && <div className="small muted">{t.intake[n.key].note}</div>}</td>
                    <td className="num">{fmt(t.intake[n.key].value, n.decimals)} {n.unit}</td>
                    <td>{t.intake[n.key].kind}</td>
                    <td className="num small">{t.upper[n.key] ? `${fmt(t.upper[n.key].value, n.decimals)}${t.upper[n.key].appliesToTotal ? "" : "*"}` : "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="small muted" style={{ marginTop: 8 }}>* 该 UL 只针对补充剂/强化食品或特定形式（如预制维生素 A、合成叶酸），食物总量不参与 UL 评分。</p>
        </div>
        <div className="card">
          <div className="card-head"><h3>限量标准（上限，越少越好）</h3></div>
          <div className="table-wrap">
            <table className="table">
              <thead><tr><th>项目</th><th className="num">理想</th><th className="num">上限</th><th>依据</th></tr></thead>
              <tbody>
                {Object.values(t.limits).map((l) => (
                  <tr key={l.key}>
                    <td>{l.zh}{l.note && <div className="small muted">{l.note}</div>}</td>
                    <td className="num">{fmt(l.ideal, 1)} {l.unit}</td>
                    <td className="num">{fmt(l.limit, 1)} {l.unit}</td>
                    <td><SourceLinks ids={[...new Set([l.idealSource, l.limitSource])]} sources={meta.sources} /></td>
                  </tr>
                ))}
                <tr><td>每餐添加糖</td><td className="num">0</td><td className="num">{t.addedSugarPerMealG} g</td><td><SourceLinks ids={["dga_2025"]} sources={meta.sources} /></td></tr>
                <tr><td>阿斯巴甜 ADI（按体重）</td><td className="num">—</td><td className="num">{fmt(t.aspartameAdiMg)} mg</td><td><SourceLinks ids={["iarc_aspartame"]} sources={meta.sources} /></td></tr>
              </tbody>
            </table>
          </div>
          <hr />
          <h3 style={{ marginBottom: 8 }}>宏量营养素可接受范围（AMDR）</h3>
          <dl className="kv">
            <dt>蛋白质</dt><dd>{t.amdr.protein.join("–")}% 能量（RDA {fmt(t.protein.rdaG)} g；DGA 2025–2030 建议 {fmt(t.protein.idealLowG)}–{fmt(t.protein.idealHighG)} g）</dd>
            <dt>碳水化合物</dt><dd>{t.amdr.carb.join("–")}% 能量</dd>
            <dt>脂肪</dt><dd>{t.amdr.fat.join("–")}% 能量</dd>
          </dl>
        </div>
      </div>
    </div>
  );
}

function DriTable() {
  const { meta } = useApp();
  const { data } = useLoad(() => api.get<{ lifeStages: { id: string; zh: string }[]; intake: Record<string, { kind: string; values: (number | null)[] }>; upper: Record<string, { values: (number | null)[]; appliesToTotal: boolean }>; sodiumCdrr: number[]; proteinPerKg: number[] }>("/standards/dri"), []);
  const [mode, setMode] = useState<"intake" | "upper">("intake");
  if (!data || !meta) return <Loading />;
  const rows = mode === "intake" ? data.intake : data.upper;
  return (
    <div className="card">
      <div className="card-head">
        <Seg value={mode} onChange={setMode} options={[{ key: "intake", label: "RDA / AI 推荐量" }, { key: "upper", label: "UL 可耐受最高摄入量" }]} />
        <span className="hint">来源：NASEM DRI 汇总表（钠/钾为 2019 版）</span>
      </div>
      <div className="table-wrap" style={{ maxHeight: 620, overflow: "auto" }}>
        <table className="table" style={{ fontSize: 12.5 }}>
          <thead>
            <tr>
              <th style={{ position: "sticky", left: 0, background: "var(--surface)" }}>营养素</th>
              {data.lifeStages.map((s) => <th key={s.id} className="num">{s.zh}</th>)}
            </tr>
          </thead>
          <tbody>
            {Object.entries(rows).map(([k, r]) => {
              const n = meta.nutrients.find((x) => x.key === k);
              return (
                <tr key={k}>
                  <td style={{ position: "sticky", left: 0, background: "var(--surface)", whiteSpace: "nowrap" }}>
                    {n?.zh ?? k} <span className="muted">{n?.unit}{"kind" in r ? ` · ${(r as { kind: string }).kind}` : (r as { appliesToTotal: boolean }).appliesToTotal ? "" : " · 仅补充剂"}</span>
                  </td>
                  {(r.values as (number | null)[]).map((v: number | null, i: number) => <td key={i} className="num">{v == null ? "ND" : fmt(v, 2)}</td>)}
                </tr>
              );
            })}
            {mode === "intake" && (
              <>
                <tr><td style={{ position: "sticky", left: 0, background: "var(--surface)" }}>蛋白质 <span className="muted">g/kg</span></td>{data.proteinPerKg.map((v, i) => <td key={i} className="num">{v}</td>)}</tr>
                <tr><td style={{ position: "sticky", left: 0, background: "var(--surface)" }}>钠 CDRR <span className="muted">mg（超过即应减少）</span></td>{data.sodiumCdrr.map((v, i) => <td key={i} className="num">{fmt(v)}</td>)}</tr>
              </>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function HazardList() {
  const { meta } = useApp();
  if (!meta) return <Loading />;
  return (
    <div className="stack">
      <div className="banner">IARC 分级表示“证据强度”而不是“危险程度”：加工肉与吸烟同属 1 类，意味着致癌证据同样充分，而不是危害同样大。本站按剂量扣分，并设单项与总计上限（每日最多扣 {meta.hazardTotalCap} 分）。</div>
      <div className="grid g2">
        {meta.hazards.map((h) => (
          <div className="card col" key={h.key} style={{ gap: 8 }}>
            <div className="row wrap"><h3>{h.zh}</h3><IarcChip group={h.iarc} /><span className="muted small">{h.en}</span></div>
            <div className="small"><b>风险：</b>{h.risk}</div>
            <div className="small"><b>判定：</b>{h.detect}</div>
            <div className="small sec"><b>例：</b>{h.examples}</div>
            <div className="small">
              <b>扣分：</b>
              {h.key === "aspartame" ? `超过按体重计算的 ADI（40 mg/kg）扣 ${h.cap} 分` : `每 ${h.refAmount} ${h.dose.unit} 扣 ${h.penaltyPerRef} 分${h.freeAmount ? `（前 ${h.freeAmount} ${h.dose.unit} 免扣）` : ""}，每日最多 ${h.cap} 分${h.sensitiveMultiplier ? `；孕期/哺乳期/未成年 ×${h.sensitiveMultiplier}` : ""}`}
            </div>
            <div className="small" style={{ color: "var(--accent-text)" }}><b>建议：</b>{h.advice}</div>
            <SourceLinks ids={h.sources} sources={meta.sources} />
          </div>
        ))}
      </div>
      <div className="card">
        <div className="card-head"><h3>已知但不计分的项目</h3></div>
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>项目</th><th>分级</th><th>常见来源</th><th>不计分原因</th></tr></thead>
            <tbody>
              {meta.hazardsInfoOnly.map((h) => (
                <tr key={h.zh}><td>{h.zh}</td><td>{h.iarc === "3" ? <span className="chip">IARC 3 类</span> : <IarcChip group={h.iarc} />}</td><td className="small">{h.examples}</td><td className="small sec">{h.why}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

function HeiTable() {
  const { meta } = useApp();
  if (!meta) return <Loading />;
  return (
    <div className="card">
      <div className="card-head"><h3>HEI-2020 组分与评分标准</h3><span className="hint">满分 100；按每 1000 kcal 密度计算，两端之间线性插值</span></div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>组分</th><th>类型</th><th className="num">满分</th><th>满分标准</th><th>零分标准</th></tr></thead>
          <tbody>
            {meta.hei.map((c) => (
              <tr key={c.key}>
                <td>{c.zh} <span className="muted small">{c.en}</span></td>
                <td>{c.kind === "adequacy" ? "充足（越多越好）" : "适度（越少越好）"}</td>
                <td className="num">{c.max}</td>
                <td>{c.kind === "adequacy" ? "≥" : "≤"} {c.best} {c.unit}</td>
                <td>{c.kind === "adequacy" ? (c.worst ? `≤ ${c.worst}` : "0") : `≥ ${c.worst}`} {c.unit}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="small muted" style={{ marginTop: 8 }}>豆类同时计入“蔬菜总量”“深绿色蔬菜与豆类”“蛋白质食物”“海产与植物蛋白”四个组分（HEI-2015 起的做法）。</p>
    </div>
  );
}

function MetTable() {
  const { meta } = useApp();
  if (!meta) return <Loading />;
  return (
    <div className="card">
      <div className="card-head"><h3>运动代谢当量（2024 Adult Compendium）</h3><span className="hint">净消耗 = (MET − 1) × 体重 × 小时，扣除静息部分避免与基础代谢重复</span></div>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th>活动</th><th className="num">MET</th><th>强度</th><th className="num">典型速度</th></tr></thead>
          <tbody>
            {meta.activities.map((a) => (
              <tr key={a.key}><td>{a.zh}</td><td className="num">{a.met}</td><td>{a.intensity === "vigorous" ? "高强度" : a.intensity === "moderate" ? "中等" : "轻度"}</td><td className="num">{a.speedKmh ? `${a.speedKmh} km/h` : "—"}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Rules() {
  const { meta } = useApp();
  if (!meta) return <Loading />;
  const cw = meta.categoryWeights;
  return (
    <div className="stack">
      <div className="card stack">
        <h2>每日综合分（0–100）</h2>
        <div className="banner accent" style={{ fontSize: 14.5 }}>
          综合分 = 膳食质量 × {cw.hei.weight}% + 营养素充足 × {cw.adequacy.weight}% + 限量控制 × {cw.moderation.weight}% + 能量平衡 × {cw.energy.weight}% − 致癌/风险物扣分（≤ {meta.hazardTotalCap}）
        </div>
        <dl className="kv">
          <dt>A 膳食质量</dt><dd>直接使用 HEI-2020 总分（0–100）。</dd>
          <dt>B 营养素充足</dt><dd>对照你的 RDA/AI，每项得分 = min(1, 摄入 ÷ 目标)，按权重加权平均。DGA 列出的“公共健康关注营养素”（蛋白质、膳食纤维、钾、钙、维生素 D）权重 ×2；育龄女性和孕妇的铁、孕妇的叶酸权重 ×2。≥100% 达标，70–100% 偏离，&lt;70% 不达标。</dd>
          <dt>C 限量控制</dt><dd>钠、添加糖、饱和脂肪（权重各 3）、酒精（2）、反式脂肪、咖啡因、超加工食品供能比、每餐添加糖 ≤10 g（各 1）、三大营养素 AMDR（各 0.5）、超过 UL 的营养素（每项 1，得 0 分）。<br />
            得分曲线：≤ 理想值 得满分；理想值 → 上限 线性降到 0.7；超过上限后线性下降，到 2 倍上限为 0。例：钠上限 2300、理想 1500 mg，吃到 3450 mg（超 50%）该项只得 0.35，折合少得约 3 分。</dd>
          <dt>D 能量平衡</dt><dd>今日目标 = 当日消耗 ± 目标调整（减重每周 0.5 kg ≈ −550 kcal/天），不低于 BMR 与 1200/1500 kcal。偏差 ≤10% 满分，偏差 50% 得 0 分。</dd>
          <dt>风险物扣分</dt><dd>按剂量扣分：加工肉每 50 g 扣 6 分（WHO：每天 50 g 结直肠癌风险 +18%），红肉超出日均 70 g 的部分每 100 g 扣 3 分，酒精每标准杯（14 g）扣 2 分，炭烤/烟熏/油炸淀粉/腌菜/咸鱼/槟榔等按份量扣分，各有上限。详见“致癌物与风险物”。</dd>
          <dt>和体重年龄挂钩的项</dt><dd>能量（NASEM 2023 EER：年龄、身高、体重、性别、活动水平）、蛋白质（g/kg）、膳食纤维（14 g/1000 kcal × 能量目标）、所有 DRI（按年龄性别分 20 个人群）、咖啡因（未成年人 2.5 mg/kg）、阿斯巴甜 ADI（40 mg/kg）、反式脂肪（能量的 1%）、添加糖上限（能量的 10%）。</dd>
        </dl>
      </div>
      <div className="card stack">
        <h2>周 / 月评分</h2>
        <div className="banner accent">周期分 = 有记录日的日均综合分 × 70% + 生活方式分 × 30%</div>
        <p className="sec">生活方式分只在按周看才有意义：中高强度运动 150–300 分钟/周（高强度按 2 倍计，权重 3）、力量训练 ≥2 天/周（1）、红肉 ≤350–500 g/周（2）、海产 ≥8 盎司/周（1）、饮酒低于大量饮酒阈值（1）、记录 ≥6 天/周（1）、体重变化速度符合目标（1）。HEI-2020 另按整个周期的总摄入计算（比单日更稳定）。</p>
        <p className="sec">体重趋势使用指数移动平均（α = 0.1）过滤每日水分波动；“反推日消耗” = 日均摄入 − 趋势体重变化 × 7700 ÷ 天数，需要 ≥14 天且 70% 以上天数记录完整。</p>
      </div>
      <div className="card">
        <h3 style={{ marginBottom: 8 }}>营养素充足度权重</h3>
        <div className="row wrap">
          {Object.entries(meta.adequacyWeights).map(([k, w]) => (
            <span key={k} className="chip">{meta.nutrients.find((n) => n.key === k)?.zh ?? k} ×{w}</span>
          ))}
        </div>
      </div>
    </div>
  );
}

function Sources() {
  const { meta } = useApp();
  if (!meta) return <Loading />;
  return (
    <div className="card">
      <div className="list">
        {meta.sources.map((s) => (
          <div className="list-item" key={s.id} style={{ alignItems: "flex-start" }}>
            <span className="chip" style={{ minWidth: 60, justifyContent: "center" }}>{s.year}</span>
            <div className="grow">
              <div style={{ fontWeight: 600 }}>{s.url ? <a href={s.url} target="_blank" rel="noreferrer">{s.title}</a> : s.title}</div>
              <div className="small muted">{s.org}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
