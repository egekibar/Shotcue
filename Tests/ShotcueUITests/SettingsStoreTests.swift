import Foundation
import Observation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

@Suite("SettingsStore")
struct SettingsStoreTests {
    /// A private suite per test so nothing leaks into the developer's own defaults. The suite name is an
    /// absolute path in the temporary directory, so the backing plist is written there instead of piling up
    /// in ~/Library/Preferences on every test run.
    func freshDefaults() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-settings-\(UUID().uuidString)").path
        return UserDefaults(suiteName: path)!
    }

    @MainActor
    @Test func defaultsMatchTheSpec() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.hotKeyLabel == "⌃⇧2")
        #expect(store.launchAtLogin == false)
        #expect(store.copyToClipboardOnCapture == false)
        #expect(store.storageRootPath == nil)
        #expect(store.claudePath == nil)
        #expect(store.defaultModel == nil)
        #expect(store.defaultEffort == nil)
        #expect(store.maxTurns == 50)
        #expect(store.maxBudgetUSD == 5.0)
        #expect(store.timeoutMinutes == 30)
        #expect(store.maxConcurrentRuns == 2)
        #expect(store.permissionMode == "bypassPermissions")
        #expect(store.extraSystemPrompt == "")
        #expect(store.keepAwake == true)
        #expect(store.sttLanguage == "tr")
        #expect(store.sttModel == "openai_whisper-large-v3-v20240930_turbo")
        #expect(store.inputDeviceUID == nil)
        #expect(store.foundationModelsEnabled == false)
        #expect(store.lastUsedProjectID == nil)
    }

    @MainActor
    @Test func writesThroughImmediatelyUnderTheExactKeys() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)

        store.hotKeyLabel = "⌥Space"
        store.launchAtLogin = true
        store.copyToClipboardOnCapture = true
        store.storageRootPath = "/Volumes/Work/Shotcue"
        store.claudePath = "/opt/homebrew/bin/claude"
        store.defaultModel = "opus"
        store.defaultEffort = "high"
        store.maxTurns = 80
        store.maxBudgetUSD = 12.5
        store.timeoutMinutes = 45
        store.maxConcurrentRuns = 3
        store.permissionMode = "acceptEdits"
        store.extraSystemPrompt = "Türkçe cevap ver."
        store.keepAwake = false
        store.sttLanguage = "en"
        store.sttModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
        store.inputDeviceUID = "BuiltInMic"
        store.foundationModelsEnabled = true
        store.lastUsedProjectID = "8A2B1D4F-0C73-4C6D-9E51-3F2A9C407B18"

        #expect(defaults.string(forKey: "hotKeyLabel") == "⌥Space")
        #expect(defaults.bool(forKey: "launchAtLogin") == true)
        #expect(defaults.bool(forKey: "copyToClipboardOnCapture") == true)
        #expect(defaults.string(forKey: "storageRootPath") == "/Volumes/Work/Shotcue")
        #expect(defaults.string(forKey: "claudePath") == "/opt/homebrew/bin/claude")
        #expect(defaults.string(forKey: "defaultModel") == "opus")
        #expect(defaults.string(forKey: "defaultEffort") == "high")
        #expect(defaults.integer(forKey: "maxTurns") == 80)
        #expect(defaults.double(forKey: "maxBudgetUSD") == 12.5)
        #expect(defaults.integer(forKey: "timeoutMinutes") == 45)
        #expect(defaults.integer(forKey: "maxConcurrentRuns") == 3)
        #expect(defaults.string(forKey: "permissionMode") == "acceptEdits")
        #expect(defaults.string(forKey: "extraSystemPrompt") == "Türkçe cevap ver.")
        #expect(defaults.bool(forKey: "keepAwake") == false)
        #expect(defaults.string(forKey: "sttLanguage") == "en")
        #expect(defaults.string(forKey: "sttModel") == "openai_whisper-large-v3-v20240930_turbo_632MB")
        #expect(defaults.string(forKey: "inputDeviceUID") == "BuiltInMic")
        #expect(defaults.bool(forKey: "foundationModelsEnabled") == true)
        #expect(defaults.string(forKey: "lastUsedProjectID") == "8A2B1D4F-0C73-4C6D-9E51-3F2A9C407B18")

        // A second store over the same suite sees everything (no in-memory-only state).
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.maxTurns == 80)
        #expect(reopened.sttLanguage == "en")
        #expect(reopened.keepAwake == false)
    }

    @MainActor
    @Test func clearingAnOptionalRemovesTheKey() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.claudePath = "/tmp/claude"
        store.claudePath = nil
        #expect(defaults.object(forKey: "claudePath") == nil)
        store.claudePath = "   "
        #expect(defaults.object(forKey: "claudePath") == nil)
        #expect(store.claudePath == nil)
    }

    @MainActor
    @Test func hotKeyResolvesThePresetForTheStoredLabel() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.hotKey == KeyCombo.defaultCombo)
        store.hotKeyLabel = "⌃⌥Space"
        #expect(store.hotKey.label == "⌃⌥Space")
        #expect(store.hotKey.modifiers == KeyCombo.controlKey | KeyCombo.optionKey)
        #expect(store.hotKey == KeyCombo.presets.last)
    }

    @MainActor
    @Test func unknownHotKeyLabelFallsBackToTheDefault() {
        let defaults = freshDefaults()
        defaults.set("⌘⌥⇧F13", forKey: "hotKeyLabel")
        let store = SettingsStore(defaults: defaults)
        #expect(store.hotKey == KeyCombo.defaultCombo)
        // Assigning an invalid label is rejected, the stored label stays valid.
        store.hotKeyLabel = "nonsense"
        #expect(store.hotKeyLabel == "⌃⇧2")
        #expect(defaults.string(forKey: "hotKeyLabel") == "⌃⇧2")
    }

    @MainActor
    @Test func derivedValues() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.storageRoot == FileStore.defaultRoot())
        store.storageRootPath = "/Volumes/Work/Shotcue"
        #expect(store.storageRoot.path == "/Volumes/Work/Shotcue")

        #expect(store.timeout == 1800)
        store.timeoutMinutes = 45
        #expect(store.timeout == 2700)

        #expect(store.claudePermissionMode == .bypassPermissions)
        store.permissionMode = "dontAsk"
        #expect(store.claudePermissionMode == .dontAsk)
        store.permissionMode = "garbage"
        #expect(store.claudePermissionMode == .bypassPermissions)

        #expect(store.lastUsedProject == nil)
        let id = UUID()
        store.lastUsedProjectID = id.uuidString
        #expect(store.lastUsedProject == id)
        store.lastUsedProjectID = "not-a-uuid"
        #expect(store.lastUsedProject == nil)
    }

    @MainActor
    @Test func numericSettersAreClampedToUsefulRanges() {
        let store = SettingsStore(defaults: freshDefaults())
        store.maxTurns = 0
        #expect(store.maxTurns == 1)
        store.maxTurns = 5000
        #expect(store.maxTurns == 500)
        store.maxBudgetUSD = -3
        #expect(store.maxBudgetUSD == 0.1)
        store.timeoutMinutes = 0
        #expect(store.timeoutMinutes == 1)
        store.maxConcurrentRuns = 99
        #expect(store.maxConcurrentRuns == 8)
    }

    /// SwiftUI only re-renders for reads that went through `access(keyPath:)`: every getter must register,
    /// not just `hotKeyLabel`'s, or a Stepper/Toggle bound to the store never refreshes its label.
    @MainActor
    @Test func everyReadRegistersWithObservation() {
        let store = SettingsStore(defaults: freshDefaults())
        func notifies(_ read: () -> Void, after write: () -> Void) -> Bool {
            let changed = Locked(false)
            withObservationTracking(read) { changed.set(true) }
            write()
            return changed.current
        }
        #expect(notifies({ _ = store.hotKeyLabel }, after: { store.hotKeyLabel = "⌥Space" }))
        #expect(notifies({ _ = store.launchAtLogin }, after: { store.launchAtLogin = true }))
        #expect(notifies({ _ = store.maxTurns }, after: { store.maxTurns = 80 }))
        #expect(notifies({ _ = store.maxBudgetUSD }, after: { store.maxBudgetUSD = 9 }))
        #expect(notifies({ _ = store.sttLanguage }, after: { store.sttLanguage = "en" }))
        #expect(notifies({ _ = store.claudePath }, after: { store.claudePath = "/tmp/claude" }))
        #expect(notifies({ _ = store.timeout }, after: { store.timeoutMinutes = 45 }))
    }
}
