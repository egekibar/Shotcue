import AppKit
import ShotcueClaudeBridge
import ShotcueCore
import ShotcueUI

/// Quitting stops the runs and keeps unsaved work (final review I2).
///
/// - A user quit (menu "Çık", ⌘Q, logout) with runs in flight asks first: "Çalışan N görev durdurulacak."
///   ("Durdur ve çık" / "Vazgeç").
/// - SIGTERM (`pkill`, `make install`) runs the same shutdown without any dialog; it bypasses AppKit otherwise.
/// - The shutdown keeps the quick panel's typed note or recording (the way a new capture retires the panel), pauses
///   the queue so a freed slot is not filled again, cancels every run through the dispatcher (SIGINT: claude saves the
///   turn) and waits, bounded, until their rows are saved, commits the inspector's drafts, and only then lets AppKit
///   terminate. Nothing to stop or save: AppKit terminates at once.
/// - The quits the app starts itself (menu "Çık", onboarding's relaunch) go through `quit(relaunching:)`, which asks
///   AppKit from the run loop (final review N1).
final class TerminationController {
    enum Trigger { case user, signal }

    /// How long the runs get to stop: the runner escalates SIGINT to SIGKILL after 10 s.
    static let settleTimeout: Duration = .seconds(12)
    /// A shutdown step that hangs (a stuck write) must not keep the app alive forever.
    static let hardDeadline: TimeInterval = 20

    private let runCoordinator: RunCoordinator
    private let dispatcher: any TaskDispatcher
    private let libraryStore: LibraryStore
    private let quickPanel: QuickPanelController

    private var trigger: Trigger = .user
    private var inProgress = false
    private var finished = false
    private var confirmationShowing = false
    private var signalSource: (any DispatchSourceSignal)?
    /// Set by `quit(relaunching: true)` (onboarding, after the Screen Recording grant); `applicationWillTerminate`
    /// starts the relauncher when it is still set, so only a quit that goes ahead relaunches. A quit the user cancels
    /// drops it — a later, unrelated quit must not reopen the app — and so does SIGTERM (`make install` opens the new
    /// build itself).
    private(set) var relaunchRequested = false

    init(
        runCoordinator: RunCoordinator, dispatcher: any TaskDispatcher, libraryStore: LibraryStore,
        quickPanel: QuickPanelController
    ) {
        self.runCoordinator = runCoordinator
        self.dispatcher = dispatcher
        self.libraryStore = libraryStore
        self.quickPanel = quickPanel
    }

    /// SIGTERM's default action kills the process on the spot, leaving `claude` children and unsaved work behind;
    /// it is ignored and delivered to a dispatch source on the main queue instead.
    func installSignalHandler() {
        guard signalSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.receivedSIGTERM() }
        }
        source.resume()
        signalSource = source
    }

    /// SIGTERM runs the shutdown first and only then asks AppKit to terminate (`finished` makes
    /// `applicationShouldTerminate` answer `.terminateNow`). Calling `terminate` from this handler instead — a
    /// main-queue block — would make AppKit spin its `.terminateLater` run loop inside that block, where the main
    /// queue, and with it every main-actor step of the shutdown, can never run again (measured: the app hung).
    private func receivedSIGTERM() {
        AppLog.app.notice("SIGTERM: shutting down without a dialog")
        trigger = .signal
        relaunchRequested = false
        if confirmationShowing {
            // A user quit is asking about the runs: the signal answers "Durdur ve çık".
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return
        }
        guard !inProgress, !finished else { return }
        guard hasWorkToSave else {
            terminateWhenFinished()
            return
        }
        inProgress = true
        armHardDeadline()
        Task { @MainActor in
            _ = await shutDown()
            guard inProgress else { return }
            inProgress = false
            terminateWhenFinished()
        }
    }

    /// Marks the shutdown done and asks AppKit to terminate from the run loop, outside any main-queue block.
    private func terminateWhenFinished() {
        finished = true
        Self.terminateFromRunLoop()
    }

    /// Every quit the app starts itself goes through here: the menu's "Çık" and onboarding's relaunch (final review
    /// N1). Their callers may run inside a main-actor Task (onboarding's "Başla") or a main-queue block, and calling
    /// `NSApp.terminate` there hangs the app whenever there are runs to stop or work to save: AppKit waits for the
    /// `.terminateLater` reply inside that block, where no main-queue or main-actor work — the shutdown, the hard
    /// deadline — can run (measured). `relaunching`: the installed bundle is opened again once this process is gone.
    func quit(relaunching: Bool = false) {
        if relaunching { relaunchRequested = true }
        Self.terminateFromRunLoop()
    }

    /// The app's one `NSApp.terminate` call. The run loop performs the block outside any main-queue block, so while
    /// AppKit waits for a `.terminateLater` reply the main queue, and with it every main-actor step, keeps running.
    private static func terminateFromRunLoop() {
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Whether quitting now would stop a run or drop text or audio.
    var hasWorkToSave: Bool {
        !runCoordinator.activeTaskIDs.isEmpty || libraryStore.detailStore?.hasUncommittedDrafts == true
            || quickPanel.hasUnsavedWork
    }

    /// `NSApplicationDelegate.applicationShouldTerminate`, for quits that go through AppKit (menu "Çık", ⌘Q,
    /// logout). AppKit then waits in its own run loop until `reply(toApplicationShouldTerminate:)`.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if finished || !hasWorkToSave { return .terminateNow }
        guard !inProgress else { return .terminateLater }
        inProgress = true
        Task { @MainActor in
            let proceed = await shutDown()
            // The hard deadline may have answered AppKit already.
            guard inProgress else { return }
            inProgress = false
            finished = proceed
            if !proceed {
                trigger = .user
                relaunchRequested = false
            }
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    private func shutDown() async -> Bool {
        let running = runCoordinator.activeTaskIDs.count
        if running > 0, trigger == .user {
            guard confirmStoppingRuns(count: running) else {
                AppLog.app.notice("quit cancelled; \(running, privacy: .public) run(s) keep running")
                return false
            }
        }
        if trigger == .user { armHardDeadline() }

        // 1. The quick panel, the way a new capture retires it: a typed note becomes an inbox draft, a recording in
        //    progress is stopped (its file closed) and stored.
        await quickPanel.retireForTermination()

        // 2. The runs. Pause first — pausing is not persisted, the queue resumes at the next launch (I1) — so a
        //    cancelled run's slot is not handed to the next queued task; cancel through the dispatcher, which owns
        //    the queue; then wait for the rows.
        if !runCoordinator.activeTaskIDs.isEmpty {
            await dispatcher.setPaused(true)
            for taskID in runCoordinator.activeTaskIDs {
                await dispatcher.cancel(taskID: taskID)
            }
            let deadline = ContinuousClock.now.advanced(by: Self.settleTimeout)
            while !runCoordinator.activeTaskIDs.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let left = runCoordinator.activeTaskIDs.count
            if left > 0 {
                AppLog.app.error("quit: \(left, privacy: .public) run(s) did not stop within the time limit")
            } else {
                AppLog.app.notice("quit: every run stopped")
            }
        }

        // 3. Inspector drafts last: a task that was running takes its text once it is cancelled.
        await libraryStore.detailStore?.commitDrafts()
        return true
    }

    /// "Çalışan N görev durdurulacak." — true for "Durdur ve çık".
    private func confirmStoppingRuns(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Çalışan \(count) görev durdurulacak."
        alert.informativeText =
            "Çıkarken çalışan Claude oturumları durdurulur. Yarıda kalan görevi sonra yeniden çalıştırabilir "
            + "ya da Terminalde devam ettirebilirsin."
        alert.addButton(withTitle: "Durdur ve çık")
        let cancel = alert.addButton(withTitle: "Vazgeç")
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate()
        confirmationShowing = true
        let response = alert.runModal()
        confirmationShowing = false
        return response == .alertFirstButtonReturn
    }

    /// Whatever a step does, the app terminates after `hardDeadline`.
    private func armHardDeadline() {
        let trigger = trigger
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hardDeadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.inProgress else { return }
                AppLog.app.error("quit: shutdown exceeded \(Self.hardDeadline, privacy: .public) s; terminating")
                self.inProgress = false
                if trigger == .signal {
                    self.terminateWhenFinished()
                } else {
                    self.finished = true
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }
}
