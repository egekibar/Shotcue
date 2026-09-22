import Foundation
import ShotcueCore
import ShotcueTestSupport
import SwiftUI
import Testing

@testable import ShotcueUI

@Suite("MenuBarStore")
struct MenuBarStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func recentTasksAreTheFiveNewestByUpdatedAt() async {
        let projectID = UUID()
        let tasks = (0..<7).map { index in
            ShotTask(
                projectID: projectID, title: "t\(index)", status: .ready, sortIndex: Double(index),
                createdAt: t0, updatedAt: t0.addingTimeInterval(Double(index) * 60))
        }
        let bundle = makeFakeServices(tasks: tasks, clock: MutableClock(t0))
        let store = MenuBarStore(services: bundle.services)
        store.start()
        #expect(await waitUntil("recent") { store.recentTasks.count == MenuBarStore.recentLimit })
        #expect(store.recentTasks.map(\.title) == ["t6", "t5", "t4", "t3", "t2"])
        store.stop()
        bundle.cleanUp()
    }

    @MainActor
    @Test func runningAndQueuedCountsFollowTheStream() async throws {
        let projectID = UUID()
        let running = ShotTask(projectID: projectID, title: "r", status: .running, createdAt: t0, updatedAt: t0)
        let queued = ShotTask(projectID: projectID, title: "q", status: .queued, createdAt: t0, updatedAt: t0)
        let ready = ShotTask(projectID: projectID, title: "d", status: .ready, createdAt: t0, updatedAt: t0)
        let bundle = makeFakeServices(tasks: [running, queued, ready], clock: MutableClock(t0))
        let store = MenuBarStore(services: bundle.services)
        store.start()
        #expect(await waitUntil("counts") { store.runningCount == 1 && store.queuedCount == 1 })

        var promoted = ready
        try promoted.transition(to: .queued, at: t0)
        try await bundle.services.tasks.save(promoted)
        #expect(await waitUntil("promoted") { store.queuedCount == 2 })
        store.stop()
        bundle.cleanUp()
    }

    @MainActor
    @Test func queueControlsReachTheDispatcher() async {
        let bundle = makeFakeServices(clock: MutableClock(t0))
        let store = MenuBarStore(services: bundle.services)
        store.start()
        _ = await waitUntil("paused loaded") { store.isPaused == false }

        await store.runQueueNow()
        #expect(bundle.dispatcher.runQueueCalls.current == 1)

        await store.togglePaused()
        #expect(store.isPaused == true)
        #expect(bundle.dispatcher.paused.current == true)

        await store.togglePaused()
        #expect(store.isPaused == false)
        #expect(bundle.dispatcher.paused.current == false)
        store.stop()
        bundle.cleanUp()
    }
}

@Suite("PermissionsStore")
struct PermissionsStoreTests {
    @MainActor
    @Test func refreshReadsEveryKind() async {
        let bundle = makeFakeServices(permissions: [
            .screenRecording: .granted,
            .microphone: .denied,
        ])
        let store = PermissionsStore(services: bundle.services)
        await store.refresh()
        #expect(store.states[.screenRecording] == .granted)
        #expect(store.states[.microphone] == .denied)
        #expect(store.states[.notifications] == .notDetermined)
        #expect(store.allGranted == false)
        // Screen recording is the only permission that blocks the whole app (spec §8).
        #expect(store.isBlocking == false)
        bundle.cleanUp()
    }

    @MainActor
    @Test func screenRecordingDenialIsBlocking() async {
        let bundle = makeFakeServices(permissions: [.screenRecording: .denied])
        let store = PermissionsStore(services: bundle.services)
        await store.refresh()
        #expect(store.isBlocking == true)
        bundle.cleanUp()
    }

    /// Review fix round 1, item 4: the real permission service reports `.notDetermined` both for a denied
    /// and for a never-asked screen recording grant, so anything but `.granted` must open onboarding.
    @MainActor
    @Test func screenRecordingNotDeterminedIsBlocking() async {
        let bundle = makeFakeServices(permissions: [.screenRecording: .notDetermined])
        let store = PermissionsStore(services: bundle.services)
        await store.refresh()
        #expect(store.isBlocking == true)
        bundle.cleanUp()
    }

    @MainActor
    @Test func requestUpdatesTheStateAndOpenSettingsDelegates() async {
        let bundle = makeFakeServices(grantOnRequest: true)
        let store = PermissionsStore(services: bundle.services)
        await store.request(.microphone)
        #expect(store.states[.microphone] == .granted)

        store.openSettings(.screenRecording)
        #expect(bundle.permissions.opened.current == [.screenRecording])
        bundle.cleanUp()
    }

    @MainActor
    @Test func deniedRequestKeepsTheDeniedState() async {
        let bundle = makeFakeServices(grantOnRequest: false)
        let store = PermissionsStore(services: bundle.services)
        await store.request(.screenRecording)
        #expect(store.states[.screenRecording] == .denied)
        #expect(store.allGranted == false)
        bundle.cleanUp()
    }

    @MainActor
    @Test func presentationHelpersAreTurkish() async {
        let bundle = makeFakeServices(permissions: [
            .screenRecording: .granted,
            .microphone: .denied,
            .notifications: .notDetermined,
        ])
        let store = PermissionsStore(services: bundle.services)
        await store.refresh()
        #expect(store.label(for: .screenRecording) == "Ekran Kaydı")
        #expect(store.label(for: .microphone) == "Mikrofon")
        #expect(store.label(for: .notifications) == "Bildirimler")
        #expect(store.symbol(for: .screenRecording) == "checkmark.circle.fill")
        #expect(store.symbol(for: .microphone) == "xmark.octagon.fill")
        #expect(store.symbol(for: .notifications) == "questionmark.circle.fill")
        #expect(store.tint(for: .screenRecording) == Color.green)
        #expect(store.tint(for: .microphone) == Color.red)
        #expect(store.tint(for: .notifications) == Color.orange)
        bundle.cleanUp()
    }
}
