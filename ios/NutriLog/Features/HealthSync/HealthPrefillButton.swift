import SwiftUI

// MARK: - 从苹果健康读取 (DESIGN §B.2, §D row 47). Owner: WP9. Embedded by Onboarding / ProfileForm (WP1).
// Asks for read access to sex, birth date, height and weight, reads them and hands the found values to the form.
// Hidden on devices without HealthKit.

struct ProfilePrefill: Sendable, Equatable { var sex: String?; var birth_date: String?; var height_cm: Double?; var weight_kg: Double? }

struct HealthPrefillButton: View {
    let onPrefill: @MainActor (ProfilePrefill) -> Void
    @Environment(AppState.self) private var app
    @State private var isReading = false

    init(onPrefill: @escaping @MainActor (ProfilePrefill) -> Void) { self.onPrefill = onPrefill }

    var body: some View {
        if HealthKitManager.isAvailable {
            Button {
                read()
            } label: {
                if isReading {
                    Spinner(size: 16)
                } else {
                    Image(systemName: "heart.text.square").foregroundStyle(Theme.critical)
                }
                Text("从“健康”App 读取")
            }
            .buttonStyle(.nl(.plain))
            .disabled(isReading)
            .accessibilityHint(Text("读取性别、出生日期、身高和体重"))
        }
    }

    private func read() {
        guard !isReading else { return }
        isReading = true
        let deliver = onPrefill
        Task {
            defer { isReading = false }
            do {
                let snap = try await HealthProfileReader.read()
                if snap.isEmpty {
                    app.toasts.show("“健康”App 中没有可用的性别、出生日期、身高或体重")
                    return
                }
                deliver(ProfilePrefill(sex: snap.sex, birth_date: snap.birthDate, height_cm: snap.heightCm, weight_kg: snap.weightKg))
                app.toasts.show("已从“健康”App 读取：\(snap.foundFields.joined(separator: "、"))")
            } catch {
                app.toasts.error(HealthKitManager.message(for: error))
            }
        }
    }
}

#Preview("从苹果健康读取") {
    HealthPrefillButton { _ in }
        .padding()
        .environment(AppState())
}
