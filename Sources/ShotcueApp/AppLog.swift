import os

/// The App layer's own log lines:
/// `log stream --predicate 'subsystem == "com.shotcue.app" AND category == "app"'`.
///
/// `NSLog` is not used: on this machine its lines did not reach the unified log (a probe printed only to
/// stderr, verified 2026-09-23), so neither Console nor the manual checks could see them.
enum AppLog {
    nonisolated static let app = Logger(subsystem: "com.shotcue.app", category: "app")
}
