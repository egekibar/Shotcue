import Foundation

/// Unique path under the system temp dir. Nothing is created; the caller writes (or expects nothing).
func scratchURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shotcue-capture-test-\(UUID().uuidString).\(ext)")
}
