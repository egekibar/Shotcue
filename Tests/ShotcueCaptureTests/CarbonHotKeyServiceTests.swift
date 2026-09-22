import Foundation
import ShotcueCore
import Testing

@testable import ShotcueCapture

/// Actual key delivery cannot be tested headlessly: Carbon needs a real application event target
/// with a running event loop, and no permission exists to synthesise a system-wide key press.
/// It is verified manually in Plan 06 with `make run` (press ⌃⇧2, the quick panel must open).
/// These tests cover registration, replacement and teardown, which is where the bugs live.
@Suite("CarbonHotKeyService")
struct CarbonHotKeyServiceTests {
    @MainActor
    @Test func registersAndUnregistersDefaultCombo() throws {
        let service = CarbonHotKeyService()
        #expect(service.registeredCombo == nil)
        try service.register(.defaultCombo) {}
        #expect(service.registeredCombo == KeyCombo.defaultCombo)
        service.unregister()
        #expect(service.registeredCombo == nil)
    }

    @MainActor
    @Test func secondRegistrationReplacesTheFirst() throws {
        let service = CarbonHotKeyService()
        try service.register(KeyCombo.presets[0]) {}
        try service.register(KeyCombo.presets[1]) {}
        #expect(service.registeredCombo == KeyCombo.presets[1])
        service.unregister()
    }

    @MainActor
    @Test func unregisterIsIdempotentAndReRegistrationWorks() throws {
        let service = CarbonHotKeyService()
        service.unregister()
        try service.register(.defaultCombo) {}
        service.unregister()
        service.unregister()
        try service.register(.defaultCombo) {}
        #expect(service.registeredCombo == KeyCombo.defaultCombo)
        service.unregister()
    }

    /// Carbon refuses a combo another registration already holds: -9878 eventHotKeyExistsErr.
    /// The failed service must be left clean so the UI can offer a different preset.
    @MainActor
    @Test func duplicateComboReportsCarbonStatus() throws {
        let holder = CarbonHotKeyService()
        try holder.register(.defaultCombo) {}
        defer { holder.unregister() }
        let second = CarbonHotKeyService()
        #expect(throws: HotKeyError.registrationFailed(OSStatus(-9878))) {
            try second.register(.defaultCombo) {}
        }
        #expect(second.registeredCombo == nil)
    }
}
