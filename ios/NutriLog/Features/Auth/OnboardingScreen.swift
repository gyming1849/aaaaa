import SwiftUI

// MARK: - Onboarding 建档 (web `pages/Onboarding.tsx`; web2 §5.7, DESIGN §D row 3)
// Shown while `me.profile == nil`. Saving the profile (`开始记录`) moves the app to the main tabs (`app.didSaveProfile`).

struct OnboardingScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = ProfileFormModel(initial: nil)
    @State private var confirmLogout = false

    init() {}

    var body: some View {
        NavigationStack {
            ProfileScrollPage {
                header
                healthPrefill
                Card {
                    ProfileFormView(model: model, submitText: "开始记录")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出登录") { confirmLogout = true }
                        .foregroundStyle(Theme.ink2)
                }
            }
            .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { Task { await app.logout() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("尚未保存的档案内容不会保留。")
            }
            .task { await app.ensureMeta() }
        }
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileBrandMark()
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "你好，\(app.user?.display_name ?? "")！先建立个人档案")
                    .font(Theme.Font.h1)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("身高、体重、年龄和性别决定你的营养目标（DRI 分人群）、能量需求（NASEM 2023 方程）和按体重计算的限量（如蛋白质、咖啡因、阿斯巴甜 ADI）。")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Optional prefill of sex, birth date, height and weight from Apple Health (WP9 `HealthPrefillButton`, which hides
    /// itself on devices without HealthKit).
    private var healthPrefill: some View {
        HStack(spacing: 0) {
            HealthPrefillButton { prefill in model.apply(prefill) }
            Spacer(minLength: 0)
        }
    }
}
