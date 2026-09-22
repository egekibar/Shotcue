import Foundation
import GRDB
import ShotcueCore
import Testing

@testable import ShotcuePersistence

@Suite("PersistenceMaintenance")
struct PersistenceMaintenanceTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    @Test func renumberSpreadsInboxTasksOverEvenSteps() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBTaskRepository(database: database)
        let a = ShotTask(title: "a", sortIndex: 1.0, createdAt: epoch, updatedAt: epoch)
        let b = ShotTask(
            title: "b", sortIndex: 1.0 + 1e-9, createdAt: epoch.addingTimeInterval(1),
            updatedAt: epoch)
        let c = ShotTask(
            title: "c", sortIndex: 2.0, createdAt: epoch.addingTimeInterval(2),
            updatedAt: epoch)
        for task in [c, b, a] { try await repository.save(task) }
        #expect(SortIndex.needsRenumber(a.sortIndex, b.sortIndex))
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: nil)
        let renumbered = try await repository.tasks(projectID: nil)
        #expect(renumbered.map(\.title) == ["a", "b", "c"])
        #expect(renumbered.map(\.sortIndex) == SortIndex.renumbered(count: 3))
        #expect(SortIndex.needsRenumber(renumbered[0].sortIndex, renumbered[1].sortIndex) == false)
    }

    @Test func renumberTouchesOnlyTheGivenProject() async throws {
        let database = try AppDatabase.inMemory()
        let projects = GRDBProjectRepository(database: database)
        let tasks = GRDBTaskRepository(database: database)
        let project = Project(name: "crm", path: "/tmp/crm", sortIndex: 1024, createdAt: epoch)
        try await projects.save(project)
        let inside = ShotTask(
            projectID: project.id, title: "inside", status: .ready, sortIndex: 7,
            createdAt: epoch, updatedAt: epoch)
        let outside = ShotTask(title: "outside", sortIndex: 9, createdAt: epoch, updatedAt: epoch)
        try await tasks.save(inside)
        try await tasks.save(outside)
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: project.id)
        #expect(try await tasks.task(id: inside.id)?.sortIndex == 1024)
        #expect(try await tasks.task(id: outside.id)?.sortIndex == 9)
    }

    @Test func renumberPreservesEveryOtherColumn() async throws {
        let database = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(database: database)
        let task = ShotTask(
            title: "keep me", noteText: "note", status: .scheduled, mode: .analyze,
            modelOverride: "opus", sortIndex: 3, scheduledAt: epoch,
            titleEditedByUser: true, createdAt: epoch, updatedAt: epoch)
        try await tasks.save(task)
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: nil)
        var expected = task
        expected.sortIndex = SortIndex.step
        #expect(try await tasks.task(id: task.id) == expected)
    }

    @Test func renumberOnAnEmptyListIsANoOp() async throws {
        let database = try AppDatabase.inMemory()
        try await PersistenceMaintenance.renumberSortIndexes(in: database, projectID: UUID())
        let repository = GRDBTaskRepository(database: database)
        #expect(try await repository.allTasks().isEmpty)
    }
}
