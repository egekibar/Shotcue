import Foundation

/// Reads GitHub's `GET /repos/{owner}/{repo}/releases/latest` answer and the `.sha256` asset next to the DMG.
public enum GitHubReleaseParser {
    private struct Payload: Decodable {
        struct Asset: Decodable {
            var name: String
            var size: Int64?
            var browser_download_url: URL
        }
        var tag_name: String
        var body: String?
        var html_url: URL
        var prerelease: Bool?
        var assets: [Asset]?
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let version = AppVersion(payload.tag_name)
        else { throw UpdateError.unreadableRelease }
        let assets = payload.assets ?? []
        let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let checksum = dmg.flatMap { dmg in assets.first { $0.name == dmg.name + ".sha256" } }
        return ReleaseInfo(
            version: version,
            tag: payload.tag_name,
            notes: payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: payload.html_url,
            dmgURL: dmg?.browser_download_url,
            dmgSize: dmg?.size ?? 0,
            checksumURL: checksum?.browser_download_url,
            isPrerelease: payload.prerelease == true || version.isPrerelease)
    }

    /// The lowercase hex digest from a `shasum -a 256` line ("<hash>  <file>"); nil when it is not one.
    public static func checksum(from text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hash = first.lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash
    }
}
