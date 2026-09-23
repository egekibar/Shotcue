import Foundation
import ShotcueCore

/// `GET https://api.github.com/repos/{repo}/releases/latest` — the newest published release that is neither a draft
/// nor marked prerelease. Unauthenticated: 60 requests an hour per IP, far above one check a day.
public struct GitHubReleaseFeed: ReleaseFeed {
    /// "owner/name".
    public let repo: String
    private let session: URLSession

    public init(repo: String, session: URLSession = .shared) {
        self.repo = repo
        self.session = session
    }

    public func latest() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.unreadableRelease
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Shotcue", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 429: throw UpdateError.rateLimited
            // A `where` would bind only to the last pattern of a multi-pattern case; 403 is checked on its own.
            case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
                throw UpdateError.rateLimited
            case 404: throw UpdateError.unreadableRelease  // no published release yet
            default: throw UpdateError.network("HTTP \(http.statusCode)")
            }
        }
        return try GitHubReleaseParser.parse(data)
    }
}
