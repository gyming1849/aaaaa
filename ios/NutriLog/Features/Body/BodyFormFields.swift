import SwiftUI
import UIKit

// MARK: - Small form building blocks shared by the Body screen and the ActivityRecognizer sheet (WP4).
// They mirror the web `.field` look of `NumberField` (label 13 pt ink-2 above a 40 pt bordered input).

/// `YYYY-MM-DD` ↔ `Date` in UTC, so a calendar-day string never shifts with the device time zone (web2 §1.4).
enum BodyDates {
    static let utc: TimeZone = TimeZone(identifier: "UTC") ?? .gmt

    static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    static func date(_ key: String) -> Date? { LocalDay.date(fromKey: key, in: utc) }
    static func key(_ date: Date) -> String { LocalDay.key(for: date, in: utc) }

    /// `HH:MM` → a `Date` on 2000-01-01 (UTC). Invalid input reads as 22:00 (the web's default weigh-in time).
    static func time(_ hhmm: String) -> Date {
        let valid = LocalDay.isValidTime(hhmm)
        let h = valid ? Int(hhmm.prefix(2)) ?? 22 : 22
        let m = valid ? Int(hhmm.suffix(2)) ?? 0 : 0
        return utcCalendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: h, minute: m)) ?? Date(timeIntervalSince1970: 0)
    }

    static func hhmm(_ date: Date) -> String { LocalDay.hhmm(date, in: utc) }

    /// `MM-DD` axis / list label of a `YYYY-MM-DD` date (web `date.slice(5)`).
    static func monthDay(_ key: String) -> String { key.count >= 10 ? String(key.dropFirst(5)) : key }
}

/// Field label (web `.field > label`): 13 pt, weight 550, ink-2.
struct BodyFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Input chrome identical to `NumberField`'s box: 40 pt tall, radius 10, 1 pt border on surface.
private struct BodyInputChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }
}

extension View {
    /// Wraps a control in the web `.input` box.
    func bodyInputChrome() -> some View { modifier(BodyInputChrome()) }

    /// Adds a `完成` button above the decimal keyboard (it has no return key).
    func bodyKeyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { BodyKeyboard.dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }
}

enum BodyKeyboard {
    /// Ends editing in whatever text field is first responder.
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// A `YYYY-MM-DD` date field: optional label above a compact date picker (max = `maxDate`, usually `app.today`).
struct BodyDateField: View {
    let label: String?
    @Binding var date: String
    let maxDate: String?
    let accessibilityName: String

    init(_ label: String?, date: Binding<String>, maxDate: String?, accessibilityName: String) {
        self.label = label
        self._date = date
        self.maxDate = maxDate
        self.accessibilityName = accessibilityName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { BodyFieldLabel(label) }
            picker
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Theme.accent)
                .environment(\.timeZone, BodyDates.utc)
                .environment(\.calendar, BodyDates.utcCalendar)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .accessibilityLabel(Text(accessibilityName))
        }
    }

    @ViewBuilder private var picker: some View {
        let selection = Binding<Date>(
            get: { BodyDates.date(date) ?? BodyDates.date(maxDate ?? "") ?? Date() },
            set: { newValue in
                var key = BodyDates.key(newValue)
                if let maxDate, LocalDay.isValid(maxDate), key > maxDate { key = maxDate }
                if key != date { date = key }
            }
        )
        if let maxDate, let upper = BodyDates.date(maxDate) {
            DatePicker(accessibilityName, selection: selection, in: ...upper, displayedComponents: .date)
        } else {
            DatePicker(accessibilityName, selection: selection, displayedComponents: .date)
        }
    }
}

/// An `HH:MM` (24 h) time field: label above a compact time picker.
struct BodyTimeField: View {
    let label: String
    @Binding var time: String

    init(_ label: String, time: Binding<String>) {
        self.label = label
        self._time = time
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BodyFieldLabel(label)
            DatePicker(label, selection: Binding(get: { BodyDates.time(time) }, set: { time = BodyDates.hhmm($0) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Theme.accent)
                .environment(\.timeZone, BodyDates.utc)
                .environment(\.calendar, BodyDates.utcCalendar)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(minHeight: 40, alignment: .leading)
        }
    }
}

/// Web `label.check`: a square checkbox followed by its text (13 pt). Used for the 0/1 flags on this screen.
struct BodyCheckboxStyle: ToggleStyle {
    var muted = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(configuration.isOn ? Theme.accent : Theme.ink3)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
                configuration.label
                    .font(Theme.Font.small)
                    .foregroundStyle(muted ? Theme.ink3 : Theme.ink1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : [.isToggle])
    }
}

extension ToggleStyle where Self == BodyCheckboxStyle {
    static var bodyCheckbox: BodyCheckboxStyle { BodyCheckboxStyle() }
    static var bodyCheckboxMuted: BodyCheckboxStyle { BodyCheckboxStyle(muted: true) }
}

/// One option of a `BodyMenuPicker`.
struct BodyPickerOption: Hashable, Sendable {
    let key: String
    let label: String
}

/// A web `<select>` look-alike: the current label in an input box with an up/down chevron, opening a menu with checkmarks.
struct BodyMenuPicker: View {
    let title: String
    @Binding var selection: String
    let options: [BodyPickerOption]

    init(_ title: String, selection: Binding<String>, options: [BodyPickerOption]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private var currentLabel: String { options.first { $0.key == selection }?.label ?? selection }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                if !options.contains(where: { $0.key == selection }) {
                    Text(verbatim: selection).tag(selection)
                }
                ForEach(options, id: \.key) { option in
                    Text(verbatim: option.label).tag(option.key)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: currentLabel)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bodyInputChrome()
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: currentLabel))
    }
}

/// Small red trash icon button (web `btn ghost sm icon danger`, aria `删除`).
struct BodyDeleteButton: View {
    let action: @MainActor () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(Theme.criticalText)
        }
        .buttonStyle(.nl(.ghost, size: .sm, iconOnly: true))
        .accessibilityLabel(Text("删除"))
    }
}

/// Section heading inside a card (web `h3`, 15 pt semibold).
struct BodySectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.h3)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Two equal flexible columns (the web's `.grid.g2` of fields on a phone).
enum BodyGrid {
    static let twoColumns = [GridItem(.flexible(), spacing: 12, alignment: .topLeading), GridItem(.flexible(), spacing: 12, alignment: .topLeading)]
}

private struct BodyFormFieldsPreview: View {
    @State private var date = "2026-09-30"
    @State private var time = "22:00"
    @State private var on = true
    var body: some View {
        Card {
            LazyVGrid(columns: BodyGrid.twoColumns, alignment: .leading, spacing: 12) {
                BodyDateField("化验日期", date: $date, maxDate: "2026-10-03", accessibilityName: "化验日期")
                BodyTimeField("时间", time: $time)
            }
            Toggle("正在服用降压药", isOn: $on).toggleStyle(.bodyCheckbox)
            Toggle("已含在设备活动能量中", isOn: $on).toggleStyle(.bodyCheckboxMuted)
            HStack { BodySectionTitle("运动"); Spacer(); BodyDeleteButton {} }
        }
    }
}

#Preview("Body form fields") {
    DSPreviewSchemes { BodyFormFieldsPreview() }
}
