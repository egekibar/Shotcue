import Foundation
import WhisperKit

/// One transcribed span as WhisperKit reports it, converted to Double/seconds.
public struct WhisperSegment: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    /// `exp(avgLogprob)` — the closest thing WhisperKit gives us to a 0…1 confidence.
    public var confidence: Double?

    public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

/// Seam between `WhisperKitTranscriber`'s logic and the 1.6 GB model: tests inject a fake.
public protocol WhisperEngine: Sendable {
    func transcribe(url: URL, language: String) async throws -> [WhisperSegment]
}

/// Real adapter over WhisperKit 1.1 (`argmax-oss-swift`). Exercised manually in Task 1, never in `swift test`.
public actor WhisperKitEngine: WhisperEngine {
    public static let repo = "argmaxinc/whisperkit-coreml"

    public enum Failure: Error, Equatable {
        case modelNotLoaded
    }

    private let modelName: String
    private let modelsDirectory: URL
    private var kit: WhisperKit?

    public init(modelName: String, modelsDirectory: URL) {
        self.modelName = modelName
        self.modelsDirectory = modelsDirectory
    }

    /// HubApi caches a repo snapshot at `downloadBase/models/<repo>/`; `WhisperKit.download`
    /// returns that path with the variant folder appended.
    public static func modelFolderURL(modelsDirectory: URL, modelName: String) -> URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    public func isDownloaded(fileManager: FileManager = .default) -> Bool {
        let folder = Self.modelFolderURL(modelsDirectory: modelsDirectory, modelName: modelName)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let callback: ProgressCallback = { progress in onProgress(progress.fractionCompleted) }
        _ = try await WhisperKit.download(
            variant: modelName,
            downloadBase: modelsDirectory,
            useBackgroundSession: false,
            from: Self.repo,
            progressCallback: callback
        )
    }

    /// Loads the CoreML models from disk. `download: false` keeps this offline — the explicit
    /// download step (spec §6.2: "Model ilk kullanımda açık onayla indirilir") owns the network.
    public func load() async throws {
        guard kit == nil else { return }
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDirectory,
            modelRepo: Self.repo,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
    }

    public func unload() {
        kit = nil
    }

    public func transcribe(url: URL, language: String) async throws -> [WhisperSegment] {
        try await load()
        guard let kit else { throw Failure.modelNotLoaded }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )
        let results: [TranscriptionResult] = try await kit.transcribe(
            audioPath: url.path,
            decodeOptions: options)
        return results.flatMap { result in
            result.segments.map { segment in
                WhisperSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: Double(exp(segment.avgLogprob))
                )
            }
        }
    }

    /// Names offered in Ayarlar > Ses; both models the spec mentions are in
    /// `recommendedModels().supported` on Apple Silicon (verified 2026-09-22).
    public static func recommendedModelNames() -> [String] {
        WhisperKit.recommendedModels().supported
    }
}
