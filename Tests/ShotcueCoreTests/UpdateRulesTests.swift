import Foundation
import ShotcueCore
import Testing

@Suite("AppVersion")
struct AppVersionTests {
    @Test func parsesTagsWithAndWithoutPrefix() throws {
        #expect(try #require(AppVersion("v1.2.3")) == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(try #require(AppVersion("1.2")) == AppVersion(major: 1, minor: 2, patch: 0))
        #expect(try #require(AppVersion(" V2 ")) == AppVersion(major: 2, minor: 0, patch: 0))
        #expect(try #require(AppVersion("1.0.1-beta.2")).isPrerelease)
    }

    @Test func rejectsGarbage() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1.x") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
    }

    @Test func comparesNumerically() throws {
        #expect(try #require(AppVersion("1.10.0")) > #require(AppVersion("1.9.9")))
        #expect(try #require(AppVersion("2.0")) > #require(AppVersion("1.99.99")))
        #expect(try #require(AppVersion("v1.0.0")) == #require(AppVersion("1.0")))
        // A prerelease sorts before its release.
        #expect(try #require(AppVersion("1.1.0-rc1")) < #require(AppVersion("1.1.0")))
    }

    @Test func descriptionIsPlain() {
        #expect(AppVersion(major: 1, minor: 2, patch: 0).description == "1.2.0")
    }
}

@Suite("GitHubReleaseParser")
struct GitHubReleaseParserTests {
    static let json = """
        {
          "tag_name": "v1.1.0", "name": "Shotcue 1.1.0", "body": "- Yeni: güncelleme\\n- Düzeltme",
          "html_url": "https://github.com/egekibar/Shotcue/releases/tag/v1.1.0",
          "draft": false, "prerelease": false, "published_at": "2026-10-01T10:00:00Z",
          "assets": [
            { "name": "Shotcue-1.1.0.dmg.sha256", "size": 84,
              "browser_download_url": "https://github.com/egekibar/Shotcue/releases/download/v1.1.0/Shotcue-1.1.0.dmg.sha256" },
            { "name": "Shotcue-1.1.0.dmg", "size": 4537710,
              "browser_download_url": "https://github.com/egekibar/Shotcue/releases/download/v1.1.0/Shotcue-1.1.0.dmg" }
          ]
        }
        """

    @Test func readsTheLatestRelease() throws {
        let release = try GitHubReleaseParser.parse(Data(Self.json.utf8))
        #expect(release.version == AppVersion(major: 1, minor: 1, patch: 0))
        #expect(release.tag == "v1.1.0")
        #expect(release.notes == "- Yeni: güncelleme\n- Düzeltme")
        #expect(release.pageURL.absoluteString == "https://github.com/egekibar/Shotcue/releases/tag/v1.1.0")
        #expect(release.dmgURL?.lastPathComponent == "Shotcue-1.1.0.dmg")
        #expect(release.dmgSize == 4_537_710)
        #expect(release.checksumURL?.lastPathComponent == "Shotcue-1.1.0.dmg.sha256")
        #expect(!release.isPrerelease)
    }

    @Test func releaseWithoutAssetsHasNoDownload() throws {
        let json = #"{"tag_name":"v1.2.0","html_url":"https://x.test/r","draft":false,"prerelease":true,"assets":[]}"#
        let release = try GitHubReleaseParser.parse(Data(json.utf8))
        #expect(release.dmgURL == nil)
        #expect(release.checksumURL == nil)
        #expect(release.notes == "")
        #expect(release.isPrerelease)
    }

    @Test func unreadableTagIsAnError() {
        let json = #"{"tag_name":"nightly","html_url":"https://x.test/r","assets":[]}"#
        #expect(throws: UpdateError.self) { try GitHubReleaseParser.parse(Data(json.utf8)) }
        #expect(throws: UpdateError.self) { try GitHubReleaseParser.parse(Data("<html>".utf8)) }
    }

    @Test func readsShasumFiles() {
        let hash = String(repeating: "ab", count: 32)
        #expect(GitHubReleaseParser.checksum(from: "\(hash)  Shotcue-1.1.0.dmg\n") == hash)
        #expect(GitHubReleaseParser.checksum(from: hash.uppercased()) == hash)
        #expect(GitHubReleaseParser.checksum(from: "abc  file") == nil)
        #expect(GitHubReleaseParser.checksum(from: "") == nil)
    }
}

@Suite("UpdateCheckPolicy")
struct UpdateCheckPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dueAfterADayOrNever() {
        #expect(UpdateCheckPolicy.isDue(lastCheck: nil, now: now, autoCheck: true))
        #expect(!UpdateCheckPolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now, autoCheck: true))
        #expect(UpdateCheckPolicy.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now, autoCheck: true))
        #expect(!UpdateCheckPolicy.isDue(lastCheck: nil, now: now, autoCheck: false))
        // A clock that went backwards must not stop checks forever.
        #expect(UpdateCheckPolicy.isDue(lastCheck: now.addingTimeInterval(86_400 * 3), now: now, autoCheck: true))
    }

    func release(_ tag: String, prerelease: Bool = false) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(tag)!, tag: tag, notes: "", pageURL: URL(string: "https://x.test")!,
            dmgURL: URL(string: "https://x.test/a.dmg"), dmgSize: 1, checksumURL: nil, isPrerelease: prerelease)
    }

    @Test func offersOnlyNewerStableReleases() {
        let current = AppVersion(major: 1, minor: 0, patch: 0)
        #expect(UpdateCheckPolicy.shouldOffer(release("v1.0.1"), current: current, skipped: nil, manual: false))
        #expect(!UpdateCheckPolicy.shouldOffer(release("v1.0.0"), current: current, skipped: nil, manual: false))
        #expect(!UpdateCheckPolicy.shouldOffer(release("v0.9.0"), current: current, skipped: nil, manual: true))
        #expect(
            !UpdateCheckPolicy.shouldOffer(
                release("v1.1.0-beta", prerelease: true), current: current, skipped: nil, manual: true))
    }

    @Test func skippedVersionOnlyStopsAutomaticOffers() {
        let current = AppVersion(major: 1, minor: 0, patch: 0)
        #expect(!UpdateCheckPolicy.shouldOffer(release("v1.1.0"), current: current, skipped: "1.1.0", manual: false))
        #expect(UpdateCheckPolicy.shouldOffer(release("v1.1.0"), current: current, skipped: "1.1.0", manual: true))
        #expect(UpdateCheckPolicy.shouldOffer(release("v1.2.0"), current: current, skipped: "1.1.0", manual: false))
    }
}
