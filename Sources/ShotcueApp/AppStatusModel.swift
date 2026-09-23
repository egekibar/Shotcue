import Foundation
import Observation
import ShotcueCore

/// Everything the UI needs to know about the host machine rather than about the data model.
/// Held by `AppEnvironment` (a reference, not view state), so SwiftUI observes it without `@State`.
@Observable
final class AppStatusModel {
    /// `<cli> --version` per agent ("kontrol ediliyor…" until it answers) and whether the CLI was found.
    var agentVersions: [AgentKind: String] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { ($0, "kontrol ediliyor…") })
    var agentFound: [AgentKind: Bool] = [:]

    /// What Settings shows for an agent: its version, or nil (the red "bulunamadı").
    func settingsVersion(of agent: AgentKind) -> String? {
        agentFound[agent] == true ? agentVersions[agent] : nil
    }
    var projects: [Project] = []
    /// Microphones for Ayarlar > Ses (`AudioDeviceCatalog`), re-read whenever Settings opens.
    var inputDevices: [(uid: String, name: String)] = []
    var loginItemStatusText: String = "bilinmiyor"
    /// Apple Intelligence availability (`FoundationModelsStatus`, A19): shown in the Diagnostics strip.
    var foundationModelsText: String = "bilinmiyor"
    var hotKeyError: String?
    var diagnosticsRunning: Bool = false
    var captureFlash: Bool = false
    var lastError: String?

    init() {}

    /// Highlights the menu bar icon right after a capture (spec §5.1 step 5).
    func flashMenuBarIcon() {
        captureFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            captureFlash = false
        }
    }
}
