import Foundation
import Testing

@testable import ShotcueCore

/// Final review I6: `Run.error` keeps machine codes; the inspector and the failure notification show Turkish text
/// for them, from this one function.
@Suite("Run error text")
struct RunErrorTextTests {
    /// Every code the code base writes today.
    static let everyCode: [String] = [
        RunErrorCode.cancelled, RunErrorCode.cancelledBeforeLaunch, RunErrorCode.interrupted, RunErrorCode.timeout,
        RunErrorCode.claudeNotFound, RunErrorCode.claudeLaunchFailed, RunErrorCode.claudeNotLoggedIn,
        RunErrorCode.claudeFailed, RunErrorCode.claudeError, RunErrorCode.noResult, RunErrorCode.maxTurns,
        RunErrorCode.maxBudget,
        RunErrorCode.executionError, RunErrorCode.voiceNotePending, RunErrorCode.voiceNoteFailed,
        RunErrorCode.voiceNotesUnreadable, RunErrorCode.gitBranchFailed, RunErrorCode.gitStashFailed,
        RunErrorCode.projectMissing, RunErrorCode.projectUnreadable, RunErrorCode.projectFolderMissing,
        RunErrorCode.taskChangedBeforeLaunch, RunErrorCode.unknownError,
    ]

    @Test(arguments: everyCode)
    func everyCodeReadsAsTurkish(code: String) throws {
        let text = try #require(RunErrorText.describe(code))
        #expect(!text.message.isEmpty)
        #expect(text.message != code)
        // A known code needs no raw code under it.
        #expect(text.detail == nil)
    }

    @Test func theCodesAreDistinctMachineTokens() {
        #expect(Set(Self.everyCode).count == Self.everyCode.count)
        #expect(Self.everyCode.allSatisfy { RunErrorCode.isCode($0) })
        #expect(RunErrorCode.maxTurns == ClaudeRunResult.maxTurnsSubtype)
        #expect(RunErrorCode.maxBudget == ClaudeRunResult.maxBudgetSubtype)
    }

    @Test func limitStopsSuggestRaisingTheLimit() throws {
        let turns = try #require(RunErrorText.describe(RunErrorCode.maxTurns, numTurns: 30))
        #expect(turns.message == "Tur limiti aşıldı (30 tur).")
        #expect(turns.suggestion == "Ayarlar > Ajanlar'dan tur limitini artırıp yeniden çalıştır.")
        let budget = try #require(RunErrorText.describe(RunErrorCode.maxBudget))
        #expect(budget.message == "Bütçe limiti aşıldı.")
        #expect(budget.suggestion == "Ayarlar > Ajanlar'dan bütçe limitini artırıp yeniden çalıştır.")
        #expect(
            RunErrorText.notificationBody(for: RunErrorCode.maxTurns, numTurns: 30)
                == "Tur limiti aşıldı (30 tur). Ayarlar > Ajanlar'dan tur limitini artırıp yeniden çalıştır.")
    }

    @Test func aDetailIsShownUnderTheTurkishText() throws {
        let stored = RunErrorCode.compose(RunErrorCode.gitBranchFailed, detail: "fatal: not a git repository")
        let text = try #require(RunErrorText.describe(stored))
        #expect(text.message.contains("branch"))
        #expect(text.detail == "fatal: not a git repository")

        let failed = try #require(RunErrorText.describe(RunErrorCode.claudeFailed, exitCode: 2))
        #expect(failed.message == "claude hata ile çıktı (kod 2).")

        let loggedOut = try #require(RunErrorText.describe(RunErrorCode.claudeNotLoggedIn))
        #expect(loggedOut.message == "claude ile tekrar giriş yapın.")  // spec §8, verbatim
    }

    /// claude reports API and auth failures (a rejected key, a usage limit) as a result with subtype `success` and
    /// `is_error`. The stored code keeps claude's first result line; the inspector and the notification show it with
    /// Turkish text instead of a raw "success".
    @Test func claudesOwnErrorLineIsShownInTheInspectorAndTheNotification() throws {
        let stored = RunErrorCode.compose(RunErrorCode.claudeError, detail: "Invalid API key · Please run /login")
        #expect(stored == "claude_error: Invalid API key · Please run /login")
        let text = try #require(RunErrorText.describe(stored))
        #expect(text.message == "claude hata bildirdi.")
        #expect(text.detail == "Invalid API key · Please run /login")
        // A rejected key is a lost session (spec §8): the text asks for a new login, first in the notification.
        #expect(text.suggestion == "claude ile tekrar giriş yapın.")
        #expect(
            RunErrorText.notificationBody(for: stored)
                == "claude ile tekrar giriş yapın. claude hata bildirdi: Invalid API key · Please run /login")

        // A line that holds ": " itself stays whole; an overloaded API is not a login problem.
        let overloaded = RunErrorCode.compose(RunErrorCode.claudeError, detail: "API Error: 529 Overloaded")
        #expect(RunErrorText.describe(overloaded)?.detail == "API Error: 529 Overloaded")
        #expect(RunErrorText.describe(overloaded)?.suggestion == nil)
        #expect(RunErrorText.notificationBody(for: overloaded) == "claude hata bildirdi: API Error: 529 Overloaded")
        // Without a result line there is nothing to quote.
        #expect(RunErrorText.notificationBody(for: RunErrorCode.claudeError) == "claude hata bildirdi.")

        // Rows written before this code existed hold claude's subtype, `success`, for the same failure; their result
        // text (shown above in the inspector) carries claude's line.
        let legacy = try #require(RunErrorText.describe(ClaudeRunResult.successSubtype))
        #expect(legacy.message == "claude hata bildirdi.")
        #expect(legacy.detail == nil)
    }

    /// Spec §8 ("Oturum düşmüş"): claude's error line for a lost or rejected session adds "claude ile tekrar giriş
    /// yapın." in the inspector and the RUN_FAILED body, as a login failure on stderr does. Case does not matter.
    @Test(
        arguments: [
            ("Invalid API key · Please run /login", true),
            ("Not logged in · Please run /login", true),
            ("OAuth token revoked · Please run /login", true),
            (#"API Error: 401 {"type":"error","error":{"type":"authentication_error"}}"#, true),
            ("INVALID API KEY", true),
            ("Error: not logged in", true),
            ("API Error: 529 Overloaded", false),
            ("Credit balance is too low", false),
            ("Claude AI usage limit reached|1790078400", false),
        ])
    func aLostSessionAsksForANewLogin(line: String, isAuthFailure: Bool) throws {
        #expect(RunErrorText.looksLikeAuthFailure(line) == isAuthFailure)
        let stored = RunErrorCode.compose(RunErrorCode.claudeError, detail: line)
        let text = try #require(RunErrorText.describe(stored))
        #expect(text.message == "claude hata bildirdi.")
        #expect(text.detail == line)
        #expect(text.suggestion == (isAuthFailure ? "claude ile tekrar giriş yapın." : nil))
        let body = RunErrorText.notificationBody(for: stored)
        #expect(
            body
                == (isAuthFailure
                    ? "claude ile tekrar giriş yapın. claude hata bildirdi: \(line)" : "claude hata bildirdi: \(line)"))
    }

    /// A notification banner shows the start of its body and cuts the rest. claude's line for a lost session can run
    /// to ~250 characters (an API error's JSON body), so the login hint leads and the line follows it.
    @Test func theLoginHintLeadsTheNotificationSoALongLineCannotCutItOff() throws {
        let line =
            #"API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"OAuth token has "#
            + #"expired. Please obtain a new token or refresh your existing token."},"request_"#
            + #"id":"req_011CTc9mQ7Zr4xWfVbN2pLsE"} · Please run /login"#
        #expect(line.count > 200)
        let body = RunErrorText.notificationBody(for: RunErrorCode.compose(RunErrorCode.claudeError, detail: line))
        #expect(body.hasPrefix("claude ile tekrar giriş yapın. "))
        #expect(body.hasSuffix("claude hata bildirdi: \(line)"))
    }

    /// The inspector shows claude's line once, as the run's result text (primary text): the failure's detail, which
    /// holds the same line, is not repeated under it.
    @Test func aDetailTheResultTextAlreadyShowsIsNotRepeated() throws {
        let failure = try #require(
            RunErrorText.describe(
                RunErrorCode.compose(RunErrorCode.claudeError, detail: "Invalid API key · Please run /login")))
        #expect(failure.detailIsShown(in: "Invalid API key · Please run /login"))
        #expect(failure.detailIsShown(in: "\nInvalid API key · Please run /login\nikinci satır"))
        // No result text (or another one): the detail is the only place the line is shown.
        #expect(!failure.detailIsShown(in: nil))
        #expect(!failure.detailIsShown(in: "Özet satırı"))
        let branch = try #require(
            RunErrorText.describe(RunErrorCode.compose(RunErrorCode.gitBranchFailed, detail: "fatal: bad ref")))
        #expect(!branch.detailIsShown(in: nil))
        // Nothing to repeat without a detail.
        let limit = try #require(RunErrorText.describe(RunErrorCode.maxTurns))
        #expect(!limit.detailIsShown(in: "Özet satırı"))
    }

    @Test func anUnknownCodeFallsBackToTurkishWithTheRawCodeUnderIt() throws {
        let text = try #require(RunErrorText.describe("error_something_new"))
        #expect(text.message == "Çalışma hata ile bitti.")
        #expect(text.detail == "error_something_new")
        let withDetail = try #require(RunErrorText.describe("brand_new_code: ayrıntı"))
        #expect(withDetail.detail == "brand_new_code: ayrıntı")
    }

    @Test func textStoredBeforeCodesIsShownAsItIs() throws {
        // Rows written before this change hold Turkish sentences (or English stderr), not codes.
        let legacy = try #require(RunErrorText.describe("claude ile tekrar giriş yapın."))
        #expect(legacy.message == "claude ile tekrar giriş yapın.")
        #expect(legacy.detail == nil)
        #expect(RunErrorCode.isCode("Proje klasörü bulunamadı: /tmp/x") == false)
    }

    @Test func nothingStoredDescribesNothing() {
        #expect(RunErrorText.describe(nil) == nil)
        #expect(RunErrorText.describe("  ") == nil)
    }

    @Test func parsingSplitsCodeAndDetail() {
        #expect(RunErrorCode.parse("git_stash_failed: error: could not write index")?.code == "git_stash_failed")
        #expect(
            RunErrorCode.parse("git_stash_failed: error: could not write index")?.detail
                == "error: could not write index")
        #expect(RunErrorCode.parse("timeout")?.detail == nil)
        #expect(RunErrorCode.parse("Zaman aşımı. Çalışma durduruldu.") == nil)
    }
}
