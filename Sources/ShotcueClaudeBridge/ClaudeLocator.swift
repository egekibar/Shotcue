import Foundation

/// Finds the `claude` executable (spec §6.4): the user's setting first, then the three install
/// locations, then `which claude` through a login shell (GUI apps inherit a minimal PATH).
public enum ClaudeLocator {
    /// Checked in order, after `preferredPath`.
    public static let defaultCandidates = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    public static func locate(preferredPath: String? = nil) -> URL? {
        locate(
            preferredPath: preferredPath, candidates: defaultCandidates,
            fileManager: .default, loginShellWhich: whichThroughLoginShell)
    }

    /// Injection points exist so tests can prove the ordering without depending on the machine.
    static func locate(
        preferredPath: String?, candidates: [String], fileManager: FileManager,
        loginShellWhich: (FileManager) -> URL?
    ) -> URL? {
        var paths: [String] = []
        if let preferredPath, !preferredPath.trimmingCharacters(in: .whitespaces).isEmpty {
            paths.append(preferredPath)
        }
        paths.append(contentsOf: candidates)
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return loginShellWhich(fileManager)
    }

    static func whichThroughLoginShell(_ fileManager: FileManager) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path =
            String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("/") } ?? ""
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
