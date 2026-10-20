import ShotcueCore
import SwiftUI

/// Turkish labels, SF Symbol names and tints for the domain states (spec §7).
/// All members are `nonisolated`; they only read `Color`'s own `nonisolated` statics.
public enum StatusPresentation {
    nonisolated public static func label(for status: TaskStatus) -> String {
        switch status {
        case .inbox: L10n.t("Inbox")
        case .ready: L10n.t("Ready")
        case .queued: L10n.t("Queued")
        case .scheduled: L10n.t("Scheduled")
        case .running: L10n.t("Running")
        case .done: L10n.t("Done")
        case .failed: L10n.t("Failed")
        case .cancelled: L10n.t("Cancelled")
        }
    }

    nonisolated public static func symbol(for status: TaskStatus) -> String {
        switch status {
        case .inbox: "tray"
        case .ready: "checkmark.circle"
        case .queued: "list.bullet.circle"
        case .scheduled: "clock"
        case .running: "circle.dotted"
        case .done: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "slash.circle"
        }
    }

    nonisolated public static func tint(for status: TaskStatus) -> Color {
        switch status {
        case .inbox: .secondary
        case .ready: .accentColor
        case .queued: .orange
        case .scheduled: .purple
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }

    /// Ordering for `SortOrder.status`: what needs attention first.
    nonisolated public static func rank(for status: TaskStatus) -> Int {
        switch status {
        case .running: 0
        case .queued: 1
        case .scheduled: 2
        case .ready: 3
        case .inbox: 4
        case .failed: 5
        case .done: 6
        case .cancelled: 7
        }
    }

    nonisolated public static func label(for state: RunState) -> String {
        switch state {
        case .starting: L10n.t("Starting")
        case .running: L10n.t("Running")
        case .succeeded: L10n.t("Succeeded")
        case .failed: L10n.t("Failed")
        case .cancelled: L10n.t("Cancelled")
        }
    }

    nonisolated public static func symbol(for state: RunState) -> String {
        switch state {
        case .starting: "circle.dashed"
        case .running: "circle.dotted"
        case .succeeded: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "slash.circle"
        }
    }

    nonisolated public static func tint(for state: RunState) -> Color {
        switch state {
        case .starting: .secondary
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }
}
