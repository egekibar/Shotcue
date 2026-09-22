import Foundation
import Observation
import ShotcueCore

/// Feeds the menu bar window (spec §5.5): the last five tasks with their status, the running/queued
/// counters and the pause switch.
@MainActor
@Observable
public final class MenuBarStore {
    public static let recentLimit = 5

    public private(set) var recentTasks: [ShotTask] = []
    public private(set) var runningCount = 0
    public private(set) var queuedCount = 0
    public private(set) var isPaused = false

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var streams: [Task<Void, Never>] = []

    public init(services: AppServices) {
        self.services = services
    }

    public func start() {
        guard streams.isEmpty else { return }
        streams.append(
            Task { [weak self] in
                guard let self else { return }
                for await list in self.services.tasks.observeAllTasks() {
                    self.recentTasks =
                        list
                        .sorted { $0.updatedAt > $1.updatedAt }
                        .prefix(Self.recentLimit)
                        .map { $0 }
                    self.runningCount = list.count { $0.status == .running }
                    self.queuedCount = list.count { $0.status == .queued }
                }
            })
        streams.append(
            Task { [weak self] in
                guard let self else { return }
                self.isPaused = await self.services.dispatcher.isPaused()
            })
    }

    public func stop() {
        for stream in streams { stream.cancel() }
        streams.removeAll()
    }

    public func runQueueNow() async {
        await services.dispatcher.runQueueNow()
    }

    public func togglePaused() async {
        await services.dispatcher.setPaused(!isPaused)
        isPaused = await services.dispatcher.isPaused()
    }
}
