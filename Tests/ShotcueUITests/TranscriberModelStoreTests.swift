import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueUI

/// A transcriber whose download parks on a gate (or fails), counting how often it was asked to download.
nonisolated final class DownloadProbeTranscriber: Transcriber, @unchecked Sendable {
    let engineName = "probe"
    let state = Locked<TranscriberModelState>(.notDownloaded)
    let downloads = Locked(0)
    let gate: Gate?
    let failure: FakeError?

    init(gate: Gate? = nil, failure: FakeError? = nil) {
        self.gate = gate
        self.failure = failure
    }

    func modelState() async -> TranscriberModelState { state.current }
    func downloadModel() async throws {
        downloads.withLock { $0 += 1 }
        state.set(.downloading(progress: 0.25))
        await gate?.wait()
        if let failure {
            state.set(.failed(failure.message))
            throw failure
        }
        state.set(.ready)
    }
    func deleteModel() async throws { state.set(.notDownloaded) }
    func modelDiskUsage() async -> Int64? { nil }
    func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        Transcript(text: "", language: language, engine: engineName)
    }
}

/// Downloads until cancelled, then pauses where it stopped — as `WhisperKitTranscriber` does. A second download
/// finishes. Tracks what is on disk so deletion can be observed.
nonisolated final class PausableTranscriber: Transcriber, @unchecked Sendable {
    let engineName = "pausable"
    let state = Locked<TranscriberModelState>(.notDownloaded)
    let downloads = Locked(0)
    let deletions = Locked(0)
    let bytesOnDisk = Locked<Int64?>(nil)

    func modelState() async -> TranscriberModelState { state.current }
    func downloadModel() async throws {
        let attempt = downloads.withLock { count -> Int in
            count += 1
            return count
        }
        state.set(.downloading(progress: 0.3))
        bytesOnDisk.set(500_000_000)
        guard attempt == 1 else {
            bytesOnDisk.set(1_500_000_000)
            state.set(.ready)
            return
        }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            state.set(.paused(progress: 0.3))
            throw CancellationError()
        }
    }
    func deleteModel() async throws {
        deletions.withLock { $0 += 1 }
        bytesOnDisk.set(nil)
        state.set(.notDownloaded)
    }
    func modelDiskUsage() async -> Int64? { bytesOnDisk.current }
    func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        Transcript(text: "", language: language, engine: engineName)
    }
}

/// Spec §6.2 and final review C1 (c): a voice note recorded without the model says "model indirilmedi", never an
/// endless "çevriliyor", and offers the download — with its size, behind an explicit click, through the same flow
/// Settings uses. Nothing downloads on its own.
@Suite("Transcription model")
struct TranscriberModelStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func refreshMirrorsTheTranscriber() async {
        let transcriber = FakeTranscriber(state: .notDownloaded)
        let queue = FakeTranscriptionQueue()
        let store = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: queue,
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        await store.refresh()
        #expect(store.state == .notDownloaded)
        #expect(store.isReady == false)
        transcriber.state.set(.ready)
        await store.refresh()
        #expect(store.isReady)
        // Refreshing never downloads.
        #expect(queue.processPendingCalls.current == 0)
    }

    @MainActor
    @Test func theDownloadRunsOnceShowsProgressAndThenTranscribesWhatWaited() async {
        let gate = Gate()
        let transcriber = DownloadProbeTranscriber(gate: gate)
        let queue = FakeTranscriptionQueue()
        let store = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: queue,
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        store.progressPollInterval = .milliseconds(10)

        store.startDownload()
        store.startDownload()
        #expect(await waitUntil("parked") { gate.arrivals.current == 1 })
        #expect(await waitUntil("progress") { store.state == .downloading(progress: 0.25) })
        // A refresh while downloading keeps the download's own progress.
        await store.refresh()
        #expect(store.state == .downloading(progress: 0.25))

        gate.open()
        await store.downloadTask?.value
        #expect(store.state == .ready)
        #expect(transcriber.downloads.current == 1)
        #expect(await waitUntil("pending notes processed") { queue.processPendingCalls.current == 1 })
    }

    @MainActor
    @Test func aFailedDownloadSaysWhy() async {
        let transcriber = DownloadProbeTranscriber(failure: FakeError("ağ yok"))
        let store = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: FakeTranscriptionQueue(),
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        store.startDownload()
        await store.downloadTask?.value
        guard case .failed = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
        // It can be tried again.
        #expect(store.downloadTask == nil)
    }

    @MainActor
    @Test func aPausedDownloadResumesAndThenTranscribesWhatWaited() async {
        let transcriber = PausableTranscriber()
        let queue = FakeTranscriptionQueue()
        let store = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: queue,
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        store.progressPollInterval = .milliseconds(10)

        store.startDownload()
        #expect(await waitUntil("progress") { store.state == .downloading(progress: 0.3) })
        store.pauseDownload()
        await store.downloadTask?.value
        #expect(store.state == .paused(progress: 0.3))
        #expect(store.downloadTask == nil)
        #expect(store.diskUsage == 500_000_000)
        // Pausing is not a failure, and nothing waited for the model is processed yet.
        #expect(queue.processPendingCalls.current == 0)

        store.startDownload()
        // Resuming starts from where it paused, not from 0.
        #expect(store.state == .downloading(progress: 0.3))
        await store.downloadTask?.value
        #expect(store.state == .ready)
        #expect(transcriber.downloads.current == 2)
        #expect(store.diskUsage == 1_500_000_000)
        #expect(await waitUntil("pending notes processed") { queue.processPendingCalls.current == 1 })
    }

    @MainActor
    @Test func deletingStopsADownloadAndForgetsIt() async {
        let transcriber = PausableTranscriber()
        let store = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: FakeTranscriptionQueue(),
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        store.progressPollInterval = .milliseconds(10)

        store.startDownload()
        #expect(await waitUntil("progress") { store.state == .downloading(progress: 0.3) })
        await store.deleteModel()

        #expect(transcriber.deletions.current == 1)
        #expect(store.downloadTask == nil)
        #expect(store.state == .notDownloaded)
        #expect(store.diskUsage == nil)
        #expect(store.isDeleting == false)
    }

    @MainActor
    @Test func deletingAReadyModel() async {
        let transcriber = FakeTranscriber(state: .ready)
        transcriber.diskUsage.set(1_500_000_000)
        let store = TranscriberModelStore(
            transcriber: transcriber, transcriptionQueue: FakeTranscriptionQueue(),
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        await store.refresh()
        #expect(store.diskUsage == 1_500_000_000)
        #expect(store.diskUsageText?.contains("GB") == true)

        await store.deleteModel()
        #expect(transcriber.deletions.current == 1)
        #expect(store.state == .notDownloaded)
        #expect(store.diskUsageText == nil)
    }

    @Test func downloadSizesAreShownForBothModels() {
        #expect(
            TranscriberModelStore.downloadSizeText(forModel: "openai_whisper-large-v3-v20240930_turbo") == "≈1,6 GB")
        #expect(
            TranscriberModelStore.downloadSizeText(forModel: "openai_whisper-large-v3-v20240930_turbo_632MB")
                == "≈632 MB")
    }

    @Test func aPendingNoteSaysWhatItWaitsFor() {
        let pending = VoiceNote(taskID: UUID(), relPath: "audio/a.m4a", durationSec: 3, transcriptState: .pending)
        #expect(VoiceNoteStatus.of(pending, model: .ready) == .transcribing)
        #expect(VoiceNoteStatus.of(pending, model: .notDownloaded) == .waitingForModel)
        #expect(VoiceNoteStatus.of(pending, model: .downloading(progress: 0.5)) == .modelDownloading(0.5))
        #expect(VoiceNoteStatus.of(pending, model: .failed("x")) == .modelUnavailable)
        #expect(VoiceNoteStatus.of(pending, model: .paused(progress: 0.3)) == .modelPaused)
        #expect(VoiceNoteStatus.modelPaused.label == "model indirme duraklatıldı")
        #expect(VoiceNoteStatus.modelPaused.offersModelDownload)
        #expect(VoiceNoteStatus.waitingForModel.label == "model indirilmedi")
        #expect(VoiceNoteStatus.transcribing.label == "çevriliyor")
        #expect(VoiceNoteStatus.waitingForModel.offersModelDownload)
        #expect(VoiceNoteStatus.modelUnavailable.offersModelDownload)
        #expect(!VoiceNoteStatus.transcribing.offersModelDownload)

        var failed = pending
        failed.transcriptState = .failed
        #expect(VoiceNoteStatus.of(failed, model: .notDownloaded) == .failed)
        var edited = pending
        edited.transcriptState = .done
        edited.editedByUser = true
        #expect(VoiceNoteStatus.of(edited, model: .notDownloaded) == .edited)
        var done = pending
        done.transcriptState = .done
        #expect(VoiceNoteStatus.of(done, model: .notDownloaded) == .done)
        #expect(VoiceNoteStatus.done.label == nil)
    }

    @MainActor
    @Test func thePanelOffersTheDownloadAfterARecordingWithoutAModel() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(title: "Yakalama", status: .inbox, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(
            projects: [project], tasks: [task], permissions: [.microphone: .granted],
            transcriberState: .notDownloaded, clock: MutableClock(t0))
        let model = TranscriberModelStore(
            transcriber: bundle.transcriber, transcriptionQueue: bundle.transcriptionQueue,
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shotcue-model-\(UUID())").path
        let store = QuickPanelStore(
            services: bundle.services, settings: SettingsStore(defaults: UserDefaults(suiteName: path)!),
            modelStore: model)
        await store.capture(taskID: task.id)
        #expect(store.showsModelNotice == false)

        await store.toggleRecording()
        await store.toggleRecording()
        #expect(store.showsModelNotice)
        #expect(model.state == .notDownloaded)
        // Nothing was downloaded without a click.
        #expect(bundle.transcriber.state.current == .notDownloaded)

        model.startDownload()
        await model.downloadTask?.value
        #expect(model.isReady)
        #expect(store.showsModelNotice == false)
        bundle.cleanUp()
    }

    @MainActor
    @Test func theInspectorLabelsPendingNotesByTheModel() async throws {
        let project = Project(name: "acme-web", path: "/tmp/acme-web", sortIndex: 1024, createdAt: t0)
        let task = ShotTask(projectID: project.id, title: "t", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(
            projects: [project], tasks: [task], transcriberState: .notDownloaded, clock: MutableClock(t0))
        let note = VoiceNote(taskID: task.id, relPath: "audio/a.m4a", durationSec: 3, transcriptState: .pending)
        try await bundle.services.tasks.save(note)
        let model = TranscriberModelStore(
            transcriber: bundle.transcriber, transcriptionQueue: bundle.transcriptionQueue,
            modelName: "openai_whisper-large-v3-v20240930_turbo")
        let store = TaskDetailStore(services: bundle.services, taskID: task.id, modelStore: model)
        await store.start()

        #expect(store.transcriptStatus(for: note) == .waitingForModel)
        bundle.transcriber.state.set(.ready)
        await model.refresh()
        #expect(store.transcriptStatus(for: note) == .transcribing)
        store.stop()
        bundle.cleanUp()
    }
}
