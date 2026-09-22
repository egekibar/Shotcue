import Foundation
import ShotcueCore
import SwiftUI

@main
struct ShotcueApp: App {
    init() {
        SpikeRunner.runIfRequested()
    }

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

/// Temporary diagnostics used by Plan 00 Task 11. Triggered only by SHOTCUE_SPIKE=auth|capture.
enum SpikeRunner {
    static func runIfRequested() {
        guard let spike = ProcessInfo.processInfo.environment["SHOTCUE_SPIKE"] else { return }
        let output = URL(fileURLWithPath: "/tmp/shotcue-spike-\(spike).txt")
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        let process = Process()
        process.environment = env
        switch spike {
        case "auth":
            process.executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/claude")
            process.arguments = ["auth", "status"]
        case "capture":
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-x", "-t", "png", "/tmp/shotcue-spike-capture.png"]
        default:
            return
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var text = "spike=\(spike)\n"
        do {
            try process.run()
            process.waitUntilExit()
            text += "exit=\(process.terminationStatus)\n"
            text += "stdout=\(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")\n"
            text += "stderr=\(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")\n"
        } catch {
            text += "launch-error=\(error)\n"
        }
        try? text.write(to: output, atomically: true, encoding: .utf8)
        exit(0)
    }
}
