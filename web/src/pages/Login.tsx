import { useState, type FormEvent } from "react";
import { Leaf, Sparkles, ChartLine, ShieldAlert, Users } from "lucide-react";
import { api } from "../api";
import { useApp } from "../lib/app";

export default function Login() {
  const { refreshMe, toast } = useApp();
  const [mode, setMode] = useState<"login" | "register">("login");
  const [form, setForm] = useState({ username: "", password: "", display_name: "", invite_code: "" });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof form) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      await api.post(mode === "login" ? "/auth/login" : "/auth/register", form);
      await refreshMe();
    } catch (err) {
      toast((err as Error).message, "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="auth-page">
      <div className="auth-art">
        <div className="row" style={{ gap: 12 }}>
          <div className="brand-mark" style={{ background: "rgba(255,255,255,.14)" }}>
            <Leaf color="#fff" size={19} />
          </div>
          <div style={{ fontWeight: 700, fontSize: 18, color: "#fff" }}>食迹 NutriLog</div>
        </div>
        <div>
          <h1>把每一餐，<br />变成看得见的健康趋势</h1>
          <div className="feature-list">
            <div><Sparkles /> 用一句话描述吃了什么，Claude 自动拆解成 40+ 种营养素与食物组</div>
            <div><ShieldAlert /> 对照美国 DRI、膳食指南、HEI-2020 与 IARC 致癌物分级逐项打分</div>
            <div><ChartLine /> 摄入、消耗、体重交叉对照，按日 / 周 / 月 / 年追踪</div>
            <div><Users /> 和家人朋友一起记录，自己决定分享哪些数据</div>
          </div>
        </div>
        <p className="small" style={{ opacity: 0.6 }}>评分仅用于自我管理参考，不构成医疗建议。</p>
      </div>
      <div className="auth-form">
        <form className="card stack" onSubmit={submit}>
          <div>
            <h1 style={{ fontSize: 22 }}>{mode === "login" ? "欢迎回来" : "创建账号"}</h1>
            <p className="muted small" style={{ marginTop: 4 }}>{mode === "login" ? "登录以继续记录" : "注册后先建立个人档案"}</p>
          </div>
          <div className="field">
            <label>用户名</label>
            <input className="input" value={form.username} onChange={set("username")} autoComplete="username" required />
          </div>
          {mode === "register" && (
            <div className="field">
              <label>昵称（其他成员看到的名字）</label>
              <input className="input" value={form.display_name} onChange={set("display_name")} />
            </div>
          )}
          <div className="field">
            <label>密码</label>
            <input className="input" type="password" value={form.password} onChange={set("password")} autoComplete={mode === "login" ? "current-password" : "new-password"} required minLength={mode === "register" ? 6 : undefined} />
          </div>
          {mode === "register" && (
            <div className="field">
              <label>邀请码（站点设置了才需要）</label>
              <input className="input" value={form.invite_code} onChange={set("invite_code")} />
            </div>
          )}
          <button className="btn primary lg block" disabled={busy}>
            {busy ? <span className="spinner" /> : mode === "login" ? "登录" : "注册"}
          </button>
          <button type="button" className="btn ghost block" onClick={() => setMode(mode === "login" ? "register" : "login")}>
            {mode === "login" ? "还没有账号？注册" : "已有账号？登录"}
          </button>
        </form>
      </div>
    </div>
  );
}
