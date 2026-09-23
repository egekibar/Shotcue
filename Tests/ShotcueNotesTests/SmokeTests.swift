import Testing

@testable import ShotcueNotes

@Suite("Notes smoke")
struct NotesSmokeTests {
    @Test func moduleLoads() { #expect(ShotcueNotesInfo.moduleName == "ShotcueNotes") }
}
