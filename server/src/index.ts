import express, { type NextFunction, type Request, type Response } from "express";
import fs from "node:fs";
import path from "node:path";
import { config } from "./config.ts";
import "./db/index.ts";
import { accountRouter } from "./routes/account.ts";
import { logRouter } from "./routes/log.ts";
import { bodyRouter } from "./routes/body.ts";
import { reportsRouter } from "./routes/reports.ts";
import { docsRouter } from "./routes/docs.ts";
import { HttpError } from "./lib/http.ts";
import { failStaleJobs } from "./ai/jobs.ts";
import { activeProvider } from "./ai/providers.ts";
import { startScheduler } from "./services/scheduler.ts";

const app = express();
app.disable("x-powered-by");
app.set("trust proxy", true);
app.use(express.json({ limit: "2mb" }));
app.use(express.urlencoded({ extended: false }));

// 跨域（供 Web 版 App 或其他域名的前端调用；原生 App 不受 CORS 限制）
app.use("/api", (req, res, next) => {
  const origin = req.headers.origin;
  if (origin && (config.corsOrigins.includes("*") || config.corsOrigins.includes(origin))) {
    res.setHeader("Access-Control-Allow-Origin", config.corsOrigins.includes("*") ? "*" : origin);
    res.setHeader("Vary", "Origin");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS");
    res.setHeader("Access-Control-Max-Age", "86400");
  }
  if (req.method === "OPTIONS") {
    res.status(204).end();
    return;
  }
  next();
});

// 同一套接口同时挂在 /api 与 /api/v1（App 建议使用带版本号的路径）
for (const prefix of ["/api/v1", "/api"]) {
  app.get(`${prefix}/health`, (_req, res) => {
    res.json({ ok: true, version: "1" });
  });
  app.use(prefix, docsRouter);
  app.use(prefix, accountRouter);
  app.use(prefix, bodyRouter);
  app.use(prefix, logRouter);
  app.use(prefix, reportsRouter);
}
app.use("/api", (_req, res) => {
  res.status(404).json({ error: "接口不存在" });
});

// 前端静态文件（npm run build 之后）
if (fs.existsSync(config.webDist)) {
  app.use(express.static(config.webDist, { index: false, maxAge: "1h" }));
  app.get(/^(?!\/api).*/, (_req, res) => {
    res.sendFile(path.join(config.webDist, "index.html"));
  });
}

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

failStaleJobs();
startScheduler();

app.listen(config.port, () => {
  console.log(`NutriLog 已启动：http://localhost:${config.port}`);
  console.log(`AI 模式：${activeProvider()}${activeProvider() === "mock" ? "（离线估算，配置 claude CLI 或 ANTHROPIC_API_KEY 后启用 AI）" : `，模型 ${config.ai.model}`}`);
});
