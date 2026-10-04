import Foundation

// MARK: - Number formatting (web `lib/format.ts`; web1 §0.3, web2 §1.5)

/// Web `fmt(v, d)`: `—` for nil/NaN/±∞; otherwise zh-CN grouping (`1,568`), at most `d` decimals with trailing zeros
/// dropped (`39.2`, `78`), rounding half away from zero (`2.5 → 3`), ASCII minus (`-795`).
func fmt(_ v: Double?, _ d: Int = 0) -> String {
    guard let v, v.isFinite else { return "—" }
    return v.formatted(.number.precision(.fractionLength(0...d)).locale(Locale(identifier: "zh_CN")).rounded(rule: .toNearestOrAwayFromZero))
}

enum Fmt {
    /// `+12` / `-3` / `0`: a plus sign only for positive values (web `${v > 0 ? "+" : ""}${fmt(v, d)}`).
    static func signed(_ v: Double?, _ d: Int = 0) -> String { guard let v else { return "—" }; return (v > 0 ? "+" : "") + fmt(v, d) }
    /// Web `compact`: `1.2万` when |v| ≥ 10000, else `fmt(v)`.
    static func compact(_ v: Double?) -> String { guard let v else { return "—" }; return abs(v) >= 10000 ? fmt(v / 10000, 1) + "万" : fmt(v) }
    static func kcal(_ v: Double?) -> String { "\(fmt(v)) kcal" }
    /// `68.2 kg` (1 decimal by default).
    static func kg(_ v: Double?, _ d: Int = 1) -> String { "\(fmt(v, d)) kg" }
    /// `35%` (no space, like the web's macro and percentage labels).
    static func percent(_ v: Double?, _ d: Int = 0) -> String { "\(fmt(v, d))%" }
}
