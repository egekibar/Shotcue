import CryptoKit
import Foundation
import ShotcueCore

/// Downloads a release DMG, checks it against the release's `.sha256` asset, and copies the app inside it to a
/// staging folder on the installed bundle's volume, so the swap after quitting is a rename.
public final class DMGUpdateInstaller: UpdateInstaller {
    /// The running bundle (`Bundle.main.bundleURL`).
    public let installedApp: URL
    /// The staged app must carry the same `CFBundleIdentifier`.
    public let bundleID: String
    private let session: URLSession

    public init(installedApp: URL, bundleID: String, session: URLSession = .shared) {
        self.installedApp = installedApp
        self.bundleID = bundleID
        self.session = session
    }

    public func prepare(_ release: ReleaseInfo, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard installedApp.pathExtension == "app" else { throw UpdateError.notInstalled }
        guard let dmgURL = release.dmgURL else { throw UpdateError.noDownload }
        guard let checksumURL = release.checksumURL else { throw UpdateError.noChecksum }
        let folder = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError.notWritable(folder.path)
        }

        let expected = try await fetchChecksum(checksumURL)
        progress(0)
        let dmg = try await download(dmgURL, expectedSize: release.dmgSize, progress: progress)
        defer { try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent()) }
        guard try Self.sha256(of: dmg) == expected else { throw UpdateError.checksumMismatch }
        let staged = try stage(dmg: dmg, version: release.version)
        progress(1)
        return staged
    }

    // MARK: - Steps

    private func fetchChecksum(_ url: URL) async throws -> String {
        let data: Data
        do {
            let (body, response) = try await session.data(from: url)
            try Self.checkStatus(response)
            data = body
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let hash = GitHubReleaseParser.checksum(from: String(decoding: data, as: UTF8.self)) else {
            throw UpdateError.noChecksum
        }
        return hash
    }

    /// The DMG in a folder of its own under the temporary directory (removed by the caller).
    private func download(_ url: URL, expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void)
        async throws -> URL
    {
        let delegate = DownloadProgress(expectedSize: expectedSize, report: progress)
        let temporary: URL
        do {
            let (file, response) = try await session.download(from: url, delegate: delegate)
            try Self.checkStatus(response)
            temporary = file
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-download-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            throw UpdateError.installFailed("download move: \(error.localizedDescription)")
        }
    }

    /// Mounts the image read-only, copies its `.app` out with `ditto`, checks it, and detaches.
    func stage(dmg: URL, version: AppVersion) throws -> URL {
        let fm = FileManager.default
        let mountPoint = fm.temporaryDirectory
            .appendingPathComponent("shotcue-update-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mountPoint.path, dmg.path])
        defer {
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
            try? fm.removeItem(at: mountPoint)
        }

        let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let source = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.invalidBundle("DMG'de uygulama yok")
        }
        let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.invalidBundle("paket kimliği farklı")
        }
        guard let shortVersion = info?["CFBundleShortVersionString"] as? String,
            AppVersion(shortVersion) == version
        else { throw UpdateError.invalidBundle("sürüm \(version) değil") }

        let staging: URL
        do {
            staging = try fm.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedApp, create: true)
        } catch {
            throw UpdateError.installFailed("staging: \(error.localizedDescription)")
        }
        let staged = staging.appendingPathComponent(installedApp.lastPathComponent, isDirectory: true)
        do {
            try Self.run("/usr/bin/ditto", [source.path, staged.path])
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return staged
    }

    // MARK: - Helpers

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }  // file:// in tests
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.network("HTTP \(http.statusCode)") }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed("\(tool): \(error.localizedDescription)")
        }
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw UpdateError.installFailed(
                "\(name) \(process.terminationStatus): \(String(decoding: stderr, as: UTF8.self))")
        }
        return process.terminationStatus
    }
}

/// Forwards a download's bytes as 0…1. GitHub's asset redirects may not send a length; the release's asset size
/// fills in then.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let expectedSize: Int64
    let report: @Sendable (Double) -> Void

    init(expectedSize: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.report = report
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        guard total > 0 else { return }
        report(min(Double(totalBytesWritten) / Double(total), 0.99))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
}
