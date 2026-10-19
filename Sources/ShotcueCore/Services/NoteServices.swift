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
    /// A download stopped part way; its partial files stay on disk and `downloadModel()` picks up from them.
    /// `progress` is nil when it is not known (the app was restarted since).
    case paused(progress: Double?)
    case ready
    case failed(String)
}

/// Speech-to-text on a finished audio file (WhisperKit in Plan 03). `language` is a BCP-47 base code ("tr", "en").
public protocol Transcriber: Sendable {
    var engineName: String { get }
    func modelState() async -> TranscriberModelState
    /// Downloads (or resumes) the model. Cancelling the calling task pauses it: the state becomes `.paused` and a
    /// `CancellationError` is thrown.
    func downloadModel() async throws
    /// Removes the model and any partial download from disk; the state becomes `.notDownloaded`.
    func deleteModel() async throws
    /// Bytes the model (or its partial download) takes on disk; nil when there is nothing.
    func modelDiskUsage() async -> Int64?
    func transcribe(fileURL: URL, language: String) async throws -> Transcript
}

/// Background transcription of pending voice notes (implemented by `TranscriptionCoordinator` in ShotcueNotes).
/// UI calls `enqueue` after a recording is saved; the app calls `processPending` at launch and when the model becomes ready.
public protocol TranscriptionQueue: Sendable {
    func enqueue(voiceNoteID: UUID) async
    func processPending() async
}
