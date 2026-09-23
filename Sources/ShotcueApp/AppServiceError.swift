import Foundation
import ShotcueClaudeBridge
import ShotcueCore

/// Errors raised by the composition root itself (spec §8).
enum AppServiceError: LocalizedError, Equatable {
    case storageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable(let path):
            return "Depolama klasörü kullanılamıyor: \(path)"
        }
    }
}

/// `DesktopHandoffService` takes a concrete `URL`, but `claude` may be missing. The deep links it
/// builds only carry a session id, so they still work; the generated `.command` file fails loudly when
/// opened, which matches the red status Settings already shows. (A missing `claude` at run time is
/// `DeferredClaudeRunner` throwing `ClaudeRunError.notFound`.)
nonisolated enum ClaudeFallback {
    static let executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/claude")
}
