import ShotcueCore
import SwiftUI

/// First-run / permission-recovery screen (spec §6.1, §8). Plan 06 shows it in an `NSWindow` at launch
/// when screen recording is missing, and the global hotkey opens it until the grant exists.
public struct OnboardingView: View {
    public let permissions: PermissionsStore
    /// Set once the user chose "Vazgeç" when Shotcue asked to restart for a new Screen Recording grant: the grant only
    /// works after a restart, which the finish button asks for again.
    public let restartPending: Bool
    public let onDone: () -> Void

    public init(permissions: PermissionsStore, restartPending: Bool = false, onDone: @escaping () -> Void) {
        self.permissions = permissions
        self.restartPending = restartPending
        self.onDone = onDone
    }

    /// Screen recording is the only hard requirement; microphone and notifications are optional.
    public var canFinish: Bool {
        permissions.state(of: .screenRecording) == .granted
    }

    /// The warning under the permission rows: why onboarding cannot finish yet, or that the grant still needs the
    /// restart the user put off.
    public var notice: String? {
        if !canFinish {
            return "Ekran Kaydı izni olmadan yakalama çalışmaz. İzni verdikten sonra Shotcue'yu yeniden başlat."
        }
        if restartPending {
            return "Ekran Kaydı izni, Shotcue yeniden başlayınca geçerli olur. Hazır olduğunda \"Yeniden başlat\"a bas."
        }
        return nil
    }

    public var finishTitle: String { restartPending ? "Yeniden başlat" : "Başla" }

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Shotcue'ya hoş geldin")
                    .font(.title2.weight(.semibold))
                Text("Ekrandan bir bölge yakala, üstüne yazılı ya da sesli not ekle, projeye gönder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PermissionKind.allCases, id: \.self) { kind in
                        permissionRow(kind)
                        if kind != PermissionKind.allCases.last {
                            Divider()
                        }
                    }
                }
                .padding(6)
            }

            if let notice {
                Label(notice, systemImage: canFinish ? "arrow.clockwise.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Durumları yenile") {
                    Task { await permissions.refresh() }
                }
                Button(finishTitle) { onDone() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canFinish)
            }
        }
        .padding(28)
        .frame(width: 480)
        .task { await permissions.refresh() }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: permissions.symbol(for: kind))
                    .foregroundStyle(permissions.tint(for: kind))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(permissions.label(for: kind))
                        .font(.callout.weight(.medium))
                    Text(permissions.stateLabel(for: kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if permissions.state(of: kind) == .notDetermined {
                    Button("İzin ver") {
                        Task { await permissions.request(kind) }
                    }
                    .buttonStyle(.glass)
                } else if permissions.state(of: kind) == .denied {
                    Button("Sistem Ayarları") {
                        permissions.openSettings(kind)
                    }
                    .buttonStyle(.glass)
                }
            }
            Text(permissions.explanation(for: kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
