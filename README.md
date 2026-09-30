# 食迹 NutriLog

多人使用的每日饮食记录与健康评分网站。用一句话（或一张照片）记录吃了什么，由 Claude 拆解成 40 多种营养素、USDA 食物组和致癌/风险物标记；服务器再对照**美国权威营养标准**离线打分，并把摄入、消耗、体重放在一起追踪。

![今日概览](docs/screenshots/today.png)

## 功能

- **个人档案**：性别、出生日期、身高、体重、活动水平、目标（减重/维持/增重）、孕期/哺乳期、高血压/高胆固醇/糖尿病等状况。所有目标按年龄、性别、体重个性化计算。
- **自然语言记一餐**：“中午一包李子柒螺蛳粉加一个卤蛋，喝了罐可乐”。可以附食物照片、包装、配料表或营养成分表照片。Claude（默认 Opus 5.5）会：
  - 估算每种食物的份量（g），以及 43 种营养素：能量、三大营养素、纤维、总糖/添加糖、饱和/反式/单不饱和/多不饱和脂肪、ω-3/ω-6、胆固醇、11 种矿物质、14 种维生素、胆碱、水分、咖啡因、酒精；
  - 估算 USDA 食物组当量（水果、蔬菜、深绿色蔬菜、豆类、全谷物/精制谷物、奶、蛋白质、海产、植物蛋白、红肉、加工肉、禽肉）和 NOVA 加工程度；
  - 标记致癌物与风险物（IARC 分级），例如烟熏、炭烤、腌菜、咸鱼、丙烯酰胺、阿斯巴甜等；
  - 遇到品牌包装食品时**联网查询官方营养成分表**，并附上来源链接。
- **食物库**：分析结果可一键“存入食物库”（按每 100 g 保存）；也可以输入名称让 AI 联网查询，或拍营养成分表读取标签数值。下次说出名称会自动匹配，或直接搜索并填克数，不需要再调用 AI。可以设为仅自己可见或所有成员可用。
- **离线评分**（详见 [docs/scoring.md](docs/scoring.md)）：每日综合分 = HEI-2020 膳食质量 + 营养素充足（RDA/AI）+ 限量控制（钠、添加糖、饱和脂肪、反式脂肪、酒精、咖啡因、超加工、UL、AMDR）+ 能量平衡 − 致癌物扣分。逐项列出达标/不达标、扣了多少分、依据哪条标准。
- **身体与运动**：睡前称重（体重、体脂、腰围）、步数/活动能量、运动记录（“游泳 5km”由 AI 按 2024 运动代谢当量表换算）。支持 **iPhone 快捷指令每天自动同步**，也支持导入“健康”App 的 export.zip。
- **能量交叉对照**：摄入 vs 消耗 vs 体重趋势（EMA 平滑），并用你的真实数据反推每日消耗。
- **趋势可视化**：7 天 / 30 天 / 90 天 / 今年 / 一年 / 全部 / 自定义；评分、分项得分、摄入与消耗、体重、任意营养素（带个人目标线）、年度评分日历、各项达标天数、风险物汇总。每张图都可以切换成数据表。
- **周报 / 月报**：每周一、每月 1 日自动生成，含 AI 点评（Claude 解读离线评分，给出下期 3–5 条行动建议）。
- **多人与分享**：所有成员互相看得到用户名；每个人自己决定数据是否共享、共享给所有人还是指定成员、只共享评分还是完整饮食记录。
- **标准库**：网页里可以查看本站用到的全部标准（DRI 总表、限量、HEI-2020、IARC 风险物、运动 MET、评分规则、资料来源）。
- 浅色 / 深色主题，手机与桌面自适应，可添加到手机主屏幕。

| 趋势 | 手机 | 深色 |
|---|---|---|
| ![趋势](docs/screenshots/trends.png) | ![手机](docs/screenshots/mobile.png) | ![深色](docs/screenshots/dark.png) |

## 快速开始

需要 **Node.js 22.13 或更高版本**（使用 Node 内置的 SQLite，无需安装数据库）。

```bash
npm install
npm run build        # 构建前端
npm start            # http://localhost:8787
```

打开网页注册账号，填写个人档案就可以开始记录。想先看看效果，可以生成演示数据（账号 `demo` / `xiaolin` / `ahao`，密码均为 `demo123`）：

```bash
npm run seed:demo -w server
```

开发模式（前端热更新在 http://localhost:5173，接口代理到 8787）：

```bash
npm run dev
```

运行测试与类型检查：

```bash
npm test
npm run typecheck
```

## 配置 AI

复制 `.env.example` 为 `.env`。有三种模式（`AI_PROVIDER`）：

| 模式 | 说明 |
|---|---|
| `cli` | 调用服务器上的 `claude -p`（Claude Code）。先 `npm install -g @anthropic-ai/claude-code`，用运行网站的同一个系统用户执行一次 `claude` 完成登录。支持联网搜索和读取照片。 |
| `api` | 用 Anthropic SDK 直接调用 Messages API，需要 `ANTHROPIC_API_KEY`。使用结构化输出与 `web_search` 工具，并启用了服务端 `fallbacks: "default"`：模型因安全分类器拒答时自动换推荐的后备模型重试。 |
| `mock` | 不使用 AI，按内置关键词表粗略估算，网站其余功能完全可用。 |

默认 `auto`：有 `ANTHROPIC_API_KEY` 就用 `api`，否则能找到 `claude` 命令就用 `cli`，都没有就用 `mock`。模型默认 `claude-opus-5-5`，可用 `AI_MODEL` 修改；`AI_EFFORT` 控制思考深度。

AI 调用在后台队列里执行，前端轮询进度。一次带联网查询的分析通常需要 30–90 秒。可以用下面的命令在命令行直接测试：

```bash
cd server
npx tsx src/scripts/tryAi.ts "中午吃了一包李子柒螺蛳粉，加了一个卤蛋"
npx tsx src/scripts/tryExercise.ts "游泳5km，晚上快走40分钟"
```

## 连接苹果健康

网页无法直接读取 HealthKit，提供两种方式（“身体与运动”页面有详细步骤）：

1. **iPhone 快捷指令**：在设置里生成个人 Token，用“快捷指令 → 自动化”每晚读取步数、活动能量、静息能量、体重，`POST` 到 `/api/health/ingest`，请求头 `Authorization: Bearer <Token>`：

   ```json
   {"steps": 8532, "active_kcal": 412, "resting_kcal": 1620, "exercise_min": 35, "weight_kg": 68.2}
   ```

2. **导出文件**：健康 App → 头像 → 导出所有健康数据，上传 `export.zip` 或 `export.xml`。会导入每日步数、活动/静息能量、距离、锻炼分钟、体重、体脂；iPhone 与 Apple Watch 的重复数据会去重。

手动记录的运动可以标记“已含在设备活动能量中”，避免重复计算。

## 部署建议

- 用 `pm2`、`systemd` 或 Docker 常驻运行 `npm start`；前面放 Nginx/Caddy 提供 HTTPS，并设置 `COOKIE_SECURE=true`。
- 只给家人朋友用时设置 `INVITE_CODE`，或者建好账号后把 `ALLOW_REGISTRATION` 设为 `false`。
- 定期备份 `DATA_DIR`（默认 `data/`，包含 SQLite 数据库和上传的照片）。
- iPhone 快捷指令需要能从外网访问 `/api/health/ingest`。

## 项目结构

```
server/                 Node + Express + SQLite（node:sqlite）
  src/standards/        标准数据库：营养素字典、DRI、HEI-2020、IARC 风险物、MET、能量方程、个性化目标、资料来源
  src/scoring/          离线评分引擎：每日、周期、体重趋势
  src/ai/               Claude 调用（claude -p / API / 离线）、提示词、JSON Schema、任务队列
  src/routes/           REST 接口
  src/services/         数据装载、评分缓存、定时任务
  test/                 评分引擎单元测试
web/                    React + Vite + ECharts 前端
docs/scoring.md         离线评分标准说明
```

## 免责声明

营养数据由 AI 估算，评分依据公开的人群标准，仅用于自我管理参考，不构成医疗建议。孕期、慢性病（尤其肾病、糖尿病）请遵医嘱调整目标。
