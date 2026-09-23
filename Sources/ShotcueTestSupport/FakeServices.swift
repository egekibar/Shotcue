import Foundation
import ShotcueCore

public final class FakeCaptureService: CaptureService, @unchecked Sendable {
    public enum Behavior: Sendable {
        case success(width: Int, height: Int, scale: Double)
        case cancel
        case failure(String)
    }
    public let behavior: Locked<Behavior>
    public let calls = Locked<[URL]>([])
    public init(behavior: Behavior = .success(width: 128, height: 64, scale: 2)) { self.behavior = Locked(behavior) }
    public func captureRegion(to destination: URL) async throws -> CaptureResult? {
        calls.withLock { $0.append(destination) }
        switch behavior.current {
        case .cancel: return nil
        case .failure(let message): throw FakeError(message)
        case .success(let w, let h, let s):
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: destination)
            return CaptureResult(fileURL: destination, width: w, height: h, scale: s)
        }
    }
}

public final class FakeThumbnailService: ThumbnailService, @unchecked Sendable {
    public let calls = Locked<[(source: URL, destination: URL, maxPixel: Int)]>([])
    public init() {}
    public func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws {
        calls.withLock { $0.append((source, destination, maxPixel)) }
        try Data("thumb".utf8).write(to: destination)
    }
}

public final class FakePermissionService: PermissionService, @unchecked Sendable {
    public let states: Locked<[PermissionKind: PermissionState]>
    public let grantOnRequest: Locked<Bool>
    public let opened = Locked<[PermissionKind]>([])
    public init(states: [PermissionKind: PermissionState] = [:], grantOnRequest: Bool = true) {
        self.states = Locked(states)
        self.grantOnRequest = Locked(grantOnRequest)
    }
    public func state(of kind: PermissionKind) async -> PermissionState { states.current[kind] ?? .notDetermined }
    public func request(_ kind: PermissionKind) async -> PermissionState {
        let result: PermissionState = grantOnRequest.current ? .granted : .denied
        states.withLock { $0[kind] = result }
        return result
    }
    public func openSystemSettings(for kind: PermissionKind) { opened.withLock { $0.append(kind) } }
}

public final class FakeHotKeyService: HotKeyService, @unchecked Sendable {
    public let registered = Locked<KeyCombo?>(nil)
    private let handler = Locked<(@Sendable () -> Void)?>(nil)
    public init() {}
    public func register(_ combo: KeyCombo, handler: @escaping @Sendable () -> Void) throws {
        registered.set(combo)
        self.handler.set(handler)
    }
    public func unregister() {
        registered.set(nil)
        handler.set(nil)
    }
    /// Simulates the user pressing the hotkey.
    public func press() { handler.current?() }
}

public final class FakeAudioRecorder: AudioRecorder, @unchecked Sendable {
    public let startedURLs = Locked<[URL]>([])
    public let stopDuration: Locked<TimeInterval>
    public let levels: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation
    public init(stopDuration: TimeInterval = 3.5) {
        self.stopDuration = Locked(stopDuration)
        let (stream, cont) = AsyncStream<Float>.makeStream()
        levels = stream
        continuation = cont
    }
    public func start(writingTo url: URL) async throws {
        startedURLs.withLock { $0.append(url) }
        try Data("m4a".utf8).write(to: url)
    }
    public func stop() async throws -> RecordingInfo {
        let url = startedURLs.current.last ?? URL(fileURLWithPath: "/dev/null")
        return RecordingInfo(fileURL: url, duration: stopDuration.current)
    }
    public func emitLevel(_ level: Float) { continuation.yield(level) }
}

public final class FakeTranscriber: Transcriber, @unchecked Sendable {
    public let engineName = "fake"
    public let state: Locked<TranscriberModelState>
    public let result: Locked<Result<Transcript, FakeError>>
    public let calls = Locked<[(fileURL: URL, language: String)]>([])
    public init(
        state: TranscriberModelState = .ready,
        result: Result<Transcript, FakeError> = .success(
            Transcript(text: "merhaba dünya", language: "tr", engine: "fake"))
    ) {
        self.state = Locked(state)
        self.result = Locked(result)
    }
    public func modelState() async -> TranscriberModelState { state.current }
    public func downloadModel() async throws { state.set(.ready) }
    public func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        calls.withLock { $0.append((fileURL, language)) }
        return try result.current.get()
    }
}

/// Replays scripted events, then returns the scripted result (or throws). Records every spec it was given.
public final class FakeClaudeRunner: ClaudeRunner, @unchecked Sendable {
    public let events: Locked<[RunEvent]>
    public let outcome: Locked<Result<ClaudeRunResult, FakeError>>
    public let specs = Locked<[RunSpec]>([])
    public let cancelled = Locked<[UUID]>([])
    public let eventDelay: Locked<Duration>
    public let versionString: Locked<String>
    public init(
        events: [RunEvent] = [],
        outcome: Result<ClaudeRunResult, FakeError> = .success(ClaudeRunResult(subtype: "success", isError: false)),
        eventDelay: Duration = .zero, version: String = "2.1.278 (Claude Code)"
    ) {
        self.events = Locked(events)
        self.outcome = Locked(outcome)
        self.eventDelay = Locked(eventDelay)
        versionString = Locked(version)
    }
    public func run(_ spec: RunSpec, onEvent: @escaping @Sendable (RunEvent) -> Void) async throws -> ClaudeRunResult {
        specs.withLock { $0.append(spec) }
        for event in events.current {
            if eventDelay.current > .zero { try await Task.sleep(for: eventDelay.current) }
            try Task.checkCancellation()
            onEvent(event)
        }
        var result = try outcome.current.get()
        if result.sessionID == nil { result.sessionID = spec.runID.uuidString }
        return result
    }
    public func cancel(runID: UUID) async { cancelled.withLock { $0.append(runID) } }
    public func version() async throws -> String { versionString.current }
}

public final class FakeGitInspector: GitInspector, @unchecked Sendable {
    public let snapshots: Locked<[String: GitSnapshot]>
    public let branches = Locked<[(name: String, path: String)]>([])
    public let stashes = Locked<[String]>([])
    /// Set to make `createBranch` / `stashAll` fail (nothing is recorded then).
    public let branchFailure = Locked<FakeError?>(nil)
    public let stashFailure = Locked<FakeError?>(nil)
    public init(snapshots: [String: GitSnapshot] = [:]) { self.snapshots = Locked(snapshots) }
    public func snapshot(at path: String) async -> GitSnapshot? { snapshots.current[path] }
    public func createBranch(_ name: String, at path: String) async throws {
        if let failure = branchFailure.current { throw failure }
        branches.withLock { $0.append((name, path)) }
        snapshots.withLock { $0[path]?.branch = name }
    }
    public func stashAll(at path: String) async throws {
        if let failure = stashFailure.current { throw failure }
        stashes.withLock { $0.append(path) }
        snapshots.withLock { $0[path]?.isDirty = false }
    }
}

public final class MutableClock: Clock, @unchecked Sendable {
    private let value: Locked<Date>
    public init(_ now: Date = Date(timeIntervalSince1970: 1_758_500_000)) { value = Locked(now) }
    public var now: Date { value.current }
    public func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    public func set(_ date: Date) { value.set(date) }
}

public final class FakeNotifier: Notifier, @unchecked Sendable {
    public let sent = Locked<[AppNotification]>([])
    public init() {}
    public func notify(_ notification: AppNotification) async { sent.withLock { $0.append(notification) } }
}

public final class FakeHandoffService: HandoffService, @unchecked Sendable {
    public let actions = Locked<[String]>([])
    public init() {}
    public func openInTerminal(sessionID: String, projectPath: String) throws {
        actions.withLock { $0.append("terminal:\(sessionID)@\(projectPath)") }
    }
    public func openInDesktop(sessionID: String) throws { actions.withLock { $0.append("desktop:\(sessionID)") } }
    public func openDesktopComposer(prompt: String, projectPath: String, files: [String]) throws {
        actions.withLock { $0.append("composer:\(projectPath):\(files.count)") }
    }
}

/// Records dispatch calls; `emit(runID:event:)` feeds `liveEvents` subscribers (uses `Broadcaster` from InMemoryRepositories.swift).
public final class FakeTaskDispatcher: TaskDispatcher, @unchecked Sendable {
    public let enqueued = Locked<[UUID]>([])
    public let cancelledTasks = Locked<[UUID]>([])
    public let runQueueCalls = Locked(0)
    public let paused = Locked(false)
    /// Set to make `enqueue` fail (nothing is recorded then), e.g. the app's "claude missing" refusal.
    public let enqueueError = Locked<FakeError?>(nil)
    private let broadcasters = Locked<[UUID: Broadcaster<RunEvent>]>([:])
    public init() {}
    public func enqueue(taskID: UUID) async throws {
        if let error = enqueueError.current { throw error }
        enqueued.withLock { $0.append(taskID) }
    }
    public func cancel(taskID: UUID) async { cancelledTasks.withLock { $0.append(taskID) } }
    public func runQueueNow() async { runQueueCalls.withLock { $0 += 1 } }
    public func setPaused(_ value: Bool) async { paused.set(value) }
    public func isPaused() async -> Bool { paused.current }
    public func liveEvents(runID: UUID) -> AsyncStream<RunEvent> {
        let b = broadcasters.withLock { dict -> Broadcaster<RunEvent> in
            if let existing = dict[runID] { return existing }
            let created = Broadcaster<RunEvent>()
            dict[runID] = created
            return created
        }
        return b.stream(initial: .other(type: "subscribed"))
    }
    public func emit(runID: UUID, event: RunEvent) { broadcasters.current[runID]?.send(event) }
}

public final class FakeTranscriptionQueue: TranscriptionQueue, @unchecked Sendable {
    public let enqueued = Locked<[UUID]>([])
    public let processPendingCalls = Locked(0)
    public init() {}
    public func enqueue(voiceNoteID: UUID) async { enqueued.withLock { $0.append(voiceNoteID) } }
    public func processPending() async { processPendingCalls.withLock { $0 += 1 } }
}
