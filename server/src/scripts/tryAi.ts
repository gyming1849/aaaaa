// 手动测试 AI 分析：npx tsx src/scripts/tryAi.ts "今天中午吃了一包李子柒螺蛳粉，加了一个卤蛋"
import { analyzeMeal } from "../ai/service.ts";
import { activeProvider } from "../ai/providers.ts";

const text = process.argv[2] ?? "中午吃了一包李子柒螺蛳粉，加了一个卤蛋，喝了一罐可乐";
console.log("provider:", activeProvider());
const t0 = Date.now();
const r = await analyzeMeal(0, { text, date: "2026-09-30", time: "12:30", meal_type: "lunch", photos: [] }, null);
console.log(`耗时 ${Math.round((Date.now() - t0) / 1000)} 秒`);
for (const it of r.items) {
  const n = it.nutrients;
  console.log(`- ${it.name} ${it.amount_g}g (${it.amount_desc}) | ${Math.round(n.energy_kcal)} kcal, 蛋白 ${n.protein_g.toFixed(1)}g, 钠 ${Math.round(n.sodium_mg)}mg, 添加糖 ${n.added_sugars_g.toFixed(1)}g, 饱和脂肪 ${n.sat_fat_g.toFixed(1)}g | NOVA ${it.nova_group} | 风险 ${JSON.stringify(it.hazards)} | 建议保存 ${it.save_suggested}`);
}
console.log("summary:", r.summary);
console.log("assumptions:", r.assumptions);
console.log("sources:", r.sources);
