import express, { type NextFunction, type Request, type Response } from "express";
import fs from "node:fs";
import path from "node:path";
import { config } from "./config.ts";
import "./db/index.ts";
import { accountRouter } from "./routes/account.ts";
import { logRouter } from "./routes/log.ts";
import { bodyRouter } from "./routes/body.ts";
import { reportsRouter } from "./routes/reports.ts";
import { HttpError } from "./lib/http.ts";
import { failStaleJobs } from "./ai/jobs.ts";
import { activeProvider } from "./ai/providers.ts";
import { startScheduler } from "./services/scheduler.ts";

const app = express();
app.disable("x-powered-by");
app.set("trust proxy", true);
app.use(express.json({ limit: "2mb" }));
app.use(express.urlencoded({ extended: false }));

app.get("/api/health", (_req, res) => {
  res.json({ ok: true });
});
app.use("/api", accountRouter);
app.use("/api", bodyRouter);
app.use("/api", logRouter);
app.use("/api", reportsRouter);
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
