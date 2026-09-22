import Foundation
import ShotcueCore
import ShotcueTestSupport
import Testing

@testable import ShotcuePersistence

/// The two implementations of `TaskRepository` that ship in v1.
enum RepositoryFlavor: String, CaseIterable, Sendable {
    case inMemory
    case grdb
}

@Suite("Task repository contract")
struct TaskRepositoryContractTests {
    static let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    /// The GRDB flavour keeps its `AppDatabase` alive through the repository's own
    /// reference, so returning the protocol existential is enough.
    static func makeRepository(_ flavor: RepositoryFlavor) throws -> any TaskRepository {
        switch flavor {
        case .inMemory:
            return InMemoryTaskRepository()
        case .grdb:
            return GRDBTaskRepository(database: try AppDatabase.inMemory())
        }
    }

    @Test(arguments: RepositoryFlavor.allCases)
    func inboxOrderingSearchAndCascade(flavor: RepositoryFlavor) async throws {
        let repository = try Self.makeRepository(flavor)
        let epoch = Self.epoch
        let inboxLate = ShotTask(
            title: "sonra", status: .inbox, sortIndex: 2048,
            createdAt: epoch, updatedAt: epoch)
        let inboxEarly = ShotTask(
            title: "once", status: .inbox, sortIndex: 1024,
            createdAt: epoch, updatedAt: epoch)
        try await repository.save(inboxLate)
        try await repository.save(inboxEarly)
        #expect(try await repository.tasks(projectID: nil).map(\.id) == [inboxEarly.id, inboxLate.id])
        #expect(try await repository.allTasks().map(\.id) == [inboxEarly.id, inboxLate.id])

        try await repository.save(
            Capture(
                taskID: inboxEarly.id, relPath: "captures/a.png",
                width: 10, height: 10, createdAt: epoch))
        try await repository.save(
            VoiceNote(
                taskID: inboxEarly.id, relPath: "audio/a.m4a",
                durationSec: 1, transcript: "cache temizle",
                transcriptState: .done, createdAt: epoch))
        #expect(try await repository.search("CACHE").map(\.id) == [inboxEarly.id])
        #expect(try await repository.search("once").map(\.id) == [inboxEarly.id])
        #expect(try await repository.search("").count == 2)

        try await repository.deleteTask(id: inboxEarly.id)
        #expect(try await repository.captures(taskID: inboxEarly.id).isEmpty)
        #expect(try await repository.voiceNotes(taskID: inboxEarly.id).isEmpty)
        #expect(try await repository.allTasks().map(\.id) == [inboxLate.id])
    }

    @Test(arguments: RepositoryFlavor.allCases)
    func statusFilterAndMoveCapturesBehaveIdentically(flavor: RepositoryFlavor) async throws {
        let repository = try Self.makeRepository(flavor)
        let epoch = Self.epoch
        let ready = ShotTask(
            title: "ready", status: .ready, sortIndex: 1024,
            createdAt: epoch, updatedAt: epoch)
        let done = ShotTask(
            title: "done", status: .done, sortIndex: 2048,
            createdAt: epoch, updatedAt: epoch)
        try await repository.save(ready)
        try await repository.save(done)
        #expect(try await repository.tasks(status: .ready).map(\.id) == [ready.id])
        #expect(try await repository.tasks(status: .queued).isEmpty)
        #expect(try await repository.task(id: UUID()) == nil)

        let capture = Capture(
            taskID: ready.id, relPath: "captures/a.png", width: 4, height: 4,
            createdAt: epoch)
        try await repository.save(capture)
        try await repository.moveCaptures(ids: [capture.id], toTaskID: done.id)
        #expect(try await repository.captures(taskID: ready.id).isEmpty)
        #expect(try await repository.captures(taskID: done.id).map(\.id) == [capture.id])
    }

    @Test(arguments: RepositoryFlavor.allCases)
    func observationEmitsCurrentValueThenEveryChange(flavor: RepositoryFlavor) async throws {
        let repository = try Self.makeRepository(flavor)
        let epoch = Self.epoch
        var iterator = repository.observeAllTasks().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        try await repository.save(
            ShotTask(
                title: "b", sortIndex: 2048, createdAt: epoch,
                updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["b"])
        try await repository.save(
            ShotTask(
                title: "a", sortIndex: 1024, createdAt: epoch,
                updatedAt: epoch))
        #expect(await iterator.next()?.map(\.title) == ["a", "b"])

        var inboxIterator = repository.observeTasks(projectID: nil).makeAsyncIterator()
        #expect(await inboxIterator.next()?.map(\.title) == ["a", "b"])
    }
}
