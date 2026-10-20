import Foundation

/// This module's localized strings (`Resources/<language>.lproj/Localizable.strings`), keyed by the English text:
/// `L10n.t("Save")`, `L10n.t("\(count) tasks")` (key `%lld tasks`).
nonisolated enum L10n {
    static let bundle = Bundle.module

    static func t(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle)
    }
}
