import Foundation

/// Main-actor, Task-based debouncer (rule A.4.7). Each `schedule` cancels the pending action;
/// the action runs once `delay` has passed without another call. Typical delays: 200–400 ms.
@MainActor final class Debouncer {
    private var task: Task<Void, Never>?
    let delay: Duration
    init(_ delay: Duration) { self.delay = delay }
    func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await action()
        }
    }
    func cancel() { task?.cancel() }
}
