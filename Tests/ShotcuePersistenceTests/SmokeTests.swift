import Testing

@testable import ShotcuePersistence

@Suite("Persistence smoke")
struct PersistenceSmokeTests {
    @Test func moduleLoads() { #expect(ShotcuePersistenceInfo.moduleName == "ShotcuePersistence") }
}
