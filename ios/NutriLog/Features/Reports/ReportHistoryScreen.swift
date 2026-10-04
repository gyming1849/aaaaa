import SwiftUI
import Observation

// MARK: - 历史报告 (iOS only; rep §8, DESIGN §D row 51)
// `GET /reports`: up to 60 stored reports, newest period first. A row shows the period kind, the range, the LE8 score
// at generation time and the AI headline. Tapping a row opens Reports at that range, which recomputes it live via
// `GET /period` (so the numbers there may differ from the stored LE8 score).

struct ReportHistoryScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = ReportHistoryModel()
    @State private var opened: ReportsRange?

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.gap) {
                Text("每周一自动生成上周报告，每月 1 日生成上月报告；在报告页生成的 AI 点评也会保存在这里。打开某一期时按最新数据重新计算。")
                    .font(Theme.Font.subtitle)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            .padding(Theme.Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.page)
        .navigationTitle("历史报告")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $opened) { r in
            ReportsScreen(start: r.start, end: r.end, kind: r.kind)
        }
        .refreshable { await model.load(app: app) }
        .task(id: app.dataVersion) { await model.load(app: app) }
    }

    @ViewBuilder private var content: some View {
        if let error = model.error {
            ReportsRetryBanner(message: error) {
                Task { await model.load(app: app) }
            }
        }
        if let items = model.items {
            if items.isEmpty {
                Card { EmptyState("还没有已生成的报告", icon: "doc.text") }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            let range = ReportsRange.detect(start: item.start_date, end: item.end_date)
                            Button {
                                opened = range
                            } label: {
                                ReportHistoryRow(item: item, range: range)
                            }
                            .buttonStyle(ReportHistoryRowStyle())
                            if i < items.count - 1 {
                                Rectangle().fill(Theme.hair).frame(height: 1).padding(.leading, 16)
                            }
                        }
                    }
                }
                .opacity(model.isLoading ? 0.55 : 1)
                .animation(.easeInOut(duration: 0.2), value: model.isLoading)
            }
        } else if model.error == nil {
            LoadingView()
        }
    }
}

// MARK: - Row

private struct ReportHistoryRow: View {
    let item: ReportListItem
    let range: ReportsRange

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Chip(range.kind.zh, style: range.kind == .week ? .accent : .plain)
                    Text(verbatim: range.label)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let headline = item.ai_summary?.headline, !headline.isEmpty {
                    Text(headline)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("暂无 AI 点评")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.ink3)
                }
                if let created = Timestamps.sqlite(item.created_at) {
                    Text(verbatim: "生成于 \(created.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))")
                        .font(Theme.Font.foot)
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(verbatim: fmt(item.score))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(item.score == nil ? Theme.ink3 : Theme.ink)
                Text(verbatim: "LE8")
                    .font(Theme.Font.foot)
                    .foregroundStyle(Theme.ink3)
            }
            .fixedSize()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Row highlight on press (surface-2), like a list cell.
private struct ReportHistoryRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : Color.clear)
    }
}

// MARK: - Model

@MainActor @Observable final class ReportHistoryModel {
    private(set) var items: [ReportListItem]?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var generation = 0

    func load(app: AppState) async {
        generation += 1
        let current = generation
        isLoading = true
        error = nil
        defer { if current == generation { isLoading = false } }
        do {
            let rows = try await app.api.reports()
            guard current == generation else { return }
            items = rows
        } catch {
            guard current == generation, !(error is CancellationError), !Task.isCancelled else { return }
            self.error = APIError.from(error).message
        }
    }
}
