export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function request<T>(method: string, url: string, body?: unknown): Promise<T> {
  const init: RequestInit = { method, credentials: "same-origin", headers: {} };
  if (body instanceof FormData) {
    init.body = body;
  } else if (body !== undefined) {
    init.body = JSON.stringify(body);
    (init.headers as Record<string, string>)["Content-Type"] = "application/json";
  }
  const res = await fetch(`/api${url}`, init);
  const text = await res.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { error: text };
  }
  if (!res.ok) {
    const msg = (data as { error?: string })?.error ?? `请求失败（${res.status}）`;
    if (res.status === 401 && !url.startsWith("/auth/")) window.dispatchEvent(new Event("nl:unauthorized"));
    throw new ApiError(res.status, msg);
  }
  return data as T;
}

export const api = {
  get: <T>(url: string) => request<T>("GET", url),
  post: <T>(url: string, body?: unknown) => request<T>("POST", url, body ?? {}),
  put: <T>(url: string, body?: unknown) => request<T>("PUT", url, body ?? {}),
  patch: <T>(url: string, body?: unknown) => request<T>("PATCH", url, body ?? {}),
  del: <T>(url: string) => request<T>("DELETE", url),
};

export interface Job<T> {
  id: string;
  kind: string;
  status: "queued" | "running" | "done" | "error";
  error: string | null;
  result: T | null;
}

/** 轮询 AI 任务直到完成 */
export async function waitJob<T>(jobId: string, onTick?: (job: Job<T>) => void, signal?: AbortSignal): Promise<T> {
  for (;;) {
    if (signal?.aborted) throw new Error("已取消");
    const job = await api.get<Job<T>>(`/ai/jobs/${jobId}`);
    onTick?.(job);
    if (job.status === "done") return job.result as T;
    if (job.status === "error") throw new Error(job.error ?? "AI 任务失败");
    await new Promise((r) => setTimeout(r, 1500));
  }
}

export async function uploadPhotos(files: File[]): Promise<{ id: string; url: string }[]> {
  const fd = new FormData();
  for (const f of files) fd.append("photos", f);
  const r = await api.post<{ photos: { id: string; url: string }[] }>("/uploads", fd);
  return r.photos;
}

export const qs = (params: Record<string, string | number | undefined | null>) => {
  const s = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== "") s.set(k, String(v));
  const q = s.toString();
  return q ? `?${q}` : "";
};
