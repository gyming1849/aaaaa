import SwiftUI

// MARK: - NumberField (web `.field` + `.input-affix`): label 13 pt ink-2 (weight 550) above a 40 pt input
// (radius 10, 1 pt border, surface, 15 pt) with a unit affix (13 pt ink-3). Decimal keyboard. No placeholder unless
// `prompt` is given (the label is the field's accessibility label).
// Empty text ↔ `nil` (the web's "empty means null"); the text the user types is kept as typed.

struct NumberField: View {
    let label: String
    @Binding var value: Double?
    let unit: String?
    let prompt: String?
    @State private var text: String
    @FocusState private var focused: Bool

    init(_ label: String, value: Binding<Double?>, unit: String? = nil, prompt: String? = nil) {
        self.label = label
        self._value = value
        self.unit = unit
        self.prompt = prompt
        self._text = State(initialValue: Self.format(value.wrappedValue))
    }

    /// Display form of a value: no grouping, up to 4 decimals, trailing zeros dropped (`70`, `70.2`).
    static func format(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return v.formatted(.number.grouping(.never).precision(.fractionLength(0...4)).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// Parses user input; accepts `,` / `，` / `。` as the decimal separator. Blank or invalid → nil.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.ink2)
            }
            HStack(spacing: 6) {
                // Always an explicit prompt: with `nil`, SwiftUI shows the title as the placeholder, repeating the label
                // above inside the box (truncated in two-column grids). The web inputs have no placeholder.
                TextField(label, text: $text, prompt: Text(verbatim: prompt ?? "").foregroundStyle(Theme.ink3))
                    .keyboardType(.decimalPad)
                    .font(Theme.Font.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.border, lineWidth: 1)
            }
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius + 3, style: .continuous)
                        .stroke(Theme.accentSoft, lineWidth: 3)
                        .padding(-1.5)
                }
            }
            .accessibilityValue(Text(verbatim: unit.map { "\(text) \($0)" } ?? text))
        }
        .onChange(of: text) { _, newText in
            let parsed = Self.parse(newText)
            if parsed != value { value = parsed }
        }
        .onChange(of: value) { _, newValue in
            if Self.parse(text) != newValue { text = Self.format(newValue) }
        }
    }
}

private struct NumberFieldPreview: View {
    @State private var weight: Double? = 70.2
    @State private var steps: Double?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NumberField("体重", value: $weight, unit: "kg")
            NumberField("步数", value: $steps, unit: "步", prompt: "—")
        }
        Text(verbatim: "weight = \(DSFormat.js(weight)), steps = \(DSFormat.js(steps))").font(Theme.Font.small).foregroundStyle(Theme.ink3)
    }
}

#Preview("NumberField") {
    DSPreviewSchemes { NumberFieldPreview() }
}
