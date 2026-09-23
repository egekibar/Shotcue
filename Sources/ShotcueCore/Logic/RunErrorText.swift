import Foundation

/// A run's failure as the user reads it.
public struct RunErrorDescription: Hashable, Sendable {
    /// What happened, in one Turkish sentence.
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

/// The one place `Run.error` codes become Turkish (final review I6): the inspector's run rows and the RUN_FAILED
/// notification both read it, and the database keeps the codes.
public enum RunErrorText {
    /// nil when nothing is stored. `exitCode` / `numTurns` are the run's own, for the codes that mention them.
    public static func describe(_ stored: String?, exitCode: Int32? = nil, numTurns: Int? = nil)
        -> RunErrorDescription?
    {
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let (code, detail) = RunErrorCode.parse(stored) else {
            // Free text from before codes existed: it was written to be read as it is.
            return RunErrorDescription(message: stored.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard var text = known(code, detail: detail, exitCode: exitCode, numTurns: numTurns) else {
            return RunErrorDescription(message: "Çalışma hata ile bitti.", detail: stored)
        }
        text.detail = detail
        return text
    }

    /// The failure notification's body: the message, then the suggestion. For `claude_error` it is claude's own error
    /// line after the Turkish lead: that line is the reason itself (a rejected key, a usage limit), as the body showed
    /// before codes existed; a login hint follows it after a dash. Other details (git's stderr, a path) stay in the
    /// inspector.
    public static func notificationBody(for stored: String?, exitCode: Int32? = nil, numTurns: Int? = nil) -> String {
        guard let text = describe(stored, exitCode: exitCode, numTurns: numTurns) else {
            return "Çalışma hata ile bitti."
        }
        if let stored, let line = text.detail, RunErrorCode.parse(stored)?.code == RunErrorCode.claudeError {
            return ["\(claudeErrorLead): \(line)", text.suggestion].compactMap { $0 }.joined(separator: " — ")
        }
        return [text.message, text.suggestion].compactMap { $0 }.joined(separator: " ")
    }

    /// `claude_error` in Turkish: the inspector shows it under claude's line, the notification before it.
    private static let claudeErrorLead = "claude hata bildirdi"

    /// Spec §8 ("Oturum düşmüş"): what a lost claude session says, whether stderr or claude's own error line tells.
    private static let loginAgain = "claude ile tekrar giriş yapın."

    /// Parts of claude's error line that mean the session is lost or rejected, compared case-insensitively: "Invalid
    /// API key · Please run /login", "Not logged in", an API `authentication_error`.
    private static let authFailureMarks = ["/login", "invalid api key", "authentication", "not logged in"]

    /// Whether claude's error line (a `claude_error` detail) says the session is lost, so the text asks for a new
    /// login (spec §8).
    public static func looksLikeAuthFailure(_ line: String?) -> Bool {
        guard let line = line?.lowercased() else { return false }
        return authFailureMarks.contains { line.contains($0) }
    }

    private static func known(_ code: String, detail: String?, exitCode: Int32?, numTurns: Int?)
        -> RunErrorDescription?
    {
        switch code {
        case RunErrorCode.cancelled:
            return RunErrorDescription(message: "İptal edildi.")
        case RunErrorCode.cancelledBeforeLaunch:
            return RunErrorDescription(message: "claude başlamadan iptal edildi.")
        case RunErrorCode.interrupted:
            return RunErrorDescription(
                message: "Uygulama kapandığı için yarıda kaldı.",
                suggestion: "Oturum başladıysa Terminalde devam edebilir ya da yeniden çalıştırabilirsin.")
        case RunErrorCode.timeout:
            return RunErrorDescription(
                message: "Zaman aşımı: çalışma süre sınırında durduruldu.",
                suggestion: "Gerekirse Ayarlar > Claude'dan zaman aşımını artırıp yeniden çalıştır.")
        case RunErrorCode.claudeNotFound:
            return RunErrorDescription(
                message: "claude bulunamadı.", suggestion: "Ayarlar > Claude'dan yolu kontrol et.")
        case RunErrorCode.claudeLaunchFailed:
            return RunErrorDescription(message: "claude başlatılamadı.")
        case RunErrorCode.claudeNotLoggedIn:
            return RunErrorDescription(message: loginAgain, suggestion: "Terminalde `claude` çalıştırıp giriş yap.")
        case RunErrorCode.claudeFailed:
            return RunErrorDescription(
                message: exitCode.map { "claude hata ile çıktı (kod \($0))." } ?? "claude hata ile çıktı.")
        case RunErrorCode.claudeError, ClaudeRunResult.successSubtype:
            // `success`: what rows written before `claude_error` existed hold for the same failure; claude's line is
            // then only in the run's result text, which the inspector shows. A line that says the session is lost
            // adds the login hint (spec §8).
            return RunErrorDescription(
                message: "\(claudeErrorLead).", suggestion: looksLikeAuthFailure(detail) ? loginAgain : nil)
        case RunErrorCode.noResult:
            return RunErrorDescription(message: "claude sonuç satırı üretmeden çıktı.")
        case RunErrorCode.maxTurns:
            return RunErrorDescription(
                message: numTurns.map { "Tur limiti aşıldı (\($0) tur)." } ?? "Tur limiti aşıldı.",
                suggestion: "Ayarlar > Claude'dan tur limitini artırıp yeniden çalıştır.")
        case RunErrorCode.maxBudget:
            return RunErrorDescription(
                message: "Bütçe limiti aşıldı.",
                suggestion: "Ayarlar > Claude'dan bütçe limitini artırıp yeniden çalıştır.")
        case RunErrorCode.executionError:
            return RunErrorDescription(
                message: "Claude çalışırken bir hatayla durdu.", suggestion: "Logu inceleyip yeniden çalıştır.")
        case RunErrorCode.voiceNotePending:
            return RunErrorDescription(
                message: "Sesli not henüz yazıya dökülmediği için gönderilmedi.",
                suggestion: "Transkript bitince yeniden gönder.")
        case RunErrorCode.voiceNoteFailed:
            return RunErrorDescription(
                message: "Sesli not yazıya dökülemediği için gönderilmedi.",
                suggestion: "Transkripti elle yaz ya da yeniden çevir, sonra yeniden gönder.")
        case RunErrorCode.voiceNotesUnreadable:
            return RunErrorDescription(
                message: "Sesli notlar okunamadığı için gönderilmedi.", suggestion: "Yeniden gönder.")
        case RunErrorCode.gitBranchFailed:
            return RunErrorDescription(
                message: "Yeni git branch'i açılamadı; claude başlatılmadı.",
                suggestion:
                    "Projenin git durumunu düzelt ya da proje ayarlarında \"Her çalıştırmayı yeni branch'te başlat\"ı kapat."
            )
        case RunErrorCode.gitStashFailed:
            return RunErrorDescription(
                message: "Değişiklikler stash'lenemedi; claude başlatılmadı.",
                suggestion:
                    "Projenin git durumunu düzelt ya da proje ayarlarında \"Çalıştırmadan önce değişiklikleri stash'le\"yi kapat."
            )
        case RunErrorCode.projectMissing:
            return RunErrorDescription(
                message: "Proje bulunamadı.", suggestion: "Görevi bir projeye atayıp yeniden gönder.")
        case RunErrorCode.projectUnreadable:
            return RunErrorDescription(message: "Proje okunamadı.", suggestion: "Yeniden gönder.")
        case RunErrorCode.projectFolderMissing:
            return RunErrorDescription(
                message: "Proje klasörü bulunamadı.",
                suggestion: "Kütüphanede projeye sağ tıklayıp \"Proje ayarları…\"ndan yolu düzelt.")
        case RunErrorCode.taskChangedBeforeLaunch:
            return RunErrorDescription(
                message: "Görev, claude başlatılmadan önce değişti ya da silindi; çalıştırılmadı.")
        case RunErrorCode.unknownError:
            return RunErrorDescription(message: "Beklenmeyen bir hata oluştu.")
        default:
            return nil
        }
    }
}
