import Foundation

/// When to ask GitHub, and which answers to show.
public enum UpdateCheckPolicy {
    /// Automatic checks run at most once a day.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether an automatic check should run now. A last check in the future (the clock went back) counts as due,
    /// otherwise checks would stop until the clock caught up.
    public static func isDue(lastCheck: Date?, now: Date, autoCheck: Bool) -> Bool {
        guard autoCheck else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// Only a newer, stable release is offered. The version the user skipped is not offered by automatic checks;
    /// asking by hand ("Güncellemeleri denetle…") still offers it.
    public static func shouldOffer(_ release: ReleaseInfo, current: AppVersion, skipped: String?, manual: Bool) -> Bool
    {
        guard !release.isPrerelease, release.version > current else { return false }
        if !manual, let skipped, AppVersion(skipped) == release.version { return false }
        return true
    }
}
