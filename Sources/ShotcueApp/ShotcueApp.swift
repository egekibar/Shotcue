import AppKit
import ShotcueCore
import ShotcueUI
import SwiftUI

@main
struct ShotcueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarSceneRoot()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Kütüphane", id: AppWindowID.library) {
            LibrarySceneRoot()
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsSceneRoot()
        }
    }
}

/// The menu bar icon. Also the app's one reliable "a view exists" moment during launch, so this is
/// where SwiftUI's window actions are handed to `WindowOpener` (verified: runs before
/// `applicationDidFinishLaunching`).
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var environment: AppEnvironment { AppBootstrap.environment }

    var body: some View {
        Image(systemName: environment.status.captureFlash ? "checkmark.circle.fill" : "camera.viewfinder")
            .onAppear {
                environment.windowOpener.connect(
                    openWindow: { openWindow(id: $0) },
                    openSettings: { openSettings() })
            }
    }
}

struct MenuBarSceneRoot: View {
    private var environment: AppEnvironment { AppBootstrap.environment }

    var body: some View {
        MenuBarView(
            store: environment.menuBarStore,
            openLibrary: { environment.windowOpener.openLibrary() },
            openSettings: { environment.windowOpener.openSettingsWindow() },
            // The app's quits go through the termination controller, which asks AppKit from the run loop (N1).
            quit: { environment.termination.quit() },
            checkForUpdates: { environment.updates.checkNow() }
        )
        // The task list streams all the time; the pause flag is only read on (re)start, so refresh it
        // whenever the menu opens (the library can toggle it in between).
        .onAppear { environment.refreshMenuBar() }
    }
}

struct LibrarySceneRoot: View {
    private var environment: AppEnvironment { AppBootstrap.environment }

    var body: some View {
        // One shared cache: the grid, the inspector (through LibraryView) and the quick panel decode once.
        LibraryView(store: environment.libraryStore, thumbnails: environment.thumbnails)
            .onAppear { environment.activationPolicy.begin(ActivationPolicyController.libraryReason) }
            .onDisappear { environment.activationPolicy.end(ActivationPolicyController.libraryReason) }
    }
}

struct SettingsSceneRoot: View {
    private var environment: AppEnvironment { AppBootstrap.environment }

    var body: some View {
        let status = environment.status
        VStack(spacing: 0) {
            SettingsView(
                settings: environment.settings,
                permissions: environment.permissionsStore,
                projects: status.projects,
                // SettingsView shows nil as the red "bulunamadı — gönderme devre dışı" state.
                claudeVersion: status.claudeFound ? status.claudeVersion : nil,
                transcriberState: environment.transcriberModel.state,
                // The one download flow (spec §6.2: explicit consent), shared with the quick panel and inspector.
                onDownloadModel: { environment.transcriberModel.startDownload() },
                modelDownloadSize: environment.transcriberModel.downloadSizeText,
                inputDevices: status.inputDevices,
                appVersion: environment.updates.appVersionText,
                onCheckForUpdates: { environment.updates.checkNow() })
            Divider()
            DiagnosticsBar(
                status: status,
                claudeVersion: status.claudeVersion,
                loginItemStatus: status.loginItemStatusText,
                run: { environment.runDiagnostics() })
        }
        .frame(minWidth: 660, minHeight: 560)
        .onAppear {
            // Login item status is read live every time Settings opens (research 01 §8).
            environment.refreshStatus()
        }
        .onDisappear {
            // Belt and braces next to SettingsObserver: apply whatever changed while the window was open.
            environment.applySettings()
        }
    }
}
