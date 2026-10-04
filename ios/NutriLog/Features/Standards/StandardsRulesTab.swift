import SwiftUI

// MARK: - Tab `rules` 评分规则 (web2 §5.10, rep §9.9). Static text from `StandardsRulesText`; only `heiUsMean` and the
// MAR nutrient names come from `meta`.

struct StandardsRulesTab: View {
    let meta: Meta

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
            banner
            dailyCard
            le8Card
            wcrfCard
            energyCard
        }
    }

    // Accent banner, 14.5 pt, two lines (`<br />`).
    private var banner: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(StandardsRulesText.bannerLine1)
            Text(StandardsRulesText.bannerLine2)
        }
        .font(.system(size: 14.5))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .nlBanner(.accent)
        .accessibilityElement(children: .combine)
    }

    private var dailyCard: some View {
        Card {
            title(StandardsRulesText.dailyTitle)
            StandardsKeyValueList(items: StandardsRulesText.dailyItems(heiUsMean: StandardsText.raw(meta.heiUsMean),
                                                                       marNutrientNames: marNames))
        }
    }

    /// `meta.marNutrients` → nutrient `zh`, joined with `、` (an unknown key contributes an empty string, like the web).
    private var marNames: String {
        meta.marNutrients.map { key in meta.nutrients.first { $0.key == key }?.zh ?? "" }.joined(separator: "、")
    }

    private var le8Card: some View {
        Card {
            title(StandardsRulesText.le8Title)
            paragraph(StandardsText.emphasized(StandardsRulesText.le8IntroLead, bold: StandardsRulesText.le8IntroBold,
                                               StandardsRulesText.le8IntroTail))
            StandardsRuleTable(rows: StandardsRulesText.le8Table)
        }
    }

    private var wcrfCard: some View {
        Card {
            title(StandardsRulesText.wcrfTitle)
            paragraph(AttributedString(StandardsRulesText.wcrfIntro))
            StandardsRuleTable(rows: StandardsRulesText.wcrfTable)
        }
    }

    private var energyCard: some View {
        Card {
            title(StandardsRulesText.energyTitle)
            paragraph(AttributedString(StandardsRulesText.energyText))
        }
    }

    // h2 (18 pt) card title.
    private func title(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.h2)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    // `p.sec`: body text in ink-2.
    private func paragraph(_ text: AttributedString) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
