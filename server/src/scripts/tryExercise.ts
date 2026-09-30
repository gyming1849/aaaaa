// 手动测试运动解析：npx tsx src/scripts/tryExercise.ts "游泳5km，然后散步半小时"
import { parseExercise } from "../ai/service.ts";
import { activeProvider } from "../ai/providers.ts";

console.log("provider:", activeProvider());
const r = await parseExercise(process.argv[2] ?? "早上游泳5km，晚上快走40分钟", 70);
console.log(JSON.stringify(r, null, 1));
