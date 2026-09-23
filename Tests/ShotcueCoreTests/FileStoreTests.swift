import Foundation
import Testing

@testable import ShotcueCore

@Suite("FileStore")
struct FileStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "shotcue-fs-\(UUID().uuidString)", isDirectory: true)
    let id = UUID(uuidString: "3F2A9C40-7B18-4C6D-9E51-8A2B1D4F0C73")!
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func relativePathsFollowSpecLayout() {
        let fs = FileStore(rootURL: root)
        let date = Date(timeIntervalSince1970: 1_790_078_400)  // 2026-09-22 12:00 UTC
        #expect(
            fs.captureRelPath(id: id, date: date, calendar: utc)
                == "captures/2026/09/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.png")
        #expect(fs.thumbRelPath(id: id) == "thumbs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.jpg")
        #expect(fs.audioRelPath(id: id) == "audio/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.m4a")
        #expect(fs.runLogRelPath(id: id) == "runs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73.jsonl")
        #expect(fs.promptRelPath(id: id) == "runs/3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73-prompt.md")
        #expect(fs.databaseURL.lastPathComponent == "shotcue.sqlite")
    }

    @Test func absoluteAndRelativeRoundTrip() {
        let fs = FileStore(rootURL: root)
        let abs = fs.absoluteURL(for: "audio/x.m4a")
        #expect(abs.path.hasSuffix("/audio/x.m4a"))
        #expect(fs.relativePath(for: abs) == "audio/x.m4a")
        #expect(fs.relativePath(for: URL(fileURLWithPath: "/etc/hosts")) == nil)
    }

    @Test func ensureDirectoriesCreatesLayout() throws {
        let fs = FileStore(rootURL: root)
        try fs.ensureDirectories()
        for dir in ["captures", "thumbs", "audio", "runs"] {
            var isDir: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).path, isDirectory: &isDir)
                    && isDir.boolValue)
        }
        let rel = fs.captureRelPath(id: id, date: Date(), calendar: utc)
        try fs.ensureParentDirectory(for: rel)
        #expect(FileManager.default.fileExists(atPath: fs.absoluteURL(for: rel).deletingLastPathComponent().path))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func defaultRootIsApplicationSupportShotcue() {
        #expect(FileStore.defaultRoot().path.hasSuffix("/Library/Application Support/Shotcue"))
    }
}
