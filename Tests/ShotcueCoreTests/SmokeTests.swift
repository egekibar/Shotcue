import Testing

@testable import ShotcueCore

@Suite("Core smoke")
struct CoreSmokeTests {
    @Test func moduleLoads() {
        #expect(ShotcueCoreInfo.moduleName == "ShotcueCore")
    }
}
