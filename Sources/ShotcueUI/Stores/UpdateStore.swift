import Foundation
import Observation
import ShotcueCore
import os

/// In-app updates from GitHub Releases: what the update window shows, and the one flow that checks, downloads and
/// hands a staged app to the app for the swap.
///
/// Automatic checks (`checkIfDue`) are quiet: only a release worth offering opens the window. A check by hand
/// (`checkNow`) opens the window at once and shows whatever happens, "güncel" and failures included.
@MainActor
@Observable
public final class UpdateStore {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        /// Staged and handed to the app, which is quitting to swap it in.
        case installing(ReleaseInfo)
        /// The release is kept when there is one, so "Yeniden dene" and the release page stay available.
        case failed(ReleaseInfo?, String)
    }

    public private(set) var phase: Phase = .idle
    public let currentVersion: AppVersion

    /// Asks the app to show the update window.
    @ObservationIgnored public var onPresent: (() -> Void)?
    /// Hands the staged app over; the app quits and swaps it in (or calls `installCancelled()`).
    @ObservationIgnored public var onInstall: ((URL) -> Void)?

    @ObservationIgnored private let feed: any ReleaseFeed
    @ObservationIgnored private let installer: any UpdateInstaller
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let log = Logger(subsystem: "com.shotcue.app", category: "update")

    public init(
        feed: any ReleaseFeed, installer: any UpdateInstaller, settings: SettingsStore, currentVersion: AppVersion,
        clock: any Clock
    ) {
        self.feed = feed
        self.installer = installer
        self.settings = settings
        self.currentVersion = currentVersion
        self.clock = clock
    }

    /// The release on screen, if any.
    public var release: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .installing(let release): release
        case .failed(let release, _): release
        case .idle, .checking, .upToDate: nil
        }
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    // MARK: - Checking

    /// The timer's check: runs when the setting is on and a day has passed, and never over a window in use.
    public func checkIfDue() async {
        switch phase {
        case .idle, .upToDate: break
        default: return
        }
        guard
            UpdateCheckPolicy.isDue(
                lastCheck: settings.lastUpdateCheck, now: clock.now, autoCheck: settings.autoCheckUpdates)
        else { return }
        await check(manual: false)
    }

    /// "Güncellemeleri denetle…".
    public func checkNow() async {
        guard !isBusy else {
            onPresent?()
            return
        }
        phase = .checking
        onPresent?()
        await check(manual: true)
    }

    private func check(manual: Bool) async {
        do {
            let latest = try await feed.latest()
            settings.lastUpdateCheck = clock.now
            if UpdateCheckPolicy.shouldOffer(
                latest, current: currentVersion, skipped: settings.skippedUpdateVersion, manual: manual)
            {
                log.notice("update available: \(latest.version.description, privacy: .public)")
                phase = .available(latest)
                if !manual { onPresent?() }
            } else {
                phase = manual ? .upToDate : .idle
            }
        } catch {
            let updateError = error as? UpdateError ?? .network(error.localizedDescription)
            log.error("update check failed: \(String(describing: updateError), privacy: .public)")
            phase = manual ? .failed(nil, updateError.message) : .idle
        }
    }

    // MARK: - Actions

    /// "Güncelle" (and "Yeniden dene" after a failed download).
    public func install() async {
        guard let release, !isBusy else { return }
        phase = .downloading(release, progress: 0)
        do {
            let staged = try await installer.prepare(release) { [weak self] value in
                Task { @MainActor in self?.report(progress: value, for: release) }
            }
            log.notice("update \(release.version.description, privacy: .public) staged")
            phase = .installing(release)
            onInstall?(staged)
        } catch {
            let updateError = error as? UpdateError ?? .installFailed(error.localizedDescription)
            log.error("update install failed: \(String(describing: updateError), privacy: .public)")
            phase = .failed(release, updateError.message)
        }
    }

    private func report(progress: Double, for release: ReleaseInfo) {
        guard case .downloading(let current, _) = phase, current == release else { return }
        phase = .downloading(release, progress: progress)
    }

    /// "Bu sürümü atla".
    public func skip() {
        if let release { settings.skippedUpdateVersion = release.version.description }
        dismiss()
    }

    /// "Sonra" / closing the window. A download or install in progress carries on.
    public func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }

    /// The quit that would install was cancelled ("Vazgeç"): the update is offered again.
    public func installCancelled() {
        guard case .installing(let release) = phase else { return }
        phase = .available(release)
    }
}
