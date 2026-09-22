import CoreGraphics
import Foundation
import ImageIO

/// Pixel size and Retina scale read straight out of the image metadata.
/// `screencapture` writes DPI (144 on a 2x display), so the scale never has to be guessed from
/// `NSScreen`'s backing scale factor — the only correct source on mixed-DPI setups (spec §6.1, research §7.4).
public enum ImageInfo {
    /// nil when the file is missing or ImageIO cannot parse it as an image.
    public static func read(url: URL) -> (width: Int, height: Int, scale: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // No DPI in the file (thumbnails we write ourselves, screencapture with -r) means 1x.
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double
        let scale = dpi.map { $0 > 0 ? $0 / 72 : 1 } ?? 1
        return (width: width, height: height, scale: scale)
    }
}
