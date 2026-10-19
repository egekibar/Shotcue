import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueNotes

/// A model download that reports `progress`, then either finishes or waits until it is cancelled (like HubApi,
/// which throws `CancellationError` or `URLError(.cancelled)` when its task is cancelled).
final class FakeModelSource: WhisperModelSource, @unchecked Sendable {
    enum Ending {
        case completes
        case waitsForCancellation
        /// HubApi's URLSession reports the cancel as a URL error instead of `CancellationError`.
        case waitsThenThrowsURLCancelled
    }

    let ending: Locked<Ending>
    let progress: Double
    let downloads = Locked(0)
    let loads = Locked(0)
    let unloads = Locked(0)

    init(ending: Ending, progress: Double = 0.4) {
        self.ending = Locked(ending)
        self.progress = progress
    }

    func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        downloads.withLock { $0 += 1 }
        onProgress(progress)
        switch ending.current {
        case .completes:
            return
        case .waitsForCancellation:
            try await Task.sleep(for: .seconds(60))
        case .waitsThenThrowsURLCancelled:
            try? await Task.sleep(for: .seconds(60))
            throw URLError(.cancelled)
        }
    }

    func load() async throws { loads.withLock { $0 += 1 } }
    func unload() async { unloads.withLock { $0 += 1 } }
}

/// Revize-1: the transcription model download can be paused, resumed and deleted.
@Suite("Model download controls")
struct ModelDownloadControlTests {
    private func emptyModelsDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-models-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func transcriber(_ source: FakeModelSource, in directory: URL) -> WhisperKitTranscriber {
        WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName, modelsDirectory: directory,
            engine: RecordingWhisperEngine(), modelSource: source)
    }

    /// Polls the actor until `expected` (its progress arrives through an unstructured task).
    private func waitForState(
        _ transcriber: WhisperKitTranscriber, _ expected: TranscriberModelState
    ) async -> Bool {
        for _ in 0..<400 {
            if await transcriber.modelState() == expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await transcriber.modelState() == expected
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func cancellingTheDownloadPausesItAtItsProgress() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FakeModelSource(ending: .waitsForCancellation)
        let transcriber = transcriber(source, in: directory)

        let download = Task { try await transcriber.downloadModel() }
        #expect(await waitForState(transcriber, .downloading(progress: 0.4)))
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }

        #expect(await transcriber.modelState() == .paused(progress: 0.4))
        #expect(source.loads.current == 0)
    }

    @Test func aURLSessionCancelAlsoPauses() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FakeModelSource(ending: .waitsThenThrowsURLCancelled)
        let transcriber = transcriber(source, in: directory)

        let download = Task { try await transcriber.downloadModel() }
        #expect(await waitForState(transcriber, .downloading(progress: 0.4)))
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(await transcriber.modelState() == .paused(progress: 0.4))
    }

    @Test func resumingStartsFromThePausedProgressAndEndsReady() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FakeModelSource(ending: .waitsForCancellation)
        let transcriber = transcriber(source, in: directory)

        let first = Task { try await transcriber.downloadModel() }
        #expect(await waitForState(transcriber, .downloading(progress: 0.4)))
        first.cancel()
        _ = try? await first.value

        source.ending.set(.completes)
        try await transcriber.downloadModel()
        #expect(await transcriber.modelState() == .ready)
        #expect(source.downloads.current == 2)
        #expect(source.loads.current == 1)
    }

    @Test func aPartialDownloadLeftOnDiskReadsAsPausedAfterARestart() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = transcriber(FakeModelSource(ending: .completes), in: directory)
        #expect(await transcriber.modelState() == .notDownloaded)

        try write(
            "partial",
            to: transcriber.partialDownloadFolderURL.appendingPathComponent(
                "AudioEncoder.mlmodelc/weights/weight.bin.0123abcd.incomplete"))
        #expect(await transcriber.modelState() == .paused(progress: nil))
    }

    @Test func onlyMetadataLeftOnDiskIsNotAPausedDownload() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = transcriber(FakeModelSource(ending: .completes), in: directory)
        try write(
            "commit\netag\n0\n",
            to: transcriber.partialDownloadFolderURL.appendingPathComponent("config.json.metadata"))
        #expect(await transcriber.modelState() == .notDownloaded)
    }

    @Test func deletingRemovesTheModelAndThePartialFiles() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FakeModelSource(ending: .completes)
        let transcriber = transcriber(source, in: directory)
        for name in WhisperKitEngine.requiredBundles {
            try write("model", to: transcriber.modelFolderURL.appendingPathComponent("\(name).mlmodelc/weights.bin"))
        }
        try write("x", to: transcriber.partialDownloadFolderURL.appendingPathComponent("config.json.metadata"))
        #expect(await transcriber.modelState() == .ready)
        #expect(await transcriber.modelDiskUsage() == 16)

        try await transcriber.deleteModel()

        #expect(source.unloads.current == 1)
        #expect(!FileManager.default.fileExists(atPath: transcriber.modelFolderURL.path))
        #expect(!FileManager.default.fileExists(atPath: transcriber.partialDownloadFolderURL.path))
        #expect(await transcriber.modelState() == .notDownloaded)
        #expect(await transcriber.modelDiskUsage() == nil)
    }

    @Test func deletingAPausedDownloadForgetsIt() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = transcriber(FakeModelSource(ending: .completes), in: directory)
        try write(
            "partial", to: transcriber.partialDownloadFolderURL.appendingPathComponent("a.bin.ff.incomplete"))
        #expect(await transcriber.modelState() == .paused(progress: nil))

        try await transcriber.deleteModel()
        #expect(await transcriber.modelState() == .notDownloaded)
    }

    @Test func deletingWhileDownloadingIsRefused() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = transcriber(FakeModelSource(ending: .waitsForCancellation), in: directory)

        let download = Task { try await transcriber.downloadModel() }
        #expect(await waitForState(transcriber, .downloading(progress: 0.4)))
        await #expect(throws: WhisperKitTranscriber.Failure.downloadInProgress) {
            try await transcriber.deleteModel()
        }
        download.cancel()
        _ = try? await download.value
    }

    @Test func diskUsageIsNilWithNothingOnDisk() async {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = transcriber(FakeModelSource(ending: .completes), in: directory)
        #expect(await transcriber.modelDiskUsage() == nil)
    }
}
