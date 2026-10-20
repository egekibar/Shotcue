import Testing

@testable import ShotcueCore

@Suite("TranscriptionLanguage")
struct TranscriptionLanguageTests {
    /// A new install transcribes in the interface's language; Whisper knows both, and any other interface is English.
    @Test func theDefaultFollowsTheInterface() {
        #expect(TranscriptionLanguage.defaultCode(interfaceLanguage: "tr") == "tr")
        #expect(TranscriptionLanguage.defaultCode(interfaceLanguage: "en") == "en")
        #expect(TranscriptionLanguage.defaultCode(interfaceLanguage: nil) == "en")
    }

    @Test func automaticIsItsOwnValue() {
        #expect(TranscriptionLanguage.automatic == "auto")
        #expect(TranscriptionLanguage.isAutomatic("auto"))
        #expect(!TranscriptionLanguage.isAutomatic("tr"))
    }
}
