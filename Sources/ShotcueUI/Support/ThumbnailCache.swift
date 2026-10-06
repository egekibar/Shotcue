import AppKit
import Foundation
import Observation
import ShotcueCore

/// Shared `NSImage` cache for the grid and the inspector, keyed by the FileStore-relative path the DB
/// stores (spec §6.3). Decoding happens off the main actor; `generation` is an observed stored property
/// that is bumped when an image lands, so any `body` that read through this cache re-renders.
///
/// A cache miss returns nil *and* starts the load, which is what lets `TaskCardView` stay stateless:
/// no `@State`, no `.task` per cell, no duplicated work (the in-flight set collapses repeat requests).
///
/// Storage is a strong, count-bounded LRU on purpose, not `NSCache`. `NSCache` drops entries on its own
/// under memory pressure without telling anyone: an image that landed was gone again by the time the
/// invalidated card re-read it, so the card missed, reloaded, bumped `generation`, missed again — a
/// reload loop that burned CPU and left every card on its placeholder. Here an entry only leaves when
/// `countLimit` newer or more recently read images push it out.
@MainActor
@Observable
public final class ThumbnailCache {
    @ObservationIgnored private var storage: [String: NSImage] = [:]
    /// Keys from least to most recently used; the front is evicted first.
    @ObservationIgnored private var recency: [String] = []
    @ObservationIgnored private let countLimit: Int
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let fileStore: FileStore

    /// Bumped on every insertion; reading it inside `image(relPath:)` registers the dependency.
    private var generation = 0

    public init(fileStore: FileStore, countLimit: Int = 256) {
        self.fileStore = fileStore
        self.countLimit = max(1, countLimit)
    }

    /// Cache-only lookup; never starts a load. Useful in tests and for placeholder decisions.
    public func cached(relPath: String) -> NSImage? {
        storage[relPath]
    }

    /// The accessor views call. Returns nil on a miss and loads in the background.
    public func image(relPath: String) -> NSImage? {
        _ = generation
        if let hit = storage[relPath] {
            touch(relPath)
            return hit
        }
        load(relPath)
        return nil
    }

    /// Same thing for an absolute URL (what `TaskCardView` is handed); URLs outside the store are nil.
    public func image(at url: URL?) -> NSImage? {
        guard let url, let relPath = fileStore.relativePath(for: url) else { return nil }
        return image(relPath: relPath)
    }

    /// Inserts an image the app already has in memory (e.g. right after a capture).
    public func store(_ image: NSImage, relPath: String) {
        insert(image, relPath: relPath)
        generation += 1
    }

    public func removeAll() {
        storage.removeAll()
        recency.removeAll()
        inFlight.removeAll()
        generation += 1
    }

    private func insert(_ image: NSImage, relPath: String) {
        storage[relPath] = image
        touch(relPath)
        while recency.count > countLimit {
            storage[recency.removeFirst()] = nil
        }
    }

    private func touch(_ relPath: String) {
        if recency.last == relPath { return }
        recency.removeAll { $0 == relPath }
        recency.append(relPath)
    }

    private func load(_ relPath: String) {
        guard !inFlight.contains(relPath) else { return }
        inFlight.insert(relPath)
        let url = fileStore.absoluteURL(for: relPath)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return NSImage(data: data)
            }.value
            guard let self else { return }
            self.inFlight.remove(relPath)
            guard let loaded else { return }  // Missing/corrupt file: stay empty, allow a retry later.
            self.insert(loaded, relPath: relPath)
            self.generation += 1
        }
    }
}
