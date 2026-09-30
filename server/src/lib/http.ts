import type { Request, Response, NextFunction, RequestHandler } from "express";

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export const bad = (msg: string) => new HttpError(400, msg);
export const notFound = (msg = "不存在") => new HttpError(404, msg);
export const forbidden = (msg = "无权访问") => new HttpError(403, msg);

/** 包装异步路由，统一错误处理 */
export function ah(fn: (req: Request, res: Response) => unknown): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    Promise.resolve()
      .then(() => fn(req, res))
      .then((data) => {
        if (!res.headersSent && data !== undefined) res.json(data);
      })
      .catch(next);
  };
}

export function num(v: unknown, opts: { min?: number; max?: number; optional?: boolean; name?: string } = {}): number | null {
  if (v === undefined || v === null || v === "") {
    if (opts.optional) return null;
    throw bad(`${opts.name ?? "数值"}不能为空`);
  }
  const n = Number(v);
  if (!Number.isFinite(n)) throw bad(`${opts.name ?? "数值"}格式不正确`);
  if (opts.min !== undefined && n < opts.min) throw bad(`${opts.name ?? "数值"}不能小于 ${opts.min}`);
  if (opts.max !== undefined && n > opts.max) throw bad(`${opts.name ?? "数值"}不能大于 ${opts.max}`);
  return n;
}

export function str(v: unknown, opts: { max?: number; optional?: boolean; name?: string } = {}): string {
  if (v === undefined || v === null) {
    if (opts.optional) return "";
    throw bad(`${opts.name ?? "字段"}不能为空`);
  }
  const s = String(v).trim();
  if (!opts.optional && !s) throw bad(`${opts.name ?? "字段"}不能为空`);
  return opts.max ? s.slice(0, opts.max) : s;
}

export function oneOf<T extends string>(v: unknown, values: readonly T[], fallback?: T): T {
  if (values.includes(v as T)) return v as T;
  if (fallback !== undefined) return fallback;
  throw bad(`取值必须是 ${values.join(" / ")}`);
}
