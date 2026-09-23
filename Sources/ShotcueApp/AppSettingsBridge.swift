import Foundation
import ShotcueClaudeBridge
import ShotcueCore
import ShotcueUI

/// Value-type mirror of every `SettingsStore` field the app has to react to.
/// Equatable so `AppEnvironment.applySettings()` can skip no-op re-applications.
/// `sttModel`, `inputDeviceUID`, `storageRootPath` and the agent paths cannot be applied to a live service —
/// they are baked into the transcriber, the recorder, the file store and the agent locators at init — but
/// they are part of the snapshot so a change is *noticed* and the user is told a restart is needed.
struct AppSettingsSnapshot: Equatable, Sendable {
    var defaultAgent: AgentKind
    var maxConcurrent: Int
    var maxTurns: Int
    var maxBudgetUSD: Double
    var timeout: TimeInterval
    var permissionMode: ClaudePermissionMode
    var model: String?
    var effort: String?
    var codexModel: String?
    var codexEffort: String?
    var antigravityModel: String?
    var antigravityEffort: String?
    var extraSystemPrompt: String
    var keepAwake: Bool
    var sttLanguage: String
    var sttModel: String
    var inputDeviceUID: String?
    var hotKey: KeyCombo
    /// Settings' shortcut recorder is listening: the global hotkey is unregistered until it finishes.
    var hotKeyPaused: Bool
    var launchAtLogin: Bool
    var copyToClipboardOnCapture: Bool
    /// The effective storage root (`SettingsStore.storageRootPath` is optional: nil means the default).
    var storageRootPath: String
    /// Settings > Ajanlar > Yol, per agent; a missing entry = search the default locations.
    var agentPaths: [AgentKind: String]
}

/// The only place that translates user-facing settings into service inputs. Pure functions only:
/// this is the piece of App code worth reasoning about, so it must stay side-effect free.
enum AppSettingsBridge {
    static func snapshot(of settings: SettingsStore) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            defaultAgent: settings.defaultAgent,
            maxConcurrent: max(1, settings.maxConcurrentRuns),
            maxTurns: max(1, settings.maxTurns),
            maxBudgetUSD: max(0.01, settings.maxBudgetUSD),
            timeout: settings.timeout,
            permissionMode: settings.claudePermissionMode,
            model: nonEmpty(settings.defaultModel),
            effort: nonEmpty(settings.defaultEffort),
            codexModel: nonEmpty(settings.codexDefaultModel),
            codexEffort: nonEmpty(settings.codexDefaultEffort),
            antigravityModel: nonEmpty(settings.antigravityDefaultModel),
            antigravityEffort: nonEmpty(settings.antigravityDefaultEffort),
            extraSystemPrompt: settings.extraSystemPrompt,
            keepAwake: settings.keepAwake,
            sttLanguage: nonEmpty(settings.sttLanguage) ?? "tr",
            sttModel: nonEmpty(settings.sttModel) ?? defaultSTTModel,
            inputDeviceUID: nonEmpty(settings.inputDeviceUID),
            hotKey: settings.hotKey,
            hotKeyPaused: settings.isRecordingHotKey,
            launchAtLogin: settings.launchAtLogin,
            copyToClipboardOnCapture: settings.copyToClipboardOnCapture,
            storageRootPath: settings.storageRoot.path,
            agentPaths: agentPaths(of: settings))
    }

    static func agentPaths(of settings: SettingsStore) -> [AgentKind: String] {
        var paths: [AgentKind: String] = [:]
        for agent in AgentKind.allCases {
            paths[agent] = nonEmpty(settings.executablePath(for: agent))
        }
        return paths
    }

    static func runSettings(from snapshot: AppSettingsSnapshot) -> RunSettings {
        RunSettings(
            defaultAgent: snapshot.defaultAgent,
            maxConcurrent: snapshot.maxConcurrent,
            maxTurns: snapshot.maxTurns,
            maxBudgetUSD: snapshot.maxBudgetUSD,
            timeout: snapshot.timeout,
            permissionMode: snapshot.permissionMode,
            model: snapshot.model,
            effort: snapshot.effort,
            codexModel: snapshot.codexModel,
            codexEffort: snapshot.codexEffort,
            antigravityModel: snapshot.antigravityModel,
            antigravityEffort: snapshot.antigravityEffort,
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
