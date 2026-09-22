import ShotcueCore
import SwiftUI

@main
struct ShotcueApp: App {
    var body: some Scene {
        MenuBarExtra("Shotcue", systemImage: "camera.viewfinder") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shotcue").font(.headline)
                Text("Kurulum tamam. Kütüphane ve yakalama Plan 05 ile gelir.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Çık") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 260)
        }
        .menuBarExtraStyle(.window)
    }
}
