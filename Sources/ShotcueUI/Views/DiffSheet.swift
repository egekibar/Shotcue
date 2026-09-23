import AppKit
import SwiftUI

/// Plain-text diff of a run (spec §6.4). Rendered one row per line in a lazy stack, because a single
/// `Text` holding up to 1 MB freezes layout; each line is selectable and "Tümünü kopyala" copies the lot.
public struct DiffSheet: View {
    public let text: String
    public let onClose: () -> Void
    /// `text` split once here rather than on every body evaluation.
    let lines: [String]

    public init(text: String, onClose: @escaping () -> Void) {
        self.text = text
        self.onClose = onClose
        self.lines = text.isEmpty ? ["Değişiklik yok."] : text.components(separatedBy: "\n")
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        // A blank line keeps its height.
                        Text(lines[index].isEmpty ? " " : lines[index])
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Divider()
            HStack {
                Button("Tümünü kopyala", systemImage: "doc.on.doc") {
                    Self.copy(text, to: .general)
                }
                Spacer()
                Button("Kapat") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// Replaces the pasteboard's contents with `text`. Tests pass a private pasteboard.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
