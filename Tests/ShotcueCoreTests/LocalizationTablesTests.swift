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

    @Test func theUIModuleIsLocalized() throws {
        let ui = try #require(Self.localizedModules.first { $0.lastPathComponent == "ShotcueUI" })
        // The source scan finds the calls, so `everyKeyUsedInTheSourcesIsInTheTable` checks something.
        #expect(Self.usedKeys(in: ui).count > 50)
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

    /// Every `L10n.t("…")` in a module's sources has an entry in its English table. Interpolations are compared as
    /// wildcards (`\(count)` against `%lld`), since their types are only known to the compiler.
    @Test func everyKeyUsedInTheSourcesIsInTheTable() throws {
        for module in Self.localizedModules {
            let keys = Set(try Self.table(module, "en").keys.map(Self.wildcardKey(table:)))
            for (file, key) in Self.usedKeys(in: module) {
                #expect(keys.contains(Self.wildcardKey(source: key)), "\(file): \"\(key)\" is not in the table")
            }
        }
    }

    /// `L10n.t("…")` literals in a module's Swift files (not in `L10n.swift`, whose doc comment shows examples).
    static func usedKeys(in module: URL) -> [(file: String, key: String)] {
        let files = FileManager.default.enumerator(at: module, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "L10n.swift" } ?? []
        return files.flatMap { file -> [(file: String, key: String)] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return literals(after: "L10n.t(", in: text).map { (file.lastPathComponent, $0) }
        }
    }

    /// The string literal right after each `marker`, as written in the source (escapes and `\(…)` kept), with
    /// interpolations' parentheses balanced however deep they nest.
    static func literals(after marker: String, in text: String) -> [String] {
        var result: [String] = []
        var rest = text[...]
        while let found = rest.range(of: marker) {
            var index = found.upperBound
            while index < rest.endIndex, rest[index].isWhitespace { index = rest.index(after: index) }
            guard index < rest.endIndex, rest[index] == "\"" else {
                rest = rest[found.upperBound...]
                continue
            }
            index = rest.index(after: index)
            let start = index
            var depth = 0
            while index < rest.endIndex {
                let character = rest[index]
                if depth == 0 && character == "\"" { break }
                if character == "\\" {
                    let next = rest.index(after: index)
                    if next < rest.endIndex, rest[next] == "(" { depth += 1 }
                    index = rest.index(after: next)
                    continue
                }
                if depth > 0 && character == "(" { depth += 1 }
                if depth > 0 && character == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            result.append(String(rest[start..<index]))
            rest = rest[min(index, rest.endIndex)...]
        }
        return result
    }

    /// `\(…)` (balanced) becomes `•`; `\"` and `\\` become what they stand for.
    static func wildcardKey(source: String) -> String {
        var output = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            guard character == "\\", next < source.endIndex else {
                output.append(character)
                index = next
                continue
            }
            if source[next] == "(" {
                var depth = 1
                var cursor = source.index(after: next)
                while cursor < source.endIndex, depth > 0 {
                    if source[cursor] == "(" { depth += 1 }
                    if source[cursor] == ")" { depth -= 1 }
                    cursor = source.index(after: cursor)
                }
                output.append("•")
                index = cursor
            } else {
                output.append(source[next])
                index = source.index(after: next)
            }
        }
        return output
    }

    static func wildcardKey(table: String) -> String {
        table.replacing(/%(\d+\$)?[-+ #0]*\d*(\.\d+)?(hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]/, with: "•")
            .replacing("%%", with: "%")
    }

    @Test func wildcardKeysMatchAcrossSourceAndTable() {
        #expect(Self.wildcardKey(source: #"Downloading… \(Int((p * 100).rounded()))%"#) == "Downloading… •%")
        #expect(Self.wildcardKey(table: "Downloading… %lld%%") == "Downloading… •%")
        #expect(Self.wildcardKey(source: #"Error: \(message)"#) == Self.wildcardKey(table: "Error: %@"))
    }

    @Test func placeholderMatchingIgnoresOrder() {
        #expect(Self.placeholders("%1$@ in %2$lld min") == Self.placeholders("%2$lld dk içinde %1$@"))
        #expect(Self.placeholders("%@ of %d") != Self.placeholders("%@"))
    }
}
