import Foundation

/// The voice-note language setting: a Whisper language code ("tr", "de"…) or `automatic`.
public enum TranscriptionLanguage {
    /// "Detect automatically": Whisper picks the language of each recording.
    public static let automatic = "auto"

    public static func isAutomatic(_ code: String) -> Bool { code == automatic }

    /// What a new install transcribes in: the interface's language (English or Turkish), English otherwise.
    public static func defaultCode(interfaceLanguage: String?) -> String {
        interfaceLanguage == "tr" ? "tr" : "en"
    }
}
