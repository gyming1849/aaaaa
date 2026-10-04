import SwiftUI

// MARK: - (8) `风险物暴露汇总` (web2 §5.1.5 (8); web `HazardTable`), shown only when `period.hazards` is non-empty.
// Columns `项目` | `分级` (IarcChip) | `出现天数` | `累计量` (`{fmt(dose)} {unit}`); rows in server order (days desc).

struct TrendsHazardTable: View {
    let hazards: [PeriodHazard]

    var body: some View {
        Card {
            CardHeader("风险物暴露汇总", hint: "只作警示，不另设扣分")
                .headingLevel(.h3)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    head("项目").gridColumnAlignment(.leading)
                    head("分级").gridColumnAlignment(.leading)
                    head("出现天数").gridColumnAlignment(.trailing)
                    head("累计量").gridColumnAlignment(.trailing)
                }
                .padding(.vertical, 8)
                Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(hazards.enumerated()), id: \.element.id) { i, h in
                    if i > 0 { Rectangle().fill(Theme.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    GridRow(alignment: .center) {
                        Text(h.zh)
                            .foregroundStyle(Theme.ink1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IarcChip(h.iarc)
                        Text(verbatim: "\(h.days)")
                            .foregroundStyle(Theme.ink1)
                            .monospacedDigit()
                        Text(verbatim: "\(fmt(h.dose)) \(h.unit)")
                            .foregroundStyle(Theme.ink1)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(Theme.Font.meter)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func head(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.tableHead)
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .fixedSize()
    }
}
