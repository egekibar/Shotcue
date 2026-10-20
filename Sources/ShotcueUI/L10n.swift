import Foundation

/// This module's localized strings (`Resources/<language>.lproj/Localizable.strings`), keyed by the English text.
///
/// `L10n.t("Save")` and `L10n.t("Max turns: \(count)")` (key `Max turns: %lld`) return the text in the app's
/// language; views pass the result to `Text`, `Button`, `Toggle`… as a plain string, because most SwiftUI controls
/// only look keys up in the main bundle, not in this module's.
nonisolated enum L10n {
    static let bundle = Bundle.module

    static func t(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle)
    }
}
