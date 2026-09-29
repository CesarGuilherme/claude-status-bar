import Foundation

/// User-facing text. Keys are the English wording; each language lives in
/// `Resources/<lang>.lproj/Localizable.strings` and macOS picks the one that
/// matches the system language, English otherwise.
enum L10n {
    static let bundle = Bundle.module

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        format(bundle.localizedString(forKey: key, value: key, table: nil), args)
    }

    /// The same text in one given language, for tests.
    static func tr(_ key: String, in localization: String, _ args: CVarArg...) -> String {
        guard let path = bundle.path(forResource: localization, ofType: "lproj"),
              let lproj = Bundle(path: path) else { return format(key, args) }
        return format(lproj.localizedString(forKey: key, value: key, table: nil), args)
    }

    /// The language the texts are shown in: "en", "pt-BR", "es", "fr" or "de".
    static var language: String {
        bundle.preferredLocalizations.first ?? "en"
    }

    private static func format(_ text: String, _ args: [CVarArg]) -> String {
        args.isEmpty ? text : String(format: text, locale: .current, arguments: args)
    }
}
