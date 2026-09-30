// 致癌物 / 饮食风险物数据库。
// IARC 分级：1 = 对人类致癌；2A = 很可能致癌；2B = 可能致癌（分级表示证据强度，不表示危害大小）。
// 评分规则 v2 中这些只作为警示展示、不另设扣分；加工肉、红肉、酒精与含糖饮料在 WCRF/AICR 防癌评分中计分。

export type HazardDose =
  /** 剂量来自食物组当量（如加工肉克数） */
  | { from: "group"; key: string; unit: "g" }
  /** 剂量来自营养素（如酒精克数） */
  | { from: "nutrient"; key: string; unit: "g" | "mg" }
  /** 剂量来自 AI 标注的风险项（与该风险相关的食物克数/毫克数） */
  | { from: "flag"; unit: "g" | "mg" | "ml" };

export interface HazardDef {
  key: string;
  zh: string;
  en: string;
  iarc: "1" | "2A" | "2B" | "—";
  /** 风险类型 */
  category: "carcinogen" | "toxicant" | "lifestyle";
  /** 主要关联的疾病/部位 */
  risk: string;
  /** AI 识别时的判定说明（也会展示给用户） */
  detect: string;
  examples: string;
  dose: HazardDose;
  /** 参考份量：AI 未给出剂量时按一份计 */
  refAmount: number;
  /** 是否让 AI 主动标注（剂量来自 flag 的项才需要） */
  aiFlag: boolean;
  sources: string[];
  advice: string;
}

export const HAZARDS: HazardDef[] = [
  {
    key: "processed_meat",
    zh: "加工肉",
    en: "Processed meat",
    iarc: "1",
    category: "carcinogen",
    risk: "结直肠癌（每天 50 g 风险约增加 18%），胃癌",
    detect: "经腌制、烟熏、发酵、添加亚硝酸盐等方式加工的肉",
    examples: "培根、火腿、香肠、腊肉、腊肠、午餐肉、热狗、肉松、牛肉干、咸肉",
    dose: { from: "group", key: "processed_meat_g", unit: "g" },
    refAmount: 50,
    aiFlag: false,
    sources: ["iarc_114", "iarc_qa_meat", "wcrf"],
    advice: "尽量少吃，WCRF 建议“很少或不吃”。可用新鲜禽肉、鱼、豆制品代替。",
  },
  {
    key: "red_meat",
    zh: "红肉",
    en: "Red meat",
    iarc: "2A",
    category: "carcinogen",
    risk: "结直肠癌（很可能），胰腺癌、前列腺癌（有限证据）",
    detect: "猪牛羊等哺乳动物的新鲜肌肉肉",
    examples: "猪肉、牛肉、羊肉、牛排、红烧肉",
    dose: { from: "group", key: "red_meat_g", unit: "g" },
    refAmount: 100,
    aiFlag: false,
    sources: ["iarc_114", "wcrf"],
    advice: "每周红肉熟重控制在 350–500 g 以内，日均不超过约 70 g。",
  },
  {
    key: "alcohol",
    zh: "酒精饮料",
    en: "Alcoholic beverages",
    iarc: "1",
    category: "carcinogen",
    risk: "口腔、咽、喉、食管、肝、结直肠、乳腺等多种癌症；无安全阈值",
    detect: "按纯酒精克数计",
    examples: "啤酒、白酒、红酒、黄酒、鸡尾酒",
    dose: { from: "nutrient", key: "alcohol_g", unit: "g" },
    refAmount: 14,
    aiFlag: false,
    sources: ["iarc_list", "niaaa_drink", "dga_2020"],
    advice: "越少越好。孕期、未成年人应完全避免。",
  },
  {
    key: "salted_fish_cantonese",
    zh: "中式咸鱼",
    en: "Chinese-style salted fish",
    iarc: "1",
    category: "carcinogen",
    risk: "鼻咽癌",
    detect: "传统盐腌、晾晒发酵的咸鱼（腌制过程产生亚硝胺）",
    examples: "咸鱼、梅香咸鱼、咸鱼茄子煲、咸鱼炒饭中的咸鱼",
    dose: { from: "flag", unit: "g" },
    refAmount: 50,
    aiFlag: true,
    sources: ["iarc_list"],
    advice: "尽量避免，尤其不要从小经常食用。",
  },
  {
    key: "areca_nut",
    zh: "槟榔",
    en: "Areca nut / betel quid",
    iarc: "1",
    category: "carcinogen",
    risk: "口腔癌、咽癌、食管癌",
    detect: "嚼食槟榔（无论是否含烟草）",
    examples: "槟榔、槟榔果、含槟榔的嚼块",
    dose: { from: "flag", unit: "g" },
    refAmount: 10,
    aiFlag: true,
    sources: ["iarc_list"],
    advice: "不要嚼槟榔。",
  },
  {
    key: "aflatoxin_risk",
    zh: "黄曲霉毒素风险",
    en: "Aflatoxins",
    iarc: "1",
    category: "carcinogen",
    risk: "肝癌",
    detect: "食用明显发霉/变味的花生、玉米、坚果、谷物，或未经精炼的土榨花生油",
    examples: "发霉花生、哈喇味坚果、发霉玉米、自榨花生油",
    dose: { from: "flag", unit: "g" },
    refAmount: 30,
    aiFlag: true,
    sources: ["iarc_list"],
    advice: "发霉或有哈喇味的坚果谷物一律丢弃；选择精炼食用油。",
  },
  {
    key: "high_temp_meat",
    zh: "高温烧烤/焦糊肉类",
    en: "Meat cooked at high temperature (HCAs/PAHs)",
    iarc: "2A",
    category: "carcinogen",
    risk: "杂环胺 (HCAs) 与多环芳烃 (PAHs，苯并[a]芘为 1 类) —— 结直肠、胰腺、前列腺癌风险",
    detect: "明火烧烤、炭烤、铁板高温煎至焦黑的肉/鱼",
    examples: "烤串、炭烤肉、韩式烤肉、烤鸭皮焦黑部分、煎到焦黑的牛排",
    dose: { from: "flag", unit: "g" },
    refAmount: 100,
    aiFlag: true,
    sources: ["nci_hca_pah", "iarc_list"],
    advice: "避免焦黑部分，多翻面、先预煮、降低火候，搭配蔬菜。",
  },
  {
    key: "smoked_food",
    zh: "烟熏食品",
    en: "Smoked foods (PAHs)",
    iarc: "2A",
    category: "carcinogen",
    risk: "多环芳烃 (PAHs) 暴露",
    detect: "烟熏工艺制作的肉、鱼、豆制品等",
    examples: "烟熏三文鱼、烟熏香肠、熏肉、熏鱼、烟熏豆干",
    dose: { from: "flag", unit: "g" },
    refAmount: 100,
    aiFlag: true,
    sources: ["nci_hca_pah", "iarc_list"],
    advice: "减少烟熏食品频率。",
  },
  {
    key: "acrylamide",
    zh: "丙烯酰胺(高温油炸/烘烤淀粉)",
    en: "Acrylamide",
    iarc: "2A",
    category: "carcinogen",
    risk: "动物实验致癌，人类很可能致癌",
    detect: "淀粉类食物经 120°C 以上油炸/烘烤，颜色金黄至焦褐",
    examples: "薯条、薯片、油条、炸糕、深烤吐司、焦饼干",
    dose: { from: "flag", unit: "g" },
    refAmount: 100,
    aiFlag: true,
    sources: ["fda_acrylamide", "iarc_list"],
    advice: "烤至金黄即可，避免焦褐；少吃油炸淀粉类。",
  },
  {
    key: "pickled_vegetables",
    zh: "传统腌菜",
    en: "Pickled vegetables (traditional Asian)",
    iarc: "2B",
    category: "carcinogen",
    risk: "食管癌、胃癌（可能）；同时高盐",
    detect: "传统盐腌/发酵蔬菜（非现做醋泡）",
    examples: "酸菜、泡菜、咸菜、榨菜、梅干菜、雪菜、腌萝卜",
    dose: { from: "flag", unit: "g" },
    refAmount: 50,
    aiFlag: true,
    sources: ["iarc_list"],
    advice: "少量佐餐即可，同时注意钠摄入。",
  },
  {
    key: "very_hot_beverage",
    zh: "过烫饮品(>65°C)",
    en: "Very hot beverages",
    iarc: "2A",
    category: "carcinogen",
    risk: "食管鳞癌",
    detect: "用户明确提到很烫/滚烫时饮用的茶、咖啡、汤等",
    examples: "滚烫的茶、刚出锅的热汤一口闷",
    dose: { from: "flag", unit: "ml" },
    refAmount: 250,
    aiFlag: true,
    sources: ["iarc_hot_bev"],
    advice: "稍放凉（< 60°C）再喝。",
  },
  {
    key: "bracken_fern",
    zh: "蕨菜",
    en: "Bracken fern",
    iarc: "2B",
    category: "carcinogen",
    risk: "含原蕨苷 (ptaquiloside)，动物实验致胃癌、膀胱癌",
    detect: "食用蕨菜（龙须菜不算）",
    examples: "凉拌蕨菜、蕨根粉（淀粉制品风险较低）",
    dose: { from: "flag", unit: "g" },
    refAmount: 100,
    aiFlag: true,
    sources: ["iarc_list"],
    advice: "偶尔吃无妨，避免经常大量食用；充分焯水可降低含量。",
  },
  {
    key: "high_mercury_fish",
    zh: "高汞鱼类",
    en: "High-mercury fish",
    iarc: "—",
    category: "toxicant",
    risk: "甲基汞神经毒性（孕妇、哺乳期、儿童尤其敏感）",
    detect: "FDA/EPA 列为“应避免”的高汞鱼",
    examples: "大耳马鲛/王鲭、枪鱼(马林鱼)、橙棘鲷、鲨鱼、剑鱼、方头鱼(墨西哥湾)、大眼金枪鱼",
    dose: { from: "flag", unit: "g" },
    refAmount: 100,
    aiFlag: true,
    sources: ["fda_fish"],
    advice: "选择三文鱼、鳕鱼、虾、罗非鱼等低汞海产。",
  },
  {
    key: "hijiki",
    zh: "羊栖菜(无机砷)",
    en: "Hijiki seaweed (inorganic arsenic)",
    iarc: "1",
    category: "carcinogen",
    risk: "无机砷为 1 类致癌物（肺、膀胱、皮肤）",
    detect: "食用羊栖菜（鹿尾菜/ひじき）",
    examples: "羊栖菜沙拉、日式煮羊栖菜",
    dose: { from: "flag", unit: "g" },
    refAmount: 50,
    aiFlag: true,
    sources: ["iarc_list"],
    advice: "海带、紫菜、裙带菜等不受影响，避免羊栖菜即可。",
  },
  {
    key: "aspartame",
    zh: "阿斯巴甜(超过 ADI 时扣分)",
    en: "Aspartame",
    iarc: "2B",
    category: "carcinogen",
    risk: "IARC 2B；JECFA 认为在 ADI（40 mg/kg 体重）以内可接受",
    detect: "含阿斯巴甜的无糖饮料/食品，按阿斯巴甜毫克数（一罐 355 ml 无糖可乐约 180–200 mg）",
    examples: "健怡/零度可乐（部分配方）、无糖口香糖、代糖",
    dose: { from: "flag", unit: "mg" },
    refAmount: 1,
    aiFlag: true,
    sources: ["iarc_aspartame"],
    advice: "偶尔饮用在安全范围内；按体重计算，不要长期大量饮用。",
  },
];

export const HAZARD_MAP: Record<string, HazardDef> = Object.fromEntries(HAZARDS.map((h) => [h.key, h]));
export const AI_HAZARD_KEYS = HAZARDS.filter((h) => h.aiFlag).map((h) => h.key);

/** 阿斯巴甜 ADI（JECFA 2023） mg/kg 体重/天 */
export const ASPARTAME_ADI_MG_PER_KG = 40;

/** 已知但不警示的项目（饮食中常见剂量下风险较低或证据不足），仅在标准库中展示 */
export const HAZARDS_INFO_ONLY = [
  { zh: "呋喃 (Furan)", iarc: "2B", examples: "咖啡、罐头、罐装婴儿食品", why: "日常饮食暴露量低，且咖啡本身对多种癌症呈中性或保护作用，不计分" },
  { zh: "4-甲基咪唑 (4-MEI)", iarc: "2B", examples: "可乐等焦糖色饮料、老抽", why: "膳食暴露量远低于风险水平，已由添加糖/钠规则覆盖" },
  { zh: "咖啡", iarc: "3", examples: "咖啡", why: "IARC 2016 年将咖啡降为第 3 类（无法分类），不警示；咖啡因另行限量" },
  { zh: "亚硝酸盐 (内源性亚硝化条件下)", iarc: "2A", examples: "腌肉、腌菜", why: "已由加工肉、腌菜、咸鱼规则覆盖" },
  { zh: "稻米中的无机砷", iarc: "1", examples: "大米、糙米、米粉", why: "作为主食的一般摄入量低于风险水平；仅对羊栖菜单独计分" },
];
