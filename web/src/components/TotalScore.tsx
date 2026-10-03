// 综合总分（满分 100，本站自定权重）的一行分项说明
import type { CompositeScore } from "../types";
import { fmt } from "../lib/format";

export function TotalParts({ total }: { total: CompositeScore }) {
  if (total.score == null) return null;
  const avail = total.parts.filter((p) => p.score != null);
  const scale = 100 / Math.max(1, avail.reduce((s, p) => s + p.weight, 0));
  return (
    <div className="small sec">
      {avail.map((p) => `${p.zh} ${fmt(p.points, 1)}/${fmt(p.weight * scale, total.missing.length ? 1 : 0)}`).join(" · ")}
      {total.missing.length > 0 && <span className="muted">（缺{total.missing.join("、")}，其余按权重折算）</span>}
    </div>
  );
}
