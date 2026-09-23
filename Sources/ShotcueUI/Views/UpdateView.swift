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
            Text("Güncellemeler denetleniyor…").font(.headline)
            ProgressView().controlSize(.small)
            buttons { Button("Kapat", action: dismiss).keyboardShortcut(.cancelAction) }

        case .upToDate:
            Text("Shotcue güncel").font(.headline)
            Text("Kullandığın sürüm (\(store.currentVersion.description)) en yeni sürüm.")
                .foregroundStyle(.secondary)
            buttons { Button("Tamam", action: dismiss).keyboardShortcut(.defaultAction) }

        case .available(let release):
            header(release)
            notes(release)
            HStack {
                Button("Bu sürümü atla") {
                    store.skip()
                    close()
                }
                Spacer()
                Button("Sonra", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Güncelle") { Task { await store.install() } }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading(let release, let progress):
            header(release)
            ProgressView(value: progress) {
                Text("İndiriliyor…").font(.callout)
            }
            Text("İndirme bitince Shotcue kapanıp yeni sürümle yeniden açılacak.")
                .font(.callout).foregroundStyle(.secondary)

        case .installing(let release):
            header(release)
            ProgressView().controlSize(.small)
            Text("Shotcue yeniden başlatılıyor…").font(.callout).foregroundStyle(.secondary)

        case .failed(let release, let message):
            Text(release == nil ? "Güncellemeler denetlenemedi" : "Güncelleme kurulamadı").font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let release {
                    Button("Sürüm sayfasını aç") { openURL(release.pageURL) }
                }
                Spacer()
                Button("Kapat", action: dismiss).keyboardShortcut(.cancelAction)
                if release != nil {
                    Button("Yeniden dene") { Task { await store.install() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func header(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shotcue \(release.version.description) hazır").font(.headline)
            Text("Şu an \(store.currentVersion.description) sürümünü kullanıyorsun.")
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

    /// Release notes are Markdown; line breaks are kept, inline styling and links render.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
