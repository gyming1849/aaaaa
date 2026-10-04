import SwiftUI

// MARK: - (1) Summary tiles (web2 §5.1.5 (1); web `SummaryTiles`), 2×2 on iPhone:
// `区间总分` · `日均摄入 / 消耗` · `趋势体重变化` · `按实际数据反推的日消耗`. Strings come from `TrendsBucketing.summaryTiles`.

struct TrendsSummaryTiles: View {
    let days: [TrendDay]
    let period: PeriodScore?

    var body: some View {
        let tiles = TrendsBucketing.summaryTiles(days: days, period: period)
        StatTileGrid {
            ForEach(tiles, id: \.label) { tile in
                StatTile(label: tile.label, value: tile.value, unit: tile.unit, delta: tile.delta)
            }
        }
    }
}
