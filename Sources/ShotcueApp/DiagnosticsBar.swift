import ShotcueCore
import SwiftUI

/// "Tanılama çalıştır" strip below `SettingsView`; writes the report to the per-user temporary directory
/// and opens it. Also the place where app-level errors (hotkey refused, login item, restart needed) are
/// shown, because `SettingsView` has no slot for them.
struct DiagnosticsBar: View {
    let status: AppStatusModel
    /// Its CLI missing is shown in red; the other agents are optional.
    let defaultAgent: AgentKind
    let loginItemStatus: String
    let run: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    ForEach(AgentKind.allCases) { agent in
                        Text("\(agent.executableName): \(status.agentVersions[agent] ?? "?")")
                            .font(.caption)
                            .foregroundStyle(
                                status.agentFound[agent] == false && agent == defaultAgent
                                    ? Color.red : .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text("Girişte başlat: \(loginItemStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // macOS can park the registration in `requiresApproval`; this is the only way out.
                    Button("Giriş Öğeleri") { LoginItemManager.openSystemSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                // Settings > Ses > Deneysel points here for the Apple Intelligence state (A19).
                Text("Apple Intelligence (Foundation Models): \(status.foundationModelsText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hotKeyError = status.hotKeyError {
                    Text(hotKeyError).font(.caption).foregroundStyle(Color.red)
                }
                if let lastError = status.lastError {
                    Text(lastError).font(.caption).foregroundStyle(Color.red)
                }
            }
            Spacer()
            Button("Tanılama çalıştır", action: run)
                .disabled(status.diagnosticsRunning)
            if status.diagnosticsRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
