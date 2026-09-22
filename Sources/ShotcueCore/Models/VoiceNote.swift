import Foundation

public enum TranscriptState: String, Sendable, Codable, CaseIterable {
    case pending, done, failed
}

/// Transcription output; stored as JSON next to the plain text.
public struct Transcript: Hashable, Sendable, Codable {
    public struct Segment: Hashable, Sendable, Codable {
        public var start: Double
        public var end: Double
        public var text: String
        public var confidence: Double?
        public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.confidence = confidence
        }
    }
    public var text: String
    public var language: String
    public var engine: String
    public var segments: [Segment]
    public init(text: String, language: String, engine: String, segments: [Segment] = []) {
        self.text = text
        self.language = language
        self.engine = engine
        self.segments = segments
    }
}

public struct VoiceNote: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID
    public var relPath: String
    public var durationSec: Double
    public var transcript: String?
    public var transcriptJSON: String?
    public var transcriptState: TranscriptState
    public var engine: String?
    public var editedByUser: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(), taskID: UUID, relPath: String, durationSec: Double,
        transcript: String? = nil, transcriptJSON: String? = nil, transcriptState: TranscriptState = .pending,
        engine: String? = nil, editedByUser: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.relPath = relPath
        self.durationSec = durationSec
        self.transcript = transcript
        self.transcriptJSON = transcriptJSON
        self.transcriptState = transcriptState
        self.engine = engine
        self.editedByUser = editedByUser
        self.createdAt = createdAt
    }
}
