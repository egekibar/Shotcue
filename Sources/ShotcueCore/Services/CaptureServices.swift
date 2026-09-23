import Foundation

public struct CaptureResult: Hashable, Sendable {
    public var fileURL: URL
    public var width: Int
    public var height: Int
    public var scale: Double
    public init(fileURL: URL, width: Int, height: Int, scale: Double) {
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// Region screenshot. v1 wraps `/usr/sbin/screencapture -i -s`; returns nil when the user cancels (ESC).
public protocol CaptureService: Sendable {
    func captureRegion(to destination: URL) async throws -> CaptureResult?
}

public protocol ThumbnailService: Sendable {
    /// Writes a JPEG whose longest side is `maxPixel`.
    func makeThumbnail(from source: URL, to destination: URL, maxPixel: Int) async throws
}

public enum PermissionKind: String, Sendable, Codable, CaseIterable {
    case screenRecording, microphone, notifications
}

public enum PermissionState: String, Sendable, Codable {
    case notDetermined, granted, denied
}

public protocol PermissionService: Sendable {
    func state(of kind: PermissionKind) async -> PermissionState
    /// Triggers the system prompt when possible; returns the resulting state.
    func request(_ kind: PermissionKind) async -> PermissionState
    func openSystemSettings(for kind: PermissionKind)
}

/// Global hotkey (Carbon RegisterEventHotKey in Plan 02). One combo at a time.
public protocol HotKeyService: Sendable {
    func register(_ combo: KeyCombo, handler: @escaping @Sendable () -> Void) throws
    func unregister()
}
