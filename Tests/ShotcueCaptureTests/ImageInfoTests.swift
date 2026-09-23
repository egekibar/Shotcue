import Foundation
import Testing

@testable import ShotcueCapture

@Suite("ImageInfo")
struct ImageInfoTests {
    /// sample.png is 64x64 pixels written with 144 dpi, so the Retina scale is 144/72 = 2.
    @Test func readsPixelSizeAndRetinaScale() throws {
        let info = try #require(ImageInfo.read(url: TestPaths.fixture("sample.png")))
        #expect(info.width == 64)
        #expect(info.height == 64)
        #expect(info.scale == 2.0)
    }

    @Test func returnsNilForNonImageFile() throws {
        let url = scratchURL("txt")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImageInfo.read(url: url) == nil)
    }

    @Test func returnsNilForMissingFile() {
        #expect(ImageInfo.read(url: URL(fileURLWithPath: "/nope/missing.png")) == nil)
    }
}
