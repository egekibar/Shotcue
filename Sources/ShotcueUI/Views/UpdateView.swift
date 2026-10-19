import ShotcueCore
import SwiftUI

/// The update window's content: whatever `UpdateStore` is doing, with the actions that fit it.
public struct UpdateView: View {
    public let store: UpdateStore
    /// Closes the window (the store is told separately, through `dismiss()` / `skip()`).
    public let close: () -> Void

    @Environment(\.openURL) private var openURL

    public init(store: UpdateStore, close: @escaping () -> Void) {
        self.store = store
        self.close = close
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(symbolColor)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .idle, .checking:
            Text(L10n.t("Checking for updates…")).font(.headline)
            ProgressView().controlSize(.small)
            buttons { Button(L10n.t("Close"), action: dismiss).keyboardShortcut(.cancelAction) }

        case .upToDate:
            Text(L10n.t("Shotcue is up to date")).font(.headline)
            Text(L10n.t("The version you use (\(store.currentVersion.description)) is the latest."))
                .foregroundStyle(.secondary)
            buttons { Button(L10n.t("OK"), action: dismiss).keyboardShortcut(.defaultAction) }

        case .available(let release):
            header(release)
            notes(release)
            HStack {
                Button(L10n.t("Skip This Version")) {
                    store.skip()
                    close()
                }
                Spacer()
                Button(L10n.t("Later"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(L10n.t("Update")) { Task { await store.install() } }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading(let release, let progress):
            header(release)
            ProgressView(value: progress) {
                Text(L10n.t("Downloading…")).font(.callout)
            }
            Text(L10n.t("When the download is done, Shotcue quits and reopens with the new version."))
                .font(.callout).foregroundStyle(.secondary)

        case .installing(let release):
            header(release)
            ProgressView().controlSize(.small)
            Text(L10n.t("Shotcue is restarting…")).font(.callout).foregroundStyle(.secondary)

        case .failed(let release, let message):
            Text(release == nil ? L10n.t("Could not check for updates") : L10n.t("Could not install the update")).font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let release {
                    Button(L10n.t("Open the Release Page")) { openURL(release.pageURL) }
                }
                Spacer()
                Button(L10n.t("Close"), action: dismiss).keyboardShortcut(.cancelAction)
                if release != nil {
                    Button(L10n.t("Try Again")) { Task { await store.install() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func header(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Shotcue \(release.version.description) is available")).font(.headline)
            Text(L10n.t("You are using \(store.currentVersion.description)."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func notes(_ release: ReleaseInfo) -> some View {
        if !release.notes.isEmpty {
            ScrollView {
                Text(Self.markdown(release.notes))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 220)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    private func dismiss() {
        store.dismiss()
        close()
    }

    private var symbol: String {
        switch store.phase {
        case .failed: "exclamationmark.triangle.fill"
        case .upToDate: "checkmark.circle.fill"
        default: "arrow.down.circle.fill"
        }
    }

    private var symbolColor: Color {
        switch store.phase {
        case .failed: .orange
        case .upToDate: .green
        default: .accentColor
        }
    }

    /// Release notes are Markdown; line breaks are kept, inline styling and links render. Inline-only parsing leaves
    /// `## Başlık` lines as they are, so headings are turned into bold lines first.
    static func markdown(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("#") else { return line }
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "" : "**\(title)**"
        }
        let source = lines.joined(separator: "\n")
        return
            (try? AttributedString(
                markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
