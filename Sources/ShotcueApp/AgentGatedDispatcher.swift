import Foundation
import ShotcueCore

/// What every send path shows when the task's agent CLI is missing (quick panel, library, inspector,
/// notification "Yeniden çalıştır"): the stores display `localizedDescription`.
nonisolated struct AgentMissingError: LocalizedError, Equatable {
    var agent: AgentKind = .claude

    var errorDescription: String? {
        "\(agent.executableName) bulunamadı — Ayarlar > Ajanlar'dan yolu ayarlayıp Shotcue'yu yeniden başlatın."
    }
}

/// Spec §8 "`claude` bulunamadı → … gönder düğmeleri devre dışı". The buttons are Plan 05's, so the refusal
/// happens one layer down, in the dispatcher every sender shares (AppServices → quick panel, library,
/// inspector; SchedulerDriver): with no executable for the task's agent, `enqueue` throws `AgentMissingError`,
/// and with no agent CLI at all `runQueueNow` does nothing, instead of queueing runs that each end in a
/// RUN_FAILED banner. Everything else goes straight to the coordinator.
nonisolated final class AgentGatedDispatcher: TaskDispatcher {
    private let base: any TaskDispatcher
    private let locators: AgentLocators
    /// The agent the task's run would go to (its project's, else the Settings default).
    private let agentForTask: @Sendable (UUID) async -> AgentKind

    init(
        base: any TaskDispatcher, locators: AgentLocators,
        agentForTask: @escaping @Sendable (UUID) async -> AgentKind
    ) {
        self.base = base
        self.locators = locators
        self.agentForTask = agentForTask
    }

    /// Waits for the locator's background search (only possible in the first seconds after launch), so a
    /// send is refused exactly when the agent's CLI is known to be missing.
    func enqueue(taskID: UUID) async throws {
        let agent = await agentForTask(taskID)
        guard await locators[agent].executable() != nil else { throw AgentMissingError(agent: agent) }
        try await base.enqueue(taskID: taskID)
    }

    func cancel(taskID: UUID) async {
        await base.cancel(taskID: taskID)
    }

    func runQueueNow() async {
        guard await locators.anyFound() else { return }
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
