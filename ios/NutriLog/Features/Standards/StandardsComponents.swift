import SwiftUI

// MARK: - Building blocks shared by the 标准库 tabs (web `.tabs`, `.table`, `.kv`, `.list`; web2 §3.3)

// MARK: Tab bar

/// Web `.tabs`: horizontal, scrollable, 14.5 pt weight 550 ink-3; the selected tab is ink with a 2 pt accent underline,
/// above a full-width hairline. The selected tab is scrolled into view (deep links to `评分规则` / `资料来源`).
struct StandardsTabBar: View {
    @Binding var selection: StandardsTab

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(StandardsTab.allCases, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, Theme.Metrics.pagePadding - 12)
            }
            .background(alignment: .bottom) {
                Rectangle().fill(Theme.hair).frame(height: 1)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, tab in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ tab: StandardsTab) -> some View {
        let on = tab == selection
        return Button {
            selection = tab
        } label: {
            Text(tab.title)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(on ? Theme.ink : Theme.ink3)
                .lineLimit(1)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(on ? Theme.accent : Color.clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(tab)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

// MARK: Tables

/// Table header cell (web `.table th`): 12.5 pt semibold ink-3, never wraps.
struct StandardsTableHead: View {
    let title: String
    let trailing: Bool

    init(_ title: String, trailing: Bool = false) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        Text(title)
            .font(Theme.Font.tableHead)
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(trailing ? .trailing : .leading)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-width 1 pt `hair` rule between table rows (inside a `Grid` it spans every column).
struct StandardsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hair)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
            .accessibilityHidden(true)
    }
}

/// Fixed-width table cell: never wraps; `trailing` for numeric columns (web `td.num`, tabular digits).
struct StandardsNumberCell: View {
    let text: String
    var font: Font = Theme.Font.meter
    var color: Color = Theme.ink1
    var trailing: Bool = true

    init(_ text: String, font: Font = Theme.Font.meter, color: Color = Theme.ink1, trailing: Bool = true) {
        self.text = text
        self.font = font
        self.color = color
        self.trailing = trailing
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(trailing ? .trailing : .leading)
    }
}

/// Primary cell of a row: the name (13.5 pt ink-1) with an optional small muted line under it (web `div.small.muted`).
struct StandardsNameCell: View {
    let name: String
    let detail: String?

    init(_ name: String, detail: String? = nil) {
        self.name = name
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Theme.Font.meter)
                .foregroundStyle(Theme.ink1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A `label  value` pair shown under a table row when the web's extra columns do not fit an iPhone
/// (label ink-3, value 13 pt in the given colour).
struct StandardsInlineField: View {
    let label: String
    let value: String
    var color: Color = Theme.ink1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.ink3)
                .fixedSize()
            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.Font.small)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Key/value list

/// Web `.kv`: a two-column grid (key column sized to the widest key), 6 × 16 pt gaps, 14 pt; keys ink-3, values ink-1.
struct StandardsKeyValueList: View {
    let items: [StandardsKeyValue]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(items) { item in
                GridRow(alignment: .firstTextBaseline) {
                    Text(item.key)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize()
                    Text(item.value)
                        .foregroundStyle(Theme.ink1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 14))
    }
}

// MARK: Rule table (评分规则: LE8 and WCRF/AICR)

/// The web's two-column rule table (bold label | small rule). On an iPhone the label sits above its rule so both stay
/// readable; rows are separated by hairlines.
struct StandardsRuleTable: View {
    let rows: [StandardsRuleRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink1)
                    Text(row.rule)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink1)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 {
                    Rectangle().fill(Theme.hair).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: Text helpers

enum StandardsText {
    /// `<b>{label}</b>{text}` (web hazard cards: `风险：`, `判定：`, `例：`, `建议：`).
    static func labeled(_ label: String, _ text: String) -> AttributedString {
        var bold = AttributedString(label)
        bold.inlinePresentationIntent = .stronglyEmphasized
        return bold + AttributedString(text)
    }

    /// `{lead}<b>{bold}</b>{tail}`.
    static func emphasized(_ lead: String, bold: String, _ tail: String) -> AttributedString {
        var middle = AttributedString(bold)
        middle.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString(lead) + middle + AttributedString(tail)
    }

    /// Numbers the web interpolates without `fmt` (HEI criteria, MET values, AMDR bounds, protein g/kg …).
    static func raw(_ v: Double) -> String { DSFormat.js(v) }
}

// MARK: States

/// Screen-level load failure (§A.10): warning banner with the server / network message and a 重试 button.
struct StandardsLoadErrorBanner: View {
    let message: String
    let retry: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry)
                .buttonStyle(.nl(.plain, size: .sm))
        }
        .nlBanner(.warn)
    }
}
