import ShotcueTestSupport
import Testing

@testable import ShotcueCore

@Suite("DiffText")
struct DiffTextTests {
    @Test func composesTheTrackedDiffThenEachUntrackedFile() {
        let text = DiffText.compose(
            tracked: "diff --git a/a.swift b/a.swift\n+yeni satır\n",
            untracked: ["diff --git a/new.txt b/new.txt\n+x\n", "", "diff --git a/y b/y\n"],
            maxBytes: 10_000)
        #expect(
            text == "diff --git a/a.swift b/a.swift\n+yeni satır\n"
                + "diff --git a/new.txt b/new.txt\n+x\ndiff --git a/y b/y")
    }

    @Test func emptyWhenNothingChanged() {
        #expect(DiffText.compose(tracked: "  \n", untracked: [], maxBytes: 10_000) == "")
    }

    @Test func truncatesAtALineBoundaryWithANoticeOnItsOwnLine() {
        let long = String(repeating: "+line\n", count: 100)
        let text = DiffText.compose(tracked: long, untracked: [], maxBytes: 20)
        #expect(text == "+line\n+line\n+line\n" + DiffText.truncationNotice(maxBytes: 20))
        #expect(DiffText.truncationNotice(maxBytes: 20) == "… (çıktı 20 bayttan sonra kesildi)")
        #expect(DiffText.truncated("kısa", maxBytes: 100) == "kısa")
    }

    @Test func parsesNulSeparatedPathsVerbatim() {
        let output = "new.txt\0a b.txt\0say \"hi\".md\0özet.md\0"
        #expect(DiffText.paths(fromNulSeparated: output) == ["new.txt", "a b.txt", "say \"hi\".md", "özet.md"])
        #expect(DiffText.paths(fromNulSeparated: "").isEmpty)
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
