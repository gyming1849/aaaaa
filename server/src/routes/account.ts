import { Router } from "express";
import { all, get, run, tx } from "../db/index.ts";
import { config } from "../config.ts";
import {
  hashPassword, verifyPassword, createSession, destroySession, requireAuth, newApiToken, createAppToken,
} from "../auth.ts";
import { ah, bad, num, str, oneOf, HttpError } from "../lib/http.ts";
import { isDate, todayIn } from "../lib/dates.ts";
import { getProfile, invalidateAll, targetsFor, getWeights, weightOn } from "../services/userdata.ts";
import { activeProvider } from "../ai/providers.ts";
import { CONDITIONS } from "../standards/targets.ts";

export const accountRouter = Router();

const COLORS = ["#2f7d5b", "#3b6fb6", "#b5523b", "#7a5bb5", "#b58a2f", "#2f8c93", "#b53b72", "#5b7a2f"];

interface UserRow {
  id: number;
  username: string;
  display_name: string;
  password_hash: string;
  avatar_color: string;
  share_mode: string;
  share_detail: string;
  api_token_hint: string | null;
}

function publicUser(u: UserRow) {
  return {
    id: u.id,
    username: u.username,
    display_name: u.display_name,
    avatar_color: u.avatar_color,
    share_mode: u.share_mode,
    share_detail: u.share_detail,
    api_token_hint: u.api_token_hint,
  };
}

accountRouter.post(
  "/auth/register",
  ah((req, res) => {
    if (!config.allowRegistration) throw new HttpError(403, "当前站点已关闭注册");
    if (config.inviteCode && req.body.invite_code !== config.inviteCode) throw bad("邀请码不正确");
    const username = str(req.body.username, { name: "用户名", max: 32 });
    if (!/^[\w一-龥.-]{2,32}$/.test(username)) throw bad("用户名为 2–32 位，可用中文、字母、数字、_ . -");
    const password = str(req.body.password, { name: "密码" });
    if (password.length < 6) throw bad("密码至少 6 位");
    if (get("SELECT id FROM users WHERE username = ?", username)) throw bad("用户名已被占用");
    const display = str(req.body.display_name, { optional: true, max: 32 }) || username;
    const color = COLORS[Math.floor(Math.random() * COLORS.length)];
    const r = run(
      "INSERT INTO users (username, display_name, password_hash, avatar_color) VALUES (?, ?, ?, ?)",
      username,
      display,
      hashPassword(password),
      color,
    );
    const uid = Number(r.lastInsertRowid);
    // App 注册：传 device_name 时直接返回 Bearer 令牌
    if (req.body.device_name) return { ok: true, ...createAppToken(uid, String(req.body.device_name)) };
    createSession(res, uid);
    return { ok: true };
  }),
);

/** App 登录：返回 Bearer 令牌（请求头 Authorization: Bearer <token>），适用于移动端或第三方客户端 */
accountRouter.post(
  "/auth/token",
  ah((req) => {
    const username = str(req.body.username, { name: "用户名" });
    const password = str(req.body.password, { name: "密码" });
    const u = get<UserRow>("SELECT * FROM users WHERE username = ?", username);
    if (!u || !verifyPassword(password, u.password_hash)) throw new HttpError(401, "用户名或密码错误");
    const device = str(req.body.device_name, { optional: true, max: 60 }) || "App";
    return { ...createAppToken(u.id, device), user: publicUser(u) };
  }),
);

accountRouter.get(
  "/auth/sessions",
  requireAuth,
  ah((req) =>
    all<{ id: number; kind: string; device_name: string | null; created_at: string | null; last_used_at: string | null; expires_at: string }>(
      "SELECT rowid AS id, kind, device_name, created_at, last_used_at, expires_at FROM sessions WHERE user_id = ? ORDER BY last_used_at DESC",
      req.user!.id,
    ),
  ),
);

accountRouter.delete(
  "/auth/sessions/:id",
  requireAuth,
  ah((req) => {
    run("DELETE FROM sessions WHERE rowid = ? AND user_id = ?", Number(req.params.id), req.user!.id);
    return { ok: true };
  }),
);

accountRouter.post(
  "/auth/login",
  ah((req, res) => {
    const username = str(req.body.username, { name: "用户名" });
    const password = str(req.body.password, { name: "密码" });
    const u = get<UserRow>("SELECT * FROM users WHERE username = ?", username);
    if (!u || !verifyPassword(password, u.password_hash)) throw new HttpError(401, "用户名或密码错误");
    createSession(res, u.id);
    return { ok: true };
  }),
);

accountRouter.post(
  "/auth/logout",
  ah((req, res) => {
    destroySession(req, res);
    return { ok: true };
  }),
);

accountRouter.get(
  "/auth/me",
  requireAuth,
  ah((req) => {
    const u = get<UserRow>("SELECT * FROM users WHERE id = ?", req.user!.id)!;
    const profile = getProfile(u.id);
    const shareWith = all<{ viewer_id: number }>("SELECT viewer_id FROM share_grants WHERE owner_id = ?", u.id).map((r) => r.viewer_id);
    return {
      user: { ...publicUser(u), share_with: shareWith },
      profile,
      today: profile ? todayIn(profile.timezone) : new Date().toISOString().slice(0, 10),
      ai: { provider: activeProvider(), model: activeProvider() === "mock" ? "offline" : config.ai.model },
      conditions: CONDITIONS,
    };
  }),
);

accountRouter.post(
  "/auth/password",
  requireAuth,
  ah((req) => {
    const u = get<UserRow>("SELECT * FROM users WHERE id = ?", req.user!.id)!;
    if (!verifyPassword(String(req.body.old_password ?? ""), u.password_hash)) throw bad("原密码不正确");
    const pw = str(req.body.new_password, { name: "新密码" });
    if (pw.length < 6) throw bad("密码至少 6 位");
    run("UPDATE users SET password_hash = ? WHERE id = ?", hashPassword(pw), u.id);
    return { ok: true };
  }),
);

accountRouter.put(
  "/profile",
  requireAuth,
  ah((req) => {
    const b = req.body ?? {};
    const sex = oneOf(b.sex, ["male", "female"] as const);
    const birth = str(b.birth_date, { name: "出生日期" });
    if (!isDate(birth)) throw bad("出生日期格式应为 YYYY-MM-DD");
    const height = num(b.height_cm, { min: 80, max: 250, name: "身高" })!;
    const weight = num(b.weight_kg, { min: 20, max: 350, name: "体重" })!;
    const level = oneOf(b.activity_level, ["inactive", "low_active", "active", "very_active"] as const, "low_active");
    const goal = oneOf(b.goal, ["lose", "maintain", "gain"] as const, "maintain");
    const rate = num(b.goal_rate_kg_week, { min: 0.1, max: 1, optional: true, name: "目标速度" }) ?? 0.5;
    const target = num(b.target_weight_kg, { min: 20, max: 350, optional: true, name: "目标体重" });
    const physiology = sex === "female" ? oneOf(b.physiology, ["none", "pregnant", "lactating"] as const, "none") : "none";
    const sodiumMode = oneOf(b.sodium_mode, ["cdrr", "aha"] as const, "cdrr");
    const conditions = Array.isArray(b.conditions) ? b.conditions.filter((c: unknown) => CONDITIONS.some((x) => x.key === c)) : [];
    const nicotine = oneOf(b.nicotine, ["unknown", "never", "former_5y", "former_1_5y", "former_lt1y", "ecig", "current"] as const, "unknown");
    const secondhand = b.secondhand_smoke ? 1 : 0;
    let tz = str(b.timezone, { optional: true, max: 64 }) || "Asia/Shanghai";
    try {
      new Intl.DateTimeFormat("en", { timeZone: tz });
    } catch {
      tz = "Asia/Shanghai";
    }
    const uid = req.user!.id;
    const existed = get("SELECT user_id FROM profiles WHERE user_id = ?", uid);
    tx(() => {
      run(
        `INSERT INTO profiles (user_id, sex, birth_date, height_cm, weight_kg, activity_level, goal, goal_rate_kg_week, target_weight_kg, physiology, sodium_mode, conditions, timezone, nicotine, secondhand_smoke, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
         ON CONFLICT(user_id) DO UPDATE SET sex=excluded.sex, birth_date=excluded.birth_date, height_cm=excluded.height_cm, weight_kg=excluded.weight_kg,
           activity_level=excluded.activity_level, goal=excluded.goal, goal_rate_kg_week=excluded.goal_rate_kg_week, target_weight_kg=excluded.target_weight_kg,
           physiology=excluded.physiology, sodium_mode=excluded.sodium_mode, conditions=excluded.conditions, timezone=excluded.timezone,
           nicotine=excluded.nicotine, secondhand_smoke=excluded.secondhand_smoke, updated_at=excluded.updated_at`,
        uid, sex, birth, height, weight, level, goal, rate, target, physiology, sodiumMode, JSON.stringify(conditions), tz, nicotine, secondhand,
      );
      // 首次建档时把当前体重记入体重记录
      if (!existed) {
        run("INSERT INTO body_metrics (user_id, date, time, weight_kg, note, source) VALUES (?, ?, ?, ?, ?, 'profile')", uid, todayIn(tz), "08:00", weight, "建档体重");
      }
      invalidateAll(uid);
    });
    return { ok: true, profile: getProfile(uid) };
  }),
);

accountRouter.get(
  "/profile/targets",
  requireAuth,
  ah((req) => {
    const p = getProfile(req.user!.id);
    if (!p) throw bad("请先完善个人档案");
    const date = isDate(req.query.date) ? (req.query.date as string) : todayIn(p.timezone);
    const w = weightOn(getWeights(req.user!.id, date), date, p.weight_kg);
    return targetsFor(p, date, w);
  }),
);

accountRouter.put(
  "/settings",
  requireAuth,
  ah((req) => {
    const b = req.body ?? {};
    const uid = req.user!.id;
    const display = str(b.display_name, { optional: true, max: 32 });
    const color = typeof b.avatar_color === "string" && /^#[0-9a-f]{6}$/i.test(b.avatar_color) ? b.avatar_color : null;
    const mode = oneOf(b.share_mode, ["private", "public", "selected"] as const, "private");
    const detail = oneOf(b.share_detail, ["summary", "full"] as const, "summary");
    tx(() => {
      run(
        "UPDATE users SET display_name = COALESCE(NULLIF(?, ''), display_name), avatar_color = COALESCE(?, avatar_color), share_mode = ?, share_detail = ? WHERE id = ?",
        display, color, mode, detail, uid,
      );
      if (Array.isArray(b.share_with)) {
        run("DELETE FROM share_grants WHERE owner_id = ?", uid);
        for (const v of b.share_with) {
          const vid = Number(v);
          if (Number.isInteger(vid) && vid !== uid && get("SELECT id FROM users WHERE id = ?", vid)) {
            run("INSERT OR IGNORE INTO share_grants (owner_id, viewer_id) VALUES (?, ?)", uid, vid);
          }
        }
      }
    });
    return { ok: true };
  }),
);

accountRouter.post(
  "/settings/token",
  requireAuth,
  ah((req) => ({ token: newApiToken(req.user!.id) })),
);
