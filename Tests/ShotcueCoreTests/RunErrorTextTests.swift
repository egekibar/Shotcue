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
        RunErrorCode.claudeFailed, RunErrorCode.noResult, RunErrorCode.maxTurns, RunErrorCode.maxBudget,
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
        #expect(turns.suggestion == "Ayarlar > Claude'dan tur limitini artırıp yeniden çalıştır.")
        let budget = try #require(RunErrorText.describe(RunErrorCode.maxBudget))
        #expect(budget.message == "Bütçe limiti aşıldı.")
        #expect(budget.suggestion == "Ayarlar > Claude'dan bütçe limitini artırıp yeniden çalıştır.")
        #expect(
            RunErrorText.notificationBody(for: RunErrorCode.maxTurns, numTurns: 30)
                == "Tur limiti aşıldı (30 tur). Ayarlar > Claude'dan tur limitini artırıp yeniden çalıştır.")
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
