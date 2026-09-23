import Foundation

/// Model choices offered by the model pickers. Aliases track the latest model of each family in the
/// Claude CLI (`--model fable|opus|sonnet|haiku`); "" means "inherit" (project → settings → CLI default).
public enum ClaudeModelChoices {
    public static let aliases = ["", "fable", "opus", "sonnet", "haiku"]

    /// The aliases, plus a stored value that is not one of them (e.g. a full model id saved earlier)
    /// so the picker can still show and keep it.
    public static func options(including stored: String?) -> [String] {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !aliases.contains(trimmed) else { return aliases }
        return aliases + [trimmed]
    }
}
