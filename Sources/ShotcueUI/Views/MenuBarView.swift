import ShotcueCore
import SwiftUI

/// Contents of the menu bar window (spec §5.5): the last five tasks with their status, queue controls
/// and the three app entry points. Plan 06 owns the `MenuBarExtra` scene and supplies the callbacks.
public struct MenuBarView: View {
    public let store: MenuBarStore
    public let openLibrary: () -> Void
    public let openSettings: () -> Void
    public let quit: () -> Void
    /// "Güncellemeleri denetle…"; the row is hidden when nil.
    public let checkForUpdates: (() -> Void)?

    public init(
        store: MenuBarStore,
        openLibrary: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        checkForUpdates: (() -> Void)? = nil
    ) {
        self.store = store
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.quit = quit
        self.checkForUpdates = checkForUpdates
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            recentSection
            Divider()
            queueSection
            Divider()
            navigationSection
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .foregroundStyle(.tint)
            Text("Shotcue").font(.headline)
            Spacer()
            if store.isPaused {
                Label("Duraklatıldı", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if store.runningCount > 0 {
                Label("\(store.runningCount) çalışıyor", systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if store.queuedCount > 0 {
                Label("\(store.queuedCount) kuyrukta", systemImage: "list.bullet.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if store.recentTasks.isEmpty {
            Text("Henüz yakalama yok. Kısayolla ekrandan bir bölge seç.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("SON GÖREVLER")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(store.recentTasks) { task in
                    Button {
                        openLibrary()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: StatusPresentation.symbol(for: task.status))
                                .foregroundStyle(StatusPresentation.tint(for: task.status))
                                .frame(width: 16)
                            Text(task.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Formatting.relativeDate(task.updatedAt, now: Date()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(StatusPresentation.label(for: task.status))
                }
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await store.runQueueNow() }
            } label: {
                Label("Kuyruğu şimdi çalıştır", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(store.isPaused)

            Button {
                Task { await store.togglePaused() }
            } label: {
                Label(
                    store.isPaused ? "Sürdür" : "Duraklat",
                    systemImage: store.isPaused ? "play.circle" : "pause.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openLibrary()
            } label: {
                Label("Kütüphane", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("l")

            Button {
                openSettings()
            } label: {
                Label("Ayarlar…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",")

            if let checkForUpdates {
                Button {
                    checkForUpdates()
                } label: {
                    Label("Güncellemeleri denetle…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Button {
                quit()
            } label: {
                Label("Çık", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }
}
