import CoreGraphics
import Foundation
import ImageIO
import ShotcueCore
import UniformTypeIdentifiers

/// JPEG thumbnails via ImageIO — roughly 30x faster than redrawing through NSImage
/// (~26 ms for a 12 MP source, research §7.2). Always off the main thread: the library grid
/// asks for a hundred of these at once.
///
/// JPEG at quality 0.8 is fine here because the thumbnail is only ever a grid tile; the master
/// screenshot stays PNG so text edges survive for Claude to read (research §7.1).
public struct ImageIOThumbnailService: ThumbnailService {
    public init() {}

    public func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws {
        try await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                // Always decode from the full image: an embedded EXIF thumbnail may be tiny or absent.
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    imageSource, 0, options as CFDictionary)
            else { throw CaptureError.unreadableImage(source) }

            // Returns nil when the parent directory is missing or not writable.
            guard
                let output = CGImageDestinationCreateWithURL(
                    destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw CaptureError.unreadableImage(destination) }
            CGImageDestinationAddImage(
                output, thumbnail,
                [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(output) else {
                throw CaptureError.unreadableImage(destination)
            }
        }.value
    }
}
