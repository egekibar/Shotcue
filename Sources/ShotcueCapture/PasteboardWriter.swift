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
        pasteboard.clearContents()
        let wroteData = pasteboard.setData(data, forType: .png)
        let wroteURL = pasteboard.writeObjects([url as NSURL])
        return wroteData && wroteURL
    }
}
