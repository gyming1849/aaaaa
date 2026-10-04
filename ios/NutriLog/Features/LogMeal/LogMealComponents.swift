import SwiftUI
import UIKit

// MARK: - Small building blocks shared by the Log Meal screens (web `.field`, `.input`, `.input-affix`, `.macro-line`)

/// Web `.input` (40 pt, 15 pt text, radius 10, padding 12) and `.input.sm` (32 pt, 14 pt, radius 8, padding 9).
enum LogMealInputSize: Sendable {
    case md, sm
    var height: CGFloat { self == .md ? 40 : 32 }
    var font: Font { self == .md ? Theme.Font.body : .system(size: 14) }
    var radius: CGFloat { self == .md ? Theme.Metrics.smallRadius : 8 }
    var padding: CGFloat { self == .md ? 12 : 9 }
}

private struct LogMealInputChrome: ViewModifier {
    let size: LogMealInputSize
    let focused: Bool
    /// `nil` = fixed height (single-line inputs); multi-line inputs pass their own vertical padding.
    let verticalPadding: CGFloat?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        content
            .font(size.font)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, size.padding)
            .padding(.vertical, verticalPadding ?? 0)
            .frame(minHeight: size.height)
            .background(Theme.surface, in: shape)
            .overlay { shape.strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: 1) }
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: size.radius + 3, style: .continuous)
                        .stroke(Theme.accentSoft, lineWidth: 3)
                        .padding(-1.5)
                }
            }
    }
}

extension View {
    /// Web `.input` chrome: surface fill, 1 pt border, accent border plus a soft ring while focused.
    func logMealInputChrome(_ size: LogMealInputSize = .md, focused: Bool = false, verticalPadding: CGFloat? = nil) -> some View {
        modifier(LogMealInputChrome(size: size, focused: focused, verticalPadding: verticalPadding))
    }
}

/// Web `.field > label`: 13 pt, ink-2, weight 550, 6 pt above the control.
struct LogMealField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.Font.label)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Single-line text input in web `.input` chrome.
struct LogMealTextInput: View {
    let label: String
    @Binding var text: String
    var prompt: String?
    var size: LogMealInputSize = .md
    var weight: Font.Weight = .regular
    @FocusState private var focused: Bool

    init(_ label: String, text: Binding<String>, prompt: String? = nil, size: LogMealInputSize = .md, weight: Font.Weight = .regular) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.size = size
        self.weight = weight
    }

    var body: some View {
        TextField(label, text: $text, prompt: prompt.map { Text($0).foregroundStyle(Theme.ink3) })
            .fontWeight(weight)
            .focused($focused)
            .logMealInputChrome(size, focused: focused)
    }
}

/// Decimal input with a unit affix (web `<input type="number">` + `.affix`).
///
/// The text belongs to the user while the field is focused: every edit reports the parsed value (`nil` when blank or not
/// a number) through `onEdit`, and the caller decides whether to apply it (the web ignores grams ≤ 0, nutrients clamp
/// to ≥ 0). The text is re-synced from `value` (rounded to `decimals`, the web's display rounding) when the field loses
/// focus, and while focused only when `value` changed to something the text does not already say (a chip tap).
/// Programmatic re-syncs never call `onEdit`, so displaying a rounded value can never edit the item.
struct LogMealDecimalField: View {
    let value: Double?
    let decimals: Int
    let unit: String?
    let accessibilityLabel: String
    var size: LogMealInputSize
    var prompt: String?
    var autoFocus: Bool
    let onEdit: @MainActor (Double?) -> Void

    @State private var text: String
    @State private var programmaticText: String?
    @FocusState private var focused: Bool

    init(value: Double?, decimals: Int, unit: String?, accessibilityLabel: String, size: LogMealInputSize = .sm,
         prompt: String? = nil, autoFocus: Bool = false, onEdit: @escaping @MainActor (Double?) -> Void) {
        self.value = value
        self.decimals = decimals
        self.unit = unit
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.prompt = prompt
        self.autoFocus = autoFocus
        self.onEdit = onEdit
        self._text = State(initialValue: Self.display(value, decimals))
    }

    /// Web `Math.round(v × 10^d) / 10^d`, written without grouping and without trailing zeros.
    static func display(_ v: Double?, _ decimals: Int) -> String {
        guard let v, v.isFinite else { return "" }
        let p = pow(10, Double(max(0, min(decimals, 6))))
        let r = (v * p).rounded(.toNearestOrAwayFromZero) / p
        return NumberField.format(r.isFinite ? r : v)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(accessibilityLabel, text: $text, prompt: prompt.map { Text($0).foregroundStyle(Theme.ink3) })
                .keyboardType(.decimalPad)
                .monospacedDigit()
                .focused($focused)
                .accessibilityLabel(Text(accessibilityLabel))
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.system(size: size == .md ? 13 : 11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
        .logMealInputChrome(size, focused: focused)
        .onChange(of: text) { _, newText in
            if let p = programmaticText, p == newText {
                programmaticText = nil
                return
            }
            programmaticText = nil
            onEdit(NumberField.parse(newText))
        }
        .onChange(of: value) { _, _ in sync(force: false) }
        .onChange(of: focused) { _, isFocused in if !isFocused { sync(force: true) } }
        .task {
            guard autoFocus else { return }
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }

    private func sync(force: Bool) {
        if !force, focused {
            // Blank / unparsable text stays while typing; matching text is left untouched.
            guard let parsed = NumberField.parse(text), parsed != value else { return }
        }
        let s = Self.display(value, decimals)
        guard s != text else { return }
        programmaticText = s
        text = s
    }
}

/// Web `.macro-line`: wrapping row of `label <b>value</b>unit` parts, 12 pt apart; ink-2 text with bold ink-1 numbers.
struct LogMealMacroLine: View {
    struct Part: Hashable {
        let prefix: String
        let value: String
        let suffix: String
        init(_ prefix: String, _ value: String, _ suffix: String) {
            self.prefix = prefix
            self.value = value
            self.suffix = suffix
        }
    }

    let parts: [Part]
    var fontSize: CGFloat = 12.5

    init(_ parts: [Part], fontSize: CGFloat = 12.5) {
        self.parts = parts
        self.fontSize = fontSize
    }

    var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(attributed(part))
                    .font(.system(size: fontSize))
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func attributed(_ part: Part) -> AttributedString {
        var value = AttributedString(part.value)
        value.font = .system(size: fontSize, weight: .semibold)
        value.foregroundColor = Theme.ink1
        return AttributedString(part.prefix) + value + AttributedString(part.suffix)
    }
}

/// Bullet list (web `<ul>`), used for AI questions and assumptions.
struct LogMealBulletList: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Keyboard accessory `完成` button: the decimal pad has no return key.
struct LogMealKeyboardDone: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完成") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .fontWeight(.semibold)
        }
    }
}
