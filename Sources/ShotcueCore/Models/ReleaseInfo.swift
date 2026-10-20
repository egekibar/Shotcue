import Foundation

/// The newest published release, as far as updating needs it.
public struct ReleaseInfo: Hashable, Sendable {
    public var version: AppVersion
    /// The git tag as published ("v1.1.0").
    public var tag: String
    /// The release body (Markdown), shown in the update window.
    public var notes: String
    /// The release page, for installing by hand.
    public var pageURL: URL
    /// The `.dmg` asset; nil when the release has none (nothing to install).
    public var dmgURL: URL?
    public var dmgSize: Int64
    /// The `<dmg>.sha256` asset (`shasum -a 256` format); nil when the release has none.
    public var checksumURL: URL?
    public var isPrerelease: Bool

    public init(
        version: AppVersion, tag: String, notes: String, pageURL: URL, dmgURL: URL?, dmgSize: Int64,
        checksumURL: URL?, isPrerelease: Bool
    ) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
        self.checksumURL = checksumURL
        self.isPrerelease = isPrerelease
    }
}

/// Why checking for or installing an update failed. `message` is what the update window shows.
public enum UpdateError: Error, Equatable, Sendable {
    /// Offline, DNS, a timeout, a non-2xx answer. The payload is for the log.
    case network(String)
    /// GitHub's unauthenticated limit (60 requests an hour) is used up.
    case rateLimited
    /// The answer was not a release this version can read.
    case unreadableRelease
    case noDownload
    case noChecksum
    case checksumMismatch
    /// Shotcue runs from something other than an `.app` (the bare `swift build` binary).
    case notInstalled
    /// The folder holding Shotcue.app cannot be written.
    case notWritable(String)
    /// The downloaded image does not hold the expected app (wrong bundle id or version, no `.app`).
    case invalidBundle(String)
    /// `hdiutil` or a file operation failed. The payload is for the log.
    case installFailed(String)

    public var message: String {
        switch self {
        case .network: L10n.t("GitHub could not be reached. Check your internet connection and try again.")
        case .rateLimited: L10n.t("GitHub is getting too many requests right now. Try again in an hour.")
        case .unreadableRelease: L10n.t("The latest release's details could not be read.")
        case .noDownload: L10n.t("This release has no DMG to download.")
        case .noChecksum: L10n.t("This release has no SHA-256 file, so the update cannot be verified.")
        case .checksumMismatch: L10n.t("The update could not be verified: the downloaded file's SHA-256 does not match.")
        case .notInstalled: L10n.t("Shotcue is not running from an app bundle, so the update cannot be installed.")
        case .notWritable(let path): L10n.t("\(path) is not writable. You can install the update from the DMG yourself.")
        case .invalidBundle(let reason): L10n.t("The downloaded package is not the expected app (\(reason)).")
        case .installFailed: L10n.t("The update could not be prepared.")
        }
    }
}
