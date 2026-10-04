import SwiftUI

// MARK: - DateNav (web1 §3.3): one bordered pill `[<] label [>]`.
// `<` (前一天) moves −1 day with no lower bound; `>` (后一天) moves +1 day and is disabled when date ≥ today.
// The label is `dateLabel(date, today)`, semibold 14 pt, ≥128 pt wide; tapping it opens a date picker with max = today.
// Dates are `YYYY-MM-DD` calendar days, so the picker works in UTC (no device time zone involved).

struct DateNav: View {
    @Binding var date: String
    let today: String
    @State private var picking = false

    init(date: Binding<String>, today: String) {
        self._date = date
        self.today = today
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.utc
        return c
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                date = LocalDay.addDays(date, -1)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
            .accessibilityLabel(Text("前一天"))

            Button {
                picking = true
            } label: {
                Text(LocalDay.dateLabel(date, today: today))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 128, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $picking) {
                picker
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                date = LocalDay.addDays(date, 1)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
            .disabled(date >= today)
            .accessibilityLabel(Text("后一天"))
        }
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
        .fixedSize()
    }

    private var picker: some View {
        let maxDate = LocalDay.date(fromKey: today, in: Self.utc) ?? Date()
        let selection = Binding<Date>(
            get: { LocalDay.date(fromKey: date, in: Self.utc) ?? maxDate },
            set: { newValue in
                let key = LocalDay.key(for: newValue, in: Self.utc)
                if key <= today, key != date { date = key }
                picking = false
            }
        )
        return DatePicker("", selection: selection, in: ...maxDate, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Theme.accent)
            .environment(\.timeZone, Self.utc)
            .environment(\.calendar, utcCalendar)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 320)
            .padding(12)
    }
}

private struct DateNavPreview: View {
    @State private var date = "2026-09-30"
    var body: some View {
        DateNav(date: $date, today: "2026-09-30")
        Text(verbatim: date).font(Theme.Font.small).foregroundStyle(Theme.ink3)
    }
}

#Preview("DateNav") {
    DSPreviewSchemes { DateNavPreview() }
}
