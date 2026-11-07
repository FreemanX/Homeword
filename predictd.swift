// predictd: a long-lived input-prediction service on top of Apple's on-device model (FoundationModels).
// Newline-delimited JSON over a unix socket. See README.md for the protocol and the pipeline.
import Foundation
import FoundationModels
import AppKit

let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: config

struct Config {
    var socketPath = "/tmp/predictd-\(getuid()).sock"
    var shots = 99, words = 5, maxTokens = 14, textBudget = 200, hardCap = 4000, margin = 60
    var settleMs = 800.0, keepAliveSec = 6.0, keepAliveMaxIdleSec = 300.0, idleExitSec = 0.0
    var waitSettle = false, includeSchema = false, exactTrim = false
    var oneSentence = true, instructionsVariant = "long", sessionMode = "reuse", guardrails = "permissive", invalidPolicy = "drop", format = "suffix", output = "schema"
    var lenientApps: Set<String> = ["terminal", "code"]

    mutating func apply(_ d: [String: Any]) {
        func i(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func f(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        func b(_ k: String) -> Bool? { d[k] as? Bool }
        func s(_ k: String) -> String? { d[k] as? String }
        shots = i("shots") ?? shots; words = i("words") ?? words; maxTokens = i("maxTokens") ?? maxTokens; textBudget = i("textBudget") ?? textBudget
        hardCap = i("hardCap") ?? hardCap; margin = i("margin") ?? margin
        settleMs = f("settleMs") ?? settleMs; keepAliveSec = f("keepAliveSec") ?? keepAliveSec
        keepAliveMaxIdleSec = f("keepAliveMaxIdleSec") ?? keepAliveMaxIdleSec; idleExitSec = f("idleExitSec") ?? idleExitSec
        waitSettle = b("waitSettle") ?? waitSettle; oneSentence = b("oneSentence") ?? oneSentence; instructionsVariant = s("instructions") ?? instructionsVariant; sessionMode = s("sessionMode") ?? sessionMode; includeSchema = b("includeSchema") ?? includeSchema; exactTrim = b("exactTrim") ?? exactTrim
        guardrails = s("guardrails") ?? guardrails; format = s("format") ?? format; output = s("output") ?? output; invalidPolicy = s("invalidPolicy") ?? invalidPolicy
        if let a = d["lenientApps"] as? [String] { lenientApps = Set(a) }
        socketPath = s("socketPath") ?? socketPath
    }
}

struct Shot { var app: String, text: String, completion: String }
struct Prompt { var instructions: String; var instructionsShort: String; var instructionsFullword: String; var shots: [Shot] }

func loadJSON(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}
func loadPrompt(_ path: String) -> Prompt {
    let o = loadJSON(path)
    let shots = (o["shots"] as? [[String: String]] ?? []).map { Shot(app: $0["app"] ?? "", text: $0["text"] ?? "", completion: $0["completion"] ?? "") }
    return Prompt(instructions: o["instructions"] as? String ?? "Predict how the text continues.", instructionsShort: o["instructions_short"] as? String ?? o["instructions"] as? String ?? "", instructionsFullword: o["instructions_fullword"] as? String ?? o["instructions"] as? String ?? "", shots: shots)
}

func userPrompt(_ app: String, _ text: String) -> String { "App: \(app)\nText: \(text)" }
func makeSchema() -> GenerationSchema {
    GenerationSchema(type: GeneratedContent.self, description: "Prediction", properties: [
        GenerationSchema.Property(name: "completion", description: "how the text continues", type: String.self)])
}

// MARK: text helpers (trim, token estimate, assemble)

func isCJK(_ u: Unicode.Scalar) -> Bool {
    (0x3040...0x30FF).contains(u.value) || (0x3400...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value)
}

/// Keep the tail of `text` that fits `budget` estimated tokens, cut on a word boundary.
/// chars/token measured on this model: prose 5.1, code 2.9, shell 2.6, Chinese 1.6.
func trimTail(_ text: String, budget: Int, charsPerToken override: Double? = nil) -> (String, Double, Bool) {
    let window = Array(text.suffix(max(budget, 1) * 8))
    let sym = window.filter { !$0.isLetter && !$0.isWhitespace }.count
    let ratio = override ?? (Double(sym) / Double(max(window.count, 1)) > 0.08 ? 2.9 : 4.8)
    var cost = 0.0, cut = window.count
    while cut > 0 {
        let ch = window[cut - 1]
        let c = ch.unicodeScalars.contains(where: isCJK) ? 1 / 1.6 : 1 / ratio
        if cost + c > Double(budget) { break }
        cost += c; cut -= 1
    }
    let whole = cut == 0 && window.count == text.count
    if !whole && cut < window.count {
        // do not start mid-word
        while cut < window.count && !window[cut - 1].isWhitespace && !window[cut].isWhitespace { cut += 1 }
        if cut < window.count && window[cut - 1].isWhitespace == false { cut += 1 }
    }
    let out = String(window[cut...])
    return (out, cost, !whole)
}

struct Assembly {
    var shown = "", raw = "", partial = "", firstWord = ""
    var droppedPartial = false, sentenceEnd = false, glued = false, respaced = false, valid = true, suppressed: String? = nil
    var words = 0, misspelled = 0
}

@MainActor func checkWord(_ w: String) -> Bool {
    guard !w.isEmpty, w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }), !w.unicodeScalars.contains(where: isCJK) else { return true }
    func ok(_ x: String) -> Bool { NSSpellChecker.shared.checkSpelling(of: x, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
    // "friday" is only a word as "Friday"; but don't accept every name ("justine" is not "just in"), only days and months
    let capitalOK: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
                                  "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    return ok(w) || (capitalOK.contains(w.lowercased()) && ok(w.capitalized))
}


/// Whether the last response in the transcript stopped at maximumResponseTokens. The finish reason is not public API, but it is
/// a stored property of the transcript entry, so reflection can read it (Transcript.Response.finishReason, macOS 27).
func hitTokenCap(_ t: Transcript) -> Bool {
    guard let last = t.last else { return false }
    func walk(_ x: Any, _ depth: Int) -> Bool {
        if depth > 4 { return false }
        for c in Mirror(reflecting: x).children {
            if c.label == "finishReason" { return String(describing: c.value).contains("maximumResponseTokens") }
            if walk(c.value, depth + 1) { return true }
        }
        return false
    }
    return walk(last, 0)
}

/// Index just after the end of the first sentence in `s` (a . ! ? … followed by whitespace or the end, not an abbreviation or initial), or nil.
func sentenceEnd(_ s: String) -> String.Index? {
    let abbr: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "etc", "e.g", "i.e", "st", "no", "inc", "jr", "sr", "approx", "fig"]
    var i = s.startIndex
    while i < s.endIndex {
        let ch = s[i]
        if "。！？".contains(ch) {
            var j = s.index(after: i); while j < s.endIndex, "」』）”".contains(s[j]) { j = s.index(after: j) }
            return j
        }
        if ".!?…".contains(ch) {
            var j = s.index(after: i)
            while j < s.endIndex, ".!?…".contains(s[j]) { j = s.index(after: j) }          // "?!" "..."
            var k = j; while k < s.endIndex, "\"')]”’".contains(s[k]) { k = s.index(after: k) }  // closing quote or bracket
            if k == s.endIndex || s[k].isWhitespace {
                if ch == "." {
                    let before = s[s.startIndex..<i].reversed().prefix(while: { !$0.isWhitespace })
                    let tok = String(before.reversed()).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'([“"))
                    if abbr.contains(tok) || (tok.count == 1 && tok.first!.isLetter) || (!tok.isEmpty && tok.allSatisfy({ $0.isNumber })) { i = j; continue }
                }
                return k
            }
            i = j; continue
        }
        i = s.index(after: i)
    }
    return nil
}

@MainActor func assemble(text: String, completion: String, app: String, cfg: Config, truncated: Bool = false) -> Assembly {
    var a = Assembly()
    var comp = completion.replacingOccurrences(of: "\n", with: " ")
    let partial = String(String(text.reversed().prefix(while: { ($0.isLetter && !$0.unicodeScalars.contains(where: isCJK)) || $0 == "'" || $0 == "’" })).reversed())
    a.partial = partial
    if cfg.format == "fullword", !partial.isEmpty {   // the model re-wrote the last word in full: cut the typed part off
        comp = String(comp.drop(while: { $0.isWhitespace }))
        guard comp.lowercased().hasPrefix(partial.lowercased()) else { a.suppressed = "prefix_mismatch"; a.valid = false; return a }
        comp = String(comp.dropFirst(partial.count))
    }
    if let last = text.last, last.isWhitespace {
        comp = String(comp.drop(while: { $0.isWhitespace }))
    } else if partial.isEmpty, let f = comp.first, !f.isWhitespace, let last = text.last, ",.;:!?)".contains(last) {
        comp = " " + comp
    } else if !partial.isEmpty, let f = comp.first, !f.isWhitespace {
        a.glued = true
    }
    // cut by the token cap: the last word may be unfinished ("for so" of "for some"), drop it unless it is the only one
    if truncated {
        let trimmed = comp.trimmingCharacters(in: .whitespaces)
        if let sp = trimmed.lastIndex(where: { $0.isWhitespace }) {
            let lead = comp.prefix(while: { $0.isWhitespace })
            comp = String(lead) + String(trimmed[trimmed.startIndex..<sp])
            a.droppedPartial = true
        }
    }
    // one sentence only: stop at the first sentence end (not for shell lines or code, where . ! ? are syntax)
    if cfg.oneSentence && !cfg.lenientApps.contains(app), let e = sentenceEnd(comp) {
        comp = String(comp[comp.startIndex..<e]); a.sentenceEnd = true
    }
    // cap the number of words: the unfinished word counts as one, then `words` more
    let limit = cfg.words + (a.glued ? 1 : 0)
    var count = 0, end = comp.startIndex, i = comp.startIndex, inWord = false
    while i < comp.endIndex {
        let ch = comp[i]
        if ch.isWhitespace { if inWord { count += 1; end = i; inWord = false; if count == limit { break } } }
        else { inWord = true }
        i = comp.index(after: i)
    }
    if inWord && count < limit { count += 1; end = comp.endIndex }
    comp = String(comp[comp.startIndex..<end])
    while let l = comp.last, l.isWhitespace { comp.removeLast() }
    a.raw = comp; a.words = count
    if a.glued {
        let piece = comp.prefix(while: { !$0.isWhitespace })
        let strip = CharacterSet(charactersIn: ",.;:!?\"')]}")
        let core = String(partial + piece).trimmingCharacters(in: strip)
        a.firstWord = core
        a.valid = checkWord(core)
        // The model cannot reliably write the leading space after a word that is already finished ("git" + "commit -m",
        // "with the" + "project"), so decide here whether the piece is the end of the typed word or a new word:
        //  - it starts with something that cannot continue a word (a flag, path, operator, an opening quote): new word
        //  - the glued word is not a word but the piece alone is (3+ letters): new word
        let attach: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "'", "’"]
        let f = piece.first!
        var separate = false
        if !f.isLetter && !f.isNumber && !attach.contains(f) {
            separate = f == "\"" ? text.filter({ $0 == "\"" }).count % 2 == 0 : true   // a quote closes a word only inside an open quote
        }
        let word = String(piece).trimmingCharacters(in: strip)
        // a capital right after lowercase letters is a new sentence/word in prose ("out" + "I would"), camelCase only in code
        if !separate && f.isUppercase && (partial.last?.isLowercase ?? false) && !cfg.lenientApps.contains(app) { separate = true }
        let short = word.count < 3   // "to", "a", "I": only when the typed part is itself a finished word ("have" + "to")
        if !separate && !a.valid && !word.isEmpty && word.allSatisfy({ $0.isLetter }) && checkWord(word)
            && checkWord(partial)   // an unfinished typed word ("fri") must not be split off from the model's next word
            && (!short || word.count == 2 || ["a", "i"].contains(word.lowercased())) { separate = true }
        if separate {
            a.glued = false; a.valid = true; a.respaced = true; comp = " " + comp; a.firstWord = String(piece)
        }
    } else {
        a.firstWord = String(comp.drop(while: { $0.isWhitespace }).prefix(while: { !$0.isWhitespace }))
    }
    let all = (partial + comp).split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'()[]{}")) }
    a.misspelled = all.filter { !checkWord($0) }.count
    a.shown = comp
    if a.glued && !a.valid && cfg.invalidPolicy == "drop" && !cfg.lenientApps.contains(app) { a.shown = ""; a.suppressed = "invalid_word" }
    return a
}

// MARK: connection + engine

final class Conn: @unchecked Sendable {
    let fd: Int32; let lock = NSLock()
    init(_ fd: Int32) { self.fd = fd }
    func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(10)
        lock.lock(); defer { lock.unlock() }
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count { let n = write(fd, p.baseAddress! + off, d.count - off); if n <= 0 { return }; off += n }
        }
    }
}

struct Stats { var reused = 0, guardrail = 0, requests = 0, cold = 0, settling = 0, ready = 0, cancelled = 0, errors = 0, keepAlives = 0 }

actor Engine {
    var cfg: Config; var prompt: Prompt; var model: SystemLanguageModel
    let schema = makeSchema()
    var spare: (s: LanguageModelSession, at: ContinuousClock.Instant)?
    var lastActivity = clock.now
    var stats = Stats(); var prefixTokens = 0; var busy = 0
    var generating = false
    var pendingTakeover = 0
    var sessionOf: [String: LanguageModelSession] = [:]
    var main: LanguageModelSession? = nil
    var mainBase: Transcript? = nil
    var mainUsedAt = clock.now
    var inflight: [String: (id: String, task: Task<[String: Any], Never>)] = [:]
    var pending: [String: (req: [String: Any], conn: Conn)] = [:]
    let started = clock.now
    let configPath: String, promptPath: String

    init(cfg: Config, prompt: Prompt, configPath: String, promptPath: String) {
        self.cfg = cfg; self.prompt = prompt; self.configPath = configPath; self.promptPath = promptPath
        self.model = Engine.makeModel(cfg)
    }
    static func makeModel(_ c: Config) -> SystemLanguageModel {
        c.guardrails == "permissive" ? SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
    }

    // -- step 0: sessions. A session carries instructions + few-shot turns; prewarm() caches that prefix inside it.
    func makeTranscript() -> Transcript {
        let full = cfg.format == "fullword"
        let ins = (full ? prompt.instructionsFullword : cfg.instructionsVariant == "short" ? prompt.instructionsShort : prompt.instructions).replacingOccurrences(of: "{words}", with: String(cfg.words))
        var e: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: ins))], toolDefinitions: []))]
        for var s in prompt.shots.prefix(cfg.shots) {
            if full, let last = s.text.last, !last.isWhitespace {   // fullword format: the answer re-writes the last word, completed
                let partial = String(String(s.text.reversed().prefix(while: { $0.isLetter || $0 == "'" })).reversed())
                if !partial.isEmpty { s.completion = partial + s.completion }
            }
            if cfg.output == "plain" {   // unstructured: the answer is just the text
                e.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: userPrompt(s.app, s.text)))])))
                e.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: s.completion))])))
                continue
            }
            e.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: userPrompt(s.app, s.text)))], responseFormat: Transcript.ResponseFormat(schema: schema))))
            e.append(.response(Transcript.Response(assetIDs: [], segments: [.structure(Transcript.StructuredSegment(schemaName: "Prediction", content: GeneratedContent(properties: ["completion": s.completion])))])))
        }
        return Transcript(entries: e)
    }
    func newSession() -> LanguageModelSession { LanguageModelSession(model: model, transcript: makeTranscript()) }
    /// Prewarm a fresh spare unless another request is generating. `after` = generations of the caller still counted in `busy`.
    func refillIfIdle(after: Int = 1) { if busy <= after && pendingTakeover == 0 { refillSpare() } else { spare = nil } }
    func refillSpare() { let s = newSession(); s.prewarm(); spare = (s, clock.now) }

    func startup() async {
        log("availability: \(model.availability)")
        let s = newSession(); s.prewarm()
        let o = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cfg.maxTokens)
        var probeIn = 0
        if cfg.output == "plain" { probeIn = (try? await s.respond(to: userPrompt("mail", "Hello"), options: o))?.usage.input.totalTokenCount ?? 0 }
        else { probeIn = (try? await s.respond(to: userPrompt("mail", "Hello"), schema: schema, includeSchemaInPrompt: false, options: o))?.usage.input.totalTokenCount ?? 0 }
        prefixTokens = max(0, probeIn - 12)
        log("prefix (instructions + \(prompt.shots.count) shots) ≈ \(prefixTokens) tokens")
        if cfg.sessionMode == "reuse" && cfg.output == "plain" { let m = newSession(); main = m; mainBase = m.transcript; m.prewarm(); mainUsedAt = clock.now }
        else { refillSpare() }
        Task { await self.keepAliveLoop() }
    }

    func keepAliveLoop() async {
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            let idle = ms(clock.now - lastActivity) / 1000
            if cfg.idleExitSec > 0 && idle > cfg.idleExitSec && busy == 0 { log("idle for \(Int(idle)) s, exiting"); unlink(cfg.socketPath); exit(0) }
            guard cfg.keepAliveSec > 0 else { continue }
            if idle > cfg.keepAliveMaxIdleSec { continue }
            // never prewarm while a request is generating: the two would compete for the GPU
            if cfg.sessionMode == "reuse" && cfg.output == "plain" {
                if busy == 0 && pendingTakeover == 0, let m = main, ms(clock.now - mainUsedAt) / 1000 >= cfg.keepAliveSec {
                    if let b = mainBase { m.transcript = b }
                    m.prewarm(); mainUsedAt = clock.now; stats.keepAlives += 1
                }
                continue
            }
            if busy == 0 && pendingTakeover == 0 && (spare == nil || ms(clock.now - spare!.at) / 1000 >= cfg.keepAliveSec) { refillSpare(); stats.keepAlives += 1 }
        }
    }

    // -- the pipeline
    func predict(_ req: [String: Any], reuse: LanguageModelSession? = nil) async -> [String: Any] {
        let t0 = clock.now
        var c = cfg; c.apply(req["opts"] as? [String: Any] ?? [:])
        let app = req["app"] as? String ?? "", text = req["text"] as? String ?? ""
        stats.requests += 1; lastActivity = t0
        busy += 1; defer { busy -= 1 }
        var resp: [String: Any] = ["id": req["id"] ?? "", "ok": true]

        // 1. trim: keep the tail that fits the text budget (never above hardCap minus prefix, template, output cap, margin)
        let budget = max(16, min(c.textBudget, c.hardCap - prefixTokens - 25 - c.maxTokens - c.margin))
        var (tail, est, trimmed) = trimTail(text, budget: budget)
        var exactTok = -1, exactCalls = 0
        if c.exactTrim {   // refine with the real tokenizer (about 25 ms per call), only ever shrinks the tail
            var b = budget
            while exactCalls < 3, let n = try? await model.tokenCount(for: tail) {
                exactTok = n; exactCalls += 1
                if n <= budget { break }
                b = Int(Double(b) * Double(budget) / Double(n) * 0.97)
                (tail, est, trimmed) = trimTail(text, budget: b)
            }
        }
        let tTrim = ms(clock.now - t0)
        if tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { resp["suggestion"] = ""; resp["timing"] = ["total_ms": ms(clock.now - t0)]; return resp }

        // 2. session: take the prewarmed spare (or build one cold)
        let t1 = clock.now
        var state = "cold", age = -1.0, settleWait = 0.0
        let session: LanguageModelSession
        if c.sessionMode == "reuse" && c.output == "plain" {
            // one session for everything: the model has a single prefix cache, and the session that generated last owns it.
            // Its transcript is restored after each answer, so the next request matches the cache: instructions, examples
            // and, while typing, most of the previous request's text too.
            if main == nil { let m = newSession(); main = m; mainBase = m.transcript; m.prewarm(); state = "cold"; stats.cold += 1 }
            else { state = ms(t1 - mainUsedAt) > 5500 ? "expired" : "reused"; stats.reused += 1 }
            session = main!
        } else if let r = reuse {
            // the session of the request this one cancelled: its transcript is unchanged and it owns the prefix cache
            session = r; state = "reused"; stats.reused += 1
        } else if let sp = spare {
            spare = nil; age = ms(t1 - sp.at); session = sp.s
            if age >= c.settleMs { state = "ready"; stats.ready += 1 }
            else {
                state = "settling"; stats.settling += 1
                if c.waitSettle { settleWait = c.settleMs - age; try? await Task.sleep(for: .milliseconds(settleWait)); state = "settled_wait" }
            }
        } else { session = newSession(); session.prewarm(); stats.cold += 1 }
        let tAcq = ms(clock.now - t1)
        if let rid = req["id"] as? String { sessionOf[rid] = session }
        defer { if let rid = req["id"] as? String { sessionOf[rid] = nil } }

        // 3. model: guided generation with the schema as the only format control
        let t2 = clock.now
        var completion = "", truncated = false
        var tokIn = 0, tokCached = 0, tokOut = 0
        do {
            let go = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: c.maxTokens)
            if c.output == "plain" {
                let r = try await session.respond(to: userPrompt(app, tail), options: go)
                completion = r.content
                truncated = hitTokenCap(session.transcript)
                tokIn = r.usage.input.totalTokenCount; tokCached = r.usage.input.cachedTokenCount; tokOut = r.usage.output.totalTokenCount
            } else {
                let r = try await session.respond(to: userPrompt(app, tail), schema: schema, includeSchemaInPrompt: c.includeSchema, options: go)
                completion = (try? r.content.value(String.self, forProperty: "completion")) ?? ""
                tokIn = r.usage.input.totalTokenCount; tokCached = r.usage.input.cachedTokenCount; tokOut = r.usage.output.totalTokenCount
            }
        } catch {
            if c.sessionMode == "reuse", session === main, let b = mainBase { session.transcript = b; mainUsedAt = clock.now }
            if Task.isCancelled || error is CancellationError { stats.cancelled += 1; return ["id": req["id"] ?? "", "ok": false, "error": "cancelled", "session": session] }
            refillIfIdle()
            let msg = "\(error)"
            if msg.contains("sensitive or unsafe") || msg.lowercased().contains("guardrail") {   // false positive even when permissive: just show nothing
                stats.guardrail += 1
                resp["suggestion"] = ""; resp["suppressed"] = "guardrail"; resp["partial"] = ""; resp["timing"] = ["total_ms": ms(clock.now - t0), "model_ms": ms(clock.now - t2), "session": state]
                return resp
            }
            stats.errors += 1
            return ["id": req["id"] ?? "", "ok": false, "error": msg.prefix(200).description]
        }
        let tModel = ms(clock.now - t2)
        if c.sessionMode == "reuse", session === main, let b = mainBase { session.transcript = b; mainUsedAt = clock.now }

        // 4. assemble: glue the unfinished word, validate it, cap the word count
        let t3 = clock.now
        let (cmp, cc) = (completion, c)
        let tr = truncated
        let a = await MainActor.run { assemble(text: text, completion: cmp, app: app, cfg: cc, truncated: tr) }
        let tAsm = ms(clock.now - t3)

        // 5. next spare. The model keeps one prefix cache, owned by whichever session prewarmed or generated last, so this
        // generation has evicted any existing spare: always prewarm a new one, but only when nothing else is generating
        // (a prewarm during a generation would evict that generation's cache). The used session's transcript has grown,
        // so it is not reused.
        lastActivity = clock.now
        if !(c.sessionMode == "reuse" && c.output == "plain") { refillIfIdle(after: 1) }

        resp["suggestion"] = a.shown; resp["raw_suggestion"] = a.raw; resp["model_completion"] = completion
        resp["partial"] = a.partial; resp["first_word"] = a.firstWord; resp["sentence_end"] = a.sentenceEnd; resp["truncated"] = truncated; resp["dropped_partial"] = a.droppedPartial; resp["glued"] = a.glued; resp["respaced"] = a.respaced; resp["valid"] = a.valid
        resp["suppressed"] = a.suppressed ?? NSNull(); resp["words"] = a.words; resp["misspelled"] = a.misspelled
        resp["timing"] = ["total_ms": ms(clock.now - t0), "trim_ms": tTrim, "acquire_ms": tAcq, "settle_wait_ms": settleWait,
                          "model_ms": tModel, "assemble_ms": tAsm, "spare_age_ms": age, "session": state]
        resp["tokens"] = ["in": tokIn, "cached": tokCached, "out": tokOut, "text_est": est, "text_exact": exactTok,
                          "budget": budget, "trimmed": trimmed, "text_chars_in": text.count, "text_chars_used": tail.count]
        return resp
    }

    func settleProbe() async -> [String: Any] {
        var rows: [[String: Any]] = []
        let sample = userPrompt("mail", "Please make sure that the final document incl")
        for age in [-1, 0, 100, 200, 400, 800, 1500] {
            try? await Task.sleep(for: .milliseconds(1500))
            let s = newSession()
            if age >= 0 { s.prewarm(); try? await Task.sleep(for: .milliseconds(age)) }
            let t = clock.now
            let r = try? await s.respond(to: sample, schema: schema, includeSchemaInPrompt: false, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cfg.maxTokens))
            rows.append(["wait_after_prewarm_ms": age, "model_ms": ms(clock.now - t), "cached": r?.usage.input.cachedTokenCount ?? -1, "in": r?.usage.input.totalTokenCount ?? -1])
        }
        return ["ok": true, "rows": rows]
    }

    // -- protocol
    func handle(_ conn: Conn, _ req: [String: Any]) {
        let id = req["id"] as? String ?? String(describing: req["id"] ?? "")
        switch req["op"] as? String ?? "predict" {
        case "ping": conn.send(["id": id, "ok": true, "pong": true])
        case "stats":
            var o: [String: Any] = ["id": id, "ok": true, "uptime_s": ms(clock.now - started) / 1000, "prefix_tokens": prefixTokens,
                "requests": stats.requests, "cold": stats.cold, "settling": stats.settling, "ready": stats.ready,
                "reused": stats.reused, "cancelled": stats.cancelled, "errors": stats.errors, "keepalives": stats.keepAlives, "guardrail": stats.guardrail]
            o["config"] = ["words": cfg.words, "maxTokens": cfg.maxTokens, "textBudget": cfg.textBudget, "settleMs": cfg.settleMs,
                           "waitSettle": cfg.waitSettle, "keepAliveSec": cfg.keepAliveSec, "guardrails": cfg.guardrails, "exactTrim": cfg.exactTrim]
            conn.send(o)
        case "reload":
            var c = Config(); c.apply(loadJSON(configPath)); c.socketPath = cfg.socketPath
            c.apply(req["config"] as? [String: Any] ?? [:]); c.socketPath = cfg.socketPath
            cfg = c; prompt = loadPrompt(promptPath); model = Engine.makeModel(c); main = nil; mainBase = nil; refillSpare()
            conn.send(["id": id, "ok": true, "reloaded": true])
        case "shutdown": conn.send(["id": id, "ok": true]); exit(0)
        case "settle_probe": Task { var r = await self.settleProbe(); r["id"] = id; conn.send(r) }
        case "cancel":
            if let k = pending.first(where: { $0.value.req["id"] as? String == req["target"] as? String })?.key { pending[k] = nil }
            conn.send(["id": id, "ok": true])
        default:
            // single flight: the model runs one generation at a time. A request that arrives meanwhile waits as the
            // newest one of its stream (an older waiting one is dropped as superseded); aborting a running generation
            // does not free the GPU in time and loses the prefix cache of the next session (measured).
            let stream = cfg.sessionMode == "reuse" ? "main" : req["stream"] as? String ?? "conn\(conn.fd)"
            if cfg.output == "plain" {
                let prev = inflight[stream]
                prev?.task.cancel()
                if prev != nil { pendingTakeover += 1 }
                let t = Task {
                    var reuse: LanguageModelSession? = nil
                    if let p = prev {
                        // wait for the cancelled request to unwind (about 0-5 ms), then take over its session
                        if let r = await p.task.value as [String: Any]?, let s = r["session"] as? LanguageModelSession { reuse = s }
                        self.takeoverDone()
                    }
                    let r = await self.predict(req, reuse: reuse)
                    var out = r; out["session"] = nil
                    conn.send(out)
                    self.clearInflight(stream, id)
                    return r                      // keeps "session" for a request that takes over after a cancel
                }
                inflight[stream] = (id, t)
                return
            }
            if generating {
                if let old = pending[stream] { stats.cancelled += 1; old.conn.send(["id": old.req["id"] ?? "", "ok": false, "error": "cancelled"]) }
                pending[stream] = (req, conn)
            } else { runPredict(req, conn) }
        }
    }
    func takeoverDone() { pendingTakeover -= 1 }
    func clearInflight(_ stream: String, _ id: String) { if inflight[stream]?.id == id { inflight[stream] = nil } }
    func runPredict(_ req: [String: Any], _ conn: Conn) {
        generating = true
        Task {
            let r = await self.predict(req)
            conn.send(r)
            self.generationDone()
        }
    }
    func generationDone() {
        generating = false
        if let k = pending.keys.first, let next = pending.removeValue(forKey: k) { runPredict(next.req, next.conn) }
    }
}

// MARK: socket server

func serve(path: String, engine: Engine) {
    signal(SIGPIPE, SIG_IGN)
    // one daemon per socket: if a live one answers on it, leave it alone (unlinking its socket would orphan it)
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    var paddr = sockaddr_un(); paddr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &paddr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
    let alive = withUnsafePointer(to: &paddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    close(probe)
    if alive { log("another predictd is already serving \(path), exiting"); exit(0) }
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard rc == 0, listen(fd, 16) == 0 else { log("bind/listen failed on \(path): errno \(errno)"); exit(2) }
    chmod(path, 0o600)
    var st = stat(); stat(path, &st); let myInode = st.st_ino
    Thread {   // exit if the socket is removed or replaced: nobody can reach this daemon any more
        while true {
            sleep(2)
            var now = stat()
            if stat(path, &now) != 0 || now.st_ino != myInode { log("socket \(path) is gone, exiting"); exit(0) }
        }
    }.start()
    Thread {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { continue }
            let conn = Conn(cfd)
            Thread {
                var buf = Data(); var chunk = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(cfd, &chunk, chunk.count)
                    if n <= 0 { close(cfd); return }
                    buf.append(chunk, count: n)
                    while let nl = buf.firstIndex(of: 10) {
                        let line = buf[buf.startIndex..<nl]; buf = Data(buf[(nl + 1)...])
                        if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { Task { await engine.handle(conn, o) } }
                    }
                }
            }.start()
        }
    }.start()
}

@main struct Predictd {
    static func main() async {
        var configPath = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("config.json").path } ?? "config.json"
        var promptPath = URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("prompt.json").path
        var socket: String? = nil
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--config": configPath = args.removeFirst()
            case "--prompt": promptPath = args.removeFirst()
            case "--socket": socket = args.removeFirst()
            case "--version": print("predictd 0.1"); return
            default: log("unknown argument \(a)"); exit(1)
            }
        }
        var cfg = Config(); cfg.apply(loadJSON(configPath)); if let s = socket { cfg.socketPath = s }
        let engine = Engine(cfg: cfg, prompt: loadPrompt(promptPath), configPath: configPath, promptPath: promptPath)
        await engine.startup()
        serve(path: cfg.socketPath, engine: engine)
        log("ready on \(cfg.socketPath)")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }
}
