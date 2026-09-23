import AppKit
import Foundation
import ShotcueCore
import ShotcueTestSupport
import SwiftUI
import Testing

@testable import ShotcueUI

@Suite("UpdateStore")
@MainActor
struct UpdateStoreTests {
    let staged = URL(fileURLWithPath: "/tmp/staging/Shotcue.app")

    func freshDefaults() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-settings-\(UUID().uuidString)").path
        return UserDefaults(suiteName: path)!
    }

    func makeStore(
        feed: FakeReleaseFeed, installer: FakeUpdateInstaller? = nil, settings: SettingsStore? = nil,
        clock: MutableClock = MutableClock()
    ) -> (UpdateStore, SettingsStore, Locked<Int>) {
        let settings = settings ?? SettingsStore(defaults: freshDefaults())
        let store = UpdateStore(
            feed: feed, installer: installer ?? FakeUpdateInstaller(.success(staged)), settings: settings,
            currentVersion: AppVersion(major: 1, minor: 0, patch: 0), clock: clock)
        let presented = Locked(0)
        store.onPresent = { presented.withLock { $0 += 1 } }
        return (store, settings, presented)
    }

    @Test func automaticCheckPresentsANewerRelease() async {
        let clock = MutableClock()
        let (store, settings, presented) = makeStore(feed: FakeReleaseFeed(.success(.fixture("1.1.0"))), clock: clock)
        await store.checkIfDue()
        #expect(store.phase == .available(.fixture("1.1.0")))
        #expect(presented.current == 1)
        #expect(settings.lastUpdateCheck == clock.now)
    }

    @Test func automaticCheckRunsOncePerDayAndHonoursTheSwitch() async {
        let clock = MutableClock()
        let feed = FakeReleaseFeed(.success(.fixture("1.0.0")))
        let (store, settings, presented) = makeStore(feed: feed, clock: clock)
        await store.checkIfDue()
        #expect(store.phase == .idle)
        clock.advance(by: 3600)
        await store.checkIfDue()
        #expect(feed.calls.current == 1)
        clock.advance(by: 86_400)
        settings.autoCheckUpdates = false
        await store.checkIfDue()
        #expect(feed.calls.current == 1)
        #expect(presented.current == 0)
    }

    @Test func automaticFailuresStayQuiet() async {
        let (store, _, presented) = makeStore(feed: FakeReleaseFeed(.failure(.network("offline"))))
        await store.checkIfDue()
        #expect(store.phase == .idle)
        #expect(presented.current == 0)
    }

    @Test func manualCheckShowsEveryOutcome() async {
        let feed = FakeReleaseFeed(.success(.fixture("1.0.0")))
        let (store, _, presented) = makeStore(feed: feed)
        await store.checkNow()
        #expect(store.phase == .upToDate)
        #expect(presented.current == 1)
        feed.result.set(.failure(.rateLimited))
        await store.checkNow()
        #expect(store.phase == .failed(nil, UpdateError.rateLimited.message))
    }

    @Test func skippedVersionIsOnlyOfferedByHand() async {
        let clock = MutableClock()
        let feed = FakeReleaseFeed(.success(.fixture("1.1.0")))
        let (store, settings, presented) = makeStore(feed: feed, clock: clock)
        await store.checkIfDue()
        store.skip()
        #expect(settings.skippedUpdateVersion == "1.1.0")
        #expect(store.phase == .idle)
        clock.advance(by: 86_400)
        await store.checkIfDue()
        #expect(store.phase == .idle)
        #expect(presented.current == 1)
        await store.checkNow()
        #expect(store.phase == .available(.fixture("1.1.0")))
    }

    @Test func installHandsTheStagedAppOverAndCanBeCancelled() async {
        let (store, _, _) = makeStore(feed: FakeReleaseFeed(.success(.fixture("1.1.0"))))
        let installed = Locked<[URL]>([])
        store.onInstall = { url in installed.withLock { $0.append(url) } }
        await store.checkNow()
        await store.install()
        #expect(store.phase == .installing(.fixture("1.1.0")))
        #expect(installed.current == [staged])
        // "Vazgeç" in the quit confirmation: the update is offered again.
        store.installCancelled()
        #expect(store.phase == .available(.fixture("1.1.0")))
    }

    @Test func downloadProgressIsShown() async {
        let parked = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let installer = FakeUpdateInstaller(.success(staged)) {
            parked.continuation.yield()
            for await _ in release.stream { break }
        }
        let (store, _, _) = makeStore(feed: FakeReleaseFeed(.success(.fixture("1.1.0"))), installer: installer)
        await store.checkNow()
        let install = Task { await store.install() }
        for await _ in parked.stream { break }
        // Progress hops to the main actor; give that hop a few turns to land.
        for _ in 0..<100 where store.phase != .downloading(.fixture("1.1.0"), progress: 0.5) { await Task.yield() }
        #expect(store.phase == .downloading(.fixture("1.1.0"), progress: 0.5))
        store.dismiss()  // closing the window does not stop a download
        #expect(store.phase == .downloading(.fixture("1.1.0"), progress: 0.5))
        release.continuation.yield()
        await install.value
        #expect(store.phase == .installing(.fixture("1.1.0")))
    }

    @Test func installFailureKeepsTheRelease() async {
        let installer = FakeUpdateInstaller(.failure(.checksumMismatch))
        let (store, _, _) = makeStore(feed: FakeReleaseFeed(.success(.fixture("1.1.0"))), installer: installer)
        await store.checkNow()
        await store.install()
        #expect(store.phase == .failed(.fixture("1.1.0"), UpdateError.checksumMismatch.message))
        // "Yeniden dene" installs the same release again.
        installer.result.set(.success(staged))
        await store.install()
        #expect(installer.prepared.current.count == 2)
    }
}

@Suite("UpdateView")
@MainActor
struct UpdateViewTests {
    @Test func rendersEveryPhaseItReaches() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shotcue-\(UUID().uuidString)").path
        let feed = FakeReleaseFeed(.success(.fixture("1.1.0")))
        let installer = FakeUpdateInstaller(.failure(.checksumMismatch))
        let store = UpdateStore(
            feed: feed, installer: installer, settings: SettingsStore(defaults: UserDefaults(suiteName: path)!),
            currentVersion: AppVersion(major: 1, minor: 0, patch: 0), clock: MutableClock())
        let closed = Locked(0)
        let hosting = NSHostingView(rootView: UpdateView(store: store, close: { closed.withLock { $0 += 1 } }))

        for step in 0..<3 {
            switch step {
            case 0: await store.checkNow()  // available
            case 1: await store.install()  // failed with the release
            default:
                feed.result.set(.success(.fixture("1.0.0")))
                store.dismiss()
                await store.checkNow()  // up to date
            }
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0)
        }
        #expect(store.phase == .upToDate)
        #expect(String(UpdateView.markdown("**Yeni:** güncelleme\n- satır").characters).contains("\n"))
    }
}
