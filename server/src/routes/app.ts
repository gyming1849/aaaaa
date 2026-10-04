// 原生 App 专用接口（网页不调用）：注册配置、令牌续期、注销账号、苹果健康直连同步

import { Router } from "express";
import { get, run, tx } from "../db/index.ts";
import { config } from "../config.ts";
import { requireAuth, verifyPassword, createAppToken, presentedToken, sha256 } from "../auth.ts";
import { ah, bad, str } from "../lib/http.ts";
import { applyHealthSync, healthSyncState, unlinkHealthDevice } from "../services/healthsync.ts";
import { deleteUserCompletely } from "../services/accountDeletion.ts";

export const appRouter = Router();

/** 本服务器支持的新能力（旧服务器没有 /auth/config，App 视为不支持） */
const FEATURES = ["health_sync", "account_delete", "token_refresh", "session_current", "ai_consent"];

/** 公开：是否开放注册、是否需要邀请码（不返回邀请码本身） */
appRouter.get(
  "/auth/config",
  ah(() => ({
    allow_registration: config.allowRegistration,
    invite_required: !!config.inviteCode,
    min_password: 6,
    server_version: "1",
    features: [...FEATURES],
  })),
);

/** 旧令牌在续期后最多还能用这么久：响应丢失（移动网络超时、App 被挂起）时客户端仍持有旧令牌，可以重试续期而不被登出 */
const REFRESH_GRACE_MS = 24 * 3600_000;

/** 续期 App 令牌：签发新令牌（保留设备名）；旧令牌的有效期缩短到最多 24 小时后（只缩短、不延长） */
appRouter.post(
  "/auth/refresh",
  requireAuth,
  ah((req) => {
    const presented = presentedToken(req);
    const hash = presented?.via === "bearer" ? sha256(presented.token) : undefined;
    const row = hash ? get<{ kind: string; device_name: string | null }>("SELECT kind, device_name FROM sessions WHERE token_hash = ?", hash) : undefined;
    if (!hash || !row || row.kind !== "app") throw bad("只有 App 令牌可以续期");
    return tx(() => {
      const next = createAppToken(req.user!.id, row.device_name ?? "App");
      // expires_at 都是 toISOString() 写入的，字符串比较即时间比较；requireAuth 会拒绝并删除过期的行
      const graceEnd = new Date(Date.now() + REFRESH_GRACE_MS).toISOString();
      run("UPDATE sessions SET expires_at = ? WHERE token_hash = ? AND expires_at > ?", graceEnd, hash, graceEnd);
      return next;
    });
  }),
);

/** App 内的 AI 第三方处理同意：granted 为 null 表示从未在 App 中回答过 */
appRouter.get(
  "/ai/consent",
  requireAuth,
  ah((req) => {
    const row = get<{ granted: number; updated_at: string }>("SELECT granted, updated_at FROM ai_consent WHERE user_id = ?", req.user!.id);
    return { granted: row ? row.granted === 1 : null, updated_at: row?.updated_at ?? null };
  }),
);

appRouter.put(
  "/ai/consent",
  requireAuth,
  ah((req) => {
    const granted = (req.body ?? {}).granted;
    if (typeof granted !== "boolean") throw bad("granted 必须是 true 或 false");
    run(
      `INSERT INTO ai_consent (user_id, granted, updated_at) VALUES (?, ?, datetime('now'))
       ON CONFLICT(user_id) DO UPDATE SET granted = excluded.granted, updated_at = excluded.updated_at`,
      req.user!.id, granted ? 1 : 0,
    );
    return { ok: true };
  }),
);

/** 注销账号（需要密码确认）：删除该用户的全部数据 */
appRouter.post(
  "/account/delete",
  requireAuth,
  ah((req) => {
    const password = str((req.body ?? {}).password, { name: "密码" });
    const u = get<{ password_hash: string }>("SELECT password_hash FROM users WHERE id = ?", req.user!.id);
    if (!u || !verifyPassword(password, u.password_hash)) throw bad("密码不正确");
    deleteUserCompletely(req.user!.id);
    return { ok: true };
  }),
);

// ---------------------------------------------------------------- 苹果健康（HealthKit）直连同步

appRouter.post("/health/sync", requireAuth, ah((req) => applyHealthSync(req.user!.id, req.body ?? {})));

appRouter.get("/health/sync/state", requireAuth, ah((req) => healthSyncState(req.user!.id)));

appRouter.post(
  "/health/sync/unlink",
  requireAuth,
  ah((req) => {
    const b = req.body ?? {};
    return unlinkHealthDevice(req.user!.id, typeof b.device_id === "string" ? b.device_id : "", b.delete_data === true);
  }),
);
