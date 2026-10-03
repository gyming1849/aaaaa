// AI 调用层：三种方式
//  - cli ：调用本机 `claude -p`（Claude Code，使用你的 Claude 订阅/登录），支持 WebSearch 与读取图片
//  - api ：Anthropic SDK 直接调用 Messages API（需要 ANTHROPIC_API_KEY），支持 web_search 服务器工具
//  - mock：离线关键词估算（无需任何 AI）

import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import Anthropic from "@anthropic-ai/sdk";
import { config } from "../config.ts";

export interface AiImage {
  path: string;
  mediaType: string;
}

export interface AiRequest {
  kind: string;
  system: string;
  prompt: string;
  images: AiImage[];
  schema: Record<string, unknown>;
  webSearch: boolean;
}

export interface AiResult {
  data: unknown;
  model: string;
  provider: string;
  costUsd?: number;
}

export class AiError extends Error {}

/** 从模型输出文本中提取 JSON（容忍 ```json 代码块或前后说明文字） */
export function extractJson(text: string): unknown {
  const trimmed = text.trim();
  try {
    return JSON.parse(trimmed);
  } catch {
    /* 继续尝试 */
  }
  const fence = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) {
    try {
      return JSON.parse(fence[1]);
    } catch {
      /* 继续尝试 */
    }
  }
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end > start) return JSON.parse(trimmed.slice(start, end + 1));
  throw new AiError("AI 未返回可解析的 JSON");
}

// ---------------------------------------------------------------- CLI

function hasClaudeCli(): boolean {
  try {
    const r = spawnSync(config.ai.claudeBin, ["--version"], { timeout: 15_000, encoding: "utf8" });
    return r.status === 0;
  } catch {
    return false;
  }
}

async function runCli(req: AiRequest): Promise<AiResult> {
  const tools = ["Read"];
  if (req.webSearch && config.ai.webSearch) tools.push("WebSearch", "WebFetch");
  const imageNote = req.images.length
    ? `\n\n用户上传了 ${req.images.length} 张图片，请先用 Read 工具查看：\n${req.images.map((i) => `- ${i.path}`).join("\n")}`
    : "";
  const workDir = path.join(config.dataDir, "claude-work");
  fs.mkdirSync(workDir, { recursive: true });
  const args = [
    "-p",
    "--output-format", "json",
    "--model", config.ai.model,
    "--effort", config.ai.effort,
    "--system-prompt", req.system,
    "--json-schema", JSON.stringify(req.schema),
    "--tools", tools.join(","),
    "--allowedTools", tools.join(","),
    "--permission-mode", "dontAsk",
    "--no-session-persistence",
    "--add-dir", config.uploadDir,
  ];

  return new Promise<AiResult>((resolve, reject) => {
    const child = spawn(config.ai.claudeBin, args, { cwd: workDir, env: process.env, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new AiError(`claude -p 超时（${Math.round(config.ai.timeoutMs / 1000)} 秒）`));
    }, config.ai.timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(new AiError(`无法启动 claude CLI：${e.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      let parsed: Record<string, unknown>;
      try {
        parsed = JSON.parse(out);
      } catch {
        reject(new AiError(`claude -p 输出无法解析（退出码 ${code}）：${(err || out).slice(0, 500)}`));
        return;
      }
      if (parsed.is_error || parsed.subtype !== "success") {
        reject(new AiError(`claude -p 失败：${String(parsed.result ?? parsed.subtype ?? err).slice(0, 500)}`));
        return;
      }
      try {
        const data = parsed.structured_output ?? extractJson(String(parsed.result ?? ""));
        resolve({ data, model: config.ai.model, provider: "cli", costUsd: Number(parsed.total_cost_usd) || undefined });
      } catch (e) {
        reject(e);
      }
    });
    child.stdin.end(req.prompt + imageNote);
  });
}

// ---------------------------------------------------------------- API

let client: Anthropic | null = null;

async function runApi(req: AiRequest): Promise<AiResult> {
  client ??= new Anthropic({ timeout: config.ai.timeoutMs, maxRetries: 2 });
  const content: Anthropic.Beta.BetaContentBlockParam[] = [];
  for (const img of req.images) {
    content.push({
      type: "image",
      source: {
        type: "base64",
        media_type: img.mediaType as "image/jpeg" | "image/png" | "image/gif" | "image/webp",
        data: fs.readFileSync(img.path).toString("base64"),
      },
    });
  }
  content.push({ type: "text", text: req.prompt });

  const tools: Anthropic.Beta.BetaToolUnion[] = [];
  if (req.webSearch && config.ai.webSearch) tools.push({ type: "web_search_20260209", name: "web_search", max_uses: 6 });

  const call = async (structured: boolean) => {
    const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: "user", content }];
    const system = structured
      ? req.system
      : `${req.system}\n\nRespond with a single JSON object that matches this JSON Schema, and nothing else:\n${JSON.stringify(req.schema)}`;
    for (let i = 0; i < 6; i++) {
      const stream = client!.beta.messages.stream({
        model: config.ai.model,
        max_tokens: 32000,
        system,
        messages,
        thinking: { type: "adaptive" },
        output_config: {
          effort: config.ai.effort,
          ...(structured ? { format: { type: "json_schema" as const, schema: req.schema } } : {}),
        },
        ...(tools.length ? { tools } : {}),
        // 模型因安全分类器拒答时，由服务端自动切换到推荐的后备模型
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
      });
      const msg = await stream.finalMessage();
      if (msg.stop_reason === "pause_turn") {
        messages.push({ role: "assistant", content: msg.content as Anthropic.Beta.BetaContentBlockParam[] });
        continue;
      }
      if (msg.stop_reason === "refusal") {
        throw new AiError(`模型拒绝了该请求：${msg.stop_details?.explanation ?? "未说明原因"}`);
      }
      if (msg.stop_reason === "max_tokens") throw new AiError("AI 输出超过长度上限");
      const text = msg.content
        .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === "text")
        .map((b) => b.text)
        .join("");
      return { data: extractJson(text), model: msg.model };
    }
    throw new AiError("联网搜索轮次过多，未能完成");
  };

  try {
    const r = await call(true);
    return { ...r, provider: "api" };
  } catch (e) {
    // 结构化输出与某些工具组合不兼容时，退回到提示词约束 JSON
    if (e instanceof Anthropic.BadRequestError) {
      const r = await call(false);
      return { ...r, provider: "api" };
    }
    throw e;
  }
}

// ---------------------------------------------------------------- 选择

let resolved: "cli" | "api" | "mock" | null = null;

export function activeProvider(): "cli" | "api" | "mock" {
  if (resolved) return resolved;
  const p = config.ai.provider;
  if (p === "cli" || p === "api" || p === "mock") resolved = p;
  else if (process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN) resolved = "api";
  else if (hasClaudeCli()) resolved = "cli";
  else resolved = "mock";
  return resolved;
}

export async function runAi(req: AiRequest): Promise<AiResult> {
  const p = activeProvider();
  if (p === "cli") return runCli(req);
  if (p === "api") return runApi(req);
  throw new AiError("mock provider 由调用方处理");
}
