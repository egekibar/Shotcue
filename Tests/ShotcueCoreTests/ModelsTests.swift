import Foundation
import Testing

@testable import ShotcueCore

@Suite("Core models")
struct ModelsTests {
    @Test func dailyTimeParsesAndFormats() throws {
        let t = try #require(DailyTime(parsing: "09:05"))
        #expect(t.hour == 9 && t.minute == 5)
        #expect(t.formatted == "09:05")
        #expect(DailyTime(parsing: "25:00") == nil)
        #expect(DailyTime(parsing: "9") == nil)
    }

    @Test func projectDefaults() {
        let p = Project(name: "crm", path: "/tmp/crm")
        #expect(p.defaultMode == .implement)
        #expect(p.dailyEnabled == false && p.dailyTime == nil)
        #expect(p.runInBranch == false && p.stashBeforeRun == false)
    }

    @Test func shotTaskDefaultsToInboxWithoutProject() {
        let t = ShotTask(title: "x")
        #expect(t.status == .inbox)
        #expect(t.projectID == nil)
        #expect(t.mode == .implement)
        #expect(t.titleEditedByUser == false)
    }

    @Test func modelsRoundTripThroughJSON() throws {
        let now = Date(timeIntervalSince1970: 1_758_500_000)
        let task = ShotTask(
            id: UUID(), projectID: UUID(), title: "t", noteText: "n", status: .scheduled,
            mode: .analyze, modelOverride: "opus", sortIndex: 2048, scheduledAt: now,
            titleEditedByUser: true, createdAt: now, updatedAt: now)
        let run = Run(
            id: UUID(), taskID: task.id, state: .succeeded, startedAt: now, finishedAt: now,
            numTurns: 3, costUSD: 0.12, resultText: "ok", subtype: "success", exitCode: 0, error: nil,
            logRelPath: "runs/x.jsonl", gitHeadBefore: "abc", gitDirtyBefore: false,
            gitHeadAfter: "def", gitBranch: "main")
        let transcript = Transcript(
            text: "merhaba", language: "tr", engine: "whisperkit/turbo",
            segments: [.init(start: 0, end: 1.5, text: "merhaba", confidence: 0.9)])
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        #expect(try dec.decode(ShotTask.self, from: enc.encode(task)) == task)
        #expect(try dec.decode(Run.self, from: enc.encode(run)) == run)
        #expect(try dec.decode(Transcript.self, from: enc.encode(transcript)) == transcript)
    }

    @Test func statusAndModeRawValuesAreStable() {
        #expect(
            TaskStatus.allCases.map(\.rawValue) == [
                "inbox", "ready", "queued", "scheduled", "running", "done", "failed", "cancelled",
            ])
        #expect(TaskMode.allCases.map(\.rawValue) == ["analyze", "implement"])
        #expect(RunState.allCases.map(\.rawValue) == ["starting", "running", "succeeded", "failed", "cancelled"])
        #expect(TranscriptState.allCases.map(\.rawValue) == ["pending", "done", "failed"])
    }
}
