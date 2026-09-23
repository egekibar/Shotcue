import Foundation

/// Replaces the installed bundle with the staged one once the app has exited, then opens it.
///
/// A detached `/bin/sh` does the work because a running app cannot safely replace its own bundle, and because the
/// new instance must not start while this one still holds the global hotkey (see `OnboardingWindowController`).
/// The old bundle is moved aside first and only deleted once the new one is in place; if the move fails it goes back,
/// so a failed update still leaves a working Shotcue that is then reopened.
public enum BundleSwapper {
    /// `$1` pid, `$2` staged app, `$3` installed app, `$4` opener. Positional parameters, so paths are never re-parsed.
    static let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        staging="$(/usr/bin/dirname "$2")"
        backup="$staging/Previous.app"
        status=1
        if [ -d "$2" ]; then
          /bin/rm -rf "$backup"
          if /bin/mv "$3" "$backup"; then
            if /bin/mv "$2" "$3"; then
              status=0
            else
              /bin/mv "$backup" "$3"
            fi
          fi
        fi
        /bin/rm -rf "$staging"
        /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null
        "$4" "$3"
        exit $status
        """

    /// Starts the helper and returns at once. `opener` is `/usr/bin/open` in the app.
    @discardableResult
    public static func start(
        waitingFor pid: Int32, staged: URL, target: URL, opener: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "shotcue-update", String(pid), staged.path, target.path, opener.path]
        // `open` hands this environment to the new instance; Shotcue's own launch flags must not travel along.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SHOTCUE_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
