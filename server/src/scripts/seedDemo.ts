// 生成演示数据：npm run seed:demo（会在当前数据库里创建 demo / xiaolin / ahao 三个账号，密码均为 demo123）
import { db, run, get, tx } from "../db/index.ts";
import { hashPassword } from "../auth.ts";
import { mockAnalyzeMeal } from "../ai/mock.ts";
import { todayIn, addDays } from "../lib/dates.ts";
import { ACTIVITY_MAP, netKcal } from "../standards/met.ts";
import { invalidateAll } from "../services/userdata.ts";

const MENUS = {
  breakfast: ["两个鸡蛋，一杯牛奶，一片全麦面包", "燕麦粥一碗，一根香蕉，一个鸡蛋", "两个肉包子，一杯豆浆", "油条一根，豆浆一杯", "全麦面包两片，一杯拿铁，一个苹果", "培根两片，两个煎蛋，白吐司两片，黑咖啡"],
  lunch: ["一碗米饭，西兰花炒牛肉，番茄炒蛋", "一包螺蛳粉，一罐可乐", "牛肉面一碗", "米饭一碗，清蒸鱼，炒青菜", "汉堡一个，薯条一份，可乐一杯", "糙米饭一碗，鸡胸肉，蔬菜沙拉", "饺子一份，拍黄瓜"],
  dinner: ["米饭一碗，红烧肉，炒青菜", "三文鱼，糙米饭，西兰花", "烤串五串，啤酒一瓶", "米饭，虾，炒菠菜，豆腐", "披萨两块，零度可乐一罐", "面条一碗，鸡蛋两个，青菜", "米饭一碗，腊肠，炒油麦菜"],
  snack: ["奶茶一杯", "一个苹果", "坚果一小把", "蛋糕一块", "酸奶一杯", "一根香蕉", "薯片一小包"],
};

const USERS = [
  { username: "demo", display: "演示用户", sex: "male", birth: "1992-06-18", h: 176, w: 82, goal: "lose", target: 74, color: "#2f7d5b", share: "public", detail: "full", level: "low_active", healthy: 0.55 },
  { username: "xiaolin", display: "小林", sex: "female", birth: "1996-11-02", h: 163, w: 56, goal: "maintain", target: null, color: "#b5523b", share: "public", detail: "summary", level: "active", healthy: 0.75 },
  { username: "ahao", display: "阿豪", sex: "male", birth: "1988-03-09", h: 172, w: 70, goal: "maintain", target: null, color: "#3b6fb6", share: "private", detail: "summary", level: "inactive", healthy: 0.35 },
];

function rand(seed: number) {
  let s = seed;
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296;
    return s / 4294967296;
  };
}

const days = Number(process.argv[2] ?? 75);
const today = todayIn("Asia/Shanghai");

for (const [ui, u] of USERS.entries()) {
  const exists = get<{ id: number }>("SELECT id FROM users WHERE username = ?", u.username);
  if (exists) {
    console.log(`跳过已存在的用户 ${u.username}`);
    continue;
  }
  const r = rand(ui * 7919 + 17);
  const pick = <T,>(xs: T[], healthyBias: boolean) => {
    // healthy 用户更倾向于列表中“健康”的选项（这里简单用前半部分近似）
    const half = Math.ceil(xs.length / 2);
    return healthyBias && r() < u.healthy ? xs[Math.floor(r() * half)] : xs[Math.floor(r() * xs.length)];
  };
  tx(() => {
    const uid = Number(
      run("INSERT INTO users (username, display_name, password_hash, avatar_color, share_mode, share_detail) VALUES (?, ?, ?, ?, ?, ?)",
        u.username, u.display, hashPassword("demo123"), u.color, u.share, u.detail).lastInsertRowid,
    );
    run(
      `INSERT INTO profiles (user_id, sex, birth_date, height_cm, weight_kg, activity_level, goal, goal_rate_kg_week, target_weight_kg, physiology, sodium_mode, conditions, timezone, nicotine)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0.5, ?, 'none', 'cdrr', '[]', 'Asia/Shanghai', ?)`,
      uid, u.sex, u.birth, u.h, u.w, u.level, u.goal, u.target, ui === 2 ? "former_1_5y" : "never",
    );
    // 体检化验（用于 LE8 血脂、血糖）
    run("INSERT INTO lab_results (user_id, date, total_chol, hdl, non_hdl, fasting_glucose, hba1c) VALUES (?, ?, ?, ?, ?, ?, ?)",
      uid, addDays(today, -120), 190 + ui * 15, 48 - ui * 3, 142 + ui * 18, 94 + ui * 6, 5.4 + ui * 0.2);
    let weight = u.w;
    for (let i = days - 1; i >= 0; i--) {
      const date = addDays(today, -i);
      if (r() < 0.08 && i > 0) continue; // 偶尔漏记
      const meals: [string, string, string][] = [
        ["breakfast", "08:0" + Math.floor(r() * 9), pick(MENUS.breakfast, true)],
        ["lunch", "12:" + (10 + Math.floor(r() * 40)), pick(MENUS.lunch, true)],
        ["dinner", "18:" + (10 + Math.floor(r() * 40)), pick(MENUS.dinner, true)],
      ];
      if (r() < 0.6) meals.push(["snack", "15:30", pick(MENUS.snack, true)]);
      if (i === 0) meals.splice(2); // 今天只记到午饭
      let kcal = 0;
      for (const [type, time, text] of meals) {
        const a = mockAnalyzeMeal(text);
        const mealId = Number(run("INSERT INTO meals (user_id, date, time, meal_type, description, ai_model) VALUES (?, ?, ?, ?, ?, 'offline')", uid, date, time, type, text).lastInsertRowid);
        for (const it of a.items) {
          kcal += it.nutrients.energy_kcal;
          run(
            `INSERT INTO meal_items (meal_id, user_id, date, name, amount_g, amount_desc, category, cooking_method, nova_group, confidence, nutrients, groups, hazards, notes)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            mealId, uid, date, it.name, it.amount_g, it.amount_desc, it.category, it.cooking_method, it.nova_group, it.confidence,
            JSON.stringify(it.nutrients), JSON.stringify(it.food_groups), JSON.stringify(it.hazards), "",
          );
        }
      }
      // 活动
      const steps = Math.round(4000 + r() * 9000 + (u.level === "active" ? 3000 : 0));
      const active = Math.round(steps * 0.035 + r() * 120);
      run("INSERT INTO activity_days (user_id, date, steps, active_kcal, resting_kcal, exercise_min, sleep_hours, source) VALUES (?, ?, ?, ?, ?, ?, ?, 'apple_shortcut')",
        uid, date, steps, active, Math.round(10 * weight + 6.25 * u.h - 5 * 34 + (u.sex === "male" ? 5 : -161)), Math.round(r() * 40),
        Math.round((6 + r() * 2.6) * 10) / 10);
      if (r() < 0.3) {
        const act = ACTIVITY_MAP[["swim_freestyle_medium", "jogging", "strength_moderate", "badminton", "cycle_moderate"][Math.floor(r() * 5)]];
        const dur = 30 + Math.floor(r() * 60);
        run("INSERT INTO exercises (user_id, date, time, description, activity_key, met, duration_min, kcal, in_device, source) VALUES (?, ?, '19:30', ?, ?, ?, ?, ?, 1, 'manual')",
          uid, date, act.zh, act.key, act.met, dur, Math.round(netKcal(act.met, weight, dur)));
      }
      // 体重：跟随能量差 + 噪声
      const tdee = 10 * weight + 6.25 * u.h - 5 * 34 + 5 + active + 150;
      weight += (kcal - tdee / 0.9) / 7700 + (r() - 0.5) * 0.02;
      if (r() < 0.85) {
        const bp = i % 7 === 0 ? [118 + ui * 8 + Math.round(r() * 10), 74 + ui * 4 + Math.round(r() * 6)] : [null, null];
        run("INSERT INTO body_metrics (user_id, date, time, weight_kg, sbp, dbp, waist_cm, source) VALUES (?, ?, '22:30', ?, ?, ?, ?, 'manual')",
          uid, date, Math.round((weight + (r() - 0.5) * 0.8) * 10) / 10, bp[0], bp[1], i % 30 === 0 ? 84 + ui * 5 : null);
      }
    }
    invalidateAll(uid);
    console.log(`已创建用户 ${u.username}（密码 demo123），${days} 天数据`);
  });
}

// 公共食物库示例
const demo = get<{ id: number }>("SELECT id FROM users WHERE username = 'demo'");
if (demo && !get("SELECT id FROM foods WHERE owner_id = ? AND name = '柳州螺蛳粉'", demo.id)) {
  const lsf = mockAnalyzeMeal("螺蛳粉").items[0];
  const f = 100 / lsf.amount_g;
  const per100 = Object.fromEntries(Object.entries(lsf.nutrients).map(([k, v]) => [k, v * f]));
  const g100 = Object.fromEntries(Object.entries(lsf.food_groups).map(([k, v]) => [k, v * f]));
  run(
    `INSERT INTO foods (owner_id, visibility, name, brand, aliases, category, serving_g, serving_desc, per100, groups100, hazards100, nova_group, source, notes)
     VALUES (?, 'public', '柳州螺蛳粉', '李子柒', '螺狮粉,luosifen', 'fast_food', 335, '1 包 335 g（含全部料包）', ?, ?, ?, 4, 'ai_estimate', '演示数据：离线估算值')`,
    demo.id, JSON.stringify(per100), JSON.stringify(g100), JSON.stringify([{ key: "pickled_vegetables", amount_per_100g: 9, note: "酸笋" }]),
  );
}
console.log("完成");
db.close();
