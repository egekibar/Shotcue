import Foundation

/// A run's diff split into files, hunks and numbered lines, for the comparison screen (spec §6.4).
public struct DiffDocument: Equatable, Sendable {
    public var files: [DiffFile]
    /// The output hit `DiffText.defaultMaxBytes`: the last file may be cut short and later ones are missing.
    public var isTruncated: Bool

    public init(files: [DiffFile] = [], isTruncated: Bool = false) {
        self.files = files
        self.isTruncated = isTruncated
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct DiffFile: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case added, modified, deleted, renamed
    }

    /// Position in the document; paths are not a safe identity across the tracked and untracked parts.
    public var id: Int
    /// The new path (the old one for a deleted file).
    public var path: String
    /// Set for renames only.
    public var oldPath: String?
    public var status: Status
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public init(
        id: Int, path: String, oldPath: String? = nil, status: Status = .modified, isBinary: Bool = false,
        hunks: [DiffHunk] = []
    ) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }

    public var fileName: String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    /// The file's hunks as a patch fragment, for "Dosyayı kopyala". Without hunks (binary, empty, pure
    /// rename) it is just the two marker lines.
    public var patchText: String {
        var lines = [
            "--- " + (status == .added ? "/dev/null" : "a/\(oldPath ?? path)"),
            "+++ " + (status == .deleted ? "/dev/null" : "b/\(path)"),
        ]
        for hunk in hunks {
            lines.append(hunk.header)
            lines.append(contentsOf: hunk.lines.map(\.patchLine))
        }
        return lines.joined(separator: "\n")
    }

    /// Everything before the last `/`, empty at the repository root.
    public var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

public struct DiffHunk: Equatable, Sendable {
    /// The `@@ -a,b +c,d @@ context` line as git printed it.
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine] = []) {
        self.header = header
        self.lines = lines
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context, added, removed
        /// `\ No newline at end of file`: belongs to the line above it and has no number.
        case noNewline
    }

    public var kind: Kind
    /// The line without its one-character `+`/`-`/space prefix (the marker keeps its text whole).
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    /// The line as it appears in a patch, prefix included.
    public var patchLine: String {
        switch kind {
        case .context: " " + text
        case .added: "+" + text
        case .removed: "-" + text
        case .noNewline: text
        }
    }

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}
