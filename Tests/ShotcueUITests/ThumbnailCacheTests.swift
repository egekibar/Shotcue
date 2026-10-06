import AppKit
import Foundation
import Observation
import ShotcueCore
import Testing
import UniformTypeIdentifiers

@testable import ShotcueUI

@Suite("ThumbnailCache")
struct ThumbnailCacheTests {
    /// 1x1 red PNG, base64 — the smallest thing `NSImage(data:)` will accept. Every chunk CRC and the zlib
    /// checksum are valid, so the test does not depend on a lenient decoder.
    static let onePixelPNG = Data(
        base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg==
            """)!

    @MainActor
    @Test func missReturnsNilThenTheLoadedImageLands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-thumbs-\(UUID().uuidString)", isDirectory: true)
        let fileStore = FileStore(rootURL: root)
        try fileStore.ensureDirectories()
        let relPath = "thumbs/one.png"
        try fileStore.ensureParentDirectory(for: relPath)
        try Self.onePixelPNG.write(to: fileStore.absoluteURL(for: relPath))

        let cache = ThumbnailCache(fileStore: fileStore)
        // First read is a miss and kicks off the background load.
        #expect(cache.cached(relPath: relPath) == nil)
        #expect(cache.image(relPath: relPath) == nil)
        #expect(await waitUntil("loaded") { cache.cached(relPath: relPath) != nil })
        let image = try #require(cache.image(relPath: relPath))
        #expect(image.size.width >= 1)

        cache.removeAll()
        #expect(cache.cached(relPath: relPath) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    @Test func absoluteURLsAreResolvedBackToRelativeKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-thumbs-\(UUID().uuidString)", isDirectory: true)
        let fileStore = FileStore(rootURL: root)
        try fileStore.ensureDirectories()
        let relPath = "thumbs/two.png"
        try fileStore.ensureParentDirectory(for: relPath)
        try Self.onePixelPNG.write(to: fileStore.absoluteURL(for: relPath))

        let cache = ThumbnailCache(fileStore: fileStore)
        #expect(cache.image(at: fileStore.absoluteURL(for: relPath)) == nil)
        #expect(await waitUntil("loaded") { cache.cached(relPath: relPath) != nil })
        #expect(cache.image(at: fileStore.absoluteURL(for: relPath)) != nil)

        // Outside the store root and nil are both no-ops, never a crash.
        #expect(cache.image(at: URL(fileURLWithPath: "/etc/hosts")) == nil)
        #expect(cache.image(at: nil) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    @Test func missingFileNeverPopulatesTheCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-thumbs-\(UUID().uuidString)", isDirectory: true)
        let fileStore = FileStore(rootURL: root)
        try fileStore.ensureDirectories()
        let cache = ThumbnailCache(fileStore: fileStore)
        #expect(cache.image(relPath: "thumbs/missing.png") == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(cache.cached(relPath: "thumbs/missing.png") == nil)
        // A second read retries rather than getting stuck in the in-flight set.
        #expect(cache.image(relPath: "thumbs/missing.png") == nil)
        try? FileManager.default.removeItem(at: root)
    }

    /// What `TaskCardView` relies on: a body that read a miss must be invalidated when the decode lands,
    /// otherwise the card keeps its placeholder forever.
    @MainActor
    @Test func aLandedLoadInvalidatesTheReaderThatMissed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotcue-thumbs-\(UUID().uuidString)", isDirectory: true)
        let fileStore = FileStore(rootURL: root)
        try fileStore.ensureDirectories()
        let relPath = "thumbs/observed.png"
        try fileStore.ensureParentDirectory(for: relPath)
        try Self.onePixelPNG.write(to: fileStore.absoluteURL(for: relPath))

        let cache = ThumbnailCache(fileStore: fileStore)
        let changed = ChangeFlag()
        let first = withObservationTracking {
            cache.image(relPath: relPath)
        } onChange: {
            changed.set()
        }
        #expect(first == nil)
        #expect(await waitUntil("observer notified") { changed.isSet })
        #expect(cache.image(relPath: relPath) != nil)
        try? FileManager.default.removeItem(at: root)
    }

    /// Regression: with `NSCache` a landed image could vanish before the card re-read it (memory pressure),
    /// leaving the grid on placeholders in a reload loop. Entries now leave only through the count limit,
    /// least recently used first.
    @MainActor
    @Test func onlyTheLeastRecentlyUsedImageIsEvictedAndOnlyPastTheLimit() throws {
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shotcue-thumbs-\(UUID().uuidString)", isDirectory: true))
        let cache = ThumbnailCache(fileStore: fileStore, countLimit: 2)
        let image = try #require(NSImage(data: Self.onePixelPNG))
        cache.store(image, relPath: "thumbs/a.png")
        cache.store(image, relPath: "thumbs/b.png")
        #expect(cache.cached(relPath: "thumbs/a.png") != nil)
        #expect(cache.cached(relPath: "thumbs/b.png") != nil)

        // Reading `a` makes `b` the least recently used, so `c` pushes `b` out.
        #expect(cache.image(relPath: "thumbs/a.png") != nil)
        cache.store(image, relPath: "thumbs/c.png")
        #expect(cache.cached(relPath: "thumbs/a.png") != nil)
        #expect(cache.cached(relPath: "thumbs/b.png") == nil)
        #expect(cache.cached(relPath: "thumbs/c.png") != nil)

        // Re-storing a key does not count twice.
        cache.store(image, relPath: "thumbs/c.png")
        #expect(cache.cached(relPath: "thumbs/a.png") != nil)
    }

    @MainActor
    @Test func storeInsertsAnImageDirectly() throws {
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shotcue-thumbs-\(UUID().uuidString)", isDirectory: true))
        let cache = ThumbnailCache(fileStore: fileStore)
        let image = try #require(NSImage(data: Self.onePixelPNG))
        cache.store(image, relPath: "thumbs/direct.png")
        #expect(cache.cached(relPath: "thumbs/direct.png") != nil)
    }
}

@Suite("TaskDragItem")
struct TaskDragItemTests {
    @Test func codableRoundTripKeepsTheIDsInOrder() throws {
        let ids = [UUID(), UUID(), UUID()]
        let item = TaskDragItem(taskIDs: ids)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TaskDragItem.self, from: data)
        #expect(decoded.taskIDs == ids)
        #expect(decoded == item)
    }

    @Test func theTransferTypeIsDeclaredAndDataBacked() {
        // `.json` is system-declared and data-conforming, so `CodableRepresentation` needs no
        // Info.plist entry. A private `UTType(exportedAs:)` registers its identifier but reports
        // `conforms(to: .data) == false` until the bundle declares it — measured on this machine.
        #expect(UTType.json.isDeclared)
        #expect(UTType.json.conforms(to: .data))
        #expect(UTType.json.identifier == "public.json")
    }
}

/// Set from an observation `onChange`, which may fire off the main actor.
nonisolated private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
