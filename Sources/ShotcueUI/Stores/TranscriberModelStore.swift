import Foundation
import Observation
import ShotcueCore

/// The on-device transcription model as the UI sees it (spec §6.2): its state, its download size, and the one
/// download flow that Settings > Ses, the quick panel and the inspector share (final review C1 (c)).
///
/// The model is downloaded only by `startDownload()`, which only an explicit click calls ("Model ilk kullanımda açık
/// onayla indirilir"): nothing here — and nothing that reads `state` — ever starts a download on its own.
@MainActor
@Observable
public final class TranscriberModelStore {
    public private(set) var state: TranscriberModelState = .notDownloaded
    /// The model the running transcriber was built with (a model change takes effect after a restart).
    public let modelName: String

    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored private let transcriptionQueue: any TranscriptionQueue
    @ObservationIgnored private var download: Task<Void, Never>?
    /// How often the progress is mirrored while downloading. Internal so tests can shorten it.
    @ObservationIgnored var progressPollInterval: Duration = .milliseconds(500)

    /// The download in progress (test hook).
    var downloadTask: Task<Void, Never>? { download }

    public init(transcriber: any Transcriber, transcriptionQueue: any TranscriptionQueue, modelName: String) {
        self.transcriber = transcriber
        self.transcriptionQueue = transcriptionQueue
        self.modelName = modelName
    }

    public var isReady: Bool { state == .ready }

    /// Shown on every download button (spec §6.2: "boyut gösterilir").
    public var downloadSizeText: String { Self.downloadSizeText(forModel: modelName) }

    /// Sizes of the two models Ayarlar > Ses offers (research 03: 1.64 GB and 632 MB).
    nonisolated public static func downloadSizeText(forModel name: String) -> String {
        switch name {
        case "openai_whisper-large-v3-v20240930_turbo_632MB": "≈632 MB"
        case "openai_whisper-large-v3-v20240930_turbo": "≈1,6 GB"
        default: "boyutu bilinmiyor"
        }
    }

    /// Re-reads the transcriber's state. While a download runs, its own progress stays on screen.
    public func refresh() async {
        guard download == nil else { return }
        let current = await transcriber.modelState()
        guard download == nil else { return }
        state = current
    }

    /// "Modeli indir" (Settings, the quick panel, the inspector). A second click while downloading does nothing.
    /// The progress is mirrored every `progressPollInterval`; once the model is in, the voice notes that waited for
    /// it are transcribed.
    public func startDownload() {
        guard download == nil else { return }
        state = .downloading(progress: 0)
        let transcriber = transcriber
        let queue = transcriptionQueue
        let interval = progressPollInterval
        download = Task { [weak self] in
            let progressPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    let polled = await transcriber.modelState()
                    if !Task.isCancelled, case .downloading = polled { self?.state = polled }
                }
            }
            var failure: (any Error)?
            do {
                try await transcriber.downloadModel()
            } catch {
                failure = error
            }
            // Awaited before the final state is written, so a late poll cannot overwrite it.
            progressPoll.cancel()
            await progressPoll.value
            let final = await transcriber.modelState()
            guard let self else { return }
            if let failure {
                state = .failed(failure.localizedDescription)
            } else {
                state = final
                Task.detached(priority: .utility) { await queue.processPending() }
            }
            download = nil
        }
    }
}

/// What a voice note's transcript waits for, as the inspector and the quick panel say it (spec §6.2): a note
/// recorded without the model reads "model indirilmedi", never an endless "çevriliyor".
nonisolated public enum VoiceNoteStatus: Hashable, Sendable {
    /// The model is ready and the note is in the transcription queue.
    case transcribing
    /// The model has not been downloaded; the note waits for it.
    case waitingForModel
    case modelDownloading(Double)
    /// The model could not be loaded; the note waits until it is downloaded again.
    case modelUnavailable
    /// The transcription failed and the user typed nothing for it.
    case failed
    case edited
    case done

    /// `model` is nil when the caller cannot tell (no model store): a pending note then reads "çevriliyor".
    nonisolated public static func of(_ note: VoiceNote, model: TranscriberModelState?) -> VoiceNoteStatus {
        if note.editedByUser { return .edited }
        switch note.transcriptState {
        case .done: return .done
        case .failed: return .failed
        case .pending:
            switch model {
            case .ready, nil: return .transcribing
            case .notDownloaded: return .waitingForModel
            case .downloading(let progress): return .modelDownloading(progress)
            case .failed: return .modelUnavailable
            }
        }
    }

    nonisolated public var label: String? {
        switch self {
        case .transcribing: "çevriliyor"
        case .waitingForModel: "model indirilmedi"
        case .modelDownloading(let progress): "model indiriliyor %\(Int((progress * 100).rounded()))"
        case .modelUnavailable: "model yüklenemedi"
        case .failed: "çevrilemedi"
        case .edited: "düzenlendi"
        case .done: nil
        }
    }

    /// The note waits for a model the user can download with one click.
    nonisolated public var offersModelDownload: Bool {
        self == .waitingForModel || self == .modelUnavailable
    }
}
