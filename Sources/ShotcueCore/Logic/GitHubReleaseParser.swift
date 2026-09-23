import Foundation

/// Reads GitHub's `GET /repos/{owner}/{repo}/releases/latest` answer and the `.sha256` asset next to the DMG.
public enum GitHubReleaseParser {
    private struct Payload: Decodable {
        struct Asset: Decodable {
            var name: String
            var size: Int64?
            var downloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name, size
                case downloadURL = "browser_download_url"
            }
        }
        var tag: String
        var body: String?
        var pageURL: URL
        var prerelease: Bool?
        var assets: [Asset]?
        enum CodingKeys: String, CodingKey {
            case body, prerelease, assets
            case tag = "tag_name"
            case pageURL = "html_url"
        }
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let version = AppVersion(payload.tag)
        else { throw UpdateError.unreadableRelease }
        let assets = payload.assets ?? []
        let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let checksum = dmg.flatMap { dmg in assets.first { $0.name == dmg.name + ".sha256" } }
        return ReleaseInfo(
            version: version,
            tag: payload.tag,
            notes: payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: payload.pageURL,
            dmgURL: dmg?.downloadURL,
            dmgSize: dmg?.size ?? 0,
            checksumURL: checksum?.downloadURL,
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
