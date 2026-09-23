import Foundation

/// Working-tree changes since a commit, for the Inspector's "Diff'i göster" (spec §6.4).
public protocol DiffProvider: Sendable {
    /// Unified `git diff <since>` (against HEAD when `since` is nil) followed by a `--no-index` diff of every
    /// untracked file in `path`, joined by `DiffText.compose` and capped at `maxBytes`.
    /// `UnifiedDiffParser` turns it into a `DiffDocument`; the raw text stays copyable as a patch.
    func diff(at path: String, since: String?, maxBytes: Int) async throws -> String
}

public enum DiffText {
    public static let defaultMaxBytes = 1_000_000
    /// Start of the line `truncated` appends; the parser stops there.
    public static let truncationMarker = "… (çıktı "

    public static func truncationNotice(maxBytes: Int) -> String {
        "\(truncationMarker)\(maxBytes) bayttan sonra kesildi)"
    }

    /// The tracked diff, then each untracked file's diff, as one patch. Empty when nothing changed.
    public static func compose(tracked: String, untracked: [String], maxBytes: Int) -> String {
        let parts = ([tracked] + untracked)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return truncated(parts.joined(separator: "\n"), maxBytes: maxBytes)
    }

    /// Paths from a `-z` listing (`git ls-files -z`), exactly as stored: no C-quoting to undo.
    public static func paths(fromNulSeparated output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Cuts `text` at the last whole line within `maxBytes` and adds the truncation notice on its own line,
    /// so the parser never sees half a line.
    public static func truncated(_ text: String, maxBytes: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxBytes else { return text }
        var head = Array(utf8.prefix(maxBytes))
        if let newline = head.lastIndex(of: UInt8(ascii: "\n")) {
            head.removeSubrange((newline + 1)...)
        } else {
            head.removeAll()
        }
        return String(decoding: head, as: UTF8.self) + truncationNotice(maxBytes: maxBytes)
    }
}
