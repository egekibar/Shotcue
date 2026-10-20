import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Availability of Apple's on-device LLM, for Ayarlar > İzinler (spec §6.6).
/// The `@Generable` title suggester itself is deferred: `FoundationModelsMacros` is not shipped
/// with Command Line Tools, so `@Generable`/`@Guide` cannot be compiled without Xcode.
public enum FoundationModelsStatus: String, Sendable, CaseIterable {
    case unsupportedOS
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unavailableOther

    public static var current: FoundationModelsStatus {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else { return .unsupportedOS }
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .unavailableOther
            }
        #else
            return .unsupportedOS
        #endif
    }

    public static var isAvailable: Bool { current == .available }

    /// Turkish (`tr-Latn-TR`) arrived with Apple Intelligence in macOS 26.1.
    public static var supportsTurkish: Bool {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else { return false }
            return SystemLanguageModel.default.supportedLanguages.contains {
                $0.maximalIdentifier.hasPrefix("tr")
            }
        #else
            return false
        #endif
    }

    /// The diagnostics row's text, in the app's language.
    public var localizedDescription: String {
        switch self {
        case .unsupportedOS: return L10n.t("Not in this version of macOS")
        case .available: return L10n.t("Ready")
        case .appleIntelligenceNotEnabled: return L10n.t("Apple Intelligence is off")
        case .deviceNotEligible: return L10n.t("Not supported on this device")
        case .modelNotReady: return L10n.t("Model downloading")
        case .unavailableOther: return L10n.t("Not available")
        }
    }
}
