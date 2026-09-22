import Foundation

/// Working-tree changes since a commit, for the Inspector's "Diff'i göster" (spec §6.4).
public protocol DiffProvider: Sendable {
    /// `git diff <since>` (against HEAD when `since` is nil) plus the untracked files in `path`,
    /// formatted by `DiffText.compose` and capped at `maxBytes`.
    func diff(at path: String, since: String?, maxBytes: Int) async throws -> String
}

public enum DiffText {
    public static let defaultMaxBytes = 1_000_000

    /// Untracked files first, then the tracked diff, so cutting a long diff at `maxBytes` never drops
    /// the list of files the run created.
    public static func compose(diff: String, untracked: [String], since: String?, maxBytes: Int) -> String {
        var lines: [String] = []
        if !untracked.isEmpty {
            lines.append("# İzlenmeyen dosyalar")
            lines.append(contentsOf: untracked.map { "?? \($0)" })
            lines.append("")
        }
        let base = since.map { String($0.prefix(7)) } ?? "HEAD"
        lines.append("# git diff \(base)")
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(trimmed.isEmpty ? "(izlenen dosyalarda değişiklik yok)" : diff.trimmingCharacters(in: .newlines))
        return truncated(lines.joined(separator: "\n"), maxBytes: maxBytes)
    }

    /// The paths of the `??` (untracked) lines of `git status --porcelain`, as git's display strings:
    /// names git quotes (spaces, quotes, control characters) stay C-quoted, e.g. `"a b.txt"`.
    public static func untrackedPaths(fromPorcelain porcelain: String) -> [String] {
        porcelain.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            line.hasPrefix("?? ") ? String(line.dropFirst(3)) : nil
        }
    }

    public static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let head = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        return head + "\n\n… (çıktı \(maxBytes) bayttan sonra kesildi)"
    }
}
