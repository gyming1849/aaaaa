import SwiftUI

// MARK: - 苹果健康同步 row (replaces the web "连接苹果健康" card, web1 §7.2 Row 4; DESIGN §B.5, §D row 30)
// Shows `app.healthSync.status` and pushes `.healthSync` (WP9's HealthSyncScreen) on the Body tab's stack.

struct BodyHealthSyncRow: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let status = app.healthSync.status
        Button {
            app.router.push(.healthSync)
        } label: {
            Card {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.s5)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.isEnabled ? "Apple 健康同步" : "连接 Apple 健康")
                            .font(Theme.Font.h3)
                            .foregroundStyle(Theme.ink)
                        ForEach(Array(lines(status).enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line.text)
                                .font(Theme.Font.small)
                                .foregroundStyle(line.isWarning ? Theme.warningText : Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if status.isSyncing { Spinner() }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BodyPressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private struct Line { let text: String; let isWarning: Bool }

    private func lines(_ s: HealthSyncStatus) -> [Line] {
        if !s.serverSupportsSync { return [Line(text: HealthSyncText.serverNeedsUpgrade, isWarning: true)] }
        guard s.isEnabled else { return [] }
        var out: [Line] = []
        if let at = s.lastSyncAt {
            out.append(Line(text: "上次同步 \(Self.syncTime(at))", isWarning: false))
        }
        if let summary = s.lastSummary, !summary.isEmpty { out.append(Line(text: summary, isWarning: false)) }
        if let error = s.lastError, !error.isEmpty { out.append(Line(text: error, isWarning: true)) }
        return out
    }

    /// `10月3日 14:05` in the device's time zone (when the sync ran, not a calendar-day key).
    static func syncTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(Locale(identifier: "zh_CN")))
    }
}

/// Dims the row while pressed (list-row feedback without a List).
private struct BodyPressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
