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
        case .newest: "En yeni"
        case .oldest: "En eski"
        case .manual: "Manuel"
        case .status: "Duruma göre"
        }
    }
}

public enum ViewMode: String, Hashable, Sendable, CaseIterable {
    case grid, list

    nonisolated public var label: String {
        switch self {
        case .grid: "Izgara"
        case .list: "Liste"
        }
    }

    nonisolated public var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}
