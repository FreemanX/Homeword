// The interface language. Every text the user reads goes through L("English text", args...): the English text is the key, looked
// up in Resources/<language>.lproj (Localizable.strings; phrases with a count in Localizable.stringsdict), English when missing.
// Homeword's language (General tab) is the system's, or one the user picks (the app's own AppleLanguages; it applies after a
// relaunch). The translations live in app/Localization/; `python3 -I app/Localization/strings.py` checks them against the code.
import AppKit

/// The text in the interface language.
func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: nil, table: nil) }

/// A format in the interface language ("%d words" with plural forms, "%@ of %@"), filled in.
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), locale: Interface.locale, arguments: args) }

enum Interface {
    /// The languages the interface is translated into: those of Apple's on-device model.
    static let languages = ["en", "da", "de", "es", "fr", "it", "ja", "ko", "nb", "nl", "pt-BR", "pt-PT", "sv", "tr", "vi", "zh-Hans",
                            "zh-Hant"]

    /// The language the interface is shown in now.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var locale: Locale { Locale(identifier: current) }

    /// The language the user picked for Homeword, nil = the system's (read from the app's own settings, not the global ones;
    /// "fr-FR", as System Settings may write it, is shown as French).
    static var chosen: String? {
        get {
            guard let l = (Pref.d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first else { return nil }
            return Bundle.preferredLocalizations(from: languages, forPreferences: [l]).first
        }
        set {
            if let newValue { Pref.d.set([newValue], forKey: "AppleLanguages") } else { Pref.d.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// A language's name in that language, for the picker ("Deutsch", "Português (Portugal)").
    static func nativeName(_ id: String) -> String {
        let l = Locale(identifier: id)
        return (l.localizedString(forIdentifier: id) ?? id).capitalized(with: l)
    }

    /// Start a new copy of the app once this one has exited, then quit (a new interface language needs a fresh launch).
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath,
                       String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
        NSApp.terminate(nil)
    }
}

enum LanguageNames {
    /// A writing language's name in the interface language (or `loc`'s): "German", or with its variant where the model has
    /// several ("Portuguese (Brazil)"). `ids`: the languages it is listed among.
    static func display(_ id: String, among ids: [String], in loc: Locale = Interface.locale) -> String {
        let code = Locale.Language(identifier: id).languageCode?.identifier ?? id
        let variants = ids.filter { (Locale.Language(identifier: $0).languageCode?.identifier ?? $0) == code }.count
        let name = variants > 1 ? loc.localizedString(forIdentifier: id) : loc.localizedString(forLanguageCode: code)
        return (name ?? id).capitalized(with: loc)
    }

    /// A benchmark category's language ("da", "zh-Hans") in the interface language.
    static func category(_ key: String) -> String {
        let loc = Interface.locale
        return ((key.hasPrefix("zh") ? loc.localizedString(forIdentifier: key) : loc.localizedString(forLanguageCode: key)) ?? key)
            .capitalized(with: loc)
    }
}
