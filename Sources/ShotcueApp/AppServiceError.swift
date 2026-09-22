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

/// Stand-in runner used when `claude` is missing, so the app still launches and Settings can show the
/// red status (spec §8: "claude bulunamadı → Ayarlar'da kırmızı durum; gönder düğmeleri devre dışı").
struct MissingClaudeRunner: ClaudeRunner {
    func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        throw ClaudeRunError.notFound
    }

    func cancel(runID: UUID) async {}

    func version() async throws -> String {
        throw ClaudeRunError.notFound
    }
}

/// `DesktopHandoffService` takes a concrete `URL`, but `claude` may be missing. The deep links it
/// builds only carry a session id, so they still work; the generated `.command` file fails loudly when
/// opened, which matches the red status Settings already shows.
enum ClaudeFallback {
    static let executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/claude")
}
