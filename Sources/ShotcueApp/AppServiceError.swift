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

/// `DesktopHandoffService` takes concrete `URL`s, but a CLI may be missing. The deep links it
/// builds only carry a session id, so they still work; the generated `.command` file fails loudly when
/// opened, which matches the red status Settings already shows. (A missing CLI at run time is
/// `AgentRouterRunner` throwing `ClaudeRunError.notFound`.)
nonisolated enum AgentFallback {
    static func executableURL(for agent: AgentKind) -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/\(agent.executableName)")
    }
}
