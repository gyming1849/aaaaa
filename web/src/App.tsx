import { NavLink, Navigate, Route, Routes, useNavigate } from "react-router-dom";
import { House, ChartLine, Scale, Library, Users, BookOpen, Settings, Plus, FileText, Leaf } from "lucide-react";
import { useApp } from "./lib/app";
import { Avatar, Loading } from "./components/ui";
import Login from "./pages/Login";
import Onboarding from "./pages/Onboarding";
import Today from "./pages/Today";
import LogMeal from "./pages/LogMeal";
import Trends from "./pages/Trends";
import Reports from "./pages/Reports";
import Body from "./pages/Body";
import Foods from "./pages/Foods";
import Community from "./pages/Community";
import Standards from "./pages/Standards";
import SettingsPage from "./pages/Settings";

const NAV = [
  { to: "/", label: "今日", icon: House, end: true },
  { to: "/trends", label: "趋势", icon: ChartLine },
  { to: "/reports", label: "报告", icon: FileText },
  { to: "/body", label: "身体与运动", icon: Scale },
  { to: "/foods", label: "食物库", icon: Library },
  { to: "/community", label: "社区", icon: Users },
  { to: "/standards", label: "标准库", icon: BookOpen },
  { to: "/settings", label: "设置", icon: Settings },
];

export default function App() {
  const { me, loading } = useApp();
  if (loading) return <Loading />;
  if (!me) {
    return (
      <Routes>
        <Route path="*" element={<Login />} />
      </Routes>
    );
  }
  if (!me.profile) return <Onboarding />;
  return <Shell />;
}

function Shell() {
  const { me } = useApp();
  const nav = useNavigate();
  const u = me!.user;
  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark">
            <Leaf color="#fff" size={19} />
          </div>
          <div>
            <div className="brand-name">食迹</div>
            <div className="brand-sub">NUTRILOG</div>
          </div>
        </div>
        <button className="btn primary block" style={{ marginBottom: 12 }} onClick={() => nav("/log")}>
          <Plus /> 记一餐
        </button>
        {NAV.map((n) => (
          <NavLink key={n.to} to={n.to} end={n.end} className={({ isActive }) => `nav-link ${isActive ? "active" : ""}`}>
            <n.icon /> {n.label}
          </NavLink>
        ))}
        <div className="spacer" />
        <div className="sidebar-user">
          <Avatar name={u.display_name} color={u.avatar_color} />
          <div className="grow">
            <div style={{ fontWeight: 600, fontSize: 14 }}>{u.display_name}</div>
            <div className="small muted">@{u.username}</div>
          </div>
        </div>
      </aside>

      <main className="main">
        <Routes>
          <Route path="/" element={<Today />} />
          <Route path="/log" element={<LogMeal />} />
          <Route path="/trends" element={<Trends />} />
          <Route path="/reports" element={<Reports />} />
          <Route path="/body" element={<Body />} />
          <Route path="/foods" element={<Foods />} />
          <Route path="/community" element={<Community />} />
          <Route path="/u/:username" element={<Today />} />
          <Route path="/u/:username/trends" element={<Trends />} />
          <Route path="/standards" element={<Standards />} />
          <Route path="/settings" element={<SettingsPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>

      <nav className="bottom-nav">
        <NavLink to="/" end className={({ isActive }) => (isActive ? "active" : "")}>
          <House /> 今日
        </NavLink>
        <NavLink to="/trends" className={({ isActive }) => (isActive ? "active" : "")}>
          <ChartLine /> 趋势
        </NavLink>
        <NavLink to="/log" className={({ isActive }) => (isActive ? "active" : "")}>
          <span className="fab">
            <Plus />
          </span>
        </NavLink>
        <NavLink to="/body" className={({ isActive }) => (isActive ? "active" : "")}>
          <Scale /> 身体
        </NavLink>
        <NavLink to="/settings" className={({ isActive }) => (isActive ? "active" : "")}>
          <Settings /> 更多
        </NavLink>
      </nav>
    </div>
  );
}
