// 2018 WCRF/AICR 癌症预防建议标准化评分（Shams-White MM et al., Nutrients 2019;11:1572, Table 2）
// 7 条核心建议各 0–1 分（等权），子项平分该条的 1 分。
// “快餐与超加工食品”一条的切点是各研究数据集内的三分位数，没有公开的绝对切点，
// 因此本系统只展示超加工供能比、不计入该条（总分按 6 条计，并注明）。

export interface WcrfInputs {
  sex: "male" | "female";
  bmi: number | null;
  waistCm: number | null;
  /** 中等及以上强度活动 分钟/周（原文未规定高强度是否加倍，这里不加倍） */
  mvpaMinutesPerWeek: number | null;
  fruitVegGPerDay: number | null;
  fiberGPerDay: number | null;
  upfPct: number | null;
  redMeatGPerWeek: number | null;
  processedMeatGPerWeek: number | null;
  ssbMlPerDay: number | null;
  alcoholGPerDay: number | null;
}

export interface WcrfComponent {
  key: string;
  zh: string;
  points: number | null;
  max: number;
  detail: string;
  rule: string;
}

export interface WcrfResult {
  score: number;
  max: number;
  components: WcrfComponent[];
}

const f1 = (v: number) => (Math.round(v * 10) / 10).toString();

export function computeWcrf(x: WcrfInputs): WcrfResult {
  const comps: WcrfComponent[] = [];

  // 1. 健康体重：BMI 与腰围各 0.5；只有一项时该项分数加倍
  {
    const bmiP = x.bmi == null ? null : x.bmi >= 18.5 && x.bmi < 25 ? 0.5 : x.bmi >= 25 && x.bmi < 30 ? 0.25 : 0;
    const [hi, lo] = x.sex === "male" ? [102, 94] : [88, 80];
    const waistP = x.waistCm == null ? null : x.waistCm < lo ? 0.5 : x.waistCm < hi ? 0.25 : 0;
    const pts = bmiP != null && waistP != null ? bmiP + waistP : bmiP != null ? bmiP * 2 : waistP != null ? waistP * 2 : null;
    comps.push({
      key: "weight", zh: "保持健康体重", points: pts, max: 1,
      detail: [x.bmi != null ? `BMI ${f1(x.bmi)}` : "", x.waistCm != null ? `腰围 ${f1(x.waistCm)} cm` : "腰围未记录（按 BMI 计）"].filter(Boolean).join("，"),
      rule: `BMI 18.5–24.9 得 0.5，25–29.9 得 0.25；腰围 ${x.sex === "male" ? "男 <94 cm 得 0.5，94–101.9 得 0.25" : "女 <80 cm 得 0.5，80–87.9 得 0.25"}`,
    });
  }
  // 2. 身体活动
  comps.push({
    key: "activity", zh: "积极运动",
    points: x.mvpaMinutesPerWeek == null ? null : x.mvpaMinutesPerWeek >= 150 ? 1 : x.mvpaMinutesPerWeek >= 75 ? 0.5 : 0,
    max: 1,
    detail: x.mvpaMinutesPerWeek == null ? "无数据" : `${Math.round(x.mvpaMinutesPerWeek)} 分钟/周`,
    rule: "中高强度活动 ≥150 分钟/周得 1，75–149 得 0.5",
  });
  // 3. 全谷物、蔬菜、水果、豆类：果蔬与膳食纤维各 0.5
  {
    const fv = x.fruitVegGPerDay == null ? null : x.fruitVegGPerDay >= 400 ? 0.5 : x.fruitVegGPerDay >= 200 ? 0.25 : 0;
    const fb = x.fiberGPerDay == null ? null : x.fiberGPerDay >= 30 ? 0.5 : x.fiberGPerDay >= 15 ? 0.25 : 0;
    comps.push({
      key: "plants", zh: "多吃全谷物、蔬菜、水果、豆类", points: fv == null || fb == null ? null : fv + fb, max: 1,
      detail: x.fruitVegGPerDay == null ? "无数据" : `果蔬 ${Math.round(x.fruitVegGPerDay)} g/天，膳食纤维 ${f1(x.fiberGPerDay ?? 0)} g/天`,
      rule: "果蔬 ≥400 g/天得 0.5（200–399 得 0.25）；膳食纤维 ≥30 g/天得 0.5（15–29 得 0.25）",
    });
  }
  // 4. 快餐与超加工食品：无绝对切点，不计分
  comps.push({
    key: "upf", zh: "少吃快餐和高脂高糖高淀粉的加工食品", points: null, max: 0,
    detail: x.upfPct == null ? "无数据" : `超加工食品供能 ${Math.round(x.upfPct)}%（仅展示）`,
    rule: "原文按研究人群内的三分位数评分，没有公开的绝对切点，本系统不计分",
  });
  // 5. 红肉与加工肉
  {
    const r = x.redMeatGPerWeek;
    const p = x.processedMeatGPerWeek;
    const pts = r == null || p == null ? null : r <= 500 && p < 21 ? 1 : r <= 500 && p < 100 ? 0.5 : 0;
    comps.push({
      key: "meat", zh: "限制红肉和加工肉", points: pts, max: 1,
      detail: r == null ? "无数据" : `红肉 ${Math.round(r)} g/周，加工肉 ${Math.round(p ?? 0)} g/周`,
      rule: "红肉 ≤500 g/周且加工肉 <21 g/周得 1；加工肉 21–99 得 0.5；红肉 >500 或加工肉 ≥100 得 0",
    });
  }
  // 6. 含糖饮料
  comps.push({
    key: "ssb", zh: "限制含糖饮料",
    points: x.ssbMlPerDay == null ? null : x.ssbMlPerDay <= 0.5 ? 1 : x.ssbMlPerDay <= 250 ? 0.5 : 0,
    max: 1,
    detail: x.ssbMlPerDay == null ? "无数据" : `${Math.round(x.ssbMlPerDay)} ml/天`,
    rule: "0 得 1；≤250 ml/天得 0.5；>250 得 0",
  });
  // 7. 酒精
  {
    const lim = x.sex === "male" ? 28 : 14;
    comps.push({
      key: "alcohol", zh: "限制饮酒",
      points: x.alcoholGPerDay == null ? null : x.alcoholGPerDay <= 0.5 ? 1 : x.alcoholGPerDay <= lim ? 0.5 : 0,
      max: 1,
      detail: x.alcoholGPerDay == null ? "无数据" : `纯酒精 ${f1(x.alcoholGPerDay)} g/天`,
      rule: `不饮酒得 1；≤${lim} g/天得 0.5；>${lim} g 得 0`,
    });
  }
  const scored = comps.filter((c) => c.points != null && c.max > 0);
  return {
    score: scored.reduce((s, c) => s + (c.points ?? 0), 0),
    max: scored.reduce((s, c) => s + c.max, 0),
    components: comps,
  };
}
