import Foundation

public enum TitleMaker {
    public static let maxLength = 60

    /// Note first sentence → transcript first sentence → "Yakalama dd.MM HH:mm".
    public static func title(
        noteText: String, transcript: String?, createdAt: Date,
        calendar: Calendar = .current
    ) -> String {
        if let s = firstSentence(noteText) { return s }
        if let t = transcript, let s = firstSentence(t) { return s }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "dd.MM HH:mm"
        return "Yakalama \(f.string(from: createdAt))"
    }

    static func firstSentence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var sentence = ""
        for ch in trimmed {
            if terminators.contains(ch) { break }
            sentence.append(ch)
        }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }
        if sentence.count > maxLength {
            return String(sentence.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return sentence
    }
}
