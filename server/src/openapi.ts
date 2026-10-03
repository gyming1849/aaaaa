// OpenAPI 3.1 规范：供移动 App / 第三方客户端使用同一套后端。
// 认证：网页用 Cookie；App 用 POST /api/v1/auth/token 换取 Bearer 令牌（nla_…）；
// iPhone 快捷指令用个人 Token（nl_…）只能调用 /health/ingest。

import { NUTRIENTS, FOOD_GROUPS } from "./standards/nutrients.ts";
import { HAZARDS } from "./standards/hazards.ts";
import { ACTIVITIES } from "./standards/met.ts";
import { FOOD_CATEGORIES } from "./ai/schema.ts";

type S = Record<string, unknown>;
const ref = (name: string): S => ({ $ref: `#/components/schemas/${name}` });
const obj = (properties: Record<string, S>, required: string[] = []): S => ({ type: "object", properties, ...(required.length ? { required } : {}) });
const str = (description?: string, extra: S = {}): S => ({ type: "string", ...(description ? { description } : {}), ...extra });
const num = (description?: string): S => ({ type: "number", ...(description ? { description } : {}) });
const int = (description?: string): S => ({ type: "integer", ...(description ? { description } : {}) });
const nnum = (description?: string): S => ({ type: ["number", "null"], ...(description ? { description } : {}) });
const arr = (items: S): S => ({ type: "array", items });
const date = str("YYYY-MM-DD", { format: "date" });
const time = str("HH:MM", { pattern: "^\\d{2}:\\d{2}$" });

interface Op {
  tag: string;
  summary: string;
  description?: string;
  auth?: "none" | "user" | "user_or_personal";
  params?: { name: string; in: "path" | "query"; schema: S; required?: boolean; description?: string }[];
  body?: S;
  multipart?: S;
  response?: S;
}

const job = obj({ job_id: str("AI 任务 ID，轮询 GET /ai/jobs/{id}") }, ["job_id"]);
const ok = obj({ ok: { type: "boolean" } });
const userParam = { name: "user", in: "query" as const, schema: str(), description: "查看其他成员（需对方已共享）" };

const OPS: Record<string, Record<string, Op>> = {
  "/health": { get: { tag: "系统", summary: "健康检查", auth: "none", response: obj({ ok: { type: "boolean" }, version: str() }) } },
  "/auth/register": {
    post: {
      tag: "账号", summary: "注册", auth: "none",
      description: "传 device_name 时直接返回 App 用的 Bearer 令牌；否则设置网页 Cookie。",
      body: obj({ username: str(), password: str(), display_name: str(), invite_code: str(), device_name: str("App 设备名（可选）") }, ["username", "password"]),
      response: obj({ ok: { type: "boolean" }, token: str(), expires_at: str() }),
    },
  },
  "/auth/token": {
    post: {
      tag: "账号", summary: "App 登录，获取 Bearer 令牌", auth: "none",
      body: obj({ username: str(), password: str(), device_name: str() }, ["username", "password"]),
      response: obj({ token: str("在请求头中使用：Authorization: Bearer <token>"), expires_at: str(), user: ref("User") }),
    },
  },
  "/auth/login": { post: { tag: "账号", summary: "网页登录（设置 Cookie）", auth: "none", body: obj({ username: str(), password: str() }, ["username", "password"]), response: ok } },
  "/auth/logout": { post: { tag: "账号", summary: "退出（同时注销当前 Bearer 令牌）", response: ok } },
  "/auth/me": { get: { tag: "账号", summary: "当前用户、档案、AI 状态", response: obj({ user: ref("User"), profile: ref("Profile"), today: date, ai: obj({ provider: str(), model: str() }) }) } },
  "/auth/sessions": { get: { tag: "账号", summary: "已登录的设备 / 令牌列表", response: arr(obj({ id: int(), kind: str(), device_name: str(), last_used_at: str(), expires_at: str() })) } },
  "/auth/sessions/{id}": { delete: { tag: "账号", summary: "注销某个设备的令牌", params: [{ name: "id", in: "path", schema: int(), required: true }], response: ok } },
  "/auth/password": { post: { tag: "账号", summary: "修改密码", body: obj({ old_password: str(), new_password: str() }, ["old_password", "new_password"]), response: ok } },

  "/profile": { put: { tag: "档案", summary: "创建或更新个人档案（修改后历史评分自动重算）", body: ref("Profile"), response: obj({ ok: { type: "boolean" }, profile: ref("Profile") }) } },
  "/profile/targets": { get: { tag: "档案", summary: "个性化目标（DRI、限量、能量）", params: [{ name: "date", in: "query", schema: date }], response: ref("Targets") } },
  "/settings": { put: { tag: "档案", summary: "昵称、头像色、分享设置", body: obj({ display_name: str(), avatar_color: str(), share_mode: str("", { enum: ["private", "public", "selected"] }), share_detail: str("", { enum: ["summary", "full"] }), share_with: arr(int()) }), response: ok } },
  "/settings/token": { post: { tag: "档案", summary: "生成个人 Token（用于 iPhone 快捷指令上传健康数据）", response: obj({ token: str() }) } },

  "/uploads": { post: { tag: "饮食", summary: "上传照片（食物、包装、营养成分表、健康截图）", multipart: obj({ photos: arr(str("", { format: "binary" })) }), response: obj({ photos: arr(obj({ id: str("在 AI 接口的 photos 中引用"), url: str() })) }) } },
  "/ai/status": { get: { tag: "AI", summary: "当前 AI 模式与模型", response: obj({ provider: str("", { enum: ["cli", "api", "mock"] }), model: str(), web_search: { type: "boolean" } }) } },
  "/ai/meal": {
    post: {
      tag: "AI", summary: "AI 解析一餐（文字 + 照片），返回任务 ID",
      description: "结果为 MealDraft：用户审核、修改后再调用 POST /preview 查看合并效果，最后 POST /meals 保存。",
      body: obj({ text: str(), date, time, meal_type: str("", { enum: ["breakfast", "lunch", "dinner", "snack", "drink", "other"] }), photos: arr(str("上传返回的照片 id")) }),
      response: job,
    },
  },
  "/ai/food": { post: { tag: "AI", summary: "AI 联网查询或读取营养标签，生成食物库条目草稿（FoodDraft）", body: obj({ name: str(), brand: str(), note: str(), photos: arr(str()) }), response: job } },
  "/ai/activity": {
    post: {
      tag: "AI", summary: "AI 识别身体与活动数据（文字或健康 App / 手表 / 体脂秤截图）",
      description: "结果为 ActivityDraft（步数、能量、睡眠、体重、血压、每次运动）。审核后 POST /activity/commit 合并。",
      body: obj({ text: str(), date, photos: arr(str()) }), response: job,
    },
  },
  "/ai/exercise": { post: { tag: "AI", summary: "仅解析运动文字（旧接口，建议使用 /ai/activity）", body: obj({ text: str(), date }, ["text"]), response: job } },
  "/ai/jobs/{id}": {
    get: {
      tag: "AI", summary: "查询 AI 任务状态与结果", params: [{ name: "id", in: "path", schema: str(), required: true }],
      response: obj({ id: str(), kind: str(), status: str("", { enum: ["queued", "running", "done", "error"] }), error: str(), result: { description: "MealDraft / FoodDraft / ActivityDraft / 周期点评" } }),
    },
  },

  "/preview": {
    post: {
      tag: "饮食", summary: "合并预览：把未保存的一餐 / 活动 / 称重 / 运动加入当天后重新评分（不写库）",
      body: obj({
        date,
        meal: obj({ meal_type: str(), time, items: arr(ref("MealItem")), replace_meal_id: int("编辑已有餐食时传入") }),
        activity: ref("Activity"),
        body: obj({ weight_kg: nnum(), sbp: nnum(), dbp: nnum(), bp_treated: { type: "boolean" } }),
        workouts: arr(ref("Workout")),
      }),
      response: obj({
        date, before: ref("DailyScore"), after: ref("DailyScore"),
        indices: obj({ before: ref("HealthIndices"), after: ref("HealthIndices") }),
      }),
    },
  },
  "/meals": { post: { tag: "饮食", summary: "保存一餐（确认合并）", body: ref("MealInput"), response: obj({ id: int() }) } },
  "/meals/{id}": {
    put: { tag: "饮食", summary: "修改一餐（整体替换食物项）", params: [{ name: "id", in: "path", schema: int(), required: true }], body: ref("MealInput"), response: ok },
    delete: { tag: "饮食", summary: "删除一餐", params: [{ name: "id", in: "path", schema: int(), required: true }], response: ok },
  },
  "/meals/recent-items": { get: { tag: "饮食", summary: "近 60 天常吃的食物", response: arr(obj({ name: str(), food_id: int(), amount_g: num(), n: int() })) } },
  "/water": { post: { tag: "饮食", summary: "快速记录饮水（当天累加，可为负数撤销）", body: obj({ date, ml: num() }, ["ml"]), response: obj({ ok: { type: "boolean" }, total_ml: num() }) } },
  "/day/{date}": {
    get: {
      tag: "报告", summary: "某一天的完整数据：餐食、评分（HEI-2020 + MAR）、近 7 天 LE8 / WCRF、目标、活动、运动、身体指标",
      params: [{ name: "date", in: "path", schema: date, required: true }, userParam],
      response: obj({ date, score: ref("DailyScore"), targets: ref("Targets"), meals: arr(ref("Meal")), activity: ref("Activity"), exercises: arr(ref("Exercise")), body: arr(ref("BodyMetric")), weightTrend: nnum(), indices: ref("HealthIndices") }),
    },
  },

  "/foods": {
    get: { tag: "食物库", summary: "搜索食物库", params: [{ name: "q", in: "query", schema: str() }, { name: "scope", in: "query", schema: str("", { enum: ["all", "mine"] }) }], response: arr(ref("Food")) },
    post: { tag: "食物库", summary: "新建食物（每 100 g 数据）", body: ref("FoodInput"), response: obj({ id: int() }) },
  },
  "/foods/{id}": {
    get: { tag: "食物库", summary: "食物详情", params: [{ name: "id", in: "path", schema: int(), required: true }], response: ref("Food") },
    put: { tag: "食物库", summary: "修改（仅创建者）", params: [{ name: "id", in: "path", schema: int(), required: true }], body: ref("FoodInput"), response: ok },
    delete: { tag: "食物库", summary: "删除（仅创建者）", params: [{ name: "id", in: "path", schema: int(), required: true }], response: ok },
  },
  "/foods/{id}/item": { post: { tag: "食物库", summary: "按克数生成记录项（无需 AI）", params: [{ name: "id", in: "path", schema: int(), required: true }], body: obj({ grams: num() }), response: ref("MealItem") } },
  "/foods/from-item": { post: { tag: "食物库", summary: "把 AI 解析出的一项存入食物库", body: obj({ item: ref("MealItem"), name: str(), brand: str(), serving_g: num(), visibility: str("", { enum: ["private", "public"] }) }, ["item"]), response: obj({ id: int() }) } },

  "/body": {
    get: { tag: "身体与活动", summary: "称重 / 体脂 / 腰围 / 血压记录", params: [{ name: "start", in: "query", schema: date }, { name: "end", in: "query", schema: date }], response: arr(ref("BodyMetric")) },
    post: { tag: "身体与活动", summary: "记录体重、体脂、腰围、血压", body: obj({ date, time, weight_kg: nnum(), body_fat_pct: nnum(), waist_cm: nnum(), sbp: nnum(), dbp: nnum(), bp_treated: { type: "boolean" } }), response: obj({ id: int() }) },
  },
  "/body/{id}": { delete: { tag: "身体与活动", summary: "删除一条身体记录", params: [{ name: "id", in: "path", schema: int(), required: true }], response: ok } },
  "/labs": {
    get: { tag: "身体与活动", summary: "化验指标（胆固醇、血糖）", response: arr(ref("LabResult")) },
    post: { tag: "身体与活动", summary: "记录化验指标", body: ref("LabResult"), response: obj({ id: int() }) },
  },
  "/activity": { get: { tag: "身体与活动", summary: "每日活动与运动", params: [{ name: "start", in: "query", schema: date }, { name: "end", in: "query", schema: date }], response: obj({ days: arr(ref("Activity")), exercises: arr(ref("Exercise")) }) } },
  "/activity/{date}": { put: { tag: "身体与活动", summary: "手动填写某天的步数、活动能量、睡眠等（覆盖）", params: [{ name: "date", in: "path", schema: date, required: true }], body: ref("Activity"), response: ok } },
  "/activity/commit": { post: { tag: "身体与活动", summary: "确认合并 AI 识别或手动填写的活动 / 身体 / 运动数据", body: obj({ date, activity: ref("Activity"), body: obj({ weight_kg: nnum(), body_fat_pct: nnum(), sbp: nnum(), dbp: nnum() }), workouts: arr(ref("Workout")) }), response: obj({ ok: { type: "boolean" }, workouts: int() }) } },
  "/exercises": { post: { tag: "身体与活动", summary: "新增一次运动", body: ref("Workout"), response: obj({ id: int(), kcal: num() }) } },
  "/exercises/{id}": {
    patch: { tag: "身体与活动", summary: "标记是否已含在设备活动能量中", params: [{ name: "id", in: "path", schema: int(), required: true }], body: obj({ in_device: { type: "boolean" } }), response: ok },
    delete: { tag: "身体与活动", summary: "删除运动", params: [{ name: "id", in: "path", schema: int(), required: true }], response: ok },
  },
  "/health/ingest": {
    post: {
      tag: "身体与活动", summary: "健康数据推送（iPhone 快捷指令 / App 后台同步）", auth: "user_or_personal",
      description: "数值可以是带千分位或单位的字符串（如 \"8,532\"）；不传 date 时按用户时区记为今天。",
      body: obj({ date, steps: num(), active_kcal: num(), resting_kcal: num(), distance_km: num(), exercise_min: num(), sleep_hours: num(), weight_kg: num(), body_fat_pct: num() }),
      response: obj({ ok: { type: "boolean" }, date }),
    },
  },
  "/health/import": { post: { tag: "身体与活动", summary: "导入苹果健康 export.zip / export.xml", multipart: obj({ file: str("", { format: "binary" }), since: date }), response: obj({ ok: { type: "boolean" }, records: int(), days: int(), weights: int() }) } },

  "/trends": { get: { tag: "报告", summary: "逐日趋势序列（评分、摄入、消耗、体重、营养素、状态）", params: [{ name: "start", in: "query", schema: date }, { name: "end", in: "query", schema: date }, userParam], response: obj({ start: date, end: date, days: arr(obj({})) }) } },
  "/period": { get: { tag: "报告", summary: "周期报告（周 / 月 / 任意区间）", params: [{ name: "start", in: "query", schema: date }, { name: "end", in: "query", schema: date }, userParam], response: ref("PeriodScore") } },
  "/period/summary": { post: { tag: "报告", summary: "生成周期 AI 点评", body: obj({ start: date, end: date }), response: job } },
  "/reports": { get: { tag: "报告", summary: "已生成的周报 / 月报", response: arr(obj({})) } },
  "/users": { get: { tag: "社区", summary: "成员列表与共享状态", response: arr(obj({ id: int(), username: str(), display_name: str(), shared_with_me: { type: "boolean" }, recent: arr(obj({ date, score: nnum() })) })) } },
  "/standards/meta": { get: { tag: "标准库", summary: "营养素、食物组、风险物、HEI、运动 MET、评分体系、资料来源", response: obj({}) } },
  "/standards/dri": { get: { tag: "标准库", summary: "DRI 总表（20 个人群）", response: obj({}) } },
};

function schemas(): Record<string, S> {
  const nutrients = obj(Object.fromEntries(NUTRIENTS.map((n) => [n.key, num(`${n.zh} (${n.unit})`)])));
  const groups = obj(Object.fromEntries(FOOD_GROUPS.map((g) => [g.key, num(`${g.zh} (${g.unit})`)])));
  const hazard = obj({ key: str("", { enum: HAZARDS.map((h) => h.key) }), amount: num("与该风险相关的量（g；阿斯巴甜为 mg）"), note: str() }, ["key"]);
  const mealItem = obj({
    name: str(), amount_g: num(), amount_desc: str(), food_id: { type: ["integer", "null"], description: "引用食物库条目时由服务器按库数值重算" },
    category: str("", { enum: [...FOOD_CATEGORIES] }), cooking_method: str(), nova_group: { type: ["integer", "null"], enum: [1, 2, 3, 4, null] },
    confidence: str(), nutrients: ref("Nutrients"), groups: ref("FoodGroups"), hazards: arr(ref("Hazard")), notes: str(),
  }, ["name", "amount_g", "nutrients", "groups"]);
  return {
    Nutrients: nutrients,
    FoodGroups: groups,
    Hazard: hazard,
    MealItem: mealItem,
    MealInput: obj({ date, time, meal_type: str(), description: str(), photos: arr(str()), items: arr(ref("MealItem")), ai_summary: str(), ai_model: str() }, ["date", "time", "items"]),
    Meal: obj({ id: int(), date, time, meal_type: str(), description: str(), photos: arr(str()), items: arr(ref("MealItem")) }),
    User: obj({ id: int(), username: str(), display_name: str(), avatar_color: str(), share_mode: str(), share_detail: str() }),
    Profile: obj({
      sex: str("", { enum: ["male", "female"] }), birth_date: date, height_cm: num(), weight_kg: num(),
      activity_level: str("", { enum: ["inactive", "low_active", "active", "very_active"] }), goal: str("", { enum: ["lose", "maintain", "gain"] }),
      goal_rate_kg_week: num(), target_weight_kg: nnum(), physiology: str("", { enum: ["none", "pregnant", "lactating"] }),
      sodium_mode: str("", { enum: ["cdrr", "aha"] }), conditions: arr(str()), timezone: str(),
      nicotine: str("吸烟/尼古丁暴露（LE8）", { enum: ["unknown", "never", "former_5y", "former_1_5y", "former_lt1y", "ecig", "current"] }),
      secondhand_smoke: { type: "boolean" },
    }, ["sex", "birth_date", "height_cm", "weight_kg"]),
    Targets: obj({}),
    CompositeScore: obj({
      score: nnum(),
      parts: arr(obj({ key: str(), zh: str(), weight: num(), score: nnum(), points: nnum(), note: str() })),
      missing: arr(str()),
    }),
    DailyScore: obj({ score: nnum(), total: ref("CompositeScore") }),
    HealthIndices: obj({
      windowDays: int(), loggedDays: int(),
      le8: obj({ score: nnum(), available: int(), components: arr(obj({ key: str(), zh: str(), points: nnum(), value: str(), rule: str(), missing: str() })) }),
      wcrf: obj({ score: nnum(), max: num(), components: arr(obj({})) }),
      mepa: obj({ score: int(), days: int(), items: arr(obj({})) }),
    }),
    PeriodScore: obj({ score: nnum(), total: ref("CompositeScore") }),
    Activity: obj({ date, steps: nnum(), active_kcal: nnum(), resting_kcal: nnum(), distance_km: nnum(), exercise_min: nnum(), sleep_hours: nnum(), stand_hours: nnum(), source: str() }),
    Workout: obj({
      description: str(), activity_key: str("", { enum: ACTIVITIES.map((a) => a.key) }), met: num(), duration_min: num(), distance_km: num(),
      in_device: { type: "boolean", description: "已含在设备活动能量中" }, avg_hr: nnum(), device_kcal: nnum(), date, time,
    }, ["duration_min"]),
    Exercise: obj({ id: int(), date, time, description: str(), activity_key: str(), met: num(), duration_min: num(), distance_km: nnum(), kcal: num("净消耗 = (MET−1)×体重×小时"), in_device: int() }),
    BodyMetric: obj({ id: int(), date, time, weight_kg: nnum(), body_fat_pct: nnum(), waist_cm: nnum(), sbp: nnum(), dbp: nnum(), source: str() }),
    LabResult: obj({ date, total_chol: nnum("mg/dL"), hdl: nnum("mg/dL"), non_hdl: nnum("mg/dL"), ldl: nnum("mg/dL"), lipid_treated: { type: "boolean" }, fasting_glucose: nnum("mg/dL"), hba1c: nnum("%"), diabetes: { type: "boolean" } }),
    Food: obj({ id: int(), name: str(), brand: str(), serving_g: nnum(), serving_desc: str(), per100: ref("Nutrients"), groups100: ref("FoodGroups"), hazards100: arr(obj({ key: str(), amount_per_100g: num() })), nova_group: { type: ["integer", "null"] }, visibility: str(), mine: { type: "boolean" } }),
    FoodInput: obj({ name: str(), brand: str(), aliases: arr(str()), category: str(), serving_g: num(), serving_desc: str(), per100: ref("Nutrients"), groups100: ref("FoodGroups"), hazards100: arr(obj({ key: str(), amount_per_100g: num() })), nova_group: int(), ingredients: str(), visibility: str("", { enum: ["private", "public"] }) }, ["name"]),
    Error: obj({ error: str() }),
  };
}

export function buildOpenApi(base: string): S {
  const paths: Record<string, S> = {};
  for (const [path, methods] of Object.entries(OPS)) {
    const item: S = {};
    for (const [method, op] of Object.entries(methods)) {
      const auth = op.auth ?? "user";
      const o: S = {
        tags: [op.tag],
        summary: op.summary,
        ...(op.description ? { description: op.description } : {}),
        security: auth === "none" ? [] : auth === "user_or_personal" ? [{ bearerAuth: [] }, { personalToken: [] }, { cookieAuth: [] }] : [{ bearerAuth: [] }, { cookieAuth: [] }],
        ...(op.params ? { parameters: op.params.map((p) => ({ ...p, required: p.required ?? p.in === "path" })) } : {}),
        responses: {
          "200": { description: "成功", content: { "application/json": { schema: op.response ?? ok } } },
          "400": { description: "参数错误", content: { "application/json": { schema: ref("Error") } } },
          ...(auth !== "none" ? { "401": { description: "未登录或令牌失效", content: { "application/json": { schema: ref("Error") } } } } : {}),
        },
      };
      if (op.body) o.requestBody = { required: true, content: { "application/json": { schema: op.body } } };
      if (op.multipart) o.requestBody = { required: true, content: { "multipart/form-data": { schema: op.multipart } } };
      item[method] = o;
    }
    paths[path] = item;
  }
  return {
    openapi: "3.1.0",
    info: {
      title: "食迹 NutriLog API",
      version: "1.0.0",
      description:
        "网页与移动 App 共用的接口。App 调用 POST /auth/token 获取 Bearer 令牌后，在请求头加 `Authorization: Bearer <token>`。" +
        "AI 接口（/ai/*）异步执行：返回 job_id，轮询 /ai/jobs/{id}。所有“AI 解析 → 用户审核 → /preview 预览 → 确认保存”的流程与网页一致。",
    },
    servers: [{ url: `${base}/api/v1` }, { url: `${base}/api` }],
    components: {
      securitySchemes: {
        bearerAuth: { type: "http", scheme: "bearer", description: "App 令牌（nla_…），由 /auth/token 或 /auth/register（带 device_name）获取" },
        personalToken: { type: "http", scheme: "bearer", description: "个人 Token（nl_…），仅用于 /health/ingest" },
        cookieAuth: { type: "apiKey", in: "cookie", name: "nl_session" },
      },
      schemas: schemas(),
    },
    paths,
  };
}
