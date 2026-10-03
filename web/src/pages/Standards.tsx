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
      <div className="banner">IARC 分级表示“证据强度”而不是“危险程度”：加工肉与吸烟同属 1 类，意味着致癌证据同样充分，而不是危害同样大。没有权威机构发布过把这些分级换算成扣分的方法，所以本站只按剂量给出警示、不另设扣分；其中加工肉、红肉、酒精、含糖饮料按 WCRF/AICR 标准化评分计分。</div>
      <div className="grid g2">
        {meta.hazards.map((h) => (
          <div className="card col" key={h.key} style={{ gap: 8 }}>
            <div className="row wrap"><h3>{h.zh}</h3><IarcChip group={h.iarc} /><span className="muted small">{h.en}</span></div>
            <div className="small"><b>风险：</b>{h.risk}</div>
            <div className="small"><b>判定：</b>{h.detect}</div>
            <div className="small sec"><b>例：</b>{h.examples}</div>
            <div className="small" style={{ color: "var(--accent-text)" }}><b>建议：</b>{h.advice}</div>
            <SourceLinks ids={h.sources} sources={meta.sources} />
          </div>
        ))}
      </div>
      <div className="card">
        <div className="card-head"><h3>已知但不警示的项目</h3></div>
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>项目</th><th>分级</th><th>常见来源</th><th>原因</th></tr></thead>
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

const LE8_TABLE: [string, string][] = [
  ["饮食", "个人用 MEPA 16 题问卷：15–16 → 100；12–14 → 80；8–11 → 50；4–7 → 25；0–3 → 0（本站由饮食记录自动推算每周份数）"],
  ["身体活动（分钟/周，高强度 ×2）", "≥150 → 100；120–149 → 90；90–119 → 80；60–89 → 60；30–59 → 40；1–29 → 20；0 → 0"],
  ["尼古丁暴露", "从不 100；戒 ≥5 年 75；戒 1–5 年 50；戒 <1 年或电子烟 25；吸烟 0；家中有人室内吸烟 −20"],
  ["睡眠（小时/晚）", "7–<9 → 100；9–<10 → 90；6–<7 → 70；5–<6 或 ≥10 → 40；4–<5 → 20；<4 → 0"],
  ["BMI", "<25 → 100；25–29.9 → 70；30–34.9 → 30；35–39.9 → 15；≥40 → 0"],
  ["非 HDL 胆固醇（mg/dL）", "<130 → 100；130–159 → 60；160–189 → 40；190–219 → 20；≥220 → 0；服药 −20"],
  ["血糖", "无糖尿病：空腹 <100 或 HbA1c <5.7 → 100；100–125 或 5.7–6.4 → 60；糖尿病：HbA1c <7 → 40，7–7.9 → 30，8–8.9 → 20，9–9.9 → 10，≥10 → 0"],
  ["血压（mmHg）", "<120/<80 → 100；120–129/<80 → 75；130–139 或 80–89 → 50；140–159 或 90–99 → 25；≥160 或 ≥100 → 0；服药 −20"],
];

const WCRF_TABLE: [string, string][] = [
  ["保持健康体重", "BMI 18.5–24.9 → 0.5，25–29.9 → 0.25；腰围 男 <94 / 女 <80 cm → 0.5，男 94–101.9 / 女 80–87.9 → 0.25（只有一项时分数加倍）"],
  ["积极运动", "中高强度 ≥150 分钟/周 → 1；75–149 → 0.5；<75 → 0"],
  ["多吃全谷物、蔬菜、水果、豆类", "果蔬 ≥400 g/天 → 0.5（200–399 → 0.25）；膳食纤维 ≥30 g/天 → 0.5（15–29 → 0.25）"],
  ["少吃快餐和加工食品", "原文按研究人群内超加工供能比的三分位数评分，没有绝对切点 —— 本站只展示、不计分"],
  ["限制红肉和加工肉", "红肉 ≤500 g/周且加工肉 <21 g/周 → 1；加工肉 21–99 g/周 → 0.5；红肉 >500 或加工肉 ≥100 → 0"],
  ["限制含糖饮料", "0 → 1；≤250 ml/天 → 0.5；>250 → 0"],
  ["限制饮酒", "不饮酒 → 1；男 ≤28 / 女 ≤14 g 纯酒精/天 → 0.5；以上 → 0"],
];

function Rules() {
  const { meta } = useApp();
  if (!meta) return <Loading />;
  return (
    <div className="stack">
      <div className="banner accent" style={{ fontSize: 14.5 }}>
        评分规则 v2：全部采用已发表、经同行评议的评分体系，不自定权重。“美国心脏协会 LE8”“WCRF/AICR”“MAR”都是等权合成；HEI-2020 的组分分值由 USDA 规定。
      </div>
      <div className="card stack">
        <h2>每日：膳食质量 HEI-2020 + 微量营养素 MAR</h2>
        <dl className="kv">
          <dt>今日膳食质量</dt><dd>HEI-2020 总分（USDA / NCI）。13 个组分按每 1000 kcal 的密度在“零分标准”与“满分标准”之间线性计分，分值见“HEI-2020”标签页。例如钠 ≤1.1 g/1000 kcal 得 10 分，≥2.0 g 得 0 分，页面会写明“钠组分扣 x 分”。美国人平均 {meta.heiUsMean} 分（NHANES 2017–2018）。</dd>
          <dt>微量营养素 MAR</dt><dd>平均充足比（Madden & Yoder 1972；FAO 最低膳食多样性验证研究采用的 11 种微量营养素：{meta.marNutrients.map((k) => meta.nutrients.find((n) => n.key === k)?.zh).join("、")}）。每种 NAR = min(摄入 ÷ RDA, 1)，等权平均 × 100。注：IOM 指出按 RDA 判断个人单日摄入只是粗略参考。</dd>
          <dt>其他检查项</dt><dd>其余营养素对照 RDA/AI；钠（CDRR 2300 mg / AHA 1500 mg）、添加糖、饱和脂肪、反式脂肪、酒精、咖啡因、超加工食品、每餐添加糖、AMDR、UL；能量平衡。这些只标“达标 / 偏离 / 不达标”并写明超出多少，不另设权重。</dd>
          <dt>致癌物与风险物</dt><dd>按 IARC 分级给出警示与剂量，不另设扣分；加工肉、红肉、酒精、含糖饮料在 WCRF/AICR 评分中计分。</dd>
        </dl>
      </div>
      <div className="card stack">
        <h2>综合：美国心脏协会 Life's Essential 8（LE8）</h2>
        <p className="sec">Lloyd-Jones DM et al., Circulation 2022。8 项各 0–100 分，<b>总分 = 已有指标的等权平均</b>（缺失指标不计入分母，按官方补充材料）；80–100 高，50–79 中，0–49 低。今日页显示近 7 天，周报 / 月报显示整个周期。</p>
        <div className="table-wrap">
          <table className="table">
            <tbody>{LE8_TABLE.map(([k, v]) => <tr key={k}><td style={{ width: 200, fontWeight: 600 }}>{k}</td><td className="small">{v}</td></tr>)}</tbody>
          </table>
        </div>
      </div>
      <div className="card stack">
        <h2>防癌：2018 WCRF/AICR 标准化评分</h2>
        <p className="sec">Shams-White MM et al., Nutrients 2019。7 条建议各 1 分、等权，子项平分该条的 1 分（母乳喂养为可选项，不计）。</p>
        <div className="table-wrap">
          <table className="table">
            <tbody>{WCRF_TABLE.map(([k, v]) => <tr key={k}><td style={{ width: 200, fontWeight: 600 }}>{k}</td><td className="small">{v}</td></tr>)}</tbody>
          </table>
        </div>
      </div>
      <div className="card stack">
        <h2>能量与体重</h2>
        <p className="sec">能量需求：NASEM 2023 EER 方程（19 岁以上）；基础代谢：Mifflin-St Jeor。有设备数据时，消耗 = (静息 + 活动能量 + 未被设备记录的运动) ÷ 0.9；运动净消耗 = (MET − 1) × 体重 × 小时（2024 Compendium）。体重趋势用指数移动平均（α = 0.1）；“反推日消耗” = 日均摄入 − 趋势体重变化 × 7700 ÷ 天数。能量平衡只标状态，体重结果体现在 LE8 的 BMI 与 WCRF 的健康体重中。</p>
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
