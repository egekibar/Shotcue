import Foundation
import Testing

@testable import ShotcueUI

/// The built resource bundle carries both languages, and a Turkish lookup reads the Turkish table.
@Suite("L10n bundle")
struct L10nBundleTests {
    @Test func theBundleShipsEnglishAndTurkish() {
        #expect(Set(L10n.bundle.localizations).isSuperset(of: ["en", "tr"]))
    }

    @Test func eachLanguageReadsItsOwnTable() throws {
        func value(_ key: String, in language: String) throws -> String? {
            let path = try #require(
                L10n.bundle.path(
                    forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            return NSDictionary(contentsOfFile: path)?[key] as? String
        }
        #expect(try value("Language", in: "en") == "Language")
        #expect(try value("Language", in: "tr") == "Dil")
    }
}
