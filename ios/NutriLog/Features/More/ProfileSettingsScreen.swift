import SwiftUI

// MARK: - 个人档案 (web `pages/Settings.tsx` card `个人档案`; web2 §5.5–§5.6)
// ProfileForm with `initial = me.profile`: weight label `建档体重` + help text, submit `保存`.

struct ProfileSettingsScreen: View {
    @Environment(AppState.self) private var app

    init() {}

    var body: some View {
        Group {
            if let profile = app.profile {
                ProfileSettingsContent(profile: profile)
            } else {
                ProfileScrollPage {
                    Card { EmptyState("还没有个人档案", icon: "person.text.rectangle") }
                }
            }
        }
        .navigationTitle("个人档案")
        .navigationBarTitleDisplayMode(.inline)
        .task { await app.ensureMeta() }
    }
}

private struct ProfileSettingsContent: View {
    @State private var model: ProfileFormModel

    init(profile: Profile) {
        _model = State(initialValue: ProfileFormModel(initial: profile))
    }

    var body: some View {
        ProfileScrollPage {
            Banner("修改后所有历史评分会按新档案重新计算", icon: "info.circle")
            Card {
                ProfileFormView(model: model, submitText: "保存")
            }
        }
    }
}
