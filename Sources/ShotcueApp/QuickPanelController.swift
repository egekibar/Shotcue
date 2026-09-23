import AppKit
import ShotcueUI
import SwiftUI

/// Post-capture quick panel (spec §5.1 / §6.6, research 02 §6 recipe).
///
/// The style mask deliberately has no `.titled`: the panel is chrome-less and draggable by its
/// background. Every line below is load-bearing; the comments name what breaks without it.
final class QuickPanel: NSPanel {
    init(contentView view: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .floating  // stays above the app the user is working in
        hidesOnDeactivate = false  // spec §6.6: clicking outside must NOT close it
        becomesKeyOnlyIfNeeded = true  // key only when the text field actually needs it
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // without .canJoinAllSpaces the panel vanishes on a Space switch; without .fullScreenAuxiliary
        // it never shows over a full-screen app (research 02 §6 pitfall 7)
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false  // the controller decides the lifetime
        hasShadow = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        // QuickPanelView paints its own rounded Liquid Glass surface (`glassEffect(in: .rect(cornerRadius: 16))`);
        // an opaque window background would show as a square frame around the rounded glass.
        backgroundColor = .clear
        isOpaque = false
        self.contentView = view
    }

    /// Required. With `.nonactivatingPanel` and no `.titled`, `canBecomeKey` defaults to false and the
    /// panel's TextField/TextEditor never receives a keystroke (research 02 §6 pitfall 1).
    override var canBecomeKey: Bool { true }

    /// The panel must never become the main window; that is what would make the app look "activated".
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?

    /// Esc travels up the responder chain to here even while the SwiftUI text view is first responder
    /// (verified 2026-09-22). The key monitor does the same; the store's `dismiss()` is idempotent.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

enum PanelPlacement {
    static let inset: CGFloat = 16

    /// The display the mouse is on — i.e. the display the user just captured from (spec §5.1).
    /// `NSEvent.mouseLocation` is in global screen coordinates, same space as `NSScreen.frame`.
    static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Top-right corner of the usable area (below the menu bar, clear of the Dock), 16 pt inset.
    static func topRightOrigin(for size: NSSize) -> NSPoint {
        guard let screen = screenUnderMouse() else { return NSPoint(x: inset, y: inset) }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.maxX - size.width - inset, y: frame.maxY - size.height - inset)
    }
}

/// Esc / ⌘↩ / ⌘⇧↩ handling for the quick panel.
///
/// Why a monitor instead of relying on SwiftUI `.keyboardShortcut`: measured 2026-09-22 inside exactly
/// this panel, a `Button(...).keyboardShortcut(.return, modifiers: .command)` also fired for ⌘⇧↩, so
/// "Kaydet" and "Kaydet ve gönder" could not be distinguished. A local key-down monitor returning nil
/// consumes the event before SwiftUI sees it and the modifier test becomes exact (verified: one
/// `cmd-return` and one `cmd-shift-return`, no double fire). Scoped to `event.window === panel` so the
/// library window's own Esc/⌘↩ handling is untouched.
final class PanelKeyMonitor {
    private var monitor: Any?

    private static let escapeKeyCode: UInt16 = 53  // kVK_Escape
    private static let returnKeyCode: UInt16 = 36  // kVK_Return

    func install(
        for panel: NSWindow, onSave: (() -> Void)?, onSaveAndSend: (() -> Void)?,
        onCancel: @escaping () -> Void
    ) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard let panel, event.window === panel else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case Self.escapeKeyCode:
                onCancel()
                return nil
            case Self.returnKeyCode where flags.contains(.command):
                if flags.contains(.shift) {
                    guard let onSaveAndSend else { return event }
                    onSaveAndSend()
                } else {
                    guard let onSave else { return event }
                    onSave()
                }
                return nil
            default:
                return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Owns the one quick panel on screen. The store decides *when* the panel closes (⌘↩ and ⌘⇧↩ close only
/// after a successful save, Esc after a recording in flight is stored) and reports it through `onClose`;
/// this controller only turns keys into store actions and hides the window.
final class QuickPanelController {
    private let makeStore: (UUID) -> QuickPanelStore
    private let thumbnails: ThumbnailCache
    private var panel: QuickPanel?
    private var store: QuickPanelStore?
    /// Esc reached the current store through this controller (key monitor, `cancelOperation`, `dismiss()`).
    /// A store that is still closing after Esc (a recording being stored) must not be saved on retirement.
    private var escapePressed = false
    private let keyMonitor = PanelKeyMonitor()

    /// Called after the panel closed through the store (spec §5.1 step 5: the menu bar icon highlights).
    var onClosed: (() -> Void)?

    init(makeStore: @escaping (UUID) -> QuickPanelStore, thumbnails: ThumbnailCache) {
        self.makeStore = makeStore
        self.thumbnails = thumbnails
    }

    /// Shows the panel for a freshly captured task. A second capture replaces the contents rather than
    /// stacking windows, so there is never more than one quick panel on screen.
    func present(taskID: UUID) {
        retireCurrentStore()
        tearDown()
        escapePressed = false

        let store = makeStore(taskID)
        // Only the store that owns the panel may close it: a retired store finishing late is ignored.
        store.onClose = { [weak self, weak store] in
            guard let self, let store, self.store === store else { return }
            self.tearDown()
            self.onClosed?()
        }
        self.store = store

        let hosting: NSHostingView<QuickPanelView> = NSHostingView(
            rootView: QuickPanelView(store: store, thumbnails: thumbnails))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize

        let panel = QuickPanel(contentView: hosting)
        panel.onCancel = { [weak self, weak store] in
            guard let store else { return }
            self?.cancel(store)
        }
        self.panel = panel

        // Size to the hosted content first, then place: NSHostingView shrinks the panel to its
        // intrinsic height, so the origin must be computed from the final frame (verified).
        panel.setContentSize(NSSize(width: max(420, fitting.width), height: max(180, fitting.height)))
        panel.setFrameOrigin(PanelPlacement.topRightOrigin(for: panel.frame.size))

        // NEVER NSApp.activate here (Global Constraints / research 02 §6 pitfall 2): the panel takes
        // keyboard focus without pulling the user out of the app they were working in.
        panel.makeKeyAndOrderFront(nil)

        // R7: the monitor is authoritative for these three keys and calls the store's own actions.
        keyMonitor.install(
            for: panel,
            onSave: { [weak store] in
                guard let store else { return }
                Task { await store.saveAndClose() }
            },
            onSaveAndSend: { [weak store] in
                guard let store else { return }
                Task { await store.saveAndSend() }
            },
            onCancel: { [weak self, weak store] in
                guard let store else { return }
                self?.cancel(store)
            })
    }

    /// Esc semantics from outside the panel: nothing is written, a recording in flight is still stored,
    /// and the panel closes through the store's `onClose` (spec §5.1 step 4).
    func dismiss() {
        guard let store else { return }
        cancel(store)
    }

    private func cancel(_ store: QuickPanelStore) {
        if store === self.store { escapePressed = true }
        store.dismiss()
    }

    /// A newer capture takes the panel over. The closure keeps the old store alive until it reports
    /// closing (its own recording task only holds it weakly) and then lets go of itself.
    ///
    /// A typed note must not be lost: unless Esc was pressed, a non-blank note is saved first — without a
    /// project, since the old panel's choice was never confirmed, so the task stays a project-less inbox
    /// draft carrying its note (`save()` also stores a recording in flight). The final `dismiss()` then
    /// closes the store, which fires `onClose`. A blank note only gets the Esc path, which still stores a
    /// recording in flight.
    private func retireCurrentStore() {
        guard let retiring = store else { return }
        let keepsNote =
            !escapePressed && !retiring.noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        store = nil
        retiring.onClose = { [retiring] in retiring.onClose = nil }
        guard keepsNote else {
            retiring.dismiss()
            return
        }
        retiring.selectedProjectID = nil
        Task {
            _ = await retiring.save()
            retiring.dismiss()
        }
    }

    private func tearDown() {
        keyMonitor.remove()
        panel?.onCancel = nil
        panel?.orderOut(nil)
        panel = nil
        store?.onClose = nil
        store = nil
    }
}
