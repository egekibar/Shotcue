import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcueNotes

/// Records the language it was called with and replays scripted segments.
final class RecordingWhisperEngine: WhisperEngine, @unchecked Sendable {
    let calls = Locked<[(url: URL, language: String)]>([])
    let segments: [WhisperSegment]
    let failure: FakeError?

    init(
        segments: [WhisperSegment] = [
            WhisperSegment(start: 0, end: 2.4, text: "login ekranındaki modal", confidence: 0.91),
            WhisperSegment(start: 2.4, end: 4.8, text: "API endpoint'i deploy et", confidence: 0.88),
        ], failure: FakeError? = nil
    ) {
        self.segments = segments
        self.failure = failure
    }

    func transcribe(url: URL, language: String) async throws -> [WhisperSegment] {
        calls.withLock { $0.append((url, language)) }
        if let failure { throw failure }
        return segments
    }
}

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {
    private func emptyModelsDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-models-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func engineNameCarriesTheModelName() async {
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName,
            modelsDirectory: emptyModelsDirectory())
        #expect(transcriber.engineName == "whisperkit/openai_whisper-large-v3-v20240930_turbo")
    }

    @Test func modelStateIsNotDownloadedForAnEmptyDirectory() async {
        let directory = emptyModelsDirectory()
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName,
            modelsDirectory: directory)
        #expect(await transcriber.modelState() == .notDownloaded)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Final review M8: an interrupted download leaves the folder behind; only the three CoreML bundles WhisperKit
    /// loads make the model ready.
    @Test func aModelFolderWithoutItsBundlesIsNotReady() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName,
            modelsDirectory: directory)
        try FileManager.default.createDirectory(at: transcriber.modelFolderURL, withIntermediateDirectories: true)
        #expect(await transcriber.modelState() == .notDownloaded)

        // Two of the three bundles: still not ready.
        for name in ["MelSpectrogram", "AudioEncoder"] {
            try FileManager.default.createDirectory(
                at: transcriber.modelFolderURL.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true)
        }
        #expect(await transcriber.modelState() == .notDownloaded)
    }

    @Test func modelStateIsReadyOnceTheThreeBundlesExist() async throws {
        let directory = emptyModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName,
            modelsDirectory: directory)
        #expect(WhisperKitEngine.requiredBundles == ["MelSpectrogram", "AudioEncoder", "TextDecoder"])
        for name in WhisperKitEngine.requiredBundles {
            try FileManager.default.createDirectory(
                at: transcriber.modelFolderURL.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true)
        }
        #expect(await transcriber.modelState() == .ready)
        let engine = WhisperKitEngine(modelName: WhisperKitTranscriber.defaultModelName, modelsDirectory: directory)
        #expect(await engine.isDownloaded())
    }

    @Test func modelFolderFollowsTheHubCacheLayout() async {
        let root = URL(fileURLWithPath: "/tmp/shotcue-models")
        let folder = WhisperKitEngine.modelFolderURL(
            modelsDirectory: root,
            modelName: WhisperKitTranscriber.defaultModelName)
        #expect(
            folder.path
                == "/tmp/shotcue-models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
    }

    @Test func loadingLooksInsideTheModelFolderWithoutDownloading() async {
        // Offline and model-free: with no model files WhisperKit must fail on a file inside `modelFolderURL`.
        // "Model folder is not set." instead would mean `load()` can never succeed, even after a download.
        let directory = emptyModelsDirectory()
        let engine = WhisperKitEngine(modelName: WhisperKitTranscriber.defaultModelName, modelsDirectory: directory)
        let folder = WhisperKitEngine.modelFolderURL(
            modelsDirectory: directory, modelName: WhisperKitTranscriber.defaultModelName)
        do {
            try await engine.load()
            Issue.record("load() must fail without model files")
        } catch {
            #expect(String(describing: error).contains(folder.path))
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func passesLanguageThroughAndMapsSegments() async throws {
        let engine = RecordingWhisperEngine()
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName,
            modelsDirectory: emptyModelsDirectory(),
            engine: engine, initialState: .ready)
        let audio = URL(fileURLWithPath: "/tmp/note.m4a")
        let transcript = try await transcriber.transcribe(fileURL: audio, language: "tr")

        #expect(engine.calls.current.count == 1)
        #expect(engine.calls.current.first?.language == "tr")
        #expect(engine.calls.current.first?.url == audio)
        #expect(transcript.text == "login ekranındaki modal API endpoint'i deploy et")
        #expect(transcript.language == "tr")
        #expect(transcript.engine == "whisperkit/openai_whisper-large-v3-v20240930_turbo")
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].start == 0)
        #expect(transcript.segments[1].end == 4.8)
        #expect(transcript.segments[0].confidence == 0.91)
    }

    @Test func englishLanguageIsPassedThroughUnchanged() async throws {
        let engine = RecordingWhisperEngine(segments: [WhisperSegment(start: 0, end: 1, text: "clear the cache")])
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.compactModelName,
            modelsDirectory: emptyModelsDirectory(),
            engine: engine, initialState: .ready)
        let transcript = try await transcriber.transcribe(
            fileURL: URL(fileURLWithPath: "/tmp/en.m4a"),
            language: "en")
        #expect(engine.calls.current.first?.language == "en")
        #expect(transcript.engine == "whisperkit/openai_whisper-large-v3-v20240930_turbo_632MB")
        #expect(transcript.text == "clear the cache")
    }

    @Test func aPerFileFailureKeepsTheModelReady() async {
        // One unreadable recording fails that note only (spec §8, retryable); it must not block the queue.
        let engine = RecordingWhisperEngine(failure: FakeError("bad audio"))
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName,
            modelsDirectory: emptyModelsDirectory(),
            engine: engine, initialState: .ready)
        await #expect(throws: FakeError("bad audio")) {
            _ = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: "/tmp/x.m4a"), language: "tr")
        }
        let state = await transcriber.modelState()
        #expect(state == .ready)
    }

    @Test func aModelThatCannotBeLoadedMovesTheStateToFailed() async {
        // Production engine on an empty models directory: loading fails offline, on the missing model files.
        let directory = emptyModelsDirectory()
        let transcriber = WhisperKitTranscriber(
            modelName: WhisperKitTranscriber.defaultModelName, modelsDirectory: directory)
        await #expect(throws: (any Error).self) {
            _ = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: "/tmp/x.m4a"), language: "tr")
        }
        if case .failed(let message) = await transcriber.modelState() {
            #expect(message.contains(transcriber.modelFolderURL.path))
        } else {
            Issue.record("state should be .failed")
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
