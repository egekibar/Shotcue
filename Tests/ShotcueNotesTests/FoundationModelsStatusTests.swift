import Foundation
import Testing

@testable import ShotcueNotes

@Suite("FoundationModelsStatus")
struct FoundationModelsStatusTests {
    @Test func currentStatusIsOneOfTheKnownCases() {
        #expect(FoundationModelsStatus.allCases.contains(FoundationModelsStatus.current))
    }

    @Test func availabilityFlagAgreesWithTheStatus() {
        #expect(FoundationModelsStatus.isAvailable == (FoundationModelsStatus.current == .available))
    }

    @Test func everyCaseHasTurkishCopy() {
        for status in FoundationModelsStatus.allCases {
            #expect(!status.localizedDescription.isEmpty)
        }
    }
}
