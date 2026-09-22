import Foundation
import ShotcueCore
import ShotcueTestSupport
import SwiftUI
import Testing

@testable import ShotcueUI

@Suite("MenuBarView")
struct MenuBarViewTests {
    let t0 = Date(timeIntervalSince1970: 1_790_078_400)

    @MainActor
    @Test func viewIsWiredToItsStoreAndCallbacks() async {
        let projectID = UUID()
        let bundle = makeFakeServices(
            tasks: [
                ShotTask(
                    projectID: projectID, title: "Buton rengi", status: .running,
                    createdAt: t0, updatedAt: t0)
            ],
            clock: MutableClock(t0))
        let store = MenuBarStore(services: bundle.services)
        store.start()
        _ = await waitUntil("recent") { store.recentTasks.count == 1 }

        let hits = Locked<[String]>([])
        let view = MenuBarView(
            store: store,
            openLibrary: { hits.withLock { $0.append("library") } },
            openSettings: { hits.withLock { $0.append("settings") } },
            quit: { hits.withLock { $0.append("quit") } })

        #expect(view.store === store)
        view.openLibrary()
        view.openSettings()
        view.quit()
        #expect(hits.current == ["library", "settings", "quit"])
        #expect(store.runningCount == 1)
        store.stop()
        bundle.cleanUp()
    }
}
