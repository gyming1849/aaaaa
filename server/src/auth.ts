import crypto from "node:crypto";
import type { Request, Response, NextFunction } from "express";
import { db } from "./db/index.ts";
import { config } from "./config.ts";

const COOKIE = "nl_session";

export interface AuthedUser {
  id: number;
  username: string;
  display_name: string;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: AuthedUser;
    }
  }
}

export function hashPassword(password: string): string {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(password, salt, 64, { N: 16384, r: 8, p: 1 });
  return `scrypt$${salt.toString("base64")}$${hash.toString("base64")}`;
}

export function verifyPassword(password: string, stored: string): boolean {
  const [scheme, saltB64, hashB64] = stored.split("$");
  if (scheme !== "scrypt" || !saltB64 || !hashB64) return false;
  const expected = Buffer.from(hashB64, "base64");
  const actual = crypto.scryptSync(password, Buffer.from(saltB64, "base64"), expected.length, { N: 16384, r: 8, p: 1 });
  return crypto.timingSafeEqual(expected, actual);
}

export const sha256 = (s: string) => crypto.createHash("sha256").update(s).digest("hex");

export function createSession(res: Response, userId: number) {
  const token = crypto.randomBytes(32).toString("base64url");
  const expires = new Date(Date.now() + config.sessionDays * 86400_000);
  db.prepare("INSERT INTO sessions (token_hash, user_id, expires_at, kind, created_at, last_used_at) VALUES (?, ?, ?, 'web', datetime('now'), datetime('now'))").run(
    sha256(token),
    userId,
    expires.toISOString(),
  );
  res.cookie(COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.COOKIE_SECURE === "true",
    expires,
    path: "/",
  });
}

/** 为移动 App / 第三方客户端签发 Bearer 令牌（默认 365 天） */
export function createAppToken(userId: number, deviceName: string): { token: string; expires_at: string } {
  const token = `nla_${crypto.randomBytes(32).toString("base64url")}`;
  const expires = new Date(Date.now() + config.appTokenDays * 86400_000).toISOString();
  db.prepare(
    "INSERT INTO sessions (token_hash, user_id, expires_at, kind, device_name, created_at, last_used_at) VALUES (?, ?, ?, 'app', ?, datetime('now'), datetime('now'))",
  ).run(sha256(token), userId, expires, deviceName.slice(0, 60));
  return { token, expires_at: expires };
}

function bearer(req: Request): string | undefined {
  const auth = req.headers.authorization;
  return auth?.startsWith("Bearer ") ? auth.slice(7).trim() : undefined;
}

export function destroySession(req: Request, res: Response) {
  const token = readCookie(req, COOKIE) ?? bearer(req);
  if (token) db.prepare("DELETE FROM sessions WHERE token_hash = ?").run(sha256(token));
  res.clearCookie(COOKIE, { path: "/" });
}

function readCookie(req: Request, name: string): string | undefined {
  const header = req.headers.cookie;
  if (!header) return undefined;
  for (const part of header.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return decodeURIComponent(v.join("="));
  }
  return undefined;
}

function userFromSession(req: Request): AuthedUser | undefined {
  // 网页用 Cookie；App 用 Authorization: Bearer nla_...
  const cookie = readCookie(req, COOKIE);
  const b = bearer(req);
  const token = cookie ?? (b && !b.startsWith("nl_") ? b : undefined);
  if (!token) return undefined;
  const hash = sha256(token);
  const row = db
    .prepare(
      `SELECT u.id, u.username, u.display_name, s.expires_at, s.kind
       FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?`,
    )
    .get(hash) as (AuthedUser & { expires_at: string; kind: string }) | undefined;
  if (!row) return undefined;
  if (new Date(row.expires_at) < new Date()) {
    db.prepare("DELETE FROM sessions WHERE token_hash = ?").run(hash);
    return undefined;
  }
  if (row.kind === "app") db.prepare("UPDATE sessions SET last_used_at = datetime('now') WHERE token_hash = ?").run(hash);
  return { id: row.id, username: row.username, display_name: row.display_name };
}

function userFromApiToken(req: Request): AuthedUser | undefined {
  const b = bearer(req);
  const token = b?.startsWith("nl_") ? b : (req.query.token as string | undefined);
  if (!token) return undefined;
  return db
    .prepare("SELECT id, username, display_name FROM users WHERE api_token_hash = ?")
    .get(sha256(token)) as AuthedUser | undefined;
}

export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const user = userFromSession(req);
  if (!user) {
    res.status(401).json({ error: "未登录或令牌已失效" });
    return;
  }
  req.user = user;
  next();
}

/** 允许会话或个人 API Token（用于 iPhone 快捷指令上传健康数据） */
export function requireAuthOrToken(req: Request, res: Response, next: NextFunction) {
  const user = userFromSession(req) ?? userFromApiToken(req);
  if (!user) {
    res.status(401).json({ error: "未登录或 Token 无效" });
    return;
  }
  req.user = user;
  next();
}

export function newApiToken(userId: number): string {
  const token = `nl_${crypto.randomBytes(24).toString("base64url")}`;
  db.prepare("UPDATE users SET api_token_hash = ?, api_token_hint = ? WHERE id = ?").run(
    sha256(token),
    token.slice(0, 7) + "…" + token.slice(-4),
    userId,
  );
  return token;
}
