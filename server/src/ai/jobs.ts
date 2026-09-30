// 简单的后台任务队列：AI 调用可能需要 1–3 分钟（联网查询时更久），前端轮询任务状态。

import crypto from "node:crypto";
import { run, get } from "../db/index.ts";
import { config } from "../config.ts";

type Task = () => Promise<unknown>;

const queue: { id: string; task: Task }[] = [];
let running = 0;

function pump() {
  while (running < config.ai.concurrency && queue.length) {
    const { id, task } = queue.shift()!;
    running++;
    run("UPDATE ai_jobs SET status = 'running' WHERE id = ?", id);
    task()
      .then((result) => {
        run("UPDATE ai_jobs SET status = 'done', result = ?, finished_at = datetime('now') WHERE id = ?", JSON.stringify(result), id);
      })
      .catch((e: unknown) => {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[ai job ${id}]`, msg);
        run("UPDATE ai_jobs SET status = 'error', error = ?, finished_at = datetime('now') WHERE id = ?", msg.slice(0, 1000), id);
      })
      .finally(() => {
        running--;
        pump();
      });
  }
}

export function enqueue(userId: number, kind: string, input: unknown, task: Task): string {
  const id = crypto.randomUUID();
  run("INSERT INTO ai_jobs (id, user_id, kind, input) VALUES (?, ?, ?, ?)", id, userId, kind, JSON.stringify(input));
  queue.push({ id, task });
  pump();
  return id;
}

export interface JobRow {
  id: string;
  kind: string;
  status: string;
  result: string | null;
  error: string | null;
  created_at: string;
  finished_at: string | null;
}

export function getJob(userId: number, id: string): JobRow | undefined {
  return get<JobRow>("SELECT id, kind, status, result, error, created_at, finished_at FROM ai_jobs WHERE id = ? AND user_id = ?", id, userId);
}

/** 服务重启时把未完成的任务标记为失败 */
export function failStaleJobs() {
  run("UPDATE ai_jobs SET status = 'error', error = '服务器重启，任务中断，请重试' WHERE status IN ('queued', 'running')");
  run("DELETE FROM ai_jobs WHERE created_at < datetime('now', '-7 days')");
}
