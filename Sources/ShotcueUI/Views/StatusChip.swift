import ShotcueCore
import SwiftUI

/// Capsule status badge used on cards, in the table and in the inspector toolbar (research 05 §C.2).
public struct StatusChip: View {
    public let status: TaskStatus
    public let compact: Bool

    public init(status: TaskStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: StatusPresentation.symbol(for: status))
                .imageScale(.small)
            if !compact {
                Text(StatusPresentation.label(for: status))
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(StatusPresentation.tint(for: status).opacity(0.18)))
        .foregroundStyle(StatusPresentation.tint(for: status))
        .accessibilityLabel(StatusPresentation.label(for: status))
    }
}

/// Same treatment for a run row in the inspector's history list.
public struct RunStateChip: View {
    public let state: RunState

    public init(state: RunState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: StatusPresentation.symbol(for: state)).imageScale(.small)
            Text(StatusPresentation.label(for: state))
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(StatusPresentation.tint(for: state).opacity(0.18)))
        .foregroundStyle(StatusPresentation.tint(for: state))
    }
}
