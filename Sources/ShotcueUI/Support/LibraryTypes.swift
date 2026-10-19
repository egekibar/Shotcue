import Foundation
import ShotcueCore

/// What the library sidebar has selected. Doubles as the key of `LibraryStore.counts`.
public enum SidebarSelection: Hashable, Sendable {
    /// Tasks with no project yet.
    case inbox
    case project(UUID)
    case status(TaskStatus)
}

/// Content ordering, spec §5.3 ("En yeni / En eski / Manuel / Durum").
public enum SortOrder: String, Hashable, Sendable, CaseIterable {
    case newest, oldest, manual, status

    nonisolated public var label: String {
        switch self {
        case .newest: L10n.t("Newest")
        case .oldest: L10n.t("Oldest")
        case .manual: L10n.t("Manual")
        case .status: L10n.t("By Status")
        }
    }
}

public enum ViewMode: String, Hashable, Sendable, CaseIterable {
    case grid, list

    nonisolated public var label: String {
        switch self {
        case .grid: L10n.t("Grid")
        case .list: L10n.t("List")
        }
    }

    nonisolated public var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}
