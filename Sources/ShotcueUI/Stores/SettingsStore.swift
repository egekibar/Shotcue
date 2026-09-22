import Foundation
import Observation
import ShotcueCore

/// Typed, observable façade over `UserDefaults` (spec §6.3: "Ayarlar `UserDefaults`").
///
/// Every property is a computed property that reads and writes `UserDefaults` directly, so a value set
/// here is durable the instant the user flips a switch and a second `SettingsStore` over the same suite
/// sees it. `@Observable` only instruments *stored* properties, so each accessor calls the generated
/// `access(keyPath:)` / `withMutation(keyPath:)` hooks by hand — that is what makes SwiftUI re-render.
///
/// `init` stays MainActor-isolated: `UserDefaults` is not `Sendable`, so it cannot be stored from a
/// `nonisolated` initializer in this MainActor-by-default module.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys and defaults

    /// The `UserDefaults` keys are the property names verbatim, so they read the same in `defaults read`.
    enum Key {
        static let hotKeyLabel = "hotKeyLabel"
        static let launchAtLogin = "launchAtLogin"
        static let copyToClipboardOnCapture = "copyToClipboardOnCapture"
        static let storageRootPath = "storageRootPath"
        static let claudePath = "claudePath"
        static let defaultModel = "defaultModel"
        static let defaultEffort = "defaultEffort"
        static let maxTurns = "maxTurns"
        static let maxBudgetUSD = "maxBudgetUSD"
        static let timeoutMinutes = "timeoutMinutes"
        static let maxConcurrentRuns = "maxConcurrentRuns"
        static let permissionMode = "permissionMode"
        static let extraSystemPrompt = "extraSystemPrompt"
        static let keepAwake = "keepAwake"
        static let sttLanguage = "sttLanguage"
        static let sttModel = "sttModel"
        static let inputDeviceUID = "inputDeviceUID"
        static let foundationModelsEnabled = "foundationModelsEnabled"
        static let lastUsedProjectID = "lastUsedProjectID"
    }

    public static let defaultHotKeyLabel = "⌃⇧2"
    public static let defaultSTTLanguage = "tr"
    public static let defaultSTTModel = "openai_whisper-large-v3-v20240930_turbo"
    public static let defaultPermissionMode = ClaudePermissionMode.bypassPermissions.rawValue
    /// Offered in Ayarlar > Ses; both are in `WhisperKit.recommendedModels().supported` (spec §6.2).
    public static let sttModelChoices = [
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3-v20240930_turbo_632MB",
    ]
    public static let sttLanguageChoices = ["tr", "en"]

    // MARK: - General

    /// Always one of `KeyCombo.presets` labels; an unknown value is coerced back to the default.
    public var hotKeyLabel: String {
        get {
            access(keyPath: \.hotKeyLabel)
            let stored = defaults.string(forKey: Key.hotKeyLabel) ?? Self.defaultHotKeyLabel
            return KeyCombo.presets.contains(where: { $0.label == stored }) ? stored : Self.defaultHotKeyLabel
        }
        set {
            let valid =
                KeyCombo.presets.contains(where: { $0.label == newValue })
                ? newValue : Self.defaultHotKeyLabel
            withMutation(keyPath: \.hotKeyLabel) { defaults.set(valid, forKey: Key.hotKeyLabel) }
        }
    }

    /// The combo Plan 02's `HotKeyCenter` registers. Never nil: falls back to `KeyCombo.defaultCombo`.
    public var hotKey: KeyCombo {
        KeyCombo.presets.first { $0.label == hotKeyLabel } ?? KeyCombo.defaultCombo
    }

    public var launchAtLogin: Bool {
        get { bool(Key.launchAtLogin, default: false, keyPath: \.launchAtLogin) }
        set { setBool(newValue, Key.launchAtLogin, keyPath: \.launchAtLogin) }
    }

    public var copyToClipboardOnCapture: Bool {
        get { bool(Key.copyToClipboardOnCapture, default: false, keyPath: \.copyToClipboardOnCapture) }
        set { setBool(newValue, Key.copyToClipboardOnCapture, keyPath: \.copyToClipboardOnCapture) }
    }

    /// `nil` means "use `FileStore.defaultRoot()`".
    public var storageRootPath: String? {
        get { optionalString(Key.storageRootPath, keyPath: \.storageRootPath) }
        set { setOptionalString(newValue, Key.storageRootPath, keyPath: \.storageRootPath) }
    }

    public var storageRoot: URL {
        if let path = storageRootPath { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileStore.defaultRoot()
    }

    // MARK: - Claude

    public var claudePath: String? {
        get { optionalString(Key.claudePath, keyPath: \.claudePath) }
        set { setOptionalString(newValue, Key.claudePath, keyPath: \.claudePath) }
    }

    public var defaultModel: String? {
        get { optionalString(Key.defaultModel, keyPath: \.defaultModel) }
        set { setOptionalString(newValue, Key.defaultModel, keyPath: \.defaultModel) }
    }

    public var defaultEffort: String? {
        get { optionalString(Key.defaultEffort, keyPath: \.defaultEffort) }
        set { setOptionalString(newValue, Key.defaultEffort, keyPath: \.defaultEffort) }
    }

    public var maxTurns: Int {
        get { int(Key.maxTurns, default: 50, keyPath: \.maxTurns) }
        set { setInt(newValue, Key.maxTurns, range: 1...500, keyPath: \.maxTurns) }
    }

    public var maxBudgetUSD: Double {
        get { double(Key.maxBudgetUSD, default: 5.0, keyPath: \.maxBudgetUSD) }
        set {
            let clamped = min(max(newValue, 0.1), 100)
            withMutation(keyPath: \.maxBudgetUSD) { defaults.set(clamped, forKey: Key.maxBudgetUSD) }
        }
    }

    public var timeoutMinutes: Int {
        get { int(Key.timeoutMinutes, default: 30, keyPath: \.timeoutMinutes) }
        set { setInt(newValue, Key.timeoutMinutes, range: 1...480, keyPath: \.timeoutMinutes) }
    }

    /// Seconds, for `RunSpec.timeout`.
    public var timeout: TimeInterval { TimeInterval(timeoutMinutes) * 60 }

    public var maxConcurrentRuns: Int {
        get { int(Key.maxConcurrentRuns, default: 2, keyPath: \.maxConcurrentRuns) }
        set { setInt(newValue, Key.maxConcurrentRuns, range: 1...8, keyPath: \.maxConcurrentRuns) }
    }

    /// Raw value of `ClaudePermissionMode`; stored as a string so an unknown value cannot crash.
    public var permissionMode: String {
        get { string(Key.permissionMode, default: Self.defaultPermissionMode, keyPath: \.permissionMode) }
        set { withMutation(keyPath: \.permissionMode) { defaults.set(newValue, forKey: Key.permissionMode) } }
    }

    public var claudePermissionMode: ClaudePermissionMode {
        ClaudePermissionMode(rawValue: permissionMode) ?? .bypassPermissions
    }

    /// Appended after `PromptBuilder.systemPromptAppend` (spec §6.4).
    public var extraSystemPrompt: String {
        get { string(Key.extraSystemPrompt, default: "", keyPath: \.extraSystemPrompt) }
        set { withMutation(keyPath: \.extraSystemPrompt) { defaults.set(newValue, forKey: Key.extraSystemPrompt) } }
    }

    /// "önümüzdeki 1 saat içinde zamanlanmış iş varsa uyanık tut" (spec §6.5).
    public var keepAwake: Bool {
        get { bool(Key.keepAwake, default: true, keyPath: \.keepAwake) }
        set { setBool(newValue, Key.keepAwake, keyPath: \.keepAwake) }
    }

    // MARK: - Audio

    public var sttLanguage: String {
        get { string(Key.sttLanguage, default: Self.defaultSTTLanguage, keyPath: \.sttLanguage) }
        set { withMutation(keyPath: \.sttLanguage) { defaults.set(newValue, forKey: Key.sttLanguage) } }
    }

    public var sttModel: String {
        get { string(Key.sttModel, default: Self.defaultSTTModel, keyPath: \.sttModel) }
        set { withMutation(keyPath: \.sttModel) { defaults.set(newValue, forKey: Key.sttModel) } }
    }

    public var inputDeviceUID: String? {
        get { optionalString(Key.inputDeviceUID, keyPath: \.inputDeviceUID) }
        set { setOptionalString(newValue, Key.inputDeviceUID, keyPath: \.inputDeviceUID) }
    }

    public var foundationModelsEnabled: Bool {
        get { bool(Key.foundationModelsEnabled, default: false, keyPath: \.foundationModelsEnabled) }
        set { setBool(newValue, Key.foundationModelsEnabled, keyPath: \.foundationModelsEnabled) }
    }

    // MARK: - Session memory

    /// The quick panel's default project (spec §5.1 "son kullanılan varsayılan").
    public var lastUsedProjectID: String? {
        get { optionalString(Key.lastUsedProjectID, keyPath: \.lastUsedProjectID) }
        set { setOptionalString(newValue, Key.lastUsedProjectID, keyPath: \.lastUsedProjectID) }
    }

    public var lastUsedProject: UUID? {
        guard let raw = lastUsedProjectID else { return nil }
        return UUID(uuidString: raw)
    }

    // MARK: - Accessor plumbing

    // Every read helper registers the read with `access(keyPath:)` so SwiftUI tracks it.

    private func string(_ key: String, default fallback: String, keyPath: KeyPath<SettingsStore, String>) -> String {
        access(keyPath: keyPath)
        return defaults.string(forKey: key) ?? fallback
    }

    private func optionalString(_ key: String, keyPath: KeyPath<SettingsStore, String?>) -> String? {
        access(keyPath: keyPath)
        guard let value = defaults.string(forKey: key),
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }

    private func bool(_ key: String, default fallback: Bool, keyPath: KeyPath<SettingsStore, Bool>) -> Bool {
        access(keyPath: keyPath)
        return defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func int(_ key: String, default fallback: Int, keyPath: KeyPath<SettingsStore, Int>) -> Int {
        access(keyPath: keyPath)
        return defaults.object(forKey: key) as? Int ?? fallback
    }

    private func double(_ key: String, default fallback: Double, keyPath: KeyPath<SettingsStore, Double>) -> Double {
        access(keyPath: keyPath)
        return defaults.object(forKey: key) as? Double ?? fallback
    }

    private func setBool(_ value: Bool, _ key: String, keyPath: KeyPath<SettingsStore, Bool>) {
        withMutation(keyPath: keyPath) { defaults.set(value, forKey: key) }
    }

    private func setInt(
        _ value: Int, _ key: String, range: ClosedRange<Int>,
        keyPath: KeyPath<SettingsStore, Int>
    ) {
        withMutation(keyPath: keyPath) {
            defaults.set(min(max(value, range.lowerBound), range.upperBound), forKey: key)
        }
    }

    /// Empty / whitespace-only input removes the key, so "cleared" and "never set" behave the same.
    private func setOptionalString(
        _ value: String?, _ key: String,
        keyPath: KeyPath<SettingsStore, String?>
    ) {
        withMutation(keyPath: keyPath) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
