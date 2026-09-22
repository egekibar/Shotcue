import AppKit
import Foundation
import Testing

@testable import ShotcueCapture

/// Every test writes to a private, uniquely named pasteboard and releases it afterwards:
/// running the suite must never overwrite the user's clipboard (the general pasteboard).
@Suite("PasteboardWriter")
struct PasteboardWriterTests {
    /// Both representations must land: consumers pick whichever they understand (research §7.5).
    /// They share one pasteboard item, so apps that paste every item insert the capture once.
    @MainActor
    @Test func writesPNGDataAndFileURL() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shotcue-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let url = TestPaths.fixture("sample.png")
        #expect(PasteboardWriter.copyPNG(at: url, to: pasteboard) == true)
        #expect(pasteboard.pasteboardItems?.count == 1)
        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.types.contains(.png))
        #expect(item.types.contains(.fileURL))
        #expect(pasteboard.data(forType: .png) != nil)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        #expect(urls.contains { $0.lastPathComponent == "sample.png" })
    }

    @MainActor
    @Test func returnsFalseForMissingFile() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shotcue-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(PasteboardWriter.copyPNG(at: URL(fileURLWithPath: "/nope/missing.png"), to: pasteboard) == false)
    }
}
