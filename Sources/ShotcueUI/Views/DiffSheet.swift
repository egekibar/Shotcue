import AppKit
import ShotcueCore
import SwiftUI

/// The run's code comparison screen (spec §6.4): changed files on the left, the selected file's unified diff
/// with old/new line numbers on the right. Lines render in a lazy stack, because one `Text` holding up to
/// 1 MB freezes layout; "Tümünü kopyala" copies the raw patch.
public struct DiffSheet: View {
    public let document: DiffDocument
    public let text: String
    public let onClose: () -> Void

    @UIState private var selection: DiffFile.ID?
    @FocusState private var isListFocused: Bool

    public init(document: DiffDocument, text: String, onClose: @escaping () -> Void) {
        self.document = document
        self.text = text
        self.onClose = onClose
    }

    var initialSelection: DiffFile.ID? { document.files.first?.id }

    /// "3 dosya · +120 −34".
    var summary: String {
        "\(document.files.count) dosya · +\(document.additions) −\(document.deletions)"
    }

    private var selectedFile: DiffFile? {
        guard let id = selection ?? initialSelection else { return nil }
        return document.files.first { $0.id == id }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if document.files.isEmpty {
                ContentUnavailableView(
                    "Değişiklik yok", systemImage: "checkmark.circle",
                    description: Text("Bu çalıştırmadan sonra çalışma ağacında fark bulunmadı."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                    Group {
                        if let file = selectedFile {
                            DiffFileView(file: file)
                                .id(file.id)
                        } else {
                            ContentUnavailableView("Bir dosya seçin", systemImage: "doc.text")
                        }
                    }
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if document.isTruncated {
                Label(
                    "Çıktı \(DiffText.defaultMaxBytes / 1_000_000) MB sınırında kesildi; son dosya eksik olabilir, sonrakiler listede yok.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
            Divider()
            HStack {
                if !document.files.isEmpty {
                    Text(summary)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Dosyayı kopyala", systemImage: "doc.on.clipboard") {
                    if let file = selectedFile { Self.copy(file.patchText, to: .general) }
                }
                .disabled(selectedFile == nil)
                Button("Tümünü kopyala", systemImage: "doc.on.doc") {
                    Self.copy(text, to: .general)
                }
                .disabled(text.isEmpty)
                Button("Kapat") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 960, idealWidth: 1200, minHeight: 600, idealHeight: 800)
        .onAppear {
            if selection == nil { selection = initialSelection }
            isListFocused = true
        }
    }

    private var fileList: some View {
        List(document.files, selection: $selection) { file in
            DiffFileRow(file: file)
                .tag(file.id)
        }
        .listStyle(.sidebar)
        .focused($isListFocused)
    }

    /// Replaces the pasteboard's contents with `text`. Tests pass a private pasteboard.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// One entry of the file list: status badge, name over its folder, and the +/− counts.
struct DiffFileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.badge)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(file.status.color, in: RoundedRectangle(cornerRadius: 4))
                .help(file.status.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.isBinary {
                Text("ikili").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(.green) }
                    if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(.red) }
                }
                .font(.caption.monospacedDigit())
            }
        }
        .help(file.path)
    }
}

/// The selected file: its path header, then every hunk line with old/new numbers.
struct DiffFileView: View {
    let file: DiffFile
    let rows: DiffRows

    init(file: DiffFile) {
        self.file = file
        self.rows = DiffRows(file: file)
    }

    /// Width of one line-number column: digits of monospaced 12 pt plus padding.
    private var gutterWidth: CGFloat { CGFloat(rows.gutterDigits) * 7.3 + 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(file.status.badge)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(file.status.color)
                if let oldPath = file.oldPath {
                    Text(oldPath).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                }
                Text(file.path)
                    .textSelection(.enabled)
                Spacer()
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if rows.rows.isEmpty {
                ContentUnavailableView(
                    file.isBinary ? "İkili dosya" : "Gösterilecek satır yok",
                    systemImage: file.isBinary ? "doc.zipper" : "doc",
                    description: Text(
                        file.isBinary
                            ? "İkili dosyaların içeriği karşılaştırılmaz."
                            : "Dosya boş, yalnızca taşındı ya da izinleri değişti."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.rows) { row in
                            DiffRowView(row: row, gutterWidth: gutterWidth)
                        }
                    }
                }
            }
        }
    }
}

struct DiffRowView: View {
    let row: DiffRow
    let gutterWidth: CGFloat

    var body: some View {
        switch row.content {
        case .hunkHeader(let header):
            Text(header)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, gutterWidth * 2 + 20)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08))
        case .line(let line):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(line.oldNumber)
                number(line.newNumber)
                Text(line.kind.marker)
                    .foregroundStyle(line.kind.markerColor)
                    .frame(width: 20)
                Text(line.kind == .noNewline ? "Dosya sonunda satır sonu yok" : Self.displayed(line.text))
                    .italic(line.kind == .noNewline)
                    .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 1)
            .background(line.kind.background)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 4)
            .background(Color.primary.opacity(0.03))
    }

    /// Tabs as four spaces: `Text` draws a tab narrower than an editor would.
    static func displayed(_ text: String) -> String {
        text.isEmpty ? " " : text.replacingOccurrences(of: "\t", with: "    ")
    }
}

/// A file's hunks flattened into one identifiable list for `LazyVStack`, built once per selection.
struct DiffRows {
    let rows: [DiffRow]
    /// Digits of the largest line number, so both number columns stay one width for the whole file.
    let gutterDigits: Int

    init(file: DiffFile) {
        var rows: [DiffRow] = []
        var largest = 0
        for hunk in file.hunks {
            rows.append(DiffRow(id: rows.count, content: .hunkHeader(hunk.header)))
            for line in hunk.lines {
                rows.append(DiffRow(id: rows.count, content: .line(line)))
                largest = max(largest, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        self.rows = rows
        self.gutterDigits = max(String(largest).count, 2)
    }
}

struct DiffRow: Identifiable {
    enum Content {
        case hunkHeader(String)
        case line(DiffLine)
    }

    let id: Int
    let content: Content
}

extension DiffFile.Status {
    var badge: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    var label: String {
        switch self {
        case .added: "Eklendi"
        case .modified: "Değiştirildi"
        case .deleted: "Silindi"
        case .renamed: "Taşındı"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        }
    }
}

extension DiffLine.Kind {
    var marker: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        case .context, .noNewline: ""
        }
    }

    var markerColor: Color {
        switch self {
        case .added: .green
        case .removed: .red
        case .context, .noNewline: .secondary
        }
    }

    var background: Color {
        switch self {
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        case .context, .noNewline: .clear
        }
    }
}
