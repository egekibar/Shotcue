import Foundation

/// This module's localized strings (`Resources/<language>.lproj/Localizable.strings`). Views pass
/// `bundle: L10n.bundle` to `Text`/`Button`; other code calls `String(localized:bundle:)` with it.
nonisolated enum L10n {
    static let bundle = Bundle.module
}
