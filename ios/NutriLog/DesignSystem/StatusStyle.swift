import SwiftUI

// MARK: - Status presentation (web1 §0.5, web2 §3.4). Status is never shown by colour alone: always icon + text.

extension ScoreStatus {
    /// Badge text: good/ok `达标`, warn `偏离`, bad `不达标`, info `提示` (web `statusZh`).
    var label: String { switch self { case .good, .ok: "达标"; case .warn: "偏离"; case .bad: "不达标"; case .info: "提示" } }
    /// SF Symbol for the badge icon (CircleCheck / TriangleAlert / CircleX / Info).
    var symbol: String { switch self { case .good, .ok: "checkmark.circle"; case .warn: "exclamationmark.triangle"; case .bad: "xmark.circle"; case .info: "info.circle" } }
    /// Bar / ring fill (web `statusColor`): good, warning, critical; info → axis.
    var fill: Color { switch self { case .good, .ok: Theme.good; case .warn: Theme.warning; case .bad: Theme.critical; case .info: Theme.axis } }
    /// Badge foreground: the `…-text` colours; info → ink-2.
    var text: Color { switch self { case .good, .ok: Theme.goodText; case .warn: Theme.warningText; case .bad: Theme.criticalText; case .info: Theme.ink2 } }
    /// Badge background: the `…-soft` colours; info → surface-2.
    var soft: Color { switch self { case .good, .ok: Theme.goodSoft; case .warn: Theme.warningSoft; case .bad: Theme.criticalSoft; case .info: Theme.surface2 } }

    /// Statuses that read the same to a user (good ↔ ok) compare equal here (ImpactPreview "状态变化").
    func sameLabel(as other: ScoreStatus) -> Bool { label == other.label }
}

extension ScoreStatus {
    /// Common threshold helper: `v ≥ good` → good, `v ≥ warn` → warn, else bad.
    /// LE8 components use (80, 50), HEI total (80, 51), MAR (90, 70) (web1 §3.5, §4.3).
    static func threshold(_ v: Double, good: Double, warn: Double) -> ScoreStatus {
        v >= good ? .good : v >= warn ? .warn : .bad
    }

    /// HEI component / ratio status: `r ≥ 0.999` good, `≥ 0.6` warn, else bad (web1 §4.3 F, web2 §5.2.4).
    static func ratio(_ score: Double, max: Double) -> ScoreStatus {
        let r = max > 0 ? score / max : 0
        return r >= 0.999 ? .good : r >= 0.6 ? .warn : .bad
    }
}
