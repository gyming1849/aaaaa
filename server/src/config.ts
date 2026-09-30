import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT_DIR = path.resolve(here, "../..");

// 读取根目录 .env（简单实现，不引入依赖）
const envFile = path.join(ROOT_DIR, ".env");
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && process.env[m[1]] === undefined) {
      process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  }
}

const env = process.env;
const dataDir = path.resolve(ROOT_DIR, env.DATA_DIR ?? "data");

export type AiProviderName = "cli" | "api" | "mock" | "auto";

export const config = {
  port: Number(env.PORT ?? 8787),
  dataDir,
  dbPath: path.join(dataDir, "nutrilog.db"),
  uploadDir: path.join(dataDir, "uploads"),
  webDist: path.join(ROOT_DIR, "web", "dist"),
  sessionDays: Number(env.SESSION_DAYS ?? 30),
  /** 设置后注册需要邀请码 */
  inviteCode: env.INVITE_CODE ?? "",
  allowRegistration: (env.ALLOW_REGISTRATION ?? "true") !== "false",
  ai: {
    provider: (env.AI_PROVIDER ?? "auto") as AiProviderName,
    model: env.AI_MODEL ?? "claude-opus-5-5",
    effort: (env.AI_EFFORT ?? "high") as "low" | "medium" | "high" | "xhigh" | "max",
    claudeBin: env.CLAUDE_BIN ?? "claude",
    timeoutMs: Number(env.AI_TIMEOUT_MS ?? 480_000),
    webSearch: (env.AI_WEB_SEARCH ?? "true") !== "false",
    concurrency: Number(env.AI_CONCURRENCY ?? 2),
  },
  scheduler: (env.SCHEDULER ?? "true") !== "false",
  /** 每周报告是否让 AI 生成点评 */
  weeklyAiSummary: (env.WEEKLY_AI_SUMMARY ?? "true") !== "false",
};

fs.mkdirSync(config.uploadDir, { recursive: true });
