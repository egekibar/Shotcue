import Foundation
import ShotcueTestSupport
import Testing

@testable import ShotcueCore

@Suite("TestSupport fakes")
struct FakesTests {
    @Test func fakeRunnerReplaysEventsAndFillsSessionID() async throws {
        let runner = FakeClaudeRunner(events: [.assistantText("hi"), .toolUse(name: "Read", summary: "Read a.png")])
        let spec = RunSpec(runID: UUID(), prompt: "p", projectPath: "/tmp", mode: .implement)
        let received = Locked<[RunEvent]>([])
        let result = try await runner.run(spec) { event in received.withLock { $0.append(event) } }
        #expect(received.current == [.assistantText("hi"), .toolUse(name: "Read", summary: "Read a.png")])
        #expect(result.sessionID == spec.runID.uuidString)
        #expect(runner.specs.current.count == 1)
    }

    @Test func inMemoryTaskRepositorySearchesTranscripts() async throws {
        let repo = InMemoryTaskRepository()
        let t = ShotTask(projectID: UUID(), title: "Login", noteText: "buton", status: .ready)
        try await repo.save(t)
        try await repo.save(
            VoiceNote(taskID: t.id, relPath: "audio/a.m4a", durationSec: 2, transcript: "cache temizle"))
        #expect(try await repo.search("CACHE").map(\.id) == [t.id])
        #expect(try await repo.search("yok").isEmpty)
        #expect(try await repo.tasks(projectID: nil).isEmpty)
    }

    @Test func inMemoryTaskRepositoryObservesChanges() async throws {
        let repo = InMemoryTaskRepository()
        let stream = repo.observeAllTasks()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await repo.save(ShotTask(title: "x"))
        #expect(await iterator.next()?.count == 1)
    }

    @Test func runRepositoryMarksInterrupted() async throws {
        let repo = InMemoryRunRepository([
            Run(taskID: UUID(), state: .running, logRelPath: "runs/a.jsonl"),
            Run(taskID: UUID(), state: .succeeded, logRelPath: "runs/b.jsonl"),
        ])
        let now = Date()
        #expect(try await repo.markInterruptedRuns(at: now) == 1)
        #expect(try await repo.activeRuns().isEmpty)
    }

    @Test func permissionAndHotKeyFakes() async {
        let perms = FakePermissionService(grantOnRequest: false)
        #expect(await perms.request(.microphone) == .denied)
        #expect(await perms.state(of: .microphone) == .denied)
        let hotkey = FakeHotKeyService()
        let fired = Locked(0)
        try? hotkey.register(.defaultCombo) { fired.withLock { $0 += 1 } }
        hotkey.press()
        #expect(fired.current == 1 && hotkey.registered.current == KeyCombo.defaultCombo)
    }
}
