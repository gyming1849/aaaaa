import SwiftUI
import UIKit

// MARK: - Colour tokens (web1 §0.4, web2 §3.2; values copied from web `styles.css`)
// Every token is a dynamic colour that resolves against the current trait collection / SwiftUI colour scheme,
// so `.preferredColorScheme` (Settings → 外观) and `.environment(\.colorScheme, …)` both work.

enum Theme {
    /// Dynamic colour from two `0xRRGGBB` values.
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }

    /// Dynamic colour with per-scheme alpha (used for `border` and the card shadow).
    static func dyn(_ light: UInt32, alpha lightAlpha: CGFloat, _ dark: UInt32, alpha darkAlpha: CGFloat) -> Color {
        Color(UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(rgb: dark, alpha: darkAlpha) : UIColor(rgb: light, alpha: lightAlpha)
        })
    }

    // Surfaces and ink
    static let page = dyn(0xf6f5f1, 0x0f0f0e)
    static let surface = dyn(0xfcfcfb, 0x1a1a19)
    static let surface2 = dyn(0xf1f0ec, 0x232321)
    static let surface3 = dyn(0xe9e8e2, 0x2c2c2a)
    static let ink = dyn(0x0b0b0b, 0xffffff)
    static let ink1 = dyn(0x262624, 0xecebe6)
    static let ink2 = dyn(0x52514e, 0xc3c2b7)
    static let ink3 = dyn(0x898781, 0x898781)
    static let hair = dyn(0xe1e0d9, 0x2c2c2a)
    static let axis = dyn(0xc3c2b7, 0x383835)
    /// `rgba(11,11,11,.10)` / `rgba(255,255,255,.10)`.
    static let border = dyn(0x0b0b0b, alpha: 0.10, 0xffffff, alpha: 0.10)

    // Accent
    static let accent = dyn(0x1f6f50, 0x3a9c73)
    static let accentHover = dyn(0x185a41, 0x46ad83)
    static let accentInk = dyn(0xffffff, 0xffffff)
    static let accentSoft = dyn(0xe2eee7, 0x1b3128)
    static let accentText = dyn(0x1a5e44, 0x6cc79f)

    // Status fills (identical in both schemes) and their text / soft variants
    static let good = dyn(0x0ca30c, 0x0ca30c)
    static let warning = dyn(0xfab219, 0xfab219)
    static let serious = dyn(0xec835a, 0xec835a)
    static let critical = dyn(0xd03b3b, 0xd03b3b)
    static let goodText = dyn(0x006300, 0x3fc23f)
    static let warningText = dyn(0x7a5200, 0xfab219)
    static let seriousText = dyn(0x9c4320, 0xef9670)
    static let criticalText = dyn(0xb02e2e, 0xea6b6b)
    static let goodSoft = dyn(0xe6f4e4, 0x17301a)
    static let warningSoft = dyn(0xfdf1d6, 0x342a12)
    static let seriousSoft = dyn(0xfbe8df, 0x3a2419)
    static let criticalSoft = dyn(0xf9e2e0, 0x3a1c1c)

    // Chart series (fixed order: s1 blue, s2 orange, s3 green, s4 amber, s5 pink)
    static let s1 = dyn(0x2a78d6, 0x3987e5)
    static let s2 = dyn(0xeb6834, 0xd95926)
    static let s3 = dyn(0x1baf7a, 0x199e70)
    static let s4 = dyn(0xeda100, 0xc98500)
    static let s5 = dyn(0xe87ba4, 0xd55181)

    /// Card shadow, layer 1: `0 1px 2px rgba(20,20,10,.04)` light, `0 1px 2px rgba(0,0,0,.4)` dark.
    static let shadow1 = dyn(0x14140a, alpha: 0.04, 0x000000, alpha: 0.40)
    /// Card shadow, layer 2: `0 4px 16px rgba(20,20,10,.04)` light; none in dark.
    static let shadow2 = dyn(0x14140a, alpha: 0.04, 0x000000, alpha: 0)
    /// Large shadow (`--shadow-lg`) used by toasts, tooltips and the floating action button.
    static let shadowLarge = dyn(0x14140a, alpha: 0.16, 0x000000, alpha: 0.60)

    /// Sequential palette for the calendar heatmap (web2 §3.2). Light runs light → dark; the dark list is the light list reversed.
    static let seqLight: [UInt32] = [0xcde2fb, 0x9ec5f4, 0x6da7ec, 0x3987e5, 0x256abf, 0x184f95, 0x0d366b]

    /// Step `0…6` of the sequential palette (clamped). `seq(6)` is the darkest blue in light mode and the lightest in dark mode.
    static func seq(_ step: Int) -> Color {
        let i = min(max(step, 0), seqLight.count - 1)
        return dyn(seqLight[i], seqLight[seqLight.count - 1 - i])
    }

    /// The five chart series in order (`series(0)` = `s1`).
    static func series(_ index: Int) -> Color {
        let all = [s1, s2, s3, s4, s5]
        return all[((index % all.count) + all.count) % all.count]
    }
}

// MARK: - Typography (web1 §0.4, web2 §3.3). Web weights map as 500/550 → .medium, 600/650 → .semibold, 700 → .bold.

extension Theme {
    /// Every token follows Dynamic Type: it is the text style nearest to the web size (sizes below are at the default
    /// "Large" setting; the web value is in brackets where it differs). Only the score-ring numbers stay fixed, because
    /// they sit inside a ring of fixed diameter.
    enum Font {
        /// title2 semibold, 22 [24].
        static let h1 = SwiftUI.Font.system(.title2, weight: .semibold)
        /// headline, 17 semibold [18].
        static let h2 = SwiftUI.Font.system(.headline)
        /// subheadline semibold, 15.
        static let h3 = SwiftUI.Font.system(.subheadline, weight: .semibold)
        /// subheadline, 15.
        static let body = SwiftUI.Font.system(.subheadline)
        /// footnote, 13.
        static let small = SwiftUI.Font.system(.footnote)
        /// title semibold, 28 [26].
        static let statValue = SwiftUI.Font.system(.title, weight: .semibold)
        static let ringBig = SwiftUI.Font.system(size: 48, weight: .bold)
        static let ringSmall = SwiftUI.Font.system(size: 32, weight: .bold)

        // Additional sizes used by the components
        /// Card-head hint, chip and badge text: caption, 12 [12.5].
        static let hint = SwiftUI.Font.system(.caption)
        /// Meter foot and toast-free fine print: caption, 12.
        static let foot = SwiftUI.Font.system(.caption)
        /// Meter name: footnote medium, 13 [13.5, 550].
        static let meterName = SwiftUI.Font.system(.footnote, weight: .medium)
        /// Meter value, table body, banner and segmented-control text: footnote, 13 [13.5].
        static let meter = SwiftUI.Font.system(.footnote)
        static let tableHead = SwiftUI.Font.system(.caption, weight: .semibold)
        static let badge = SwiftUI.Font.system(.caption, weight: .semibold)
        static let chip = SwiftUI.Font.system(.caption)
        static let segment = SwiftUI.Font.system(.footnote, weight: .medium)
        /// Stat-tile unit suffix: subheadline medium, 15 [14, 500].
        static let statUnit = SwiftUI.Font.system(.subheadline, weight: .medium)
        static let label = SwiftUI.Font.system(.footnote, weight: .medium)
        /// subheadline medium, 15 [14].
        static let button = SwiftUI.Font.system(.subheadline, weight: .medium)
        static let buttonSmall = SwiftUI.Font.system(.footnote, weight: .medium)
        static let buttonLarge = SwiftUI.Font.system(.subheadline, weight: .medium)
        /// subheadline, 15 [14].
        static let toast = SwiftUI.Font.system(.subheadline)
        /// Chart axis labels and the y-axis unit title: caption2, 11.
        static let axis = SwiftUI.Font.system(.caption2)
        /// Chart legend labels: caption, 12.
        static let legend = SwiftUI.Font.system(.caption)
        /// Page subtitle (ink-3): subheadline, 15 [14].
        static let subtitle = SwiftUI.Font.system(.subheadline)
    }

    /// Layout metrics (web2 §3.3).
    enum Metrics {
        static let cardRadius: CGFloat = 14
        static let cardPadding: CGFloat = 16
        static let smallRadius: CGFloat = 10
        static let chipRadius: CGFloat = 99
        static let bannerRadius: CGFloat = 12
        /// Horizontal page gutter on iPhone.
        static let pagePadding: CGFloat = 16
        /// Gap between cards (`.grid` / `.stack`).
        static let gap: CGFloat = 16
        /// Gap between 2×2 stat tiles on phones (`g4` below 480 px).
        static let tileGap: CGFloat = 10
        static let chartHeight: CGFloat = 260
        static let chartTableMaxHeight: CGFloat = 300
    }
}

// MARK: - Theme preference (Settings → 外观; stored by AppState under UserDefaults `nl.theme`)

enum ThemePreference: String, CaseIterable, Sendable {
    case system, light, dark
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    /// SF Symbols for the web's Monitor / Sun / Moon icons (web2 Appendix E).
    var symbol: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
    /// UserDefaults key (DESIGN §A.9).
    static let defaultsKey = "nl.theme"
}

// MARK: - Colour helpers

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}

extension Color {
    /// `#rrggbb`, `rrggbb`, `#rgb` or `#rrggbbaa` (e.g. `User.avatar_color`). Anything unparsable gives the `ink-3` grey.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let raw = UInt64(s, radix: 16) else {
            self = Color(UIColor(rgb: 0x898781))
            return
        }
        if s.count == 8 {
            self = Color(UIColor(rgb: UInt32((raw >> 8) & 0xffffff), alpha: CGFloat(raw & 0xff) / 255))
        } else {
            self = Color(UIColor(rgb: UInt32(raw)))
        }
    }
}

// MARK: - Text helpers shared by the design system

enum DSFormat {
    /// JavaScript `String(number)` for the small values the web interpolates without `fmt` (e.g. `/ ${wcrf.max}`,
    /// `${c.points}`): integers without a decimal point, otherwise the shortest round-trip form (`0.5`, `72.5`).
    static func js(_ v: Double?) -> String {
        guard let v else { return "null" }
        guard v.isFinite else { return v.isNaN ? "NaN" : (v > 0 ? "Infinity" : "-Infinity") }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// `"{fmt(v, d)} {unit}"` without a trailing space when the unit is empty; `—` for nil.
    static func value(_ v: Double?, _ d: Int, unit: String) -> String {
        guard let v, v.isFinite else { return "—" }
        return unit.isEmpty ? fmt(v, d) : "\(fmt(v, d)) \(unit)"
    }
}
