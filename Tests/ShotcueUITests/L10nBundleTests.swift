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

    /// Turkish puts the percent sign first ("%42"); the escaped `%%` in the table must survive formatting.
    @Test func turkishPercentagesFormatWithTheSignFirst() throws {
        let path = try #require(
            L10n.bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "tr"))
        let format = try #require(NSDictionary(contentsOfFile: path)?["Downloading… %lld%%"] as? String)
        #expect(String(format: format, 42 as Int64) == "İndiriliyor… %42")
    }
}
