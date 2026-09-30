import { Link } from "react-router-dom";
import { Lock, Eye, Flame } from "lucide-react";
import { api } from "../api";
import { useLoad } from "../lib/app";
import type { CommunityUser } from "../types";
import { Avatar, Loading } from "../components/ui";
import { fmt } from "../lib/format";

export default function Community() {
  const { data, loading } = useLoad(() => api.get<CommunityUser[]>("/users"), []);
  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>社区</h1>
          <div className="sub">所有成员都能看到彼此的用户名；每日数据是否共享、共享给谁、共享多少由每个人自己决定（<Link to="/settings#share">我的分享设置</Link>）</div>
        </div>
      </div>
      {loading && <Loading />}
      <div className="grid g3">
        {data?.map((u) => {
          const scores = u.recent.map((r) => r.score);
          const valid = scores.filter((s): s is number => s != null);
          const avg = valid.length ? valid.reduce((a, b) => a + b, 0) / valid.length : null;
          const body = (
            <div className="card col" style={{ gap: 12, height: "100%" }}>
              <div className="row">
                <Avatar name={u.display_name} color={u.avatar_color} size="lg" />
                <div className="grow">
                  <div style={{ fontWeight: 650, fontSize: 16 }}>{u.display_name} {u.is_me && <span className="chip accent">我</span>}</div>
                  <div className="small muted">@{u.username}</div>
                </div>
              </div>
              {u.shared_with_me ? (
                <>
                  <div>
                    <div className="row between small" style={{ marginBottom: 4 }}>
                      <span className="sec">近 14 天膳食质量（HEI-2020）</span>
                      <span className="muted tnum">均分 {fmt(avg)}</span>
                    </div>
                    <div className="sparkline" role="img" aria-label={`近 14 天平均 ${fmt(avg)} 分`}>
                      {u.recent.map((r) => (
                        <div key={r.date} className={r.score == null ? "none" : ""} style={{ height: r.score == null ? undefined : `${Math.max(6, r.score)}%` }} title={`${r.date}：${r.score ?? "无记录"}`} />
                      ))}
                    </div>
                  </div>
                  <div className="row small sec wrap">
                    <span className="row" style={{ gap: 4 }}><Flame size={14} color="var(--series-2)" /> 连续记录 {u.streak} 天</span>
                    <span className="muted">最近记录 {u.last_log_date ?? "—"}</span>
                  </div>
                  <span className="chip" style={{ alignSelf: "flex-start" }}><Eye size={12} /> {u.is_me ? "这是你" : u.share_detail === "full" ? "共享了完整记录" : "只共享评分摘要"}</span>
                </>
              ) : (
                <div className="row small muted" style={{ gap: 6 }}><Lock size={14} /> 未向你共享每日数据</div>
              )}
            </div>
          );
          return u.shared_with_me ? (
            <Link key={u.id} to={u.is_me ? "/" : `/u/${u.username}`} style={{ textDecoration: "none", color: "inherit" }}>{body}</Link>
          ) : (
            <div key={u.id}>{body}</div>
          );
        })}
      </div>
    </div>
  );
}
