import AppKit
import ShotcueCore
import SwiftUI

/// Ayarlar > Genel's shortcut field: click "Kaydet", press a combination, done.
///
/// Carbon wants a virtual key code, which SwiftUI's `onKeyPress` does not expose, so recording goes through a
/// local `NSEvent` monitor. Local monitors run inside `NSApplication.sendEvent` before key equivalents, so
/// ⌘Q / ⌘W pressed while recording are captured instead of quitting or closing Settings. No TCC permission is
/// involved: a local monitor only sees events already addressed to this app.
///
/// `SettingsStore.isRecordingHotKey` tells the app to unregister the global hotkey meanwhile; otherwise
/// pressing the current combo would open the quick panel instead of reaching the recorder.
struct HotKeyRecorder: View {
    let settings: SettingsStore
    @UIState private var monitor: Any?
    @UIState private var hint: String?

    private var isRecording: Bool { monitor != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Kısayol") {
                HStack(spacing: 8) {
                    Text(isRecording ? "Kombinasyona basın…" : settings.hotKeyLabel)
                        .font(.system(.body, design: .rounded).monospaced())
                        .foregroundStyle(isRecording ? .secondary : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.4))
                        )
                    Button(isRecording ? "Vazgeç" : "Kaydet") {
                        isRecording ? stop() : start()
                    }
                    Button("Varsayılan") { settings.hotKey = KeyCombo.defaultCombo }
                        .disabled(isRecording || settings.hotKey == KeyCombo.defaultCombo)
                }
            }
            Text(hint ?? "⌘, ⌃ veya ⌥ içeren bir kombinasyon ya da tek başına bir F tuşu. İptal için esc.")
                .font(.caption)
                .foregroundStyle(hint == nil ? Color.secondary : Color.orange)
        }
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        hint = nil
        settings.isRecordingHotKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        settings.isRecordingHotKey = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags
        let modifiers = KeyCombo.modifierMask(
            command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control))
        // kVK_Escape without modifiers cancels; ⌃⎋ and friends can still be recorded.
        if event.keyCode == 0x35 && modifiers == 0 {
            hint = nil
            stop()
            return
        }
        let characters = event.characters(byApplyingModifiers: []) ?? ""
        guard
            let combo = KeyCombo.recorded(keyCode: UInt32(event.keyCode), modifiers: modifiers, characters: characters)
        else {
            hint = "Bu kombinasyon kullanılamaz: ⌘, ⌃ veya ⌥ ile birlikte basın."
            return
        }
        hint = nil
        // Both writes land in one main-actor turn, so the app sees the new combo and the end of recording
        // together and registers the new combo straight away.
        settings.hotKey = combo
        stop()
    }
}
