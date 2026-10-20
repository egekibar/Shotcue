import Foundation

/// A run's failure as the user reads it, in the app's language.
public struct RunErrorDescription: Hashable, Sendable {
    /// What happened, in one sentence.
    public var message: String
    /// What to do about it, when there is something to do (spec §8: after a limit stop, raise the limit).
    public var suggestion: String?
    /// Raw text shown under the message: the stored detail (git's stderr, a path), or — for a code this version does
    /// not know — the stored value itself.
    public var detail: String?

    public init(message: String, suggestion: String? = nil, detail: String? = nil) {
        self.message = message
        self.suggestion = suggestion
        self.detail = detail
    }

    /// Whether the run's result text, which the inspector shows above the failure as primary text, already carries the
    /// detail: for `claude_error` the detail is the result's first line. The inspector then leaves the detail out, so
    /// claude's reason is shown once, prominently.
    public func detailIsShown(in resultText: String?) -> Bool {
        guard let detail, let resultText else { return false }
        return resultText.contains(detail)
    }
}

/// The one place `Run.error` codes become text (final review I6): the inspector's run rows and the RUN_FAILED
/// notification both read it, and the database keeps the codes.
public enum RunErrorText {
    /// nil when nothing is stored. `exitCode` / `numTurns` are the run's own, for the codes that mention them; `agent`
    /// is the CLI that ran it (the `claude_*` codes are stored for every agent and name the one that ran).
    public static func describe(
        _ stored: String?, exitCode: Int32? = nil, numTurns: Int? = nil, agent: AgentKind = .claude
    ) -> RunErrorDescription? {
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let (code, detail) = RunErrorCode.parse(stored) else {
            // Free text from before codes existed: it was written to be read as it is.
            return RunErrorDescription(message: stored.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard var text = known(code, detail: detail, exitCode: exitCode, numTurns: numTurns, agent: agent) else {
            return RunErrorDescription(message: L10n.t("The run ended with an error."), detail: stored)
        }
        text.detail = detail
        return text
    }

    /// The failure notification's body: the message, then the suggestion. For `claude_error` it is claude's own error
    /// line after the Turkish lead: that line is the reason itself (a rejected key, a usage limit), as the body showed
    /// before codes existed. A lost session's login hint comes first: a banner shows the start of the body and cuts the
    /// rest, and claude's line can run to ~250 characters (an API error's JSON body). Other details (git's stderr, a
    /// path) stay in the inspector.
    public static func notificationBody(
        for stored: String?, exitCode: Int32? = nil, numTurns: Int? = nil, agent: AgentKind = .claude
    ) -> String {
        guard let text = describe(stored, exitCode: exitCode, numTurns: numTurns, agent: agent) else {
            return L10n.t("The run ended with an error.")
        }
        if let stored, let line = text.detail, RunErrorCode.parse(stored)?.code == RunErrorCode.claudeError {
            // `claude_error`'s only suggestion is the login hint (`known`).
            return [text.suggestion, "\(errorLead(agent)): \(line)"].compactMap { $0 }.joined(separator: " ")
        }
        return [text.message, text.suggestion].compactMap { $0 }.joined(separator: " ")
    }

    /// `claude_error` in Turkish: the inspector shows it under the agent's line, the notification before it.
    private static func errorLead(_ agent: AgentKind) -> String { L10n.t("\(agent.executableName) reported an error") }

    /// Spec §8 ("Oturum düşmüş"): what a lost session says, whether stderr or the agent's own error line tells.
    private static func loginAgain(_ agent: AgentKind) -> String { L10n.t("Log in to \(agent.executableName) again.") }

    /// The command that logs the agent's CLI in again.
    private static func loginCommand(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "claude"
        case .codex: "codex login"
        case .antigravity: "agy"
        }
    }

    /// Where the agents' paths and limits are set.
    static let settingsTab = L10n.t("Settings > Agents")

    /// Parts of an agent's error line that mean the session is lost or rejected, compared case-insensitively: "Invalid
    /// API key · Please run /login", "Not logged in", an API `authentication_error`, Codex's "401 Unauthorized",
    /// Antigravity's "UNAUTHENTICATED".
    private static let authFailureMarks = [
        "/login", "invalid api key", "authentication", "not logged in", "unauthorized", "unauthenticated",
    ]

    /// Whether claude's error line (a `claude_error` detail) says the session is lost, so the text asks for a new
    /// login (spec §8).
    public static func looksLikeAuthFailure(_ line: String?) -> Bool {
        guard let line = line?.lowercased() else { return false }
        return authFailureMarks.contains { line.contains($0) }
    }

    private static func known(_ code: String, detail: String?, exitCode: Int32?, numTurns: Int?, agent: AgentKind)
        -> RunErrorDescription?
    {
        let cli = agent.executableName
        switch code {
        case RunErrorCode.cancelled:
            return RunErrorDescription(message: L10n.t("Cancelled."))
        case RunErrorCode.cancelledBeforeLaunch:
            return RunErrorDescription(message: L10n.t("Cancelled before \(cli) started."))
        case RunErrorCode.interrupted:
            return RunErrorDescription(
                message: L10n.t("Stopped part way because the app quit."),
                suggestion: L10n.t("If the session started, you can continue it in Terminal or run it again."))
        case RunErrorCode.timeout:
            return RunErrorDescription(
                message: L10n.t("Timed out: the run was stopped at its time limit."),
                suggestion: L10n.t("If needed, raise the timeout in \(settingsTab) and run it again."))
        case RunErrorCode.claudeNotFound:
            return RunErrorDescription(
                message: L10n.t("\(cli) was not found."), suggestion: L10n.t("Check its path in \(settingsTab)."))
        case RunErrorCode.claudeLaunchFailed:
            return RunErrorDescription(message: L10n.t("\(cli) could not be started."))
        case RunErrorCode.claudeNotLoggedIn:
            return RunErrorDescription(
                message: loginAgain(agent), suggestion: L10n.t("Run `\(loginCommand(agent))` in Terminal and log in."))
        case RunErrorCode.claudeFailed:
            return RunErrorDescription(
                message: exitCode.map { L10n.t("\(cli) exited with an error (code \($0)).") } ?? L10n.t("\(cli) exited with an error."))
        case RunErrorCode.claudeError, ClaudeRunResult.successSubtype:
            // `success`: what rows written before `claude_error` existed hold for the same failure; claude's line is
            // then only in the run's result text, which the inspector shows. A line that says the session is lost
            // adds the login hint (spec §8).
            return RunErrorDescription(
                message: "\(errorLead(agent)).", suggestion: looksLikeAuthFailure(detail) ? loginAgain(agent) : nil)
        case RunErrorCode.noResult:
            return RunErrorDescription(message: L10n.t("\(cli) exited without a result line."))
        case RunErrorCode.maxTurns:
            return RunErrorDescription(
                message: numTurns.map { L10n.t("Turn limit reached (\($0) turns).") } ?? L10n.t("Turn limit reached."),
                suggestion: L10n.t("Raise the turn limit in \(settingsTab) and run it again."))
        case RunErrorCode.maxBudget:
            return RunErrorDescription(
                message: L10n.t("Budget limit reached."),
                suggestion: L10n.t("Raise the budget limit in \(settingsTab) and run it again."))
        case RunErrorCode.executionError:
            return RunErrorDescription(
                message: L10n.t("\(agent.displayName) stopped with an error while running."), suggestion: L10n.t("Check the log and run it again."))
        case RunErrorCode.voiceNotePending:
            return RunErrorDescription(
                message: L10n.t("Not sent: the voice note is not transcribed yet."),
                suggestion: L10n.t("Send it again once the transcript is done."))
        case RunErrorCode.voiceNoteFailed:
            return RunErrorDescription(
                message: L10n.t("Not sent: the voice note could not be transcribed."),
                suggestion: L10n.t("Type the transcript or transcribe it again, then send it again."))
        case RunErrorCode.voiceNotesUnreadable:
            return RunErrorDescription(
                message: L10n.t("Not sent: the voice notes could not be read."), suggestion: L10n.t("Send it again."))
        case RunErrorCode.gitBranchFailed:
            return RunErrorDescription(
                message: L10n.t("A new git branch could not be created; \(cli) was not started."),
                suggestion:
                    L10n.t("Fix the project's git state, or turn off \"Start every run on a new branch\" in the project settings.")
            )
        case RunErrorCode.gitStashFailed:
            return RunErrorDescription(
                message: L10n.t("The changes could not be stashed; \(cli) was not started."),
                suggestion:
                    L10n.t("Fix the project's git state, or turn off \"Stash changes before every run\" in the project settings.")
            )
        case RunErrorCode.projectMissing:
            return RunErrorDescription(
                message: L10n.t("Project not found."), suggestion: L10n.t("Assign the task to a project and send it again."))
        case RunErrorCode.projectUnreadable:
            return RunErrorDescription(message: L10n.t("The project could not be read."), suggestion: L10n.t("Send it again."))
        case RunErrorCode.projectFolderMissing:
            return RunErrorDescription(
                message: L10n.t("Project folder not found."),
                suggestion: L10n.t("Right-click the project in the library and fix its path in \"Project Settings…\"."))
        case RunErrorCode.taskChangedBeforeLaunch:
            return RunErrorDescription(
                message: L10n.t("The task changed or was deleted before \(cli) started; it was not run."))
        case RunErrorCode.unknownError:
            return RunErrorDescription(message: L10n.t("An unexpected error occurred."))
        default:
            return nil
        }
    }
}
