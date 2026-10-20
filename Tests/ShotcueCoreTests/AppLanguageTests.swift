import Foundation
import Testing

@testable import ShotcueCore

@Suite("AppLanguage")
struct AppLanguageTests {
    /// A chosen language goes first in the app's `AppleLanguages`; "System" removes the override.
    @Test func eachChoiceSetsOrClearsTheAppleLanguagesOverride() {
        #expect(AppLanguage.system.appleLanguages == nil)
        #expect(AppLanguage.english.appleLanguages == ["en"])
        #expect(AppLanguage.turkish.appleLanguages == ["tr"])
    }

    @Test func storedValuesRoundTripAndUnknownOnesFollowTheSystem() {
        for language in AppLanguage.allCases {
            #expect(AppLanguage(stored: language.rawValue) == language)
        }
        #expect(AppLanguage(stored: nil) == .system)
        #expect(AppLanguage(stored: "de") == .system)
    }

    /// Each language is named in itself, so it can be found whatever the UI language is.
    @Test func languagesAreNamedInThemselves() {
        #expect(AppLanguage.english.nativeName == "English")
        #expect(AppLanguage.turkish.nativeName == "Türkçe")
        #expect(AppLanguage.system.nativeName == nil)
    }
}
