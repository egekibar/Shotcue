import Foundation
import ShotcueClaudeBridge
import ShotcueCore
import ShotcueUI

/// Value-type mirror of every `SettingsStore` field the app has to react to.
/// Equatable so `AppEnvironment.applySettings()` can skip no-op re-applications.
/// `sttModel`, `inputDeviceUID`, `storageRootPath` and `claudePath` cannot be applied to a live service —
/// they are baked into the transcriber, the recorder, the file store and the claude locator at init — but
/// they are part of the snapshot so a change is *noticed* and the user is told a restart is needed.
struct AppSettingsSnapshot: Equatable, Sendable {
    var maxConcurrent: Int
    var maxTurns: Int
    var maxBudgetUSD: Double
    var timeout: TimeInterval
    var permissionMode: ClaudePermissionMode
    var model: String?
    var effort: String?
    var extraSystemPrompt: String
    var keepAwake: Bool
    var sttLanguage: String
    var sttModel: String
    var inputDeviceUID: String?
    var hotKey: KeyCombo
    var launchAtLogin: Bool
    var copyToClipboardOnCapture: Bool
    /// The effective storage root (`SettingsStore.storageRootPath` is optional: nil means the default).
    var storageRootPath: String
    /// Settings > Claude > Yol; nil = search the default locations.
    var claudePath: String?
}

/// The only place that translates user-facing settings into service inputs. Pure functions only:
/// this is the piece of App code worth reasoning about, so it must stay side-effect free.
enum AppSettingsBridge {
    static func snapshot(of settings: SettingsStore) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            maxConcurrent: max(1, settings.maxConcurrentRuns),
            maxTurns: max(1, settings.maxTurns),
            maxBudgetUSD: max(0.01, settings.maxBudgetUSD),
            timeout: settings.timeout,
            permissionMode: settings.claudePermissionMode,
            model: nonEmpty(settings.defaultModel),
            effort: nonEmpty(settings.defaultEffort),
            extraSystemPrompt: settings.extraSystemPrompt,
            keepAwake: settings.keepAwake,
            sttLanguage: nonEmpty(settings.sttLanguage) ?? "tr",
            sttModel: nonEmpty(settings.sttModel) ?? defaultSTTModel,
            inputDeviceUID: nonEmpty(settings.inputDeviceUID),
            hotKey: settings.hotKey,
            launchAtLogin: settings.launchAtLogin,
            copyToClipboardOnCapture: settings.copyToClipboardOnCapture,
            storageRootPath: settings.storageRoot.path,
            claudePath: nonEmpty(settings.claudePath))
    }

    static func runSettings(from snapshot: AppSettingsSnapshot) -> RunSettings {
        RunSettings(
            maxConcurrent: snapshot.maxConcurrent,
            maxTurns: snapshot.maxTurns,
            maxBudgetUSD: snapshot.maxBudgetUSD,
            timeout: snapshot.timeout,
            permissionMode: snapshot.permissionMode,
            model: snapshot.model,
            effort: snapshot.effort,
            extraSystemPrompt: snapshot.extraSystemPrompt,
            keepAwake: snapshot.keepAwake)
    }

    /// WhisperKit model cache lives inside the storage root so "Depolama konumu" moves it too.
    static func modelsDirectory(in fileStore: FileStore) -> URL {
        fileStore.rootURL.appendingPathComponent("models", isDirectory: true)
    }

    static let defaultSTTModel = SettingsStore.defaultSTTModel

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
