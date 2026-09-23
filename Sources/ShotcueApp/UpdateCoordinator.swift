import AppKit
import ShotcueCore
import ShotcueUI
import ShotcueUpdater
import SwiftUI

/// The app side of in-app updates: the update window, the timer behind automatic checks, and the quit that swaps a
/// staged release in.
///
/// A plain `NSWindow`, like onboarding: an automatic check opens it from AppKit scope, before any scene may exist.
final class UpdateCoordinator: NSObject, NSWindowDelegate {
    /// Used when Info.plist has no `ShotcueUpdateRepo`.
    static let defaultRepo = "egekibar/Shotcue"
    /// Launch work (recovery, the scheduler, `claude --version`) goes first.
    static let firstCheckDelay: TimeInterval = 10
    /// The timer only asks; `UpdateCheckPolicy` decides whether a day has passed.
    static let timerInterval: TimeInterval = 60 * 60

    let store: UpdateStore
    private let activationPolicy: ActivationPolicyController
    private let termination: TerminationController
    private var window: NSWindow?
    private var timer: (any DispatchSourceTimer)?
    /// The staged app while the quit that installs it is under way.
    private var stagedApp: URL?

    init(settings: SettingsStore, activationPolicy: ActivationPolicyController, termination: TerminationController) {
        let bundle = Bundle.main
        let repo = bundle.object(forInfoDictionaryKey: "ShotcueUpdateRepo") as? String ?? Self.defaultRepo
        let version =
            (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
            ?? AppVersion(major: 0, minor: 0, patch: 0)
        self.store = UpdateStore(
            feed: GitHubReleaseFeed(repo: repo),
            installer: DMGUpdateInstaller(
                installedApp: bundle.bundleURL, bundleID: bundle.bundleIdentifier ?? "com.shotcue.app"),
            settings: settings,
            currentVersion: version,
            clock: SystemClock())
        self.activationPolicy = activationPolicy
        self.termination = termination
        super.init()
        store.onPresent = { [weak self] in self?.showWindow() }
        store.onInstall = { [weak self] staged in self?.quitToInstall(staged) }
    }

    var appVersionText: String { store.currentVersion.description }

    /// Starts automatic checks. The bare `swift build` binary has nothing to update, so it never checks by itself.
    func start() {
        guard timer == nil else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            AppLog.app.notice("not running from an .app bundle; automatic update checks are off")
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.firstCheckDelay, repeating: Self.timerInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let store = self?.store else { return }
                Task { await store.checkIfDue() }
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// "Güncellemeleri denetle…" (menu bar, Settings).
    func checkNow() {
        let store = store
        Task { await store.checkNow() }
    }

    // MARK: - Installing

    /// The quit goes through the usual shutdown (runs stopped after a confirmation, drafts kept); "Vazgeç" there
    /// cancels the update and the window offers it again.
    private func quitToInstall(_ staged: URL) {
        stagedApp = staged
        AppLog.app.notice("quitting to install an update")
        termination.quit(relaunching: true, reason: .update) { [weak self] in
            AppLog.app.notice("update install cancelled at the quit confirmation")
            self?.stagedApp = nil
            self?.store.installCancelled()
        }
    }

    /// `applicationWillTerminate`, when the quit relaunches: starts the helper that swaps the staged app in and opens
    /// it. False when there is no update to install (the caller then relaunches as before).
    func startSwapIfStaged() -> Bool {
        guard let stagedApp else { return false }
        do {
            try BundleSwapper.start(
                waitingFor: ProcessInfo.processInfo.processIdentifier, staged: stagedApp,
                target: Bundle.main.bundleURL)
            AppLog.app.notice("update helper started; the new version opens once this process exits")
            return true
        } catch {
            AppLog.app.error("update helper failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Window

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingView(
            rootView: UpdateView(store: store, close: { [weak self] in self?.window?.close() }))
        // The window follows the content, which changes height from phase to phase.
        hosting.sizingOptions = [.intrinsicContentSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Shotcue Güncellemesi"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces]
        window.delegate = self
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        window.center()
        self.window = window

        activationPolicy.begin(ActivationPolicyController.updateReason)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The close button means "Sonra"; a download in progress carries on (`dismiss` leaves it alone).
        store.dismiss()
        window?.delegate = nil
        window = nil
        activationPolicy.end(ActivationPolicyController.updateReason)
    }
}
