/// Fractional ordering: reordering touches one row. Renumber when a gap collapses.
public enum SortIndex {
    public static let step: Double = 1024
    private static let minimumGap: Double = 1e-6

    /// Index that sorts between `before` and `after`; pass nil for the list ends.
    public static func between(_ before: Double?, _ after: Double?) -> Double {
        switch (before, after) {
        case (nil, nil): return step
        case (let b?, nil): return b + step
        case (nil, let a?): return a - step
        case (let b?, let a?): return (b + a) / 2
        }
    }

    public static func needsRenumber(_ before: Double?, _ after: Double?) -> Bool {
        guard let b = before, let a = after else { return false }
        return (a - b) < minimumGap
    }

    public static func renumbered(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).map { Double($0) * step }
    }
}
