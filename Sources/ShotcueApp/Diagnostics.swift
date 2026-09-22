import Foundation
import ShotcueCore
import ShotcueUI

/// `claude --version` / `auth status` / permission report (spec §12, Plan 00 Task 11). Filled in Task 7.
struct Diagnostics {
    let claudeExecutable: URL?
    let permissions: any PermissionService
    let fileStore: FileStore
    let settings: SettingsStore

    /// Per-user temporary directory (`$TMPDIR`), never the world-readable `/tmp`.
    static let reportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("shotcue-diagnostics.txt")

    func claudeVersion() async -> (text: String, found: Bool) {
        (claudeExecutable == nil ? "bulunamadı" : "kontrol ediliyor…", claudeExecutable != nil)
    }

    func writeReport(
        transcriberState: TranscriberModelState, loginItemStatus: String, hotKeyLabel: String
    ) async throws -> URL {
        try "henüz bağlanmadı\n".write(to: Self.reportURL, atomically: true, encoding: .utf8)
        return Self.reportURL
    }
}
