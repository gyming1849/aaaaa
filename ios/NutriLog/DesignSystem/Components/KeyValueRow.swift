import SwiftUI

// MARK: - KeyValueRow (web `.kv`): key in ink-3, value in ink-1, 14 pt. On iPhone the value is trailing-aligned
// and may wrap; numbers use tabular digits.

struct KeyValueRow: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(Theme.ink1)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 14))
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

#Preview("KeyValueRow") {
    DSPreviewSchemes {
        Card {
            VStack(spacing: 6) {
                KeyValueRow("日均摄入", "2,045 kcal")
                KeyValueRow("日均消耗", "2,318 kcal")
                KeyValueRow("累计能量差", "-1,911 kcal（≈ -0.25 kg）")
                KeyValueRow("趋势体重变化", "称重数据不足")
                KeyValueRow("钙 / 钾 / 维生素 D", "612 mg / 2,140 mg / 3.2 µg")
            }
        }
    }
}
