import { useState } from "react";
import { Link } from "react-router-dom";
import { LogOut, Sun, Moon, Monitor, Sparkles, BookOpen, Library, Users, FileText } from "lucide-react";
import { api } from "../api";
import { useApp, useLoad } from "../lib/app";
import type { CommunityUser } from "../types";
import { ProfileForm } from "../components/ProfileForm";
import { Avatar, Seg } from "../components/ui";
import { applyTheme } from "../lib/theme";

const COLORS = ["#2f7d5b", "#3b6fb6", "#b5523b", "#7a5bb5", "#b58a2f", "#2f8c93", "#b53b72", "#5b7a2f"];

export default function Settings() {
  const { me, refreshMe, toast } = useApp();
  const u = me!.user;
  const users = useLoad(() => api.get<CommunityUser[]>("/users"), []);
  const [share, setShare] = useState({ display_name: u.display_name, avatar_color: u.avatar_color, share_mode: u.share_mode, share_detail: u.share_detail, share_with: u.share_with });
  const [pw, setPw] = useState({ old_password: "", new_password: "" });
  const [theme, setTheme] = useState<string>(() => {
    try {
      return localStorage.getItem("nl-theme") ?? "system";
    } catch {
      return "system";
    }
  });

  async function saveShare() {
    try {
      await api.put("/settings", share);
      await refreshMe();
      toast("已保存");
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }
  async function changePw() {
    try {
      await api.post("/auth/password", pw);
      setPw({ old_password: "", new_password: "" });
      toast("密码已修改");
    } catch (e) {
      toast((e as Error).message, "error");
    }
  }
  async function logout() {
    await api.post("/auth/logout");
    await refreshMe();
  }

  return (
    <div className="stack" style={{ maxWidth: 900 }}>
      <div className="page-head">
        <div><h1>设置</h1><div className="sub">@{u.username}</div></div>
        <button className="btn" onClick={logout}><LogOut /> 退出登录</button>
      </div>

      <div className="grid g4 only-mobile-grid">
        <Link className="card tight row" to="/reports"><FileText size={18} /> 周期报告</Link>
        <Link className="card tight row" to="/foods"><Library size={18} /> 食物库</Link>
        <Link className="card tight row" to="/community"><Users size={18} /> 社区</Link>
        <Link className="card tight row" to="/standards"><BookOpen size={18} /> 标准库</Link>
      </div>

      <div className="card">
        <div className="card-head"><h2>个人档案</h2><span className="hint">修改后所有历史评分会按新档案重新计算</span></div>
        <ProfileForm initial={me!.profile} />
      </div>

      <div className="card stack" id="share">
        <div className="card-head" style={{ marginBottom: 0 }}><h2>资料与分享</h2></div>
        <div className="grid g2">
          <div className="field"><label>昵称</label><input className="input" value={share.display_name} onChange={(e) => setShare({ ...share, display_name: e.target.value })} /></div>
          <div className="field">
            <label>头像颜色</label>
            <div className="row">
              {COLORS.map((c) => (
                <button key={c} onClick={() => setShare({ ...share, avatar_color: c })} aria-label={c}
                  style={{ width: 28, height: 28, borderRadius: 99, background: c, border: share.avatar_color === c ? "3px solid var(--ink)" : "2px solid var(--surface)", cursor: "pointer" }} />
              ))}
            </div>
          </div>
        </div>
        <div className="field">
          <label>谁能看到我的每日数据（所有人都能看到你的用户名）</label>
          <Seg value={share.share_mode} onChange={(v) => setShare({ ...share, share_mode: v })} options={[{ key: "private", label: "仅自己" }, { key: "public", label: "所有成员" }, { key: "selected", label: "指定成员" }]} />
        </div>
        {share.share_mode !== "private" && (
          <div className="field">
            <label>共享内容</label>
            <Seg value={share.share_detail} onChange={(v) => setShare({ ...share, share_detail: v })} options={[{ key: "summary", label: "仅评分与趋势" }, { key: "full", label: "完整记录（含吃了什么）" }]} />
          </div>
        )}
        {share.share_mode === "selected" && (
          <div className="field">
            <label>选择成员</label>
            <div className="row wrap">
              {users.data?.filter((x) => !x.is_me).map((x) => {
                const on = share.share_with.includes(x.id);
                return (
                  <button key={x.id} className={`chip ${on ? "on" : ""}`} onClick={() => setShare({ ...share, share_with: on ? share.share_with.filter((y) => y !== x.id) : [...share.share_with, x.id] })}>
                    <Avatar name={x.display_name} color={x.avatar_color} /> {x.display_name}
                  </button>
                );
              })}
              {users.data && users.data.length <= 1 && <span className="small muted">还没有其他成员</span>}
            </div>
          </div>
        )}
        <div className="row" style={{ justifyContent: "flex-end" }}><button className="btn primary" onClick={saveShare}>保存</button></div>
      </div>

      <div className="grid g2">
        <div className="card stack">
          <h2>外观</h2>
          <Seg value={theme} onChange={(v) => { setTheme(v); try { if (v === "system") localStorage.removeItem("nl-theme"); else localStorage.setItem("nl-theme", v); } catch { /* 忽略 */ } applyTheme(v === "system" ? null : v); }}
            options={[{ key: "system", label: <><Monitor size={14} /> 跟随系统</> }, { key: "light", label: <><Sun size={14} /> 浅色</> }, { key: "dark", label: <><Moon size={14} /> 深色</> }]} />
          <h2 style={{ marginTop: 8 }}>AI</h2>
          <div className="banner"><Sparkles /> {me!.ai.provider === "mock" ? "未配置 AI：使用离线关键词估算。在服务器上安装并登录 Claude Code（claude -p），或设置 ANTHROPIC_API_KEY 后重启即可启用。" : `当前使用 ${me!.ai.model}（${me!.ai.provider === "cli" ? "claude -p 命令行" : "Anthropic API"}）`}</div>
        </div>
        <div className="card stack">
          <h2>修改密码</h2>
          <div className="field"><label>原密码</label><input className="input" type="password" value={pw.old_password} onChange={(e) => setPw({ ...pw, old_password: e.target.value })} autoComplete="current-password" /></div>
          <div className="field"><label>新密码</label><input className="input" type="password" value={pw.new_password} onChange={(e) => setPw({ ...pw, new_password: e.target.value })} autoComplete="new-password" /></div>
          <button className="btn" onClick={changePw} disabled={!pw.old_password || pw.new_password.length < 6}>修改</button>
        </div>
      </div>
    </div>
  );
}
