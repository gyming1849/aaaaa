import Foundation

/// Boxes a non-Sendable value from a callback-based Apple API (an `HKObserverQuery` completion handler,
/// a `BGTask`) so it can be captured by a `Task`. Rule A.4.6: this is the only allowed `@unchecked Sendable`;
/// use it only where the API guarantees the value may be used from another thread.
struct UncheckedSendable<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }
