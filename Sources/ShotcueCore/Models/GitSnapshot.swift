import Foundation

/// Working-tree state recorded before and after a run (spec §6.4 safety net).
public struct GitSnapshot: Hashable, Sendable, Codable {
    public var head: String
    public var isDirty: Bool
    public var branch: String?
    public init(head: String, isDirty: Bool, branch: String?) {
        self.head = head
        self.isDirty = isDirty
        self.branch = branch
    }
}

public enum GitOutputParser {
    /// Inputs are the raw stdout of `git rev-parse HEAD`, `git status --porcelain`, `git branch --show-current`.
    public static func snapshot(revParseHead: String, statusPorcelain: String, branchShowCurrent: String)
        -> GitSnapshot?
    {
        let head = revParseHead.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard head.count == 40, head.allSatisfy(\.isHexDigit) else { return nil }
        let dirty = !statusPorcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let branch = branchShowCurrent.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitSnapshot(head: head, isDirty: dirty, branch: branch.isEmpty ? nil : branch)
    }

    /// `shotcue/<first 8 of the task id>-<first 8 of the run id>`: one branch per run (final review I4), so running
    /// a task again never collides with the branch its previous run created.
    public static func branchName(taskID: UUID, runID: UUID) -> String {
        "shotcue/" + taskID.uuidString.lowercased().prefix(8) + "-" + runID.uuidString.lowercased().prefix(8)
    }
}
