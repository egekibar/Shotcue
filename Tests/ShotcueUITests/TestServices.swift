import Foundation
import ShotcueCore
import ShotcueTestSupport

@testable import ShotcueUI

/// Typed handles on the fakes behind an `AppServices`, so a test can assert what a store called.
struct FakeBundle {
    let services: AppServices
    let projects: InMemoryProjectRepository
    let tasks: InMemoryTaskRepository
    let runs: InMemoryRunRepository
    let capture: FakeCaptureService
    let thumbnails: FakeThumbnailService
    let permissions: FakePermissionService
    let recorder: FakeAudioRecorder
    let transcriber: FakeTranscriber
    let transcriptionQueue: FakeTranscriptionQueue
    let dispatcher: FakeTaskDispatcher
    let handoff: FakeHandoffService
    let clock: MutableClock
    let root: URL

    /// Removes the temporary FileStore root. Call at the end of tests that wrote files.
    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func fileExists(_ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: services.fileStore.absoluteURL(for: relPath).path)
    }

    /// Writes a placeholder file at `relPath` (creating parents) so deletion can be observed.
    @discardableResult
    func writeFile(_ relPath: String, contents: String = "x") throws -> URL {
        try services.fileStore.ensureParentDirectory(for: relPath)
        let url = services.fileStore.absoluteURL(for: relPath)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

/// Assembles an `AppServices` out of `ShotcueTestSupport` fakes with a throwaway FileStore root.
/// `ShotcueTestSupport` belongs to Plan 00 and is never edited here; this helper lives in the test target.
func makeFakeServices(
    projects: [Project] = [],
    tasks: [ShotTask] = [],
    runs: [Run] = [],
    permissions: [PermissionKind: PermissionState] = [:],
    grantOnRequest: Bool = true,
    transcriberState: TranscriberModelState = .ready,
    recordingDuration: TimeInterval = 3.5,
    clock: MutableClock = MutableClock()
) -> FakeBundle {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("shotcue-ui-test-\(UUID().uuidString)", isDirectory: true)
    let fileStore = FileStore(rootURL: root)
    try? fileStore.ensureDirectories()

    let projectRepo = InMemoryProjectRepository(projects)
    let taskRepo = InMemoryTaskRepository(tasks)
    let runRepo = InMemoryRunRepository(runs)
    let captureService = FakeCaptureService()
    let thumbnailService = FakeThumbnailService()
    let permissionService = FakePermissionService(states: permissions, grantOnRequest: grantOnRequest)
    let recorder = FakeAudioRecorder(stopDuration: recordingDuration)
    let transcriber = FakeTranscriber(state: transcriberState)
    let queue = FakeTranscriptionQueue()
    let dispatcher = FakeTaskDispatcher()
    let handoff = FakeHandoffService()

    let services = AppServices(
        projects: projectRepo,
        tasks: taskRepo,
        runs: runRepo,
        capture: captureService,
        thumbnails: thumbnailService,
        permissions: permissionService,
        recorder: recorder,
        transcriber: transcriber,
        transcriptionQueue: queue,
        dispatcher: dispatcher,
        handoff: handoff,
        fileStore: fileStore,
        clock: clock)

    return FakeBundle(
        services: services, projects: projectRepo, tasks: taskRepo, runs: runRepo,
        capture: captureService, thumbnails: thumbnailService, permissions: permissionService,
        recorder: recorder, transcriber: transcriber, transcriptionQueue: queue,
        dispatcher: dispatcher, handoff: handoff, clock: clock, root: root)
}

/// Waits until `condition` is true or the budget runs out, yielding between checks.
/// Stores hand their work to `Task`s, so tests need a deterministic way to let those run.
@MainActor
func waitUntil(
    _ label: String, timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
