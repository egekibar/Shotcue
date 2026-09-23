import Foundation
import GRDB
import ShotcueCore
import Testing

@testable import ShotcuePersistence

@Suite("GRDBProjectRepository")
struct GRDBProjectRepositoryTests {
    let epoch = Date(timeIntervalSince1970: 1_758_500_000)

    func project(_ name: String, sort: Double, created: TimeInterval = 0) -> Project {
        Project(
            name: name, path: "/tmp/\(name)", sortIndex: sort,
            createdAt: epoch.addingTimeInterval(created))
    }

    @Test func allProjectsOrdersBySortIndexThenCreatedAt() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        let late = project("late", sort: 2048)
        let tie2 = project("tie2", sort: 1024, created: 5)
        let tie1 = project("tie1", sort: 1024, created: 1)
        for candidate in [late, tie2, tie1] { try await repository.save(candidate) }
        #expect(try await repository.allProjects().map(\.name) == ["tie1", "tie2", "late"])
    }

    @Test func getReturnsNilForUnknownID() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        #expect(try await repository.project(id: UUID()) == nil)
    }

    @Test func saveUpsertsInsteadOfDuplicating() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        var value = project("crm", sort: 1024)
        try await repository.save(value)
        value.name = "crm-renamed"
        value.dailyTime = DailyTime(hour: 7, minute: 5)
        value.dailyEnabled = true
        try await repository.save(value)
        let all = try await repository.allProjects()
        #expect(all.count == 1)
        #expect(all.first?.name == "crm-renamed")
        #expect(all.first?.dailyTime == DailyTime(hour: 7, minute: 5))
        #expect(all.first?.dailyEnabled == true)
    }

    @Test func deleteRemovesTheRowAndNullsTaskProjectID() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBProjectRepository(database: database)
        let value = project("crm", sort: 1024)
        try await repository.save(value)
        let task = ShotTask(
            projectID: value.id, title: "t", status: .ready, sortIndex: 1024,
            createdAt: epoch, updatedAt: epoch)
        try await database.writer.write { db in try TaskRecord(task).upsert(db) }
        try await repository.deleteProject(id: value.id)
        #expect(try await repository.allProjects().isEmpty)
        let orphaned = try await database.reader.read { db in
            try #require(try TaskRecord.fetchOne(db, key: task.id.dbKey)).model()
        }
        #expect(orphaned.projectID == nil)
    }

    @Test func observeProjectsEmitsCurrentValueThenChanges() async throws {
        let repository = GRDBProjectRepository(database: try AppDatabase.inMemory())
        try await repository.save(project("first", sort: 1024))
        var iterator = repository.observeProjects().makeAsyncIterator()
        #expect(await iterator.next()?.map(\.name) == ["first"])
        try await repository.save(project("second", sort: 2048))
        #expect(await iterator.next()?.map(\.name) == ["first", "second"])
    }
}
