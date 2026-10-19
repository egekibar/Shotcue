import Foundation
import ShotcueCore

/// `Transcriber` on top of WhisperKit (spec §6.2: single engine in v1, default model
/// `openai_whisper-large-v3-v20240930_turbo`, default language `tr`).
public actor WhisperKitTranscriber: Transcriber {
    public static let defaultModelName = "openai_whisper-large-v3-v20240930_turbo"
    public static let compactModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    public enum Failure: Error, Equatable {
        /// `deleteModel()` while the model is downloading: pause the download first.
        case downloadInProgress
    }

    /// `nonisolated`: an actor's `let` is only cross-actor readable inside its own module,
    /// and both the protocol requirement and the tests read this from outside `ShotcueNotes`.
    public nonisolated let engineName: String
    private let modelName: String
    private let modelsDirectory: URL
    private let engine: any WhisperEngine
    /// Downloads and loads the model; nil in tests that only exercise transcription (the model is then "ready").
    private let modelSource: (any WhisperModelSource)?
    private var state: TranscriberModelState

    /// Production: builds its own `WhisperKitEngine`.
    public init(modelName: String, modelsDirectory: URL) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
        engineName = "whisperkit/\(modelName)"
        let kitEngine = WhisperKitEngine(modelName: modelName, modelsDirectory: modelsDirectory)
        modelSource = kitEngine
        engine = kitEngine
        state = .notDownloaded
    }

    /// Tests: inject a fake engine so the mapping/state logic runs without the 1.6 GB model, and a fake
    /// `modelSource` to drive the download without the network.
    public init(
        modelName: String, modelsDirectory: URL, engine: any WhisperEngine,
        modelSource: (any WhisperModelSource)? = nil,
        initialState: TranscriberModelState = .notDownloaded
    ) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
        engineName = "whisperkit/\(modelName)"
        self.modelSource = modelSource
        self.engine = engine
        state = initialState
    }

    /// Where the CoreML bundle lands: `modelsDirectory/models/argmaxinc/whisperkit-coreml/<modelName>`.
    public nonisolated var modelFolderURL: URL {
        WhisperKitEngine.modelFolderURL(modelsDirectory: modelsDirectory, modelName: modelName)
    }

    /// Where a download keeps its `.metadata` and `.incomplete` files.
    public nonisolated var partialDownloadFolderURL: URL {
        WhisperKitEngine.partialDownloadFolderURL(modelsDirectory: modelsDirectory, modelName: modelName)
    }

    public func modelState() async -> TranscriberModelState {
        switch state {
        case .downloading, .paused, .failed:
            return state
        case .ready:
            return .ready
        case .notDownloaded:
            // The three CoreML bundles, not the folder alone: an interrupted download leaves the folder behind
            // (final review M8). Its `.incomplete` files make it a paused download the user can resume.
            if WhisperKitEngine.hasRequiredBundles(in: modelFolderURL) { return .ready }
            if WhisperKitEngine.hasIncompleteFiles(in: partialDownloadFolderURL) { return .paused(progress: nil) }
            return .notDownloaded
        }
    }

    public func downloadModel() async throws {
        guard let modelSource else {
            state = .ready
            return
        }
        // A resumed download starts from the progress it was paused at, so the bar does not jump back to 0.
        if case .paused(let progress?) = state {
            state = .downloading(progress: progress)
        } else {
            state = .downloading(progress: 0)
        }
        do {
            try await modelSource.download { [weak self] fraction in
                guard let self else { return }
                Task { await self.setProgress(fraction) }
            }
            try Task.checkCancellation()
            try await modelSource.load()
            state = .ready
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                state = .paused(progress: currentProgress)
                throw CancellationError()
            }
            state = .failed(String(describing: error))
            throw error
        }
    }

    public func deleteModel() async throws {
        if case .downloading = state { throw Failure.downloadInProgress }
        await modelSource?.unload()
        let fileManager = FileManager.default
        for folder in [modelFolderURL, partialDownloadFolderURL] where fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        state = .notDownloaded
    }

    public func modelDiskUsage() async -> Int64? {
        let bytes = WhisperKitEngine.diskUsage(of: [modelFolderURL, partialDownloadFolderURL])
        return bytes > 0 ? bytes : nil
    }

    /// Only a model that cannot be loaded marks the transcriber `.failed`. A per-file error fails that one
    /// note (spec §8, retryable) and is rethrown without touching the state, so it cannot block the queue.
    public func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        if let modelSource {
            do {
                try await modelSource.load()
            } catch {
                state = .failed(String(describing: error))
                throw error
            }
        }
        let segments = try await engine.transcribe(url: fileURL, language: language)
        state = .ready
        let text = segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return Transcript(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language,
            engine: engineName,
            segments: segments.map {
                Transcript.Segment(
                    start: $0.start, end: $0.end, text: $0.text,
                    confidence: $0.confidence)
            }
        )
    }

    private var currentProgress: Double? {
        if case .downloading(let progress) = state { return progress }
        return nil
    }

    /// HubApi reports a cancelled download as `CancellationError` or, from its URLSession, `URLError(.cancelled)`.
    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func setProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: min(1, max(0, fraction)))
    }
}
