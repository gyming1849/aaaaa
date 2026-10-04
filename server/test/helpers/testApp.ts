// 集成测试用的服务器：临时数据目录 + 与 index.ts 相同的挂载顺序与错误处理。
// 必须先设置环境变量再动态导入 src/*，因此测试文件不能静态导入 src 下的模块。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import type { DatabaseSync } from "node:sqlite";
import type { NextFunction, Request, Response } from "express";

export const INVITE = "test-invite";

export interface TestApp {
  /** 形如 http://127.0.0.1:<port>/api/v1 */
  base: string;
  db: DatabaseSync;
  dataDir: string;
  uploadDir: string;
  close(): Promise<void>;
}

let instance: Promise<TestApp> | undefined;

/** 每个测试文件（独立进程）只启动一次 */
export function makeTestApp(): Promise<TestApp> {
  instance ??= start();
  return instance;
}

async function start(): Promise<TestApp> {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "nl-test-"));
  process.env.DATA_DIR = dataDir;
  process.env.SCHEDULER = "false";
  process.env.AI_PROVIDER = "mock";
  process.env.INVITE_CODE = INVITE;
  process.env.ALLOW_REGISTRATION = "true";

  const { default: express } = await import("express");
  const { config } = await import("../../src/config.ts");
  const { db } = await import("../../src/db/index.ts");
  const { HttpError } = await import("../../src/lib/http.ts");
  const { docsRouter } = await import("../../src/routes/docs.ts");
  const { accountRouter } = await import("../../src/routes/account.ts");
  const { appRouter } = await import("../../src/routes/app.ts");
  const { bodyRouter } = await import("../../src/routes/body.ts");
  const { logRouter } = await import("../../src/routes/log.ts");
  const { reportsRouter } = await import("../../src/routes/reports.ts");

  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({ limit: "2mb" }));
  app.use(express.urlencoded({ extended: false }));
  for (const prefix of ["/api/v1", "/api"]) {
    app.get(`${prefix}/health`, (_req, res) => {
      res.json({ ok: true, version: "1" });
    });
    app.use(prefix, docsRouter);
    app.use(prefix, accountRouter);
    app.use(prefix, appRouter);
    app.use(prefix, bodyRouter);
    app.use(prefix, logRouter);
    app.use(prefix, reportsRouter);
  }
  app.use("/api", (_req, res) => {
    res.status(404).json({ error: "接口不存在" });
  });
  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof HttpError) {
      res.status(err.status).json({ error: err.message });
      return;
    }
    const e = err as { type?: string; message?: string; code?: string };
    if (e?.type === "entity.parse.failed") {
      res.status(400).json({ error: "请求格式不正确" });
      return;
    }
    if (e?.code === "LIMIT_FILE_SIZE") {
      res.status(413).json({ error: "文件太大" });
      return;
    }
    console.error(err);
    res.status(500).json({ error: "服务器内部错误" });
  });

  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address() as AddressInfo;
  return {
    base: `http://127.0.0.1:${port}/api/v1`,
    db,
    dataDir,
    uploadDir: config.uploadDir,
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      db.close();
      fs.rmSync(dataDir, { recursive: true, force: true });
    },
  };
}

export interface ApiResponse<T = any> {
  status: number;
  body: T;
  headers: Headers;
}

/** fetch 包装：JSON 请求 / 响应，Bearer 令牌或 Cookie */
export function api(base: string, token?: string, opts: { cookie?: string } = {}) {
  async function call<T = any>(method: string, p: string, body?: unknown): Promise<ApiResponse<T>> {
    const headers: Record<string, string> = { Accept: "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (opts.cookie) headers.Cookie = opts.cookie;
    let payload: string | FormData | undefined;
    if (body instanceof FormData) payload = body;
    else if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    const res = await fetch(base + p, { method, headers, body: payload });
    const text = await res.text();
    let parsed: unknown = text;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      // 非 JSON 响应（如图片）保持原文
    }
    return { status: res.status, body: parsed as T, headers: res.headers };
  }
  return {
    get: <T = any>(p: string) => call<T>("GET", p),
    post: <T = any>(p: string, body: unknown = {}) => call<T>("POST", p, body),
    put: <T = any>(p: string, body: unknown = {}) => call<T>("PUT", p, body),
    patch: <T = any>(p: string, body: unknown = {}) => call<T>("PATCH", p, body),
    del: <T = any>(p: string) => call<T>("DELETE", p),
  };
}

/** 注册一个 App 账号（带 device_name 与邀请码），返回 nla_ 令牌 */
export async function register(base: string, username: string, password = "secret123", deviceName = "测试 iPhone"): Promise<string> {
  const r = await api(base).post("/auth/register", { username, password, display_name: username, invite_code: INVITE, device_name: deviceName });
  if (r.status !== 200 || !r.body?.token) throw new Error(`register ${username} failed: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body.token as string;
}

/** 建立个人档案（Asia/Shanghai，70 kg） */
export async function withProfile(base: string, token: string): Promise<void> {
  const r = await api(base, token).put("/profile", {
    sex: "male", birth_date: "1990-01-01", height_cm: 175, weight_kg: 70, timezone: "Asia/Shanghai",
  });
  if (r.status !== 200) throw new Error(`profile failed: ${r.status} ${JSON.stringify(r.body)}`);
}

/** 注册 + 建档，返回令牌与用户 id */
export async function newUser(base: string, username: string): Promise<{ token: string; uid: number; client: ReturnType<typeof api> }> {
  const token = await register(base, username);
  await withProfile(base, token);
  const client = api(base, token);
  const me = await client.get("/auth/me");
  return { token, uid: me.body.user.id as number, client };
}

/** 档案时区（Asia/Shanghai）的今天，避免静态导入 src */
export function todaySh(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

export function addDays(date: string, n: number): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
