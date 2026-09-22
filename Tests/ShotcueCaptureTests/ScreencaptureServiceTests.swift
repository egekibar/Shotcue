import Foundation
import ShotcueCore
import Testing

@testable import ShotcueCapture

@Suite("ScreencaptureService")
struct ScreencaptureServiceTests {
    /// The fake replaces /usr/sbin/screencapture; the scenario comes from the environment.
    func service(_ scenario: String) -> ScreencaptureService {
        ScreencaptureService(
            executableURL: TestPaths.fixture("fake-screencapture.sh"),
            environment: ["FAKE_SCREENCAPTURE_SCENARIO": scenario])
    }

    @Test func buildsExactArgumentList() {
        #expect(
            ScreencaptureService.arguments(for: URL(fileURLWithPath: "/tmp/a b/shot.png"))
                == ["-i", "-s", "-x", "-t", "png", "/tmp/a b/shot.png"])
    }

    @Test func defaultExecutableIsSystemScreencapture() {
        #expect(ScreencaptureService().executableURL.path == "/usr/sbin/screencapture")
    }

    @Test func successCopiesFileAndReportsRetinaSize() async throws {
        let destination = scratchURL("png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try #require(await service("success").captureRegion(to: destination))
        #expect(result == CaptureResult(fileURL: destination, width: 64, height: 64, scale: 2.0))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// ESC in the real tool: exit 1 with empty stderr. Not an error, and nothing is left on disk.
    @Test func cancelReturnsNilAndLeavesNoFile() async throws {
        let destination = scratchURL("png")
        #expect(try await service("cancel").captureRegion(to: destination) == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func errorThrowsWithExitCodeAndStderr() async {
        let destination = scratchURL("png")
        await #expect(
            throws: CaptureError.screencaptureFailed(
                exitCode: 2, stderr: "screencapture: could not create image")
        ) {
            try await service("error").captureRegion(to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test func missingExecutableThrowsLaunchFailed() async throws {
        let service = ScreencaptureService(executableURL: URL(fileURLWithPath: "/nope/missing"))
        let destination = scratchURL("png")
        let error = await #expect(throws: CaptureError.self) {
            try await service.captureRegion(to: destination)
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed, got \(String(describing: error))")
            return
        }
    }

    /// Exit 0 but no readable PNG (disk full, tool changed): a hard error, not a silent success.
    @Test func zeroExitWithUnreadableFileThrows() async {
        let destination = scratchURL("png")
        let service = ScreencaptureService(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        await #expect(throws: CaptureError.unreadableImage(destination)) {
            try await service.captureRegion(to: destination)
        }
    }
}
