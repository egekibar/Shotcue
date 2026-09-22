import AppKit
import Foundation

/// Copies a capture to the clipboard in both flavours at once: PNG bytes for Slack/Notion/Figma,
/// the file URL for Finder/Mail. Whichever the consumer asks for, it is there (research §7.5).
public enum PasteboardWriter {
    /// false when the file cannot be read or the pasteboard refused the write; the caller treats
    /// that as "no clipboard copy", never as a failed capture (spec §5.1 step 3 is optional).
    /// `pasteboard` is the system clipboard unless a caller passes another one; tests pass a
    /// private named pasteboard so they never overwrite the user's clipboard.
    @MainActor
    public static func copyPNG(at url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        // One item carrying both flavours: two separate items would make apps that paste every
        // item insert the image and the file.
        let item = NSPasteboardItem()
        let wroteData = item.setData(data, forType: .png)
        let wroteURL = item.setString(url.absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        let wroteItem = pasteboard.writeObjects([item])
        return wroteData && wroteURL && wroteItem
    }
}
