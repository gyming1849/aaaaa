import SwiftUI

// MARK: - Entry point (DESIGN §E.3.3)

@main struct NutriLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
                .task { await app.bootstrap() }
                .onChange(of: scenePhase) { _, p in if p == .active { Task { await app.onForeground() } } }
        }
    }
}
