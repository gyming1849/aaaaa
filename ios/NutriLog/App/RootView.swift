import SwiftUI

// MARK: - Root (DESIGN §B.3)

/// Switches on `app.phase`: loading, unreachable (重试 / 更换服务器), login, onboarding, main tabs.
/// Hosts the toast overlay and the theme override for the whole app.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching: LoadingView()
            case .unreachable(let msg): RootUnreachableView(message: msg)
            case .loggedOut: LoginScreen()
            case .onboarding: OnboardingScreen()
            case .ready: MainTabView()
            }
        }
        .animation(.default, value: app.phase)
        // Text follows Dynamic Type up to AX2; beyond that the dense tables, charts and 2×2 tiles stop fitting.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .toastOverlay(app.toasts)
        .preferredColorScheme(app.themePreference.colorScheme)
    }
}

/// `/auth/me` failed for a reason other than 401 (network, 5xx): offer 重试 and 更换服务器 (§B.3).
/// Retries keep this screen up (spinner on 重试). Returning to the foreground retries too, unless the 更换服务器 sheet is
/// open (the typed address must survive a trip to another app).
private struct RootUnreachableView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    let message: String
    @State private var showServerSheet = false
    @State private var retrying = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
            Text("无法连接服务器")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
            Text(verbatim: "服务器：\(ServerConfig.displayName(app.serverURL))")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
            Button {
                retry()
            } label: {
                if retrying { ProgressView() } else { Text("重试").frame(minWidth: 120) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)
            Button("更换服务器") { showServerSheet = true }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
        .sheet(isPresented: $showServerSheet) { ServerAddressSheet().toastOverlay(app.toasts) }
        .onChange(of: scenePhase) { _, p in
            if p == .active, !showServerSheet, !retrying { retry() }
        }
    }

    private func retry() {
        retrying = true
        Task {
            await app.bootstrap(showLaunching: false)
            retrying = false
        }
    }
}
