// 账号注销（App Store 5.1.1(v)）：删除用户及其全部数据。

import fs from "node:fs";
import path from "node:path";
import { run, tx } from "../db/index.ts";
import { config } from "../config.ts";

/**
 * 彻底删除一个用户。
 * 先删身体记录与运动记录（此时用户行仍在，墓碑触发器可正常执行），再删用户行：
 * ON DELETE CASCADE 会清除会话、档案、共享授权、餐食、食物库、活动、化验、AI 任务、评分缓存、报告与 HealthKit 同步表；
 * 其他用户引用此用户公开食物的 meal_items.food_id 变为 NULL（ON DELETE SET NULL）。
 * 提交后删除上传目录。
 */
export function deleteUserCompletely(uid: number): void {
  tx(() => {
    run("DELETE FROM body_metrics WHERE user_id = ?", uid);
    run("DELETE FROM exercises WHERE user_id = ?", uid);
    run("DELETE FROM users WHERE id = ?", uid);
  });
  // 数据库已提交：照片目录删除失败（权限等）只记录日志，不让已注销的账号收到 500
  // （令牌已失效，客户端无法重试）。用户 id 为 AUTOINCREMENT，不会被新账号复用。
  try {
    fs.rmSync(path.join(config.uploadDir, String(uid)), { recursive: true, force: true });
  } catch (e) {
    console.error(`[account delete ${uid}] 删除上传目录失败`, e);
  }
}
