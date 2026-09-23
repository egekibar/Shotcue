import Foundation
import ImageIO
import Testing

@testable import ShotcueCapture

@Suite("ImageIOThumbnailService")
struct ImageIOThumbnailServiceTests {
    @Test func writesJPEGWithinMaxPixel() async throws {
        let destination = scratchURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await ImageIOThumbnailService()
            .makeThumbnail(from: TestPaths.fixture("sample.png"), to: destination, maxPixel: 32)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let info = try #require(ImageInfo.read(url: destination))
        #expect(info.width <= 32)
        #expect(info.height <= 32)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    /// ImageIO never upscales: a 64x64 source with maxPixel 512 stays 64x64.
    @Test func largerMaxPixelDoesNotUpscale() async throws {
        let destination = scratchURL("jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await ImageIOThumbnailService()
            .makeThumbnail(from: TestPaths.fixture("sample.png"), to: destination, maxPixel: 512)
        let info = try #require(ImageInfo.read(url: destination))
        #expect(info.width == 64 && info.height == 64)
    }

    @Test func throwsForUnreadableSource() async {
        let destination = scratchURL("jpg")
        await #expect(throws: CaptureError.unreadableImage(URL(fileURLWithPath: "/nope/missing.png"))) {
            try await ImageIOThumbnailService()
                .makeThumbnail(
                    from: URL(fileURLWithPath: "/nope/missing.png"),
                    to: destination, maxPixel: 32)
        }
    }

    /// The caller owns the directory (FileStore.ensureParentDirectory); a missing one is an error.
    @Test func throwsWhenDestinationDirectoryMissing() async {
        let destination = URL(fileURLWithPath: "/nope/deep/thumb.jpg")
        await #expect(throws: CaptureError.unreadableImage(destination)) {
            try await ImageIOThumbnailService()
                .makeThumbnail(from: TestPaths.fixture("sample.png"), to: destination, maxPixel: 32)
        }
    }
}
