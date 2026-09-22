import Testing

@testable import ShotcueCore

@Suite("PromptBuilder")
struct PromptBuilderTests {
    let base = PromptInput(
        mode: .implement, title: "Buton rengi yanlış", projectPath: "/Users/me/crm",
        screenshots: [
            ScreenshotRef(absolutePath: "/tmp/a.png", label: "login ekranı"),
            ScreenshotRef(absolutePath: "/tmp/b.png"),
        ],
        noteText: "Kırmızı olmalı.", transcripts: ["butonun rengi mavi olmuş kırmızı olacak"])

    @Test func headerAndSections() {
        let p = PromptBuilder.build(base)
        let lines = p.components(separatedBy: "\n")
        #expect(lines[0] == "TASK TYPE: IMPLEMENT")
        #expect(lines[1] == "TITLE: Buton rengi yanlış")
        #expect(p.contains("SCREENSHOTS (read each of these with the Read tool BEFORE doing anything else):"))
        #expect(p.contains("- /tmp/a.png  (login ekranı)"))
        #expect(p.contains("- /tmp/b.png\n"))
        #expect(p.contains("NOTE (written by the user):\nKırmızı olmalı."))
        #expect(p.contains("VOICE NOTE (dictated by the user"))
        #expect(p.contains("\"butonun rengi mavi olmuş kırmızı olacak\""))
        #expect(p.contains("PROJECT: /Users/me/crm"))
        #expect(p.contains("Do NOT commit or push"))
    }

    @Test func analyzeModeForbidsEdits() {
        var i = base
        i.mode = .analyze
        let p = PromptBuilder.build(i)
        #expect(p.hasPrefix("TASK TYPE: ANALYZE ONLY"))
        #expect(p.contains("Do NOT modify any file"))
        #expect(!p.contains("Do NOT commit or push"))
    }

    @Test func emptySectionsAreOmitted() {
        var i = base
        i.noteText = "  \n"
        i.transcripts = ["", "   "]
        i.screenshots = []
        let p = PromptBuilder.build(i)
        #expect(p.contains("SCREENSHOTS: none"))
        #expect(!p.contains("NOTE (written by the user)"))
        #expect(!p.contains("VOICE NOTE"))
    }

    @Test func systemPromptMentionsShotcueAndTranscriptCaveat() {
        #expect(PromptBuilder.systemPromptAppend.contains("Shotcue"))
        #expect(PromptBuilder.systemPromptAppend.contains("ANALYZE ONLY"))
        #expect(PromptBuilder.systemPromptAppend.contains("transcription errors"))
    }
}
