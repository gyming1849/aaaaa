import Foundation
import os

/// Shared loggers (subsystem `com.nutrilog.ios`). Never log tokens or health values with `.public` privacy.
enum AppLog {
    static let subsystem = "com.nutrilog.ios"
    /// Networking: requests, status codes, decoding failures.
    static let net = Logger(subsystem: subsystem, category: "net")
    /// HealthKit sync.
    static let health = Logger(subsystem: subsystem, category: "health")
    /// App lifecycle, caches, everything else.
    static let app = Logger(subsystem: subsystem, category: "app")
}
