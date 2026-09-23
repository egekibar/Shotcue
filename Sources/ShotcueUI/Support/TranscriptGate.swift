import Foundation
import ShotcueCore

/// Final review C1: every send path (quick panel ⌘⇧↩, inspector send/retry, library send/sendAsOne) hands a task
/// to the dispatcher only when each of its voice notes has usable text. A pending transcript is waited for, bounded,
/// while the model can produce it; anything else is refused with a Turkish reason. `RunCoordinator` refuses the
/// same tasks again right before launch (the backstop), so a path that skipped this gate still never sends a task
/// without its voice note.
struct TranscriptGate: Sendable {
    enum Decision: Hashable, Sendable {
        /// Every note has usable text: enqueue now.
        case send
        /// A transcript is on its way and the model can produce it: wait, then decide again.
        case wait
        /// The send cannot go out; the Turkish reason for the user.
        case refuse(String)
    }

    let services: AppServices
    var timeout: Duration = TranscriptGate.defaultTimeout
    var pollInterval: Duration = .milliseconds(500)

    /// "about 3 min" (controller ruling C1): long enough for a first transcription while the model loads.
    static let defaultTimeout: Duration = .seconds(180)

    /// What a send of `taskID` should do right now.
    func decide(taskID: UUID) async -> Decision {
        let notes: [VoiceNote]
        do {
            notes = try await services.tasks.voiceNotes(taskID: taskID)
        } catch {
            return .refuse(Self.unreadableMessage)
        }
        switch VoiceNoteReadiness.of(notes) {
        case .ready:
            return .send
        case .failed:
            return .refuse(Self.failedMessage)
        case .pending:
            if let refusal = Self.modelRefusal(await services.transcriber.modelState()) { return .refuse(refusal) }
            return .wait
        }
    }

    /// Waits until every task in `taskIDs` can be sent or never will, for at most `timeout`. Each task ends up
    /// `.send` or `.refuse`; a task still waiting at the deadline (or when the wait is cancelled) is refused.
    func waitForTranscripts(of taskIDs: [UUID]) async -> [UUID: Decision] {
        var outcomes: [UUID: Decision] = [:]
        var waiting = taskIDs
        await nudgeTranscription(of: waiting)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !waiting.isEmpty, !Task.isCancelled {
            var stillWaiting: [UUID] = []
            for taskID in waiting {
                let decision = await decide(taskID: taskID)
                if decision == .wait {
                    stillWaiting.append(taskID)
                } else {
                    outcomes[taskID] = decision
                }
            }
            waiting = stillWaiting
            guard !waiting.isEmpty, ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: pollInterval)
        }
        for taskID in waiting { outcomes[taskID] = .refuse(Self.timeoutMessage) }
        return outcomes
    }

    /// Makes sure the transcription queue is working on the pending notes (a no-op when it already is). Not
    /// awaited: the production queue returns only once every pending note is transcribed.
    private func nudgeTranscription(of taskIDs: [UUID]) async {
        var pendingNoteIDs: [UUID] = []
        for taskID in taskIDs {
            let notes = (try? await services.tasks.voiceNotes(taskID: taskID)) ?? []
            pendingNoteIDs += notes.filter(\.isAwaitingTranscript).map(\.id)
        }
        let queue = services.transcriptionQueue
        for noteID in pendingNoteIDs {
            Task.detached(priority: .utility) { await queue.enqueue(voiceNoteID: noteID) }
        }
    }

    // MARK: - Messages (user-visible, Turkish)

    static let failedMessage =
        "Sesli not yazıya dökülemedi, bu yüzden görev gönderilmedi. Inspector'da transkripti elle yaz ya da "
        + "\"Yeniden çevir\"e bas, sonra yeniden gönder."

    static let timeoutMessage =
        "Sesli not 3 dakika içinde yazıya dökülemedi, bu yüzden görev gönderilmedi. Transkript bitince yeniden gönder."

    static let unreadableMessage = "Sesli notlar okunamadı, bu yüzden görev gönderilmedi. Yeniden dene."

    /// Why a pending transcript cannot be waited for; nil when the model is ready.
    static func modelRefusal(_ state: TranscriberModelState) -> String? {
        switch state {
        case .ready:
            return nil
        case .notDownloaded:
            return "Sesli not yazıya dökülmeden gönderilemez: transkripsiyon modeli indirilmedi. "
                + "Ayarlar > Ses'ten modeli indir; not, model inince yazıya dökülür."
        case .downloading(let progress):
            return "Transkripsiyon modeli indiriliyor (%\(Int((progress * 100).rounded()))). "
                + "İndirme bitip sesli not yazıya dökülünce yeniden gönder."
        case .failed:
            return "Transkripsiyon modeli yüklenemedi, sesli not yazıya dökülemiyor. "
                + "Ayarlar > Ses'te hatayı görüp modeli yeniden indirebilirsin."
        }
    }
}
