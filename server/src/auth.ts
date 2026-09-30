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
  db.prepare("INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)").run(
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

export function destroySession(req: Request, res: Response) {
  const token = readCookie(req, COOKIE);
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
  const token = readCookie(req, COOKIE);
  if (!token) return undefined;
  const row = db
    .prepare(
      `SELECT u.id, u.username, u.display_name, s.expires_at
       FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?`,
    )
    .get(sha256(token)) as (AuthedUser & { expires_at: string }) | undefined;
  if (!row) return undefined;
  if (new Date(row.expires_at) < new Date()) {
    db.prepare("DELETE FROM sessions WHERE token_hash = ?").run(sha256(token));
    return undefined;
  }
  return { id: row.id, username: row.username, display_name: row.display_name };
}

function userFromApiToken(req: Request): AuthedUser | undefined {
  const auth = req.headers.authorization;
  const token = auth?.startsWith("Bearer ") ? auth.slice(7).trim() : (req.query.token as string | undefined);
  if (!token) return undefined;
  return db
    .prepare("SELECT id, username, display_name FROM users WHERE api_token_hash = ?")
    .get(sha256(token)) as AuthedUser | undefined;
}

export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const user = userFromSession(req);
  if (!user) {
    res.status(401).json({ error: "未登录" });
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
