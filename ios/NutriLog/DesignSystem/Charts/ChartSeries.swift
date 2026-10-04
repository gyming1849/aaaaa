import SwiftUI

// MARK: - Null-gap series (web2 §4 `connectNulls: false`)
// Swift Charts connects every point of one series. To leave gaps where a value is `null`, split the data into contiguous
// runs and give each run its own series identity (`seriesKey` = "\(series)-\(segment)") with the same colour:
//
//     ForEach(points) { p in
//         LineMark(x: .value("x", p.index), y: .value("y", p.value), series: .value("s", p.seriesKey))
//             .foregroundStyle(Theme.s1)
//     }

struct ChartPoint: Identifiable, Hashable {
    let index: Int
    let label: String
    let value: Double
    let series: String
    let segment: Int
    var id: String { "\(series)-\(segment)-\(index)" }
    /// Series identity for `LineMark(series:)`: one per contiguous run.
    var seriesKey: String { "\(series)-\(segment)" }
}

enum ChartSeries {
    /// Web `lineSeries`: point symbols are shown only when a series has ≤ 45 points.
    static let maxPointsWithSymbols = 45

    /// Splits `values` at `nil` (and non-finite) entries into numbered contiguous segments.
    /// `label[i]` is the x label of `values[i]` (missing labels become "").
    static func segments(label: [String], values: [Double?], series: String) -> [ChartPoint] {
        var out: [ChartPoint] = []
        out.reserveCapacity(values.count)
        var segment = 0
        var inRun = false
        for (i, value) in values.enumerated() {
            if let v = value, v.isFinite {
                out.append(ChartPoint(index: i, label: i < label.count ? label[i] : "", value: v, series: series, segment: segment))
                inRun = true
            } else if inRun {
                segment += 1
                inRun = false
            }
        }
        return out
    }

    /// Continuous series (`connectNulls: true`, e.g. the weight trend): nil values are skipped, one segment.
    static func continuous(label: [String], values: [Double?], series: String) -> [ChartPoint] {
        values.enumerated().compactMap { i, value in
            guard let v = value, v.isFinite else { return nil }
            return ChartPoint(index: i, label: i < label.count ? label[i] : "", value: v, series: series, segment: 0)
        }
    }

    /// Whether point symbols are drawn for a series of `count` buckets.
    static func showsSymbols(count: Int) -> Bool { count <= maxPointsWithSymbols }

    /// Points that form a one-point segment: a `LineMark` alone draws nothing for them, so add a `PointMark`
    /// when symbols are hidden (ECharts also hides them then; this keeps isolated values visible).
    static func isolated(_ points: [ChartPoint]) -> [ChartPoint] {
        var counts: [String: Int] = [:]
        for p in points { counts[p.seriesKey, default: 0] += 1 }
        return points.filter { counts[$0.seriesKey] == 1 }
    }

    /// Y-axis domain helper used by the weight chart: `floor(min − 1)…ceil(max + 1)`.
    static func paddedDomain(_ values: [Double?], pad: Double = 1) -> ClosedRange<Double>? {
        let v = values.compactMap { $0 }.filter(\.isFinite)
        guard let lo = v.min(), let hi = v.max() else { return nil }
        return (lo - pad).rounded(.down)...(hi + pad).rounded(.up)
    }
}
