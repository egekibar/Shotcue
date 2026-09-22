import Foundation
import Testing

@testable import ShotcueCore

@Suite("TitleMaker")
struct TitleMakerTests {
    let created = Date(timeIntervalSince1970: 1_758_542_400)  // 2025-09-22 12:00:00 UTC (yıl başlıkta görünmez)
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func usesFirstSentenceOfNote() {
        let t = TitleMaker.title(
            noteText: "Butonun rengi yanlış. Ayrıca hizalama bozuk.", transcript: nil,
            createdAt: created, calendar: utc)
        #expect(t == "Butonun rengi yanlış")
    }

    @Test func fallsBackToTranscriptThenDate() {
        #expect(
            TitleMaker.title(noteText: "  ", transcript: "login ekranı açılmıyor!", createdAt: created, calendar: utc)
                == "login ekranı açılmıyor")
        #expect(
            TitleMaker.title(noteText: "", transcript: nil, createdAt: created, calendar: utc) == "Yakalama 22.09 12:00"
        )
    }

    @Test func truncatesLongSentencesWithEllipsis() {
        let long = String(repeating: "kelime ", count: 20)
        let t = TitleMaker.title(noteText: long, transcript: nil, createdAt: created, calendar: utc)
        #expect(t.count <= TitleMaker.maxLength)
        #expect(t.hasSuffix("…"))
    }

    @Test func newlineEndsSentence() {
        #expect(
            TitleMaker.title(noteText: "ilk satır\nikinci satır", transcript: nil, createdAt: created, calendar: utc)
                == "ilk satır")
    }
}
