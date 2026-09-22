import ShotcueTestSupport
import Testing

@testable import ShotcueCore

@Suite("DiffText")
struct DiffTextTests {
    @Test func composesTrackedDiffAndUntrackedFiles() {
        let text = DiffText.compose(
            diff: "diff --git a/a.swift b/a.swift\n+yeni satır\n",
            untracked: ["new.txt", "docs/x.md"],
            since: "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7", maxBytes: 10_000)
        #expect(text.hasPrefix("# git diff c42049d\n"))
        #expect(text.contains("+yeni satır"))
        #expect(text.contains("# İzlenmeyen dosyalar\n?? new.txt\n?? docs/x.md"))
    }

    @Test func emptyDiffSaysSoAndHeadIsTheDefaultBase() {
        let text = DiffText.compose(diff: "  \n", untracked: [], since: nil, maxBytes: 10_000)
        #expect(text.hasPrefix("# git diff HEAD\n"))
        #expect(text.contains("(izlenen dosyalarda değişiklik yok)"))
        #expect(!text.contains("İzlenmeyen"))
    }

    @Test func truncatesLongOutputWithANotice() {
        let long = String(repeating: "x", count: 500)
        let text = DiffText.compose(diff: long, untracked: [], since: nil, maxBytes: 100)
        #expect(text.utf8.count < 200)
        #expect(text.hasSuffix("… (çıktı 100 bayttan sonra kesildi)"))
        #expect(DiffText.truncated("kısa", maxBytes: 100) == "kısa")
    }

    @Test func parsesUntrackedPathsFromPorcelain() {
        let porcelain = " M a.swift\n?? new.txt\nA  b.swift\n?? dir/c.md\n"
        #expect(DiffText.untrackedPaths(fromPorcelain: porcelain) == ["new.txt", "dir/c.md"])
    }

    @Test func fakeProviderRecordsCallsAndReturnsItsResult() async throws {
        let fake = FakeDiffProvider(result: .success("patch"))
        #expect(try await fake.diff(at: "/tmp/p", since: "abc", maxBytes: 7) == "patch")
        #expect(fake.calls.current.count == 1)
        #expect(fake.calls.current.first?.path == "/tmp/p")
        #expect(fake.calls.current.first?.since == "abc")
        #expect(fake.calls.current.first?.maxBytes == 7)
        fake.result.set(.failure(FakeError("boom")))
        await #expect(throws: FakeError.self) { try await fake.diff(at: "/tmp/p", since: nil, maxBytes: 7) }
    }
}
