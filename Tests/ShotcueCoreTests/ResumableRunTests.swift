import Foundation
import Testing

@testable import ShotcueCore

/// Final review M4: "Terminalde devam et" / "Desktop'ta aç" resume the newest run that actually started claude. A run
/// refused or cancelled before launch has no session: `--resume` would answer "No conversation found".
@Suite("Resumable run")
struct ResumableRunTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    func store() throws -> FileStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-resume-\(UUID().uuidString)", isDirectory: true)
        let store = FileStore(rootURL: root)
        try store.ensureDirectories()
        return store
    }

    func run(_ state: RunState, at offset: TimeInterval, error: String? = nil, store: FileStore) -> Run {
        let id = UUID()
        return Run(
            id: id, taskID: UUID(), state: state, startedAt: t0.addingTimeInterval(offset),
            finishedAt: state == .running || state == .starting ? nil : t0.addingTimeInterval(offset + 5),
            error: error, logRelPath: store.runLogRelPath(id: id))
    }

    func writeLog(for run: Run, in store: FileStore, contents: String = "{\"type\":\"system\",\"subtype\":\"init\"}\n")
        throws
    {
        try store.ensureParentDirectory(for: run.logRelPath)
        try Data(contents.utf8).write(to: store.absoluteURL(for: run.logRelPath))
    }

    @Test func theNewestRunWithEventsWins() throws {
        let files = try store()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        let older = run(.succeeded, at: 0, store: files)
        let launchedThenFailed = run(.failed, at: 60, error: RunErrorCode.timeout, store: files)
        let refused = run(.failed, at: 120, error: RunErrorCode.voiceNotePending, store: files)
        try writeLog(for: older, in: files)
        try writeLog(for: launchedThenFailed, in: files)

        #expect(files.latestLaunchedRun(in: [older, refused, launchedThenFailed]) == launchedThenFailed)
    }

    @Test func runsThatNeverStartedClaudeAreSkipped() throws {
        let files = try store()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        let refused = run(.failed, at: 0, error: RunErrorCode.gitBranchFailed, store: files)
        let cancelledEarly = run(.cancelled, at: 10, error: RunErrorCode.cancelledBeforeLaunch, store: files)
        let starting = run(.starting, at: 20, store: files)
        let emptyLog = run(.failed, at: 30, error: RunErrorCode.claudeNotFound, store: files)
        try writeLog(for: emptyLog, in: files, contents: "")

        #expect(files.latestLaunchedRun(in: [refused, cancelledEarly, starting, emptyLog]) == nil)
        #expect(files.hasRunLog(refused) == false)
        #expect(files.hasRunLog(emptyLog) == false)
    }

    @Test func aRunInFlightCounts() throws {
        let files = try store()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        let live = run(.running, at: 0, store: files)
        #expect(files.latestLaunchedRun(in: [live]) == live)
    }
}
