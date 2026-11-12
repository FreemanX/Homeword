// Writing languages. The user writes in a few of the model's languages (`languages` knob; default: the system's language when the
// model supports it, else English). Per request the policy detects which one the text is in, among those only (Apple's recognizer
// confuses close languages when it may pick any), tells the model when it is not English ("Language: French" in the request; English
// requests stay as they always were) and spell-checks in that language (or not at all where macOS has no dictionary).
import Foundation
import NaturalLanguage

enum Languages {
    /// The model's languages when predictd cannot say (its `languages` op).
    static let fallback = ["da-DK", "de-DE", "en-AU", "en-GB", "en-IN", "en-US", "es-419", "es-ES", "es-US", "fr-CA", "fr-FR", "it-IT",
                           "ja-JP", "ko-KR", "nb-NO", "nl-NL", "pt-BR", "pt-PT", "sv-SE", "tr-TR", "vi-VN", "zh-Hans-CN", "zh-Hant-HK",
                           "zh-Hant-TW"]
    private static let lock = NSLock()
    private static var model = fallback
    private static var spell: Set<String> = ["en"]
    private static var loaded = false, tried = Date.distantPast

    /// Ask predictd what the model and the spell checker support (at startup, and again after predictd restarted).
    static func load(_ link: Link) {
        lock.lock(); tried = Date(); lock.unlock()
        guard let r = try? link.call(["op": "languages"], timeout: 5), truthy(r["ok"]) else { return }
        lock.lock(); defer { lock.unlock() }
        if let m = r["model"] as? [String], !m.isEmpty { model = m.map(canonical).sorted() }
        if let s = r["spell"] as? [String] { spell = Set(s) }
        loaded = true
    }

    /// Load when not loaded yet (an older predictd without the op: at most once a minute).
    static func loadIfNeeded(_ link: Link) {
        lock.lock(); let due = !loaded && Date().timeIntervalSince(tried) > 60; lock.unlock()
        if due { load(link) }
    }

    static func forget() { lock.lock(); loaded = false; tried = .distantPast; lock.unlock() }

    static var supported: [String] { lock.lock(); defer { lock.unlock() }; return model }

    /// "en-Latn-US" -> "en-US": the script is kept for Chinese only (it is what tells Simplified from Traditional).
    static func canonical(_ id: String) -> String {
        let l = Locale.Language(identifier: id)
        let code = l.languageCode?.identifier ?? id
        let script = code == "zh" ? l.script?.identifier : nil
        return [code, script, l.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    static func code(_ id: String) -> String { Locale.Language(identifier: id).languageCode?.identifier ?? id }
    static func isEnglish(_ id: String) -> Bool { code(id) == "en" }

    /// A preferred language (the system's, "es-MX", "zh-Hant-TW", "de") as one of the model's.
    static func match(_ pref: String, in ids: [String]) -> String? {
        let p = Locale.Language(identifier: pref)
        guard var lang = p.languageCode?.identifier else { return nil }
        if lang == "no" { lang = "nb" }                     // Norwegian, written as Bokmål
        let script = lang == "zh" ? (p.script?.identifier ?? (["TW", "HK", "MO"].contains(p.region?.identifier ?? "") ? "Hant" : "Hans")) : nil
        let same = ids.filter { code($0) == lang && (script == nil || Locale.Language(identifier: $0).script?.identifier == script) }
        if same.isEmpty { return nil }
        if let r = p.region?.identifier {
            if let exact = same.first(where: { Locale.Language(identifier: $0).region?.identifier == r }) { return exact }
            if lang == "es", r != "ES", let latam = same.first(where: { $0.hasSuffix("-419") }) { return latam }   // Mexico, Argentina, ...
        }
        return same.first(where: { ["en-US", "es-ES", "fr-FR", "pt-BR", "zh-Hans-CN", "zh-Hant-TW"].contains($0) }) ?? same.first
    }

    /// The default: the system's language when the model supports it, else English.
    static func systemDefault() -> [String] {
        let ids = supported
        return [Locale.preferredLanguages.first.flatMap { match($0, in: ids) } ?? "en-US"]
    }

    /// The writing languages in effect: the configured ones the model supports, or the default. Benchmarks (no user settings)
    /// write English only unless told otherwise, so their numbers do not depend on the machine's language.
    static func resolve(_ value: Any?, user: Bool) -> [String] {
        let ids = supported
        var out: [String] = []
        for v in value as? [String] ?? [] { if let m = ids.contains(canonical(v)) ? canonical(v) : match(v, in: ids), !out.contains(m) { out.append(m) } }
        if !out.isEmpty { return out }
        return user ? systemDefault() : ["en-US"]
    }

    static func nl(_ id: String) -> NLLanguage {
        let c = code(id)
        if c == "zh" { return Locale.Language(identifier: id).script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese }
        return NLLanguage(rawValue: c)
    }

    /// How the request names the language: "French", or with its variant where the model has several ("Portuguese (Brazil)").
    static func promptName(_ id: String) -> String {
        let en = Locale(identifier: "en")
        let variants = supported.filter { code($0) == code(id) }.count
        if variants > 1 { return en.localizedString(forIdentifier: id) ?? id }
        return en.localizedString(forLanguageCode: code(id)) ?? id
    }

    /// The name in the language itself ("Français (Canada)"), for lists the user picks from.
    static func nativeName(_ id: String) -> String {
        Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    }

    /// The spell checker's language for a writing language ("pt-BR" -> "pt_BR", "fr-CA" -> "fr"), nil without a dictionary.
    static func spellCode(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let l = Locale.Language(identifier: id)
        let c = l.languageCode?.identifier ?? id
        if let r = l.region?.identifier, spell.contains("\(c)_\(r)") { return "\(c)_\(r)" }
        if spell.contains(c) { return c }
        return nil
    }

    /// Which of `ids` the text is in. One language: that one. Otherwise Apple's recognizer, limited to them; when the text is too
    /// short or the call too close, the language detected last on this stream (typing goes on in one language), else the first.
    static func detect(_ text: String, among ids: [String], previous: String?) -> String {
        guard ids.count > 1 else { return ids.first ?? "en-US" }
        let fallbackID = previous.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        let tail = String(text.suffix(400))
        var weight = 0                                       // letters, an ideograph or kana counting as three
        for s in tail.unicodeScalars where s.properties.isAlphabetic { weight += isCJK(s) ? 3 : 1 }
        if weight < 8 { return fallbackID }
        let r = NLLanguageRecognizer()
        r.languageConstraints = Array(Set(ids.map(nl)))
        r.processString(tail)
        guard let (best, p) = r.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }), p >= 0.5 else { return fallbackID }
        return ids.first(where: { nl($0) == best }) ?? fallbackID
    }
}
