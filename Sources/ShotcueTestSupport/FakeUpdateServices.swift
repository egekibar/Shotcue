import Foundation
import ShotcueCore

public final class FakeReleaseFeed: ReleaseFeed, @unchecked Sendable {
    public let result: Locked<Result<ReleaseInfo, UpdateError>>
    public let calls = Locked(0)
    public init(_ result: Result<ReleaseInfo, UpdateError>) { self.result = Locked(result) }
    public func latest() async throws -> ReleaseInfo {
        calls.withLock { $0 += 1 }
        return try result.current.get()
    }
}

public final class FakeUpdateInstaller: UpdateInstaller, @unchecked Sendable {
    public let result: Locked<Result<URL, UpdateError>>
    public let prepared = Locked<[ReleaseInfo]>([])
    /// Runs after the progress report and before `prepare` returns, so a test can park it and look at the
    /// downloading state.
    public let beforeFinishing: (@Sendable () async -> Void)?
    public init(_ result: Result<URL, UpdateError>, beforeFinishing: (@Sendable () async -> Void)? = nil) {
        self.result = Locked(result)
        self.beforeFinishing = beforeFinishing
    }
    public func prepare(_ release: ReleaseInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        prepared.withLock { $0.append(release) }
        progress(0.5)
        await beforeFinishing?()
        return try result.current.get()
    }
}

extension ReleaseInfo {
    /// A stable release with a DMG and a checksum, for tests.
    public static func fixture(_ version: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(version)!, tag: "v\(version)", notes: "- Yeni özellik",
            pageURL: URL(string: "https://github.com/egekibar/Shotcue/releases/tag/v\(version)")!,
            dmgURL: URL(string: "https://x.test/Shotcue-\(version).dmg"), dmgSize: 100,
            checksumURL: URL(string: "https://x.test/Shotcue-\(version).dmg.sha256"), isPrerelease: false)
    }
}
