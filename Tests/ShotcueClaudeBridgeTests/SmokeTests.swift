import Testing

@testable import ShotcueClaudeBridge

@Suite("ClaudeBridge smoke")
struct ClaudeBridgeSmokeTests {
    @Test func moduleLoads() { #expect(ShotcueClaudeBridgeInfo.moduleName == "ShotcueClaudeBridge") }
}
