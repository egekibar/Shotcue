import Foundation
import Testing

/// Every module's `Resources/<language>.lproj/Localizable.strings`: each language has every English key, and each
/// translation keeps the placeholders of its key, so a missing or broken translation fails `make test`, not the UI.
@Suite("Localization tables")
struct LocalizationTablesTests {
    static let languages = ["en", "tr"]

    /// `Sources/` of this checkout, found from this file's path (Tests/ShotcueCoreTests/…).
    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// Modules that ship strings: those with a `Resources/en.lproj`.
    static var localizedModules: [URL] {
        let modules =
            (try? FileManager.default.contentsOfDirectory(
                at: sourcesDirectory, includingPropertiesForKeys: nil)) ?? []
        return modules.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Resources/en.lproj").path)
        }.sorted { $0.path < $1.path }
    }

    static func table(_ module: URL, _ language: String) throws -> [String: String] {
        let url = module.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String], "\(url.path) is not a strings table")
    }

    /// `%@`, `%d`, `%lld`, `%1$@`… sorted, so a translation may reorder positional placeholders.
    static func placeholders(_ text: String) -> [String] {
        let pattern = /%(\d+\$)?[-+ #0]*\d*(\.\d+)?(hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]/
        return text.matches(of: pattern).map { String(text[$0.range]) }
            .map { $0.replacing(/\d+\$/, with: "") }
            .sorted()
    }

    @Test func theUIModuleIsLocalized() {
        #expect(Self.localizedModules.map(\.lastPathComponent).contains("ShotcueUI"))
    }

    @Test func everyLanguageHasEveryKey() throws {
        for module in Self.localizedModules {
            let english = try Self.table(module, "en")
            for language in Self.languages where language != "en" {
                let translated = try Self.table(module, language)
                let missing = Set(english.keys).subtracting(translated.keys).sorted()
                let extra = Set(translated.keys).subtracting(english.keys).sorted()
                #expect(missing.isEmpty, "\(module.lastPathComponent) \(language) misses \(missing)")
                #expect(extra.isEmpty, "\(module.lastPathComponent) \(language) has unknown keys \(extra)")
            }
        }
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        for module in Self.localizedModules {
            for language in Self.languages {
                for (key, value) in try Self.table(module, language) {
                    #expect(
                        Self.placeholders(key) == Self.placeholders(value),
                        "\(module.lastPathComponent) \(language): \"\(value)\" does not match \"\(key)\"")
                }
            }
        }
    }

    @Test func placeholderMatchingIgnoresOrder() {
        #expect(Self.placeholders("%1$@ in %2$lld min") == Self.placeholders("%2$lld dk içinde %1$@"))
        #expect(Self.placeholders("%@ of %d") != Self.placeholders("%@"))
    }
}
