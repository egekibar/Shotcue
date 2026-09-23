import Foundation

public struct RecordingInfo: Hashable, Sendable {
    public var fileURL: URL
    public var duration: TimeInterval
    public init(fileURL: URL, duration: TimeInterval) {
        self.fileURL = fileURL
        self.duration = duration
    }
}

/// Microphone recorder writing AAC .m4a. `levels` yields RMS 0…1 while recording (level meter).
public protocol AudioRecorder: Sendable {
    func start(writingTo url: URL) async throws
    func stop() async throws -> RecordingInfo
    var levels: AsyncStream<Float> { get }
}

public enum TranscriberModelState: Hashable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)
}

/// Speech-to-text on a finished audio file (WhisperKit in Plan 03). `language` is a BCP-47 base code ("tr", "en").
public protocol Transcriber: Sendable {
    var engineName: String { get }
    func modelState() async -> TranscriberModelState
    func downloadModel() async throws
    func transcribe(fileURL: URL, language: String) async throws -> Transcript
}

/// Background transcription of pending voice notes (implemented by `TranscriptionCoordinator` in ShotcueNotes).
/// UI calls `enqueue` after a recording is saved; the app calls `processPending` at launch and when the model becomes ready.
public protocol TranscriptionQueue: Sendable {
    func enqueue(voiceNoteID: UUID) async
    func processPending() async
}
