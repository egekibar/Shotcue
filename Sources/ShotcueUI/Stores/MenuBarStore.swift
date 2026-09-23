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

    /// Stream loops hold the store weakly and re-bind `self` per element, so a store that is dropped
    /// without `stop()` is not kept alive by a stream that never ends.
    public func start() {
        guard streams.isEmpty else { return }
        let taskStream = services.tasks.observeAllTasks()
        let dispatcher = services.dispatcher
        streams.append(
            Task { [weak self] in
                for await list in taskStream {
                    guard let self else { return }
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
                let paused = await dispatcher.isPaused()
                self?.isPaused = paused
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
