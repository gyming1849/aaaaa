// 手动测试运动/健康数据识别：npx tsx src/scripts/tryActivity.ts "今天走了9200步，活动能量420千卡，游泳5km，睡了7个半小时，体重76.2"
import { recognizeActivity } from "../ai/service.ts";
import { activeProvider } from "../ai/providers.ts";
import { todayIn } from "../lib/dates.ts";

const today = todayIn("Asia/Shanghai");
console.log("provider:", activeProvider());
const r = await recognizeActivity(0, { date: today, today, text: process.argv[2] ?? "今天走了9200步，活动能量420千卡，晚上游泳5km，睡了7个半小时，睡前体重76.2，血压128/82", photos: [] }, 76);
console.log(JSON.stringify(r, null, 1));
