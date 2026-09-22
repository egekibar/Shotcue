import Foundation
import Testing

@testable import ShotcueCore

@Suite("GitOutputParser")
struct GitOutputParserTests {
    let sha = "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"

    @Test func cleanRepoOnBranch() {
        let s = GitOutputParser.snapshot(revParseHead: sha + "\n", statusPorcelain: "", branchShowCurrent: "main\n")
        #expect(s == GitSnapshot(head: sha, isDirty: false, branch: "main"))
    }

    @Test func dirtyAndDetached() {
        let s = GitOutputParser.snapshot(
            revParseHead: sha.uppercased(), statusPorcelain: " M a.swift\n?? b\n", branchShowCurrent: "")
        #expect(s?.isDirty == true)
        #expect(s?.branch == nil)
        #expect(s?.head == sha)
    }

    @Test func invalidHeadReturnsNil() {
        #expect(
            GitOutputParser.snapshot(
                revParseHead: "fatal: not a git repository", statusPorcelain: "", branchShowCurrent: "") == nil)
        #expect(GitOutputParser.snapshot(revParseHead: "", statusPorcelain: "", branchShowCurrent: "") == nil)
    }

    @Test func branchNameUsesShortTaskID() {
        let id = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!
        #expect(GitOutputParser.branchName(for: id) == "shotcue/3f2a9c40")
    }
}
