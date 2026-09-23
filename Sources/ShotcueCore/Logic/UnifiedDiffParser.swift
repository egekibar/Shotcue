import Foundation

/// Turns `git diff` output (tracked diff followed by `--no-index` diffs of untracked files, see `DiffText`)
/// into a `DiffDocument`. Tolerant: lines it does not understand are skipped, never fatal.
public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> DiffDocument {
        var state = State()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(DiffText.truncationMarker) {
                state.isTruncated = true
                break
            }
            if state.consumeHunkLine(line) { continue }
            state.consumeHeaderLine(line)
        }
        state.flushFile()
        return DiffDocument(files: state.files, isTruncated: state.isTruncated)
    }

    private struct State {
        var files: [DiffFile] = []
        var isTruncated = false
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldNumber = 0
        var newNumber = 0
        /// Lines still due on each side according to the hunk header; while either is positive every
        /// line belongs to the hunk, even one that looks like `--- x` or `diff --git`.
        var oldLeft = 0
        var newLeft = 0

        /// Returns false when the line is not part of the open hunk.
        mutating func consumeHunkLine(_ line: String) -> Bool {
            guard hunk != nil else { return false }
            if line.hasPrefix("\\") {
                hunk?.lines.append(DiffLine(kind: .noNewline, text: line, oldNumber: nil, newNumber: nil))
                return true
            }
            guard oldLeft > 0 || newLeft > 0 else { return false }
            let body = String(line.dropFirst())
            switch line.first {
            case "+":
                hunk?.lines.append(DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
                newLeft -= 1
            case "-":
                hunk?.lines.append(DiffLine(kind: .removed, text: body, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
                oldLeft -= 1
            case " ", nil:
                // An empty line is a context line whose trailing space something stripped.
                hunk?.lines.append(DiffLine(kind: .context, text: body, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            default:
                flushHunk()
                return false
            }
            return true
        }

        mutating func consumeHeaderLine(_ line: String) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                file = DiffFile(id: files.count, path: UnifiedDiffParser.gitHeaderPath(String(line.dropFirst(11))))
                return
            }
            guard file != nil else { return }
            if line.hasPrefix("@@ ") {
                flushHunk()
                guard let range = UnifiedDiffParser.hunkRange(line) else { return }
                hunk = DiffHunk(header: line)
                (oldNumber, oldLeft, newNumber, newLeft) = range
            } else if line.hasPrefix("new file mode") {
                file?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                file?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                file?.status = .renamed
                file?.oldPath = UnifiedDiffParser.unquoted(String(line.dropFirst(12)))
            } else if line.hasPrefix("rename to ") {
                file?.path = UnifiedDiffParser.unquoted(String(line.dropFirst(10)))
            } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                guard let path = UnifiedDiffParser.markerPath(String(line.dropFirst(4))) else { return }
                // `+++` names the file; `---` only matters when the new side is /dev/null (a deletion).
                if line.hasPrefix("+++ ") || file?.status == .deleted { file?.path = path }
            } else if line.hasPrefix("Binary files ") {
                file?.isBinary = true
            }
        }

        mutating func flushHunk() {
            if let hunk { file?.hunks.append(hunk) }
            hunk = nil
            oldLeft = 0
            newLeft = 0
        }

        mutating func flushFile() {
            flushHunk()
            if let file { files.append(file) }
            file = nil
        }
    }

    /// `@@ -a[,b] +c[,d] @@` → (old start, old count, new start, new count); a missing count is 1.
    static func hunkRange(_ line: String) -> (Int, Int, Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func side(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(numbers[0]) else { return nil }
            guard numbers.count > 1 else { return (start, 1) }
            guard let count = Int(numbers[1]) else { return nil }
            return (start, count)
        }
        guard let old = side(parts[1]), let new = side(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// The new path from `a/P b/P` (or its C-quoted form). Renames are corrected later by `rename to`.
    static func gitHeaderPath(_ rest: String) -> String {
        if rest.hasPrefix("\"") {
            let tokens = cQuotedTokens(rest)
            return dropSidePrefix(tokens.last ?? rest)
        }
        // Both sides are equal unless the file was renamed: "a/" + P + " b/" + P.
        let characters = Array(rest)
        if characters.count >= 4, (characters.count - 4) % 2 == 0 {
            let length = (characters.count - 4) / 2
            let first = String(characters[2..<(2 + length)])
            if rest == "a/\(first) b/\(first)" { return first }
        }
        if let range = rest.range(of: " b/") { return String(rest[range.upperBound...]) }
        return rest
    }

    /// The path of a `---`/`+++` line, nil for `/dev/null`. Git ends names containing spaces with a tab.
    static func markerPath(_ rest: String) -> String? {
        var value = rest
        if value.hasSuffix("\t") { value.removeLast() }
        value = unquoted(value)
        return value == "/dev/null" ? nil : dropSidePrefix(value)
    }

    static func dropSidePrefix(_ path: String) -> String {
        path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    /// Undoes git's C-quoting (`"say \"hi\".md"`), including `\ooo` octal bytes. Unquoted input is returned as is.
    static func unquoted(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return cQuotedTokens(value).first ?? value
    }

    /// Splits a line of C-quoted and bare space-separated tokens, decoding the quoted ones.
    static func cQuotedTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: " ") {
                index += 1
                continue
            }
            var token: [UInt8] = []
            if bytes[index] == UInt8(ascii: "\"") {
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count {
                        index += 1
                        let escaped = bytes[index]
                        if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(escaped), index + 2 < bytes.count,
                            let value = UInt8(String(decoding: bytes[index...(index + 2)], as: UTF8.self), radix: 8)
                        {
                            token.append(value)
                            index += 3
                            continue
                        }
                        switch escaped {
                        case UInt8(ascii: "n"): token.append(UInt8(ascii: "\n"))
                        case UInt8(ascii: "t"): token.append(UInt8(ascii: "\t"))
                        default: token.append(escaped)
                        }
                    } else {
                        token.append(bytes[index])
                    }
                    index += 1
                }
                index += 1
            } else {
                while index < bytes.count, bytes[index] != UInt8(ascii: " ") {
                    token.append(bytes[index])
                    index += 1
                }
            }
            tokens.append(String(decoding: token, as: UTF8.self))
        }
        return tokens
    }
}
