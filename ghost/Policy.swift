// The typing-ghost policy: what to ask predictd while someone types, and how to turn the answer into ghost text.
//
// predictd only hosts the model (profiles, warm sessions, generate). Everything specific to typing prediction is here:
//   - the profile: instructions and few-shot examples (prompt.json for general, styles.json for the other writing styles),
//     registered with predictd and pinned (kept warm)
//   - per keystroke: keep the tail of the text that fits `textBudget`, format it with the template, ask for `maxTokens`
//   - assemble: the model writes the rest of the unfinished word and the next words; glue, spell-check, re-space, stop at the end
//     of the sentence, cap the words, suppress an invalid word
import Foundation

let STRUCTURED_SCHEMA: [String: Any] = ["title": "Prediction", "type": "object", "required": ["completion"],
                                        "properties": ["completion": ["type": "string", "description": "how the text continues"]]]
// "friday" is only a word as "Friday"; but don't accept every name ("justine" is not "just in"), only days and months
let CAPITAL_OK: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
                               "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
let ABBR: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "etc", "e.g", "i.e", "st", "no", "inc", "jr", "sr", "approx", "fig"]
let STRIP = ",.;:!?\"')]}"
let ATTACH = Set(",.;:!?)]}'’".unicodeScalars)

func isCJK(_ c: Unicode.Scalar) -> Bool {
    let o = c.value
    return (0x3040...0x30FF).contains(o) || (0x3400...0x9FFF).contains(o) || (0xAC00...0xD7AF).contains(o)
}

func wordChar(_ c: Unicode.Scalar) -> Bool { (c.pyAlpha && !isCJK(c)) || c == "'" || c == "’" }

/// The unfinished word at the end of text ("tomor" of "See you tomor"), or "".
func trailingPartial(_ text: String) -> String {
    let t = text.sc
    var i = t.count
    while i > 0 && wordChar(t[i - 1]) { i -= 1 }
    return String(scalars: t[i...])
}

/// Keep the tail of text that fits `budget` estimated tokens, cut on a word boundary: (tail, est_tokens, trimmed).
/// chars/token measured on this model: prose ~4.8-5.1, code 2.9, shell 2.6, Chinese 1.6.
func trimTail(_ text: String, _ budget: Int) -> (String, Double, Bool) {
    let all = text.sc
    let window = Array(all.suffix(max(budget, 1) * 8))
    let sym = window.filter { !$0.pyAlpha && !$0.pySpace }.count
    let ratio = Double(sym) / Double(max(window.count, 1)) > 0.08 ? 2.9 : 4.8
    var cost = 0.0, cut = window.count
    while cut > 0 {
        let c = isCJK(window[cut - 1]) ? 1 / 1.6 : 1 / ratio
        if cost + c > Double(budget) { break }
        cost += c
        cut -= 1
    }
    let whole = cut == 0 && window.count == all.count
    if !whole && 0 < cut && cut < window.count {                // do not start mid-word
        while cut < window.count && !window[cut - 1].pySpace && !window[cut].pySpace { cut += 1 }
        if cut < window.count && !window[cut - 1].pySpace { cut += 1 }
    }
    return (String(scalars: window[cut...]), cost, !whole)
}

func normWord(_ w: String) -> String { pyStrip(w, STRIP + "([{“‘").lowercased() }

/// Spans of non-whitespace runs (re.finditer(r"\S+")), as code point offsets.
func nonSpaceSpans(_ s: Scalars) -> [(Int, Int)] {
    var out: [(Int, Int)] = [], i = 0
    while i < s.count {
        if s[i].pySpace { i += 1; continue }
        let a = i
        while i < s.count && !s[i].pySpace { i += 1 }
        out.append((a, i))
    }
    return out
}

/// Cut comp before the first word that would complete an n-gram already in the last `window` words of text (or earlier in comp).
/// The model likes to echo recent phrases, and accepting the echo again and again loops ("timeline changes timeline adjustments
/// timeline changes ..."). The completion of an unfinished word (`partial` + first piece) is always kept. Returns (comp, cut).
func cutRepeat(_ text: String, _ partial: String, _ comp: String, _ n: Int, _ window: Int) -> (String, Bool) {
    var ctx = pySplit(text).suffix(window).map(normWord)
    if !partial.isEmpty && !ctx.isEmpty { ctx.removeLast() }      // the unfinished word is completed by the first piece
    let c = comp.sc
    let spans = nonSpaceSpans(c)
    var words = spans.map { normWord(String(scalars: c[$0.0..<$0.1])) }
    if !partial.isEmpty && !words.isEmpty { words[0] = normWord(partial + String(scalars: c[spans[0].0..<spans[0].1])) }
    let seq = ctx + words
    var seen = Set<[String]>()
    if ctx.count - n + 1 > 0 { for i in 0..<(ctx.count - n + 1) { seen.insert(Array(seq[i..<(i + n)])) } }
    for j in 0..<words.count {
        let p = ctx.count + j
        if p < n - 1 { continue }
        let g = Array(seq[(p - n + 1)...p])
        if seen.contains(g) && g.allSatisfy({ !$0.isEmpty }) && !(!partial.isEmpty && j == 0) {
            return (pyRStrip(String(scalars: c[..<spans[j].0])), true)
        }
        seen.insert(g)
    }
    return (comp, false)
}

/// Index just after the end of the first sentence in s (. ! ? … followed by whitespace or the end, not an abbreviation, initial or
/// number), or nil.
func sentenceEnd(_ str: String) -> Int? {
    let s = str.sc
    var i = 0
    let n = s.count
    let closing = Set("\"')]”’".unicodeScalars), cjkClose = Set("」』）”".unicodeScalars), stops = Set(".!?…".unicodeScalars)
    while i < n {
        let ch = s[i]
        if "。！？".unicodeScalars.contains(ch) {
            var j = i + 1
            while j < n && cjkClose.contains(s[j]) { j += 1 }
            return j
        }
        if stops.contains(ch) {
            var j = i + 1
            while j < n && stops.contains(s[j]) { j += 1 }               // "?!" "..."
            var k = j
            while k < n && closing.contains(s[k]) { k += 1 }             // closing quote or bracket
            if k == n || s[k].pySpace {
                if ch == "." {
                    var a = i
                    while a > 0 && !s[a - 1].pySpace { a -= 1 }
                    let tok = pyStrip(String(scalars: s[a..<i]).lowercased(), "\"'([“")
                    let t = tok.sc
                    if ABBR.contains(tok) || (t.count == 1 && t[0].pyAlpha) || (!t.isEmpty && t.allSatisfy { $0.pyNumeric }) {
                        i = j
                        continue
                    }
                }
                return k
            }
            i = j
            continue
        }
        i += 1
    }
    return nil
}

func pyCapitalize(_ w: String) -> String {
    guard let f = w.unicodeScalars.first else { return w }
    return f.properties.titlecaseMapping + String(scalars: w.unicodeScalars.dropFirst()).lowercased()
}

/// Word check through predictd's `spell` op (NSSpellChecker), batched and cached for one answer.
final class Speller {
    let ask: ([String]) throws -> [Bool]
    let enabled: Bool
    var known: [String: Bool] = [:]

    init(_ ask: @escaping ([String]) throws -> [Bool], _ cfg: [String: Any]) {
        self.ask = ask
        enabled = truthy(cfg["spellCheck"])
    }

    func prefetch(_ words: [String]) throws {
        guard enabled else { return }
        var want = Set<String>()
        for w in words where Speller.checkable(w) {
            want.insert(w)
            if CAPITAL_OK.contains(w.lowercased()) { want.insert(pyCapitalize(w)) }
        }
        let missing = want.filter { known[$0] == nil }.sorted(by: pyLess)
        if !missing.isEmpty {
            for (w, ok) in zip(missing, try ask(missing)) { known[w] = ok }
        }
    }

    static func checkable(_ w: String) -> Bool {
        !w.isEmpty && w.unicodeScalars.allSatisfy { $0.pyAlpha || $0 == "'" || $0 == "’" } && !w.unicodeScalars.contains(where: isCJK)
    }

    func raw(_ w: String) throws -> Bool {
        if known[w] == nil { try prefetch([w]) }
        return known[w] ?? true
    }

    func ok(_ w: String) throws -> Bool {
        if !enabled || !Speller.checkable(w) { return true }
        return try raw(w) || (CAPITAL_OK.contains(w.lowercased()) && raw(pyCapitalize(w)))
    }
}

struct Assembly {
    var shown = "", raw = "", partial = "", firstWord = ""
    var droppedPartial = false, sentenceEnd = false, glued = false, respaced = false, valid = true
    var suppressed: String? = nil
    var words = 0, misspelled = 0
    var repeatCut = false
}

/// Turn the model's raw continuation into the ghost to show after `text`.
func assemble(_ text: String, _ completion: String, _ app: String, _ cfg: [String: Any], _ truncated: Bool, _ speller: Speller) throws -> Assembly {
    let lenient = (cfg["lenientApps"] as? [String] ?? []).contains(app)
    var a = Assembly()
    var comp = completion.replacingOccurrences(of: "\n", with: " ")
    let partial = trailingPartial(text)
    a.partial = partial
    try speller.prefetch(pySplit(partial + comp).map { pyStrip($0, STRIP + "([{") } + pySplit(comp).map { pyStrip($0, STRIP + "([{") } + [partial])
    let t = text.sc
    let lastSpace = t.last?.pySpace ?? false
    if cfg["format"] as? String == "fullword" && !partial.isEmpty {   // the model re-wrote the last word in full: cut the typed part off
        comp = pyLStrip(comp)
        if !pyStarts(comp.lowercased(), partial.lowercased()) {
            a.suppressed = "prefix_mismatch"
            a.valid = false
            return a
        }
        comp = String(scalars: comp.sc.dropFirst(partial.pyLen))
    }
    let c0 = comp.unicodeScalars.first
    if !t.isEmpty && lastSpace {
        comp = pyLStrip(comp)
    } else if partial.isEmpty, let c0, !c0.pySpace, let last = t.last, ",.;:!?)".unicodeScalars.contains(last) {
        comp = " " + comp
    } else if !partial.isEmpty, let c0, !c0.pySpace {
        a.glued = true
    }
    // cut by the token cap: the last word may be unfinished ("for so" of "for some"), drop it unless it is the only one
    if truncated {
        let trimmed = pyStrip(comp).sc
        if let sp = trimmed.lastIndex(where: { $0.pySpace }) {
            let cs = comp.sc
            let lead = cs.prefix(cs.count - pyLStrip(comp).pyLen)
            comp = String(scalars: lead) + String(scalars: trimmed[..<sp])
            a.droppedPartial = true
        }
    }
    // one sentence only: stop at the first sentence end (not for shell lines or code, where . ! ? are syntax)
    if truthy(cfg["oneSentence"]) && !lenient, let e = sentenceEnd(comp) {
        comp = String(scalars: comp.sc.prefix(e))
        a.sentenceEnd = true
    }
    // cap the number of words: the unfinished word counts as one, then `words` more
    let limit = (intValue(cfg["words"]) ?? Int(num(cfg["words"]) ?? 5)) + (a.glued ? 1 : 0)
    var count = 0, end = 0, inWord = false
    let cs = comp.sc
    for (i, ch) in cs.enumerated() {
        if ch.pySpace {
            if inWord {
                count += 1
                end = i
                inWord = false
                if count == limit { break }
            }
        } else {
            inWord = true
        }
    }
    if inWord && count < limit {
        count += 1
        end = cs.count
    }
    comp = pyRStrip(String(scalars: cs.prefix(end)))
    a.raw = comp
    a.words = count
    if a.glued && !comp.isEmpty {
        let parts = pySplit(comp)
        let piece = parts.first ?? comp
        let core = pyStrip(partial + piece, STRIP)
        a.firstWord = core
        a.valid = try speller.ok(core)
        // The model cannot reliably write the leading space after a word that is already finished ("git" + "commit -m",
        // "with the" + "project"), so decide here whether the piece is the end of the typed word or a new word:
        //  - it starts with something that cannot continue a word (a flag, path, operator, an opening quote): new word
        //  - the glued word is not a word but the piece alone is (3+ letters): new word
        let f = piece.unicodeScalars.first!
        var separate = false
        if !f.pyAlpha && !f.pyNumeric && !ATTACH.contains(f) {
            separate = f == "\"" ? pyCount(text, "\"") % 2 == 0 : true   // a quote closes a word only inside an open quote
        }
        let word = pyStrip(piece, STRIP)
        // a capital right after lowercase letters is a new sentence/word in prose ("out" + "I would"), camelCase only in code
        if !separate && f.pyUpper, let pl = partial.unicodeScalars.last, pl.pyLower, !lenient { separate = true }
        let short = word.pyLen < 3   // "to", "a", "I": only when the typed part is itself a finished word ("have" + "to")
        if !separate && !a.valid && !word.isEmpty && word.unicodeScalars.allSatisfy({ $0.pyAlpha }), try speller.ok(word),
           try speller.ok(partial),  // an unfinished typed word ("fri") must not be split off from the model's next word
           // a 2-letter piece only after a typed word of 3+ letters ("have" + "to"), not after "ru" + "un" (which wanted "run")
           !short || ((word.pyLen == 2 || ["a", "i"].contains(word.lowercased())) && partial.pyLen >= 3) {
            separate = true
        }
        if separate {
            a.glued = false
            a.valid = true
            a.respaced = true
            a.firstWord = piece
            comp = " " + comp
        }
    } else {
        a.firstWord = pySplit(comp).first ?? ""
        // a new word must be a word too ("adjustments" + tab + "ments"); lowercase only, so names and acronyms pass
        let w = normWord(a.firstWord)
        if !w.isEmpty && pyEq(w, pyStrip(a.firstWord, STRIP + "([{“‘")) && !lenient, try !speller.ok(w) { a.valid = false }
    }
    let ngram = intValue(cfg["repeatNgram"]) ?? 0
    if ngram > 0 && !pyStrip(comp).isEmpty {
        (comp, a.repeatCut) = cutRepeat(text, a.glued ? partial : "", comp, ngram, intValue(cfg["repeatWindow"]) ?? 60)
        a.words = pySplit(comp).count
    }
    a.misspelled = try pySplit(partial + comp).reduce(0) { $0 + (try speller.ok(pyStrip($1, ",.;:!?\"'()[]{}")) ? 0 : 1) }
    a.shown = comp
    if !a.valid && cfg["invalidPolicy"] as? String == "drop" && !lenient {
        a.shown = ""
        a.suppressed = "invalid_word"
    } else if a.repeatCut && pyStrip(comp).isEmpty {
        a.shown = ""
        a.suppressed = "repetition"
    }
    return a
}

/// The user's config directory, outside the repo: config.json (knob overrides), prompts.json, prompt-history.json,
/// test-cases.json. The project's earlier name was input-predictor: that directory is moved here once.
func userDir() -> String {
    let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
    let d = base + "/homeword", old = base + "/input-predictor"
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: d) && FileManager.default.fileExists(atPath: old, isDirectory: &isDir) && isDir.boolValue {
        if rename(old, d) != 0 { return old }
    }
    return d
}

/// config.json, then the user's overrides of its knobs (userDir()/config.json), unless `user` is false (benchmarks).
func loadConfig(_ path: String, user: Bool) -> [String: Any] {
    var cfg = readJSON(path) as? [String: Any] ?? [:]
    if user, let u = readJSON(userDir() + "/config.json") as? [String: Any] {
        for (k, v) in u where cfg[k] != nil { cfg[k] = v }
    }
    return cfg
}

/// Write knobs to the user's overrides (userDir()/config.json), keeping the others there.
func saveUserConfig(_ updates: [String: Any]) throws {
    let path = userDir() + "/config.json"
    var d = readJSON(path) as? [String: Any] ?? [:]
    for (k, v) in updates { d[k] = v }
    try writeJSONFile(path, d)
}

/// The output cap for `words` suggested words: the unfinished word's rest + the words, ~1.2 tokens per word (5 -> 6).
func tokensForWords(_ w: Int) -> Int { w + (w + 4) / 5 }

/// str(x) for a knob value in a prompt.
func pyStr(_ v: Any?) -> String {
    if let i = intValue(v) { return String(i) }
    if let d = num(v) { return pyFloatRepr(d) }
    if isBool(v) { return (v as! NSNumber).boolValue ? "True" : "False" }
    return v.map { "\($0)" } ?? "None"
}

/// The keys of a JSON file's top-level object in file order (Python dicts keep it; JSONSerialization does not).
func topLevelKeys(_ path: String) -> [String] {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
    var keys: [String] = [], depth = 0, inString = false, escape = false, cur = "", expectKey = false
    for ch in text {
        if inString {
            if escape { escape = false; if depth == 1 && expectKey { cur.append(ch) }; continue }
            if ch == "\\" { escape = true; if depth == 1 && expectKey { cur.append(ch) }; continue }
            if ch == "\"" {
                inString = false
                if depth == 1 && expectKey { keys.append((jsonObject(Data("\"\(cur)\"".utf8)) as? String) ?? cur); expectKey = false }
                continue
            }
            if depth == 1 && expectKey { cur.append(ch) }
            continue
        }
        switch ch {
        case "\"": inString = true; cur = ""
        case "{", "[": depth += 1; if depth == 1 { expectKey = true }
        case "}", "]": depth -= 1
        case ",": if depth == 1 { expectKey = true }
        case ":": if depth == 1 { expectKey = false }
        default: break
        }
    }
    return keys
}

struct PolicyError: Error, CustomStringConvertible {
    let kind: String, message: String
    var description: String { "\(kind): \(message)" }
}

/// The policy. `overrides` change config.json for this instance; per-request `opts` change it for one request.
/// `user: false` ignores the user's config overrides and prompts (benchmarks run on the shipped ones).
final class Ghost {
    private var _cfg: [String: Any] = [:]
    private let cfgLock = NSLock()
    /// The knobs in use (POST /settings changes them while requests read them).
    var cfg: [String: Any] {
        get { cfgLock.lock(); defer { cfgLock.unlock() }; return _cfg }
        set { cfgLock.lock(); _cfg = newValue; cfgLock.unlock() }
    }
    let prompt: [String: Any]
    let styles: [String: [String: Any]]
    let styleOrder: [String]
    let user: UserPrompts
    var registered = Set<String>()
    var pinned: String?                                      // the profile predictd keeps warm for us
    let lock = NSLock()

    init(overrides: [String: Any] = [:], user: Bool) {
        let here = ROOT + "/ghost"
        var c = loadConfig(here + "/config.json", user: user)
        for (k, v) in overrides { c[k] = v }
        _cfg = c
        prompt = readJSON(here + "/prompt.json") as? [String: Any] ?? [:]
        let st = readJSON(here + "/styles.json") as? [String: Any] ?? [:]
        styleOrder = topLevelKeys(here + "/styles.json").filter { !$0.hasPrefix("_") && st[$0] != nil }
        styles = st.filter { !$0.key.hasPrefix("_") }.compactMapValues { $0 as? [String: Any] }
        let path = (c["userPrompts"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (userDir() + "/prompts.json")
        self.user = UserPrompts(user ? (path as NSString).expandingTildeInPath : nil)
    }

    func config(_ opts: [String: Any]?) -> [String: Any] {
        var c = cfg
        for (k, v) in opts ?? [:] { c[k] = v }
        return c
    }

    func template(_ app: String, _ text: String) -> String {
        let t = prompt["template"] as? String ?? "App: {app}\nText: {text}"
        return t.replacingOccurrences(of: "{app}", with: app).replacingOccurrences(of: "{text}", with: text)
    }

    // -- writing styles: general is prompt.json (with its research knobs), the others are styles.json

    func styleNames() -> [String] { ["general"] + styleOrder }
    func styleTitle(_ s: String) -> String { s == "general" ? "General" : styles[s]?["title"] as? String ?? s }
    func styleLabel(_ s: String) -> String { s == "general" ? "notes" : styles[s]?["label"] as? String ?? s }

    /// The instructions prompt.json gives this configuration (`{words}` not yet filled in).
    func defaultInstructions(_ cfg: [String: Any]) -> String {
        let p = prompt
        if cfg["format"] as? String == "fullword" { return p["instructions_fullword"] as? String ?? "" }
        return (cfg["instructions"] as? String == "short" ? p["instructions_short"] : p["instructions"]) as? String ?? ""
    }

    /// True when the style has no examples of its own and uses general's whole prompt.
    func inherits(_ style: String) -> Bool { style != "general" && styles[style]?["shots"] == nil }

    /// The shipped prompt of a style: {"instructions", "examples": [{"text", "completion", "app"?}]}. A style without its own
    /// prompt defaults to general's prompt in use (the user's version, if any).
    func defaultPrompt(_ style: String = "general", _ cfg: [String: Any]? = nil) -> [String: Any] {
        let cfg = cfg ?? self.cfg
        if inherits(style) { return promptFor("general", cfg) }
        if style == "general" {
            let shots = prompt["shots"] as? [[String: Any]] ?? []
            let n = intValue(cfg["shots"]) ?? 6
            return ["instructions": defaultInstructions(cfg),
                    "examples": shots.prefix(max(0, n)).map { ["text": $0["text"] ?? "", "completion": $0["completion"] ?? "", "app": $0["app"] ?? ""] }]
        }
        let st = styles[style] ?? [:]
        let examples: [[String: Any]] = (st["shots"] as? [[String: Any]] ?? []).map { s in
            var e: [String: Any] = [:]
            for k in ["text", "completion", "app"] where s[k] != nil { e[k] = s[k] }   // app: else the style's label
            return e
        }
        let ins = (st["instructions"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultInstructions(cfg)
        return ["instructions": ins, "examples": examples]
    }

    /// The prompt in use: the user's version (instructions, and examples if they changed them), else the shipped one.
    func promptFor(_ style: String = "general", _ cfg: [String: Any]? = nil) -> [String: Any] {
        let d = defaultPrompt(style, cfg)
        guard let u = user.get("predict-" + style) else { return d }
        return ["instructions": u["instructions"] ?? "", "examples": u["examples"] ?? d["examples"] ?? []]
    }

    /// The predictd profile for this configuration and style: instructions + examples. Its name is a hash of its content, so a
    /// request that changes the prompt (other `shots`, `instructions`, a user's edit, ...) gets its own profile instead of a stale one.
    func profile(_ cfg: [String: Any], _ style: String = "general", _ prompt: [String: Any]? = nil) -> [String: Any] {
        let full = cfg["format"] as? String == "fullword", structured = cfg["output"] as? String == "structured"
        let p = (prompt.map { $0.isEmpty ? nil : $0 } ?? nil) ?? promptFor(style, cfg)
        var examples: [[String: Any]] = []
        for s in p["examples"] as? [[String: Any]] ?? [] {
            let text = s["text"] as? String ?? ""
            var comp = s["completion"] as? String ?? ""
            if full, let last = text.unicodeScalars.last, !last.pySpace { comp = trailingPartial(text) + comp }
            let app = (s["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? styleLabel(style)
            examples.append(["prompt": template(app, text), "response": structured ? ["completion": comp] as Any : comp])
        }
        var d: [String: Any] = ["instructions": (p["instructions"] as? String ?? "").replacingOccurrences(of: "{words}", with: pyStr(cfg["words"])),
                                "examples": examples, "guardrails": cfg["guardrails"] ?? NSNull()]
        if structured { d["schema"] = STRUCTURED_SCHEMA }
        d["name"] = "ghost-" + sha1Hex(pyDumps(d)).prefix(8)
        return d
    }

    @discardableResult
    func ensureProfile(_ link: Link, _ cfg: [String: Any]? = nil, pin: Bool = false, force: Bool = false, style: String = "general",
                       prompt: [String: Any]? = nil) throws -> String {
        var prof = profile(cfg ?? self.cfg, style, prompt)
        let name = prof["name"] as! String
        lock.lock(); defer { lock.unlock() }
        // re-send when the pinned profile changes too (another style, a prompt edited and reset): profile.set of a known profile is free
        if force || !registered.contains(name) || (pin && pinned != name) {
            prof["op"] = "profile.set"
            prof["pin"] = pin
            let r = try link.call(prof)
            if !truthy(r["ok"]) { throw PolicyError(kind: "RuntimeError", message: "profile.set failed: \(r["error"] ?? "None")") }
            registered.insert(name)
            if pin { pinned = name }
        }
        return name
    }

    /// The user is about to type in this style (they switched apps): pin its profile and have predictd prewarm it now, so the
    /// first keystroke hits the cache (prewarming needs ~1 s of lead time).
    func warm(_ link: Link, _ style: String) throws -> [String: Any] {
        let name = try ensureProfile(link, pin: true, style: styles[style] != nil ? style : "general")
        let r = try link.call(["op": "prewarm", "profile": name])
        return ["ok": r["ok"] ?? false, "profile": name, "prewarmed": r["prewarmed"] ?? false]
    }

    struct Context {
        let cfg: [String: Any], app: String, text: String, tail: String, est: Double, trimmed: Bool, style: String
        let prompt: [String: Any]?, profile: String, trimMs: Double
    }

    /// The generate request for this text, and the context `finish` needs; (nil, ctx) when there is nothing to ask.
    /// `style`: a writing style (general = `app` is sent as is; others send their own label). `prompt`: try this prompt instead
    /// of the one in use (benchmarks).
    func request(_ app: String, _ text: String, _ opts: [String: Any]? = nil, style: String = "general", prompt: [String: Any]? = nil,
                 keepApp: Bool = false) -> ([String: Any]?, Context) {
        let t0 = now()
        let cfg = config(opts)
        let style = styles[style] != nil ? style : "general"
        let app = style != "general" && !keepApp ? styleLabel(style) : app   // benchmarks keep each case's own app label
        let (tail, est, trimmed) = trimTail(text, max(16, intValue(cfg["textBudget"]) ?? 100))
        let profileName = profile(cfg, style, prompt)["name"] as! String
        let ctx = Context(cfg: cfg, app: app, text: text, tail: tail, est: est, trimmed: trimmed, style: style, prompt: prompt,
                          profile: profileName, trimMs: perfMs(since: t0))
        if pyStrip(tail).isEmpty { return (nil, ctx) }
        var req: [String: Any] = ["op": "generate", "profile": profileName, "prompt": template(app, tail), "maxTokens": cfg["maxTokens"] ?? 6,
                                  "sampling": cfg["sampling"] ?? "greedy"]
        if cfg["sampling"] as? String != "greedy" {
            for k in ["topK", "topP", "temperature", "seed"] { req[k] = cfg[k] ?? NSNull() }
        }
        if cfg["output"] as? String == "structured" { req["schema"] = true }
        return (req, ctx)
    }

    /// Turn predictd's answer into the ghost. `spell(words, language) -> [Bool]` checks words (predictd's `spell` op).
    func finish(_ ctx: Context, _ resp: [String: Any], _ spell: @escaping ([String], String) throws -> [Bool]) throws -> [String: Any] {
        let cfg = ctx.cfg, text = ctx.text
        if !truthy(resp["ok"]) {
            if resp["error"] as? String == "guardrail" {         // a false positive even when permissive: just show nothing
                return ["id": resp["id"] ?? NSNull(), "ok": true, "suggestion": "", "suppressed": "guardrail", "partial": "",
                        "timing": ["total_ms": 0, "session": resp["state"] ?? NSNull()]]
            }
            return ["id": resp["id"] ?? NSNull(), "ok": false, "error": resp["error"] ?? NSNull()]
        }
        let t1 = now()
        let completion = (resp["text"] as? String) ?? ((resp["content"] as? [String: Any])?["completion"] as? String ?? "")
        let truncated = resp["finish"] as? String == "length"
        let lang = cfg["spellLanguage"] as? String ?? "en"
        let a = try assemble(text, completion, ctx.app, cfg, truncated, Speller({ try spell($0, lang) }, cfg))
        let asmMs = perfMs(since: t1)
        let t = resp["timing"] as? [String: Any] ?? [:], tok = resp["tokens"] as? [String: Any] ?? [:]
        var tokens = tok
        tokens["text_est"] = ctx.est
        tokens["budget"] = cfg["textBudget"] ?? NSNull()
        tokens["trimmed"] = ctx.trimmed
        tokens["text_chars_in"] = text.pyLen
        tokens["text_chars_used"] = ctx.tail.pyLen
        let daemonMs = num(t["total_ms"]) ?? 0
        return ["id": resp["id"] ?? NSNull(), "ok": true, "suggestion": a.shown, "raw_suggestion": a.raw, "model_completion": completion,
                "partial": a.partial, "first_word": a.firstWord, "sentence_end": a.sentenceEnd, "truncated": truncated,
                "dropped_partial": a.droppedPartial, "glued": a.glued, "respaced": a.respaced, "repeat_cut": a.repeatCut, "valid": a.valid,
                "suppressed": a.suppressed ?? NSNull(), "words": a.words, "misspelled": a.misspelled,
                "timing": ["trim_ms": ctx.trimMs, "wait_ms": t["wait_ms"] ?? 0, "model_ms": t["model_ms"] ?? 0, "assemble_ms": asmMs,
                           "daemon_ms": t["total_ms"] ?? 0, "total_ms": ctx.trimMs + daemonMs + asmMs, "session": resp["state"] ?? NSNull()],
                "tokens": tokens]
    }

    /// Blocking: one suggestion for `text`. Registers the profile when predictd does not know it (first use, or the daemon restarted).
    func predict(_ link: Link, _ app: String, _ text: String, _ opts: [String: Any]? = nil, stream: String? = nil, style: String = "general",
                 prompt: [String: Any]? = nil, keepApp: Bool = false) throws -> [String: Any] {
        let (r, ctx) = request(app, text, opts, style: style, prompt: prompt, keepApp: keepApp)
        guard var req = r else { return ["ok": true, "suggestion": "", "partial": "", "timing": ["total_ms": ctx.trimMs]] }
        if let stream, !stream.isEmpty { req["stream"] = stream }
        let pin = (opts ?? [:]).isEmpty && prompt == nil        // the prompt in use is pinned, per-request variants are not
        try ensureProfile(link, ctx.cfg, pin: pin, style: ctx.style, prompt: prompt)
        var resp = try link.call(req)
        if resp["error"] as? String == "unknown_profile" {
            lock.lock(); registered.remove(ctx.profile); lock.unlock()
            try ensureProfile(link, ctx.cfg, pin: pin, style: ctx.style, prompt: prompt)
            resp = try link.call(req)
        }
        return try finish(ctx, resp) { ws, lang in
            (try link.call(["op": "spell", "words": ws, "language": lang])["valid"] as? [Any] ?? []).map { truthy($0) }
        }
    }
}
