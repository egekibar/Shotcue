import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// Review fix round 1, item 5: "Günlük kuyruğa al" in the inspector makes the task `ready` (it used to
/// call `unschedule()`, a no-op for inbox/failed/cancelled/done tasks).
@Suite("TaskDetailStore daily queue")
struct TaskDetailDailyQueueTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func started(_ status: TaskStatus, withProject: Bool = true)
        async -> (bundle: FakeBundle, store: TaskDetailStore, task: ShotTask)
    {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(
            projectID: withProject ? project.id : nil, title: "t", status: status,
            scheduledAt: status == .scheduled ? t0.addingTimeInterval(3600) : nil, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()
        return (bundle, store, task)
    }

    @MainActor
    @Test func tasksWithAReadyEdgeBecomeReady() async throws {
        for status in [TaskStatus.failed, .cancelled, .scheduled, .inbox] {
            let f = await started(status)
            #expect(f.store.canAddToDailyQueue, "\(status)")
            await f.store.addToDailyQueue()
            #expect(try await f.bundle.tasks.task(id: f.task.id)?.status == .ready, "\(status)")
            #expect(f.store.task?.status == .ready, "\(status)")
            #expect(f.store.lastError == nil, "\(status)")
            f.store.stop()
            f.bundle.cleanUp()
        }
    }

    @MainActor
    @Test func aQueuedTaskLeavesTheQueueThroughTheDispatcher() async throws {
        let f = await started(.queued)
        #expect(f.store.canAddToDailyQueue)
        await f.store.addToDailyQueue()
        #expect(f.bundle.dispatcher.cancelledTasks.current == [f.task.id])
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.status == .ready)
        #expect(f.store.lastError == nil)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func tasksWithoutAProjectOrAReadyEdgeAreRefusedWithAReason() async throws {
        let projectless = await started(.inbox, withProject: false)
        #expect(projectless.store.canAddToDailyQueue == false)
        await projectless.store.addToDailyQueue()
        #expect(projectless.store.lastError == "Günlük kuyruğa almak için önce bir proje seç.")
        #expect(try await projectless.bundle.tasks.task(id: projectless.task.id)?.status == .inbox)
        projectless.store.stop()
        projectless.bundle.cleanUp()

        let done = await started(.done)
        #expect(done.store.canAddToDailyQueue == false)
        await done.store.addToDailyQueue()
        #expect(done.store.lastError != nil)
        #expect(try await done.bundle.tasks.task(id: done.task.id)?.status == .done)
        done.store.stop()
        done.bundle.cleanUp()

        for status in [TaskStatus.ready, .running] {
            let f = await started(status)
            #expect(f.store.canAddToDailyQueue == false, "\(status)")
            f.store.stop()
            f.bundle.cleanUp()
        }
    }
}

/// Review fix round 1, item 7: captures and voice notes follow the task stream, and pending transcripts are
/// polled because GRDB's task observation does not see voice-note writes.
@Suite("TaskDetailStore fresh attachments")
struct TaskDetailFreshAttachmentsTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func bundleWithPendingNote() async throws -> (bundle: FakeBundle, task: ShotTask, note: VoiceNote) {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "t", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let note = VoiceNote(
            taskID: task.id, relPath: "audio/n.m4a", durationSec: 2, transcriptState: .pending, createdAt: t0)
        try await bundle.services.tasks.save(note)
        return (bundle, task, note)
    }

    @MainActor
    @Test func aTranscriptWrittenBehindTheStreamsBackIsPickedUpByThePoll() async throws {
        let f = try await bundleWithPendingNote()
        defer { f.bundle.cleanUp() }
        let store = TaskDetailStore(services: f.bundle.services, taskID: f.task.id)
        store.transcriptPollInterval = .milliseconds(20)
        await store.start()
        #expect(store.isPollingTranscripts)

        // Like GRDB: the transcript lands without the task stream noticing.
        var finished = f.note
        finished.transcript = "butonun rengi yanlış"
        finished.transcriptState = .done
        f.bundle.tasks.voiceStorage.withLock { $0[f.note.id] = finished }

        #expect(await waitUntil("polled") { store.voiceNotes.first?.transcript == "butonun rengi yanlış" })
        #expect(await waitUntil("poll ends") { !store.isPollingTranscripts })
        store.stop()
    }

    @MainActor
    @Test func stoppingTheStoreStopsThePoll() async throws {
        let f = try await bundleWithPendingNote()
        defer { f.bundle.cleanUp() }
        let store = TaskDetailStore(services: f.bundle.services, taskID: f.task.id)
        store.transcriptPollInterval = .milliseconds(20)
        await store.start()
        #expect(store.isPollingTranscripts)
        store.stop()
        #expect(store.isPollingTranscripts == false)
    }

    @MainActor
    @Test func capturesAndNotesFollowTheTaskStream() async throws {
        let f = try await bundleWithPendingNote()
        defer { f.bundle.cleanUp() }
        let store = TaskDetailStore(services: f.bundle.services, taskID: f.task.id)
        await store.start()
        #expect(store.captures.isEmpty)

        try await f.bundle.services.tasks.save(
            Capture(taskID: f.task.id, relPath: "captures/2026/09/b.png", width: 8, height: 8, createdAt: t0))
        #expect(await waitUntil("capture arrived") { store.captures.count == 1 })
        store.stop()
    }
}

/// Review fix round 1, item 6: the run log follows the selected run, survives the end of a live run, and a
/// slow replay of an earlier selection never overwrites a newer one.
@Suite("TaskDetailStore run log selection")
struct TaskDetailRunLogTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    static let initLine = #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-5"}"#
    static func textLine(_ text: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + text + #""}]}}"#
    }
    static let resultLine = #"{"type":"result","subtype":"success","is_error":false,"num_turns":3}"#

    @MainActor
    func started(_ status: TaskStatus) async -> (bundle: FakeBundle, store: TaskDetailStore, task: ShotTask) {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "t", status: status, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()
        return (bundle, store, task)
    }

    @MainActor
    @Test func theLogStaysVisibleWhenTheLiveRunEnds() async throws {
        let f = await started(.running)
        defer { f.bundle.cleanUp() }
        let run = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/live.jsonl")
        try await f.bundle.runs.save(run)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty })
        f.bundle.dispatcher.emit(runID: run.id, event: .assistantText("bir"))
        f.bundle.dispatcher.emit(runID: run.id, event: .assistantText("iki"))
        #expect(await waitUntil("streamed") { f.store.liveEvents.count == 3 })
        #expect(f.store.isDisplayingLiveRun)

        var ended = run
        ended.state = .succeeded
        ended.finishedAt = t0.addingTimeInterval(60)
        try await f.bundle.runs.save(ended)
        #expect(await waitUntil("ended") { f.store.activeRun == nil })

        #expect(f.store.selectedRunID == run.id)
        #expect(f.store.isDisplayingLiveRun == false)
        #expect(f.store.displayedEvents.count == 3)
        #expect(f.store.displayedEvents.last == .assistantText("iki"))
        f.store.stop()
    }

    @MainActor
    @Test func theEndedRunIsRefreshedFromItsCompleteLogFile() async throws {
        let f = await started(.running)
        defer { f.bundle.cleanUp() }
        let run = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/full.jsonl")
        try await f.bundle.runs.save(run)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty })
        try f.bundle.writeFile(
            "runs/full.jsonl",
            contents: [Self.initLine, Self.textLine("merhaba"), Self.resultLine].joined(separator: "\n"))

        var ended = run
        ended.state = .succeeded
        try await f.bundle.runs.save(ended)

        #expect(await waitUntil("replayed") { f.store.displayedEvents.count == 3 })
        #expect(f.store.displayedEvents.first == .initialized(sessionID: "s1", model: "claude-sonnet-5"))
        #expect(f.store.displayedEvents.count == 3 && f.store.displayedEvents[1] == .assistantText("merhaba"))
        f.store.stop()
    }

    @MainActor
    @Test func anOlderRunCanBeViewedDuringALiveRun() async throws {
        let f = await started(.running)
        defer { f.bundle.cleanUp() }
        try f.bundle.writeFile("runs/older.jsonl", contents: Self.textLine("eski"))
        let older = Run(
            taskID: f.task.id, state: .failed, startedAt: t0.addingTimeInterval(-3600),
            finishedAt: t0.addingTimeInterval(-3000), logRelPath: "runs/older.jsonl")
        let live = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/live.jsonl")
        try await f.bundle.runs.save(older)
        try await f.bundle.runs.save(live)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty && f.store.runs.count == 2 })
        #expect(f.store.selectedRunID == live.id)

        await f.store.selectRun(older.id)
        #expect(f.store.isDisplayingLiveRun == false)
        #expect(f.store.displayedEvents == [.assistantText("eski")])

        f.bundle.dispatcher.emit(runID: live.id, event: .assistantText("canlı"))
        #expect(await waitUntil("streamed") { f.store.liveEvents.count == 2 })
        #expect(f.store.displayedEvents == [.assistantText("eski")])

        await f.store.selectRun(live.id)
        #expect(f.store.isDisplayingLiveRun)
        #expect(f.store.displayedEvents == f.store.liveEvents)
        f.store.stop()
    }

    @MainActor
    @Test func aSlowReplayOfAnEarlierSelectionDoesNotWin() async throws {
        let f = await started(.done)
        defer { f.bundle.cleanUp() }
        try f.bundle.writeFile("runs/slow.jsonl", contents: Self.textLine("yavaş"))
        try f.bundle.writeFile("runs/fast.jsonl", contents: Self.textLine("hızlı"))
        let slowRun = Run(
            taskID: f.task.id, state: .succeeded, startedAt: t0.addingTimeInterval(-60),
            logRelPath: "runs/slow.jsonl")
        let fastRun = Run(taskID: f.task.id, state: .succeeded, startedAt: t0, logRelPath: "runs/fast.jsonl")
        try await f.bundle.runs.save(slowRun)
        try await f.bundle.runs.save(fastRun)
        #expect(await waitUntil("runs") { f.store.runs.count == 2 })

        let gate = Gate()
        f.store.logLineReader = { url in
            if url.lastPathComponent == "slow.jsonl" { await gate.wait() }
            return (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        }
        let slowSelection = Task { await f.store.selectRun(slowRun.id) }
        #expect(await waitUntil("slow replay parked") { gate.arrivals.current == 1 })
        await f.store.selectRun(fastRun.id)
        gate.open()
        await slowSelection.value

        #expect(f.store.selectedRunID == fastRun.id)
        #expect(f.store.displayedEvents == [.assistantText("hızlı")])
        f.store.stop()
    }
}

/// Review fix round 1, item 9: inspector text fields edit store-held drafts; nothing is saved or normalised
/// per keystroke, only on commit (submit / focus loss).
@Suite("TaskDetailStore drafts")
struct TaskDetailDraftTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func started(tasks: GatedTaskRepository? = nil) async throws
        -> (bundle: FakeBundle, store: TaskDetailStore, task: ShotTask, note: VoiceNote)
    {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Buton rengi", noteText: "kırmızı olmalı", status: .ready,
            createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        let note = VoiceNote(
            taskID: task.id, relPath: "audio/n.m4a", durationSec: 2, transcript: "eski metin",
            transcriptState: .done, createdAt: t0)
        try await bundle.services.tasks.save(note)
        let services = tasks.map { bundle.services.replacingTasks($0) } ?? bundle.services
        let store = TaskDetailStore(services: services, taskID: task.id)
        await store.start()
        return (bundle, store, task, note)
    }

    @MainActor
    @Test func typingKeepsTrailingSpacesUntilCommit() async throws {
        let f = try await started()
        defer { f.bundle.cleanUp() }
        f.store.editTitle("Buton ")
        #expect(f.store.titleDraft == "Buton ")
        #expect(f.store.task?.title == "Buton rengi")
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.title == "Buton rengi")

        await f.store.commit(.title)
        #expect(f.store.task?.title == "Buton")
        #expect(f.store.task?.titleEditedByUser == true)
        #expect(f.store.titleDraft == "Buton")
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.title == "Buton")
        f.store.stop()
    }

    @MainActor
    @Test func clearingAndTypingANewTitleWorks() async throws {
        let f = try await started()
        defer { f.bundle.cleanUp() }
        f.store.editTitle("")
        #expect(f.store.titleDraft == "")
        f.store.editTitle("Yeni başlık")
        #expect(f.store.titleDraft == "Yeni başlık")
        await f.store.commit(.title)
        let saved = try #require(try await f.bundle.tasks.task(id: f.task.id))
        #expect(saved.title == "Yeni başlık")
        #expect(saved.titleEditedByUser)
        f.store.stop()
    }

    @MainActor
    @Test func committingAnEmptyTitleHandsItBackToTheAutomaticTitle() async throws {
        let f = try await started()
        defer { f.bundle.cleanUp() }
        f.store.editTitle("   ")
        await f.store.commit(.title)
        #expect(f.store.task?.title == "kırmızı olmalı")
        #expect(f.store.task?.titleEditedByUser == false)
        #expect(f.store.titleDraft == "kırmızı olmalı")
        f.store.stop()
    }

    @MainActor
    @Test func incomingChangesNeverOverwriteAnUncommittedDraft() async throws {
        let f = try await started()
        defer { f.bundle.cleanUp() }
        f.store.editNote("yazıyorum")

        var elsewhere = f.task
        elsewhere.noteText = "başka yerden"
        elsewhere.title = "Başka başlık"
        try await f.bundle.services.tasks.save(elsewhere)
        #expect(await waitUntil("stream") { f.store.task?.title == "Başka başlık" })
        #expect(f.store.noteDraft == "yazıyorum")
        #expect(f.store.titleDraft == "Başka başlık")

        await f.store.commit(.note)
        #expect(try await f.bundle.tasks.task(id: f.task.id)?.noteText == "yazıyorum")
        #expect(f.store.noteDraft == "yazıyorum")
        f.store.stop()
    }

    @MainActor
    @Test func transcriptDraftsCommitPerVoiceNote() async throws {
        let f = try await started()
        defer { f.bundle.cleanUp() }
        #expect(f.store.transcriptDraft(for: f.note.id) == "eski metin")
        f.store.editTranscript(voiceNoteID: f.note.id, text: "yeni metin ")
        #expect(f.store.transcriptDraft(for: f.note.id) == "yeni metin ")
        #expect(try await f.bundle.tasks.voiceNotes(taskID: f.task.id).first?.transcript == "eski metin")

        await f.store.commit(.transcript(f.note.id))
        let saved = try #require(try await f.bundle.tasks.voiceNotes(taskID: f.task.id).first)
        #expect(saved.transcript == "yeni metin ")
        #expect(saved.editedByUser)
        f.store.stop()
    }

    @MainActor
    @Test func commitDraftsPersistsEveryPendingEdit() async throws {
        let f = try await started()
        defer { f.bundle.cleanUp() }
        f.store.editTitle("Başlık A")
        f.store.editNote("Not B")
        await f.store.commitDrafts()
        let saved = try #require(try await f.bundle.tasks.task(id: f.task.id))
        #expect(saved.title == "Başlık A")
        #expect(saved.noteText == "Not B")
        f.store.stop()
    }

    @MainActor
    @Test func theTaskIsUpdatedBeforePersistenceCompletes() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "t", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        defer { bundle.cleanUp() }
        let gate = Gate()
        let gated = GatedTaskRepository(base: bundle.tasks, saveGate: gate)
        let store = TaskDetailStore(services: bundle.services.replacingTasks(gated), taskID: task.id)
        await store.start()
        // The edit happens later than the row the stream is still delivering (as with a real clock), so
        // that stale initial emission must not roll the local change back.
        bundle.clock.advance(by: 1)

        let saving = Task { await store.updateNote("kaydediliyor") }
        #expect(await waitUntil("parked in save") { gate.arrivals.current == 1 })
        #expect(store.task?.noteText == "kaydediliyor")
        gate.open()
        await saving.value
        #expect(try await bundle.tasks.task(id: task.id)?.noteText == "kaydediliyor")
        store.stop()
    }
}
