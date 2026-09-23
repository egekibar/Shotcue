import Foundation

/// Where published releases come from (GitHub Releases in the app).
public protocol ReleaseFeed: Sendable {
    /// The newest published release. Throws `UpdateError`.
    func latest() async throws -> ReleaseInfo
}

/// Gets a release ready to replace the running app.
public protocol UpdateInstaller: Sendable {
    /// Downloads the release's DMG (reporting 0…1 progress), checks its SHA-256, and copies the app out of it next to
    /// the installed bundle. Returns the staged `.app`; the app swaps it in once it has quit. Throws `UpdateError`.
    func prepare(_ release: ReleaseInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
