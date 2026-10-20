import Foundation

/// Forces one language for the README screenshots, which render both: every module's `L10n` then reads that
/// language's table and the date helpers use its locale. The app never sets it; outside those renders it stays nil and
/// the language is the one macOS picked at launch.
public enum LocalizationOverride {
    nonisolated(unsafe) public static var language: String?

    /// The forced language's locale, else the user's.
    public static var locale: Locale {
        guard let language else { return .autoupdatingCurrent }
        return Locale(identifier: language == "tr" ? "tr_TR" : "en_US")
    }

    /// `module`'s table for the forced language (its `<language>.lproj`), else `module` itself.
    public static func bundle(_ module: Bundle) -> Bundle { bundle(module, language: language) }

    public static func bundle(_ module: Bundle, language: String?) -> Bundle {
        guard let language, let path = module.path(forResource: language, ofType: "lproj"),
            let table = Bundle(path: path)
        else { return module }
        return table
    }
}
