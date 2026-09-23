import Foundation
import ShotcueCore

/// What every send path shows when `claude` is missing (quick panel, library, inspector, notification
/// "Yeniden çalıştır"): the stores display `localizedDescription`.
nonisolated struct ClaudeMissingError: LocalizedError, Equatable {
    var errorDescription: String? {
        "claude bulunamadı — Ayarlar > Claude'dan yolu ayarlayıp Shotcue'yu yeniden başlatın."
    }
}

/// Spec §8 "`claude` bulunamadı → … gönder düğmeleri devre dışı". The buttons are Plan 05's, so the refusal
/// happens one layer down, in the dispatcher every sender shares (AppServices → quick panel, library,
/// inspector; SchedulerDriver): with no executable, `enqueue` throws `ClaudeMissingError` and
/// `runQueueNow` does nothing, instead of queueing runs that each end in a RUN_FAILED banner.
/// Everything else goes straight to the coordinator.
nonisolated final class ClaudeGatedDispatcher: TaskDispatcher {
    private let base: any TaskDispatcher
    private let locator: ClaudeExecutableLocator

    init(base: any TaskDispatcher, locator: ClaudeExecutableLocator) {
        self.base = base
        self.locator = locator
    }

    /// Waits for the locator's background search (only possible in the first seconds after launch), so a
    /// send is refused exactly when `claude` is known to be missing.
    func enqueue(taskID: UUID) async throws {
        guard await locator.executable() != nil else { throw ClaudeMissingError() }
        try await base.enqueue(taskID: taskID)
    }

    func cancel(taskID: UUID) async {
        await base.cancel(taskID: taskID)
    }

    func runQueueNow() async {
        guard await locator.executable() != nil else { return }
        await base.runQueueNow()
    }

    func setPaused(_ paused: Bool) async {
        await base.setPaused(paused)
    }

    func isPaused() async -> Bool {
        await base.isPaused()
    }

    func liveEvents(runID: UUID) -> AsyncStream<RunEvent> {
        base.liveEvents(runID: runID)
    }
}
