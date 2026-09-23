import Testing

@testable import ShotcueCore

@Suite struct ClaudeModelChoicesTests {
    @Test func defaultOptionsStartWithEmptyThenAliases() {
        #expect(ClaudeModelChoices.options(including: nil) == ["", "fable", "opus", "sonnet", "haiku"])
    }

    @Test func knownValueDoesNotDuplicate() {
        #expect(ClaudeModelChoices.options(including: "opus") == ClaudeModelChoices.aliases)
    }

    @Test func customStoredValueIsKeptSelectable() {
        #expect(ClaudeModelChoices.options(including: "claude-opus-5-5").last == "claude-opus-5-5")
    }

    @Test func blankStoredValueIsIgnored() {
        #expect(ClaudeModelChoices.options(including: "  ") == ClaudeModelChoices.aliases)
    }
}
