import Foundation
import ShotcueCore

/// Every service the UI layer is allowed to touch, in one value type.
///
/// `ShotcueUI` never imports `ShotcuePersistence`, `ShotcueCapture`, `ShotcueNotes` or
/// `ShotcueClaudeBridge`; the composition root (`ShotcueApp`, Plan 06) builds this struct from the
/// production implementations, tests build it from `ShotcueTestSupport` fakes.
///
/// `init` must stay `nonisolated`: this module compiles with `.defaultIsolation(MainActor.self)`, so an
/// un-annotated initializer would be MainActor-bound and could not be called while setting services up
/// off the main actor.
public struct AppServices: Sendable {
    public let projects: any ProjectRepository
    public let tasks: any TaskRepository
    public let runs: any RunRepository
    public let capture: any CaptureService
    public let thumbnails: any ThumbnailService
    public let permissions: any PermissionService
    public let recorder: any AudioRecorder
    public let transcriber: any Transcriber
    public let transcriptionQueue: any TranscriptionQueue
    public let dispatcher: any TaskDispatcher
    public let handoff: any HandoffService
    public let fileStore: FileStore
    public let clock: any Clock
    /// Backs "Diff'i göster" (Plan 07); nil disables the button.
    public let diff: (any DiffProvider)?

    nonisolated public init(
        projects: any ProjectRepository,
        tasks: any TaskRepository,
        runs: any RunRepository,
        capture: any CaptureService,
        thumbnails: any ThumbnailService,
        permissions: any PermissionService,
        recorder: any AudioRecorder,
        transcriber: any Transcriber,
        transcriptionQueue: any TranscriptionQueue,
        dispatcher: any TaskDispatcher,
        handoff: any HandoffService,
        fileStore: FileStore,
        clock: any Clock,
        diff: (any DiffProvider)? = nil
    ) {
        self.projects = projects
        self.tasks = tasks
        self.runs = runs
        self.capture = capture
        self.thumbnails = thumbnails
        self.permissions = permissions
        self.recorder = recorder
        self.transcriber = transcriber
        self.transcriptionQueue = transcriptionQueue
        self.dispatcher = dispatcher
        self.handoff = handoff
        self.fileStore = fileStore
        self.clock = clock
        self.diff = diff
    }

    /// Absolute URL of a capture / voice note / run log, for AppKit calls and prompt building.
    nonisolated public func url(for relPath: String) -> URL { fileStore.absoluteURL(for: relPath) }
}
