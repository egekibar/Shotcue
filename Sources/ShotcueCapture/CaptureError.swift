import Foundation

/// Failures of the ShotcueCapture module. The UI shows `stderr` verbatim (spec §8:
/// "screencapture hata → Bildirim + log; task oluşturulmaz").
public enum CaptureError: Error, Equatable, Sendable {
    /// screencapture exited non-zero for a reason other than the user pressing ESC.
    case screencaptureFailed(exitCode: Int32, stderr: String)
    /// The file exists (or was just written) but ImageIO cannot read it as an image.
    case unreadableImage(URL)
    /// The child process could not be spawned at all: missing binary, not executable.
    case launchFailed(String)
}
