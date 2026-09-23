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
        let fake = FakeDiffProvider(result: .success("# git diff c42049d\n+x"))
        let (store, run, project, f) = await fixture(diff: fake, gitHeadBefore: head)
        defer { f.cleanUp() }
        #expect(store.canShowDiff(for: run))
        await store.showDiff(runID: run.id)
        #expect(store.diffText == "# git diff c42049d\n+x")
        #expect(store.isDiffPresented)
        #expect(store.isLoadingDiff == false)
        #expect(fake.calls.current.first?.path == project.path)
        #expect(fake.calls.current.first?.since == head)
        #expect(fake.calls.current.first?.maxBytes == DiffText.defaultMaxBytes)
        store.closeDiff()
        #expect(store.isDiffPresented == false && store.diffText == nil)
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
    @Test func diffSheetKeepsItsInputs() {
        let sheet = DiffSheet(text: "+x", onClose: {})
        #expect(sheet.text == "+x")
        // Rendered one row per line: a single Text holding up to 1 MB would freeze layout.
        #expect(DiffSheet(text: "a\n+b\n\n-c", onClose: {}).lines == ["a", "+b", "", "-c"])
        #expect(DiffSheet(text: "", onClose: {}).lines == ["Değişiklik yok."])
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
