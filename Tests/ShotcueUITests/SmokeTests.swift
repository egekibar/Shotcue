import Testing

@testable import ShotcueUI

@Suite("UI smoke")
struct UISmokeTests {
    @Test func moduleLoads() { #expect(ShotcueUIInfo.moduleName == "ShotcueUI") }
}
