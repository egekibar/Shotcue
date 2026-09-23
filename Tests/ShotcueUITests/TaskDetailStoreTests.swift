import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

@Suite("TaskDetailStore")
struct TaskDetailStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    func fixture(status: TaskStatus = .ready, titleEdited: Bool = false)
        async throws -> (bundle: FakeBundle, store: TaskDetailStore, task: ShotTask, project: Project)
    {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(
            projectID: project.id, title: "Buton rengi", noteText: "kırmızı olmalı",
            status: status, mode: .implement, sortIndex: 1024,
            titleEditedByUser: titleEdited, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(projects: [project], tasks: [task], clock: MutableClock(t0))
        try await bundle.services.tasks.save(
            Capture(
                taskID: task.id, relPath: "captures/2026/09/a.png",
                thumbRelPath: "thumbs/a.jpg", width: 800, height: 600, createdAt: t0))
        try await bundle.services.tasks.save(
            VoiceNote(
                taskID: task.id, relPath: "audio/a.m4a", durationSec: 4.2,
                transcript: "butonun rengi mavi olmuş", transcriptState: .done, createdAt: t0))
        let store = TaskDetailStore(services: bundle.services, taskID: task.id)
        await store.start()
        return (bundle, store, task, project)
    }

    @MainActor
    @Test func startLoadsEverything() async throws {
        let f = try await fixture()
        #expect(f.store.task?.id == f.task.id)
        #expect(f.store.captures.count == 1)
        #expect(f.store.voiceNotes.count == 1)
        #expect(f.store.projects.count == 1)
        #expect(f.store.project?.path == "/tmp/acme-web")
        #expect(f.store.runs.isEmpty)
        #expect(f.store.isEditable == true)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func noteUpdateAlsoRefreshesTheAutomaticTitle() async throws {
        let f = try await fixture()
        await f.store.updateNote("Hizalama bozuk. Ayrıca renk yanlış.")
        #expect(f.store.task?.noteText == "Hizalama bozuk. Ayrıca renk yanlış.")
        #expect(f.store.task?.title == "Hizalama bozuk")
        #expect(f.store.task?.titleEditedByUser == false)
        #expect(f.store.task?.updatedAt == t0)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func aUserEditedTitleIsNeverOverwritten() async throws {
        let f = try await fixture()
        await f.store.updateTitle("Checkout hitbox")
        #expect(f.store.task?.title == "Checkout hitbox")
        #expect(f.store.task?.titleEditedByUser == true)

        await f.store.updateNote("Tamamen başka bir şey yazdım.")
        #expect(f.store.task?.title == "Checkout hitbox")

        // Clearing the field hands control back to TitleMaker.
        await f.store.updateTitle("   ")
        #expect(f.store.task?.titleEditedByUser == false)
        #expect(f.store.task?.title == "Tamamen başka bir şey yazdım")
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func transcriptEditMarksEditedByUser() async throws {
        let f = try await fixture()
        let noteID = try #require(f.store.voiceNotes.first?.id)
        await f.store.updateTranscript(voiceNoteID: noteID, text: "butonun hitbox'ı 4 px kayıyor")

        let saved = try #require(try await f.bundle.services.tasks.voiceNotes(taskID: f.task.id).first)
        #expect(saved.transcript == "butonun hitbox'ı 4 px kayıyor")
        #expect(saved.editedByUser == true)
        #expect(saved.transcriptState == .done)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func modeModelAndProjectEdits() async throws {
        let f = try await fixture()
        await f.store.setMode(.analyze)
        #expect(f.store.task?.mode == .analyze)
        await f.store.setModelOverride("opus")
        #expect(f.store.task?.modelOverride == "opus")
        await f.store.setModelOverride(nil)
        #expect(f.store.task?.modelOverride == nil)

        await f.store.setProject(nil)
        #expect(f.store.task?.projectID == nil)
        #expect(f.store.task?.status == .inbox)
        await f.store.setProject(f.project.id)
        #expect(f.store.task?.projectID == f.project.id)
        #expect(f.store.task?.status == .ready)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func sendScheduleUnscheduleAndRetry() async throws {
        let f = try await fixture()
        await f.store.sendNow()
        #expect(f.bundle.dispatcher.enqueued.current == [f.task.id])

        let when = t0.addingTimeInterval(3600)
        await f.store.schedule(at: when)
        #expect(f.store.task?.status == .scheduled)
        #expect(f.store.task?.scheduledAt == when)

        await f.store.unschedule()
        #expect(f.store.task?.status == .ready)
        #expect(f.store.task?.scheduledAt == nil)

        await f.store.cancel()
        #expect(f.bundle.dispatcher.cancelledTasks.current == [f.task.id])

        await f.store.retry()
        #expect(f.bundle.dispatcher.enqueued.current == [f.task.id, f.task.id])
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func runningTasksAreNotEditableButCanBeCancelled() async throws {
        let f = try await fixture(status: .running)
        #expect(f.store.isEditable == false)
        #expect(f.store.canCancel == true)
        #expect(f.store.canSend == false)
        await f.store.updateNote("değişmemeli")
        #expect(f.store.task?.noteText == "kırmızı olmalı")
        f.store.stop()
        f.bundle.cleanUp()
    }

    /// Final review I3: the schedule controls follow the status. A failed task that kept an old date (a row written
    /// before the fix) offers "Tarih seç…" again instead of a date and a "Kaldır" that does nothing.
    @MainActor
    @Test func theScheduleControlsFollowTheStatusNotTheDate() async throws {
        let f = try await fixture(status: .failed)
        var stale = try #require(try await f.bundle.services.tasks.task(id: f.task.id))
        stale.scheduledAt = t0.addingTimeInterval(-3600)
        try await f.bundle.services.tasks.save(stale)
        await f.store.reload()
        #expect(f.store.scheduledFor == nil)

        let when = t0.addingTimeInterval(7200)
        await f.store.schedule(at: when)
        #expect(f.store.task?.status == .scheduled)
        #expect(f.store.scheduledFor == when)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func handoffUsesTheLatestRunIdAsTheSessionId() async throws {
        let f = try await fixture(status: .done)
        let run = Run(
            taskID: f.task.id, state: .succeeded, startedAt: t0,
            finishedAt: t0.addingTimeInterval(84), numTurns: 11, costUSD: 0.4137,
            resultText: "Fixed the button color.", subtype: "success",
            logRelPath: "runs/\(UUID().uuidString.lowercased()).jsonl")
        // claude wrote events for it: the run started a session (final review M4).
        try f.bundle.writeFile(run.logRelPath, contents: "{\"type\":\"system\",\"subtype\":\"init\"}\n")
        try await f.bundle.services.runs.save(run)
        _ = await waitUntil("runs") { f.store.runs.count == 1 }

        #expect(f.store.sessionID == run.id.uuidString)
        await f.store.openInTerminal()
        await f.store.openInDesktop()
        #expect(
            f.bundle.handoff.actions.current == [
                // Final review M6: Terminal resumes from the project folder.
                "terminal:\(run.id.uuidString)@/tmp/acme-web",
                "desktop:\(run.id.uuidString)",
            ])

        await f.store.openComposer()
        #expect(f.bundle.handoff.actions.current.last == "composer:/tmp/acme-web:1")
        f.store.stop()
        f.bundle.cleanUp()
    }

    /// Final review M4: resume opens the newest run that actually started claude; a newer run refused before
    /// launch (C1, I4) has no session and is skipped.
    @MainActor
    @Test func resumeSkipsRunsThatNeverStartedClaude() async throws {
        let f = try await fixture(status: .ready)
        let launched = Run(
            taskID: f.task.id, state: .succeeded, startedAt: t0, finishedAt: t0.addingTimeInterval(30),
            logRelPath: "runs/\(UUID().uuidString.lowercased()).jsonl")
        try f.bundle.writeFile(launched.logRelPath, contents: "{\"type\":\"system\",\"subtype\":\"init\"}\n")
        let refused = Run(
            taskID: f.task.id, state: .failed, startedAt: t0.addingTimeInterval(60),
            finishedAt: t0.addingTimeInterval(60), error: RunErrorCode.voiceNotePending,
            logRelPath: "runs/\(UUID().uuidString.lowercased()).jsonl")
        try await f.bundle.services.runs.save(launched)
        try await f.bundle.services.runs.save(refused)
        _ = await waitUntil("runs") { f.store.runs.count == 2 }

        #expect(f.store.latestRun?.id == refused.id)
        #expect(f.store.sessionID == launched.id.uuidString)
        await f.store.openInTerminal()
        #expect(f.bundle.handoff.actions.current.first?.hasPrefix("terminal:\(launched.id.uuidString)") == true)
        f.store.stop()
        f.bundle.cleanUp()
    }

    /// Final review M6: without a project there is no folder to resume the session from.
    @MainActor
    @Test func terminalResumeNeedsTheTasksProjectFolder() async throws {
        let f = try await fixture(status: .done)
        let run = Run(
            taskID: f.task.id, state: .succeeded, startedAt: t0, finishedAt: t0.addingTimeInterval(30),
            logRelPath: "runs/\(UUID().uuidString.lowercased()).jsonl")
        try f.bundle.writeFile(run.logRelPath, contents: "{\"type\":\"system\",\"subtype\":\"init\"}\n")
        try await f.bundle.services.runs.save(run)
        _ = await waitUntil("runs") { f.store.runs.count == 1 }
        await f.store.setProject(nil)
        _ = await waitUntil("detached") { f.store.task?.projectID == nil }

        await f.store.openInTerminal()
        #expect(f.bundle.handoff.actions.current.isEmpty)
        #expect(f.store.lastError?.contains("proje klasöründen") == true)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func resumeIsOffWhenNoRunStartedClaude() async throws {
        let f = try await fixture(status: .ready)
        let refused = Run(
            taskID: f.task.id, state: .failed, startedAt: t0, finishedAt: t0,
            error: RunErrorCode.gitBranchFailed, logRelPath: "runs/\(UUID().uuidString.lowercased()).jsonl")
        try await f.bundle.services.runs.save(refused)
        _ = await waitUntil("runs") { f.store.runs.count == 1 }

        #expect(f.store.sessionID == nil)
        await f.store.openInTerminal()
        await f.store.openInDesktop()
        #expect(f.bundle.handoff.actions.current.isEmpty)
        #expect(f.store.lastError == "Devam ettirilecek bir oturum yok.")
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func composerPromptCarriesScreenshotsNoteAndTranscript() async throws {
        let f = try await fixture()
        let prompt = f.store.composerPrompt()
        #expect(prompt.hasPrefix("TASK TYPE: IMPLEMENT"))
        #expect(prompt.contains("TITLE: Buton rengi"))
        #expect(prompt.contains("captures/2026/09/a.png"))
        #expect(prompt.contains("NOTE (written by the user):\nkırmızı olmalı"))
        #expect(prompt.contains("butonun rengi mavi olmuş"))
        #expect(prompt.contains("PROJECT: /tmp/acme-web"))
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func liveEventsArriveFromTheDispatcher() async throws {
        let f = try await fixture(status: .running)
        let run = Run(taskID: f.task.id, state: .running, startedAt: t0, logRelPath: "runs/live.jsonl")
        try await f.bundle.services.runs.save(run)
        #expect(await waitUntil("subscribed") { !f.store.liveEvents.isEmpty })
        // FakeTaskDispatcher yields `.other(type: "subscribed")` to every new subscriber first.
        #expect(f.store.liveEvents.first == .other(type: "subscribed"))

        f.bundle.dispatcher.emit(runID: run.id, event: .assistantText("Reading the screenshot first."))
        f.bundle.dispatcher.emit(runID: run.id, event: .toolUse(name: "Read", summary: "Read a.png"))
        #expect(await waitUntil("events") { f.store.liveEvents.count == 3 })
        #expect(f.store.liveEvents[1] == .assistantText("Reading the screenshot first."))
        #expect(f.store.liveEvents[2] == .toolUse(name: "Read", summary: "Read a.png"))
        #expect(f.store.activeRun?.id == run.id)
        #expect(f.store.displayedEvents.count == 3)
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func selectingAFinishedRunReplaysItsLogFile() async throws {
        let f = try await fixture(status: .done)
        let logRel = "runs/replay.jsonl"
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-5"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"merhaba"}]}}"#,
            "bozuk satır",
            #"{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.12}"#,
        ]
        try f.bundle.writeFile(logRel, contents: lines.joined(separator: "\n"))
        let run = Run(taskID: f.task.id, state: .succeeded, startedAt: t0, logRelPath: logRel)
        try await f.bundle.services.runs.save(run)
        _ = await waitUntil("runs") { f.store.runs.count == 1 }

        await f.store.selectRun(run.id)
        #expect(f.store.selectedRunEvents.count == 3)
        #expect(f.store.selectedRunEvents.first == .initialized(sessionID: "s1", model: "claude-sonnet-5"))
        #expect(f.store.selectedRunEvents[1] == .assistantText("merhaba"))
        if case .result(let result) = f.store.selectedRunEvents[2] {
            #expect(result.isSuccess)
            #expect(result.numTurns == 3)
        } else {
            Issue.record("last replayed event must be a result")
        }
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func retranscribeResetsTheNoteAndEnqueuesIt() async throws {
        let f = try await fixture()
        let noteID = try #require(f.store.voiceNotes.first?.id)
        await f.store.retranscribe(voiceNoteID: noteID)
        let saved = try #require(try await f.bundle.services.tasks.voiceNotes(taskID: f.task.id).first)
        #expect(saved.transcriptState == .pending)
        #expect(saved.editedByUser == false)
        #expect(f.bundle.transcriptionQueue.enqueued.current == [noteID])
        f.store.stop()
        f.bundle.cleanUp()
    }

    @MainActor
    @Test func copyImageAndRevealDoNotCrashOnMissingFiles() async throws {
        let f = try await fixture()
        let captureID = try #require(f.store.captures.first?.id)
        // No PNG on disk: copy must report failure rather than trap. (It returns before touching the
        // pasteboard, so this never writes to NSPasteboard.general.)
        #expect(f.store.copyImage(captureID: captureID) == false)
        // Only the unknown-id path is exercised: revealing a known capture would reach
        // NSWorkspace.activateFileViewerSelecting and open Finder, which tests must never do.
        // The happy paths of copyImage/revealInFinder are manual checks in Plan 06.
        f.store.revealInFinder(captureID: UUID())
        f.store.stop()
        f.bundle.cleanUp()
    }
}
