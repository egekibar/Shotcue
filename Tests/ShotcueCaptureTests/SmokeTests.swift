import Testing

@testable import ShotcueCapture

@Suite("Capture smoke")
struct CaptureSmokeTests {
    @Test func moduleLoads() { #expect(ShotcueCaptureInfo.moduleName == "ShotcueCapture") }
}
