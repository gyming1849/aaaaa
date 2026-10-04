import SwiftUI
import Observation

// MARK: - Standards view model (web2 §5.10 "Data"; rep §9)
// `mine` → `GET /profile/targets` (+ meta); `dri` → `GET /standards/dri` (+ meta); every other tab uses the cached
// `meta` (`AppState.ensureMeta`). Each tab shows `加载中…` until its data is available. Failures without data show a
// warning banner with 重试; a failed refresh while data is on screen keeps the data and shows an error toast.

/// `.task(id:)` key: the visible tab plus `app.dataVersion` (a profile save changes the personal targets).
struct StandardsLoadKey: Hashable, Sendable {
    let tab: StandardsTab
    let dataVersion: Int
}

@MainActor @Observable final class StandardsModel {
    private(set) var targets: Targets?
    private(set) var targetsError: String?
    private(set) var dri: DriTables?
    private(set) var driError: String?
    /// Banner message when `AppState.ensureMeta` failed and no metadata is available (`app.metaError`).
    private(set) var metaError: String?

    /// `app.dataVersion` the current `targets` were loaded for.
    @ObservationIgnored private var targetsVersion: Int?

    /// The standards metadata shown by every tab (AppState's copy, kept by `ensureMeta`).
    func meta(_ app: AppState) -> Meta? { app.meta }

    /// Loads whatever `tab` needs and is not loaded yet (called from `.task(id:)`).
    func load(_ tab: StandardsTab, app: AppState) async {
        await loadMeta(app)
        switch tab {
        case .mine: await loadTargets(app, force: false)
        case .dri: await loadDri(app, force: false)
        case .hazards, .hei, .met, .rules, .sources: break
        }
    }

    /// Pull to refresh: reloads the visible tab's data from the server.
    func refresh(_ tab: StandardsTab, app: AppState) async {
        switch tab {
        case .mine:
            await loadMeta(app)
            await loadTargets(app, force: true)
        case .dri:
            await loadMeta(app)
            await loadDri(app, force: true)
        case .hazards, .hei, .met, .rules, .sources:
            await refreshMeta(app)
        }
    }

    // MARK: Loaders

    /// `GET profile/targets` (no date → today in the profile time zone, like the web).
    func loadTargets(_ app: AppState, force: Bool) async {
        let version = app.dataVersion
        if !force, targets != nil, targetsVersion == version { return }
        if targets == nil { targetsError = nil }
        do {
            let fresh = try await app.api.targets(date: nil)
            targets = fresh
            targetsVersion = version
            targetsError = nil
        } catch is CancellationError {
            return
        } catch {
            report(error, hasData: targets != nil, app: app) { self.targetsError = $0 }
        }
    }

    /// `GET standards/dri` (static, loaded once per screen).
    func loadDri(_ app: AppState, force: Bool) async {
        if !force, dri != nil { return }
        if dri == nil { driError = nil }
        do {
            let fresh = try await app.api.standardsDri()
            dri = fresh
            driError = nil
        } catch is CancellationError {
            return
        } catch {
            report(error, hasData: dri != nil, app: app) { self.driError = $0 }
        }
    }

    /// Loads the metadata through `AppState.ensureMeta`; when that leaves `meta` empty, its `metaError` becomes the
    /// banner message.
    func loadMeta(_ app: AppState) async {
        if meta(app) != nil { return }
        metaError = nil
        await app.ensureMeta()
        if Task.isCancelled { return }
        metaError = app.meta == nil ? app.metaError : nil
    }

    /// Pull to refresh on a meta tab: `AppState.ensureMeta(force: true)` re-fetches `GET standards/meta`. A failure is
    /// reported from `app.metaError` (toast while data is on screen, banner otherwise).
    func refreshMeta(_ app: AppState) async {
        await app.ensureMeta(force: true)
        if Task.isCancelled { return }
        if let message = app.metaError {
            if meta(app) != nil {
                app.toasts.error(message)
            } else {
                metaError = message
            }
        } else {
            metaError = nil
        }
    }

    /// No data yet → banner message; data on screen → toast, data kept.
    private func report(_ error: Error, hasData: Bool, app: AppState, setBanner: (String) -> Void) {
        let message = APIError.from(error).message
        if hasData {
            app.toasts.error(message)
        } else {
            setBanner(message)
        }
    }
}
