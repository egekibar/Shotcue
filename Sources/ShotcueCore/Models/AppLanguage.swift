import Foundation

/// The interface language picked in Settings (Plan 08). Applied through the app's `AppleLanguages` default, the
/// same one macOS's per-app language setting writes, and read at launch: a change needs a restart.
public enum AppLanguage: String, CaseIterable, Sendable {
    /// Follow the system's preferred languages; English when none of them is supported.
    case system
    case english = "en"
    case turkish = "tr"

    public init(stored: String?) {
        self = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// The app's `AppleLanguages` override; nil removes it.
    public var appleLanguages: [String]? {
        self == .system ? nil : [rawValue]
    }

    /// The language's own name ("Türkçe"), shown untranslated in the picker; nil for `system`, which is localized.
    public var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }
}
