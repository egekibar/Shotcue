import AppKit
import ShotcueUI

/// Post-capture quick panel (spec §5.1, research 02 §6). Filled in Task 4.
final class QuickPanelController {
    private let makeStore: (UUID) -> QuickPanelStore
    init(makeStore: @escaping (UUID) -> QuickPanelStore) { self.makeStore = makeStore }
    func present(taskID: UUID) { _ = makeStore(taskID) }
    func dismiss() {}
}
