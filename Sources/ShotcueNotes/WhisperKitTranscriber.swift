import Foundation
import ShotcueCore

/// `Transcriber` on top of WhisperKit (spec §6.2: single engine in v1, default model
/// `openai_whisper-large-v3-v20240930_turbo`, default language `tr`).
public actor WhisperKitTranscriber: Transcriber {
    public static let defaultModelName = "openai_whisper-large-v3-v20240930_turbo"
    public static let compactModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    /// `nonisolated`: an actor's `let` is only cross-actor readable inside its own module,
    /// and both the protocol requirement and the tests read this from outside `ShotcueNotes`.
    public nonisolated let engineName: String
    private let modelName: String
    private let modelsDirectory: URL
    private let engine: any WhisperEngine
    private let whisperKitEngine: WhisperKitEngine?
    private var state: TranscriberModelState

    /// Production: builds its own `WhisperKitEngine`.
    public init(modelName: String, modelsDirectory: URL) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
        engineName = "whisperkit/\(modelName)"
        let kitEngine = WhisperKitEngine(modelName: modelName, modelsDirectory: modelsDirectory)
        whisperKitEngine = kitEngine
        engine = kitEngine
        state = .notDownloaded
    }

    /// Tests: inject a fake engine so the mapping/state logic runs without the 1.6 GB model.
    public init(
        modelName: String, modelsDirectory: URL, engine: any WhisperEngine,
        initialState: TranscriberModelState = .notDownloaded
    ) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
        engineName = "whisperkit/\(modelName)"
        whisperKitEngine = nil
        self.engine = engine
        state = initialState
    }

    /// Where the CoreML bundle lands: `modelsDirectory/models/argmaxinc/whisperkit-coreml/<modelName>`.
    public nonisolated var modelFolderURL: URL {
        WhisperKitEngine.modelFolderURL(modelsDirectory: modelsDirectory, modelName: modelName)
    }

    public func modelState() async -> TranscriberModelState {
        switch state {
        case .downloading, .failed:
            return state
        case .ready:
            return .ready
        case .notDownloaded:
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: modelFolderURL.path,
                isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? .ready : .notDownloaded
        }
    }

    public func downloadModel() async throws {
        guard let whisperKitEngine else {
            state = .ready
            return
        }
        state = .downloading(progress: 0)
        do {
            try await whisperKitEngine.download { [weak self] fraction in
                guard let self else { return }
                Task { await self.setProgress(fraction) }
            }
            try await whisperKitEngine.load()
            state = .ready
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    public func transcribe(fileURL: URL, language: String) async throws -> Transcript {
        do {
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
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    private func setProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: min(1, max(0, fraction)))
    }
}
