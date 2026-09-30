import { Leaf } from "lucide-react";
import { ProfileForm } from "../components/ProfileForm";
import { useApp } from "../lib/app";

export default function Onboarding() {
  const { me } = useApp();
  return (
    <div style={{ maxWidth: 720, margin: "0 auto", padding: "32px 16px 64px" }}>
      <div className="row" style={{ marginBottom: 20 }}>
        <div className="brand-mark">
          <Leaf color="#fff" size={19} />
        </div>
        <div>
          <h1>你好，{me?.user.display_name}！先建立个人档案</h1>
          <p className="muted small">身高、体重、年龄和性别决定你的营养目标（DRI 分人群）、能量需求（NASEM 2023 方程）和按体重计算的限量（如蛋白质、咖啡因、阿斯巴甜 ADI）。</p>
        </div>
      </div>
      <div className="card">
        <ProfileForm submitText="开始记录" />
      </div>
    </div>
  );
}
