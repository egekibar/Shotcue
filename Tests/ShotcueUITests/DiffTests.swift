import AppKit
import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

extension AppServices {
    func withDiff(_ provider: (any DiffProvider)?) -> AppServices {
        AppServices(
            projects: projects, tasks: tasks, runs: runs, capture: capture, thumbnails: thumbnails,
            permissions: permissions, recorder: recorder, transcriber: transcriber,
            transcriptionQueue: transcriptionQueue, dispatcher: dispatcher, handoff: handoff,
            fileStore: fileStore, clock: clock, diff: provider)
    }
}

@Suite("Task diff")
struct TaskDiffTests {
    let head = "c42049d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7"

    @MainActor
    func fixture(diff: FakeDiffProvider?, gitHeadBefore: String?) async -> (TaskDetailStore, Run, Project, FakeBundle) {
        let project = Project(name: "crm", path: "/tmp/crm")
        let task = ShotTask(projectID: project.id, title: "t", status: .done)
        let run = Run(taskID: task.id, state: .succeeded, logRelPath: "runs/x.jsonl", gitHeadBefore: gitHeadBefore)
        let f = makeFakeServices(projects: [project], tasks: [task], runs: [run])
        let store = TaskDetailStore(services: f.services.withDiff(diff), taskID: task.id)
        await store.reload()
        return (store, run, project, f)
    }

    @MainActor
    @Test func showDiffLoadsTheRunsDiffIntoTheSheet() async {
        let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b"
        let fake = FakeDiffProvider(result: .success(patch))
        let (store, run, project, f) = await fixture(diff: fake, gitHeadBefore: head)
        defer { f.cleanUp() }
        #expect(store.canShowDiff(for: run))
        await store.showDiff(runID: run.id)
        #expect(store.diffText == patch)
        #expect(store.diffDocument?.files.map(\.path) == ["x"])
        #expect(store.diffDocument?.additions == 1)
        #expect(store.isDiffPresented)
        #expect(store.isLoadingDiff == false)
        #expect(fake.calls.current.first?.path == project.path)
        #expect(fake.calls.current.first?.since == head)
        #expect(fake.calls.current.first?.maxBytes == DiffText.defaultMaxBytes)
        store.closeDiff()
        #expect(store.isDiffPresented == false && store.diffText == nil && store.diffDocument == nil)
    }

    @MainActor
    @Test func diffNeedsAProviderAndARecordedHead() async {
        let (withoutProvider, run1, _, f1) = await fixture(diff: nil, gitHeadBefore: head)
        defer { f1.cleanUp() }
        #expect(withoutProvider.canShowDiff(for: run1) == false)
        let (withoutHead, run2, _, f2) = await fixture(diff: FakeDiffProvider(), gitHeadBefore: nil)
        defer { f2.cleanUp() }
        #expect(withoutHead.canShowDiff(for: run2) == false)
    }

    @MainActor
    @Test func aFailingDiffReportsAnError() async {
        let fake = FakeDiffProvider(result: .failure(FakeError("not a repo")))
        let (store, run, _, f) = await fixture(diff: fake, gitHeadBefore: head)
        defer { f.cleanUp() }
        await store.showDiff(runID: run.id)
        #expect(store.isDiffPresented == false)
        #expect(store.lastError?.hasPrefix("Diff alınamadı") == true)
        // A fixed Turkish explanation: no raw (English) error text reaches the UI.
        #expect(store.lastError == "Diff alınamadı: proje bir git deposu değil ya da git komutu başarısız oldu.")
    }

    @MainActor
    @Test func showDiffFlushesTheDraftsFirst() async throws {
        let (store, run, _, f) = await fixture(diff: FakeDiffProvider(), gitHeadBefore: head)
        defer { f.cleanUp() }
        store.editNote("diff'ten önce yazıldı")
        await store.showDiff(runID: run.id)
        #expect(try await f.tasks.task(id: run.taskID)?.noteText == "diff'ten önce yazıldı")
    }

    @MainActor
    @Test func diffSheetSelectsTheFirstFileAndSummarises() {
        let document = UnifiedDiffParser.parse(
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1,2 @@\n-x\n+y\n+z\n"
                + "diff --git a/b b/b\nnew file mode 100644\n")
        let sheet = DiffSheet(document: document, text: "raw", onClose: {})
        #expect(sheet.text == "raw")
        #expect(sheet.initialSelection == 0)
        #expect(sheet.summary == "2 dosya · +2 −1")
        #expect(DiffSheet(document: DiffDocument(), text: "", onClose: {}).initialSelection == nil)
    }

    @Test func rowsFlattenHunksWithHeadersAndSizeTheGutterToTheLargestNumber() throws {
        let file = try #require(
            UnifiedDiffParser.parse(
                "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -9 +9 @@\n-x\n+y\n@@ -120 +120 @@\n-p\n+q\n"
            ).files.first)
        let rows = DiffRows(file: file)
        #expect(rows.rows.count == 6)
        #expect(rows.rows.map(\.id) == Array(0..<6))
        if case .hunkHeader(let header) = rows.rows[3].content { #expect(header == "@@ -120 +120 @@") } else {
            Issue.record("expected a hunk header")
        }
        #expect(rows.gutterDigits == 3)
    }

    @MainActor
    @Test func copyAllPutsTheWholeTextOnThePasteboard() {
        // A private pasteboard: the test never presses the button, which writes to the general one.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shotcue-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(DiffSheet.copy("# git diff c42049d\n+x", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "# git diff c42049d\n+x")
    }
}
