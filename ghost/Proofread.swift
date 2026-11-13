// The proofreading policy: fix typos and grammar in a selected text, or rewrite it more clearly, keeping its meaning and intent.
//
// Like the typing policy it is a client of predictd: one profile per mode (instructions + examples from proofread.json, not
// pinned: proofreading is occasional, the typing profile keeps the warm cache), one `generate` per paragraph. The answer comes with
// a word-level diff for display.
import Foundation

let PREAMBLE = try! NSRegularExpression(pattern: #"^\s*(here(?:'s| is) (?:the |your )?(?:corrected|revised|rewritten|improved|proofread)[^:\n]*:|(?:corrected|revised|rewritten) (?:text|version)\s*:)\s*"#,
                                        options: [.caseInsensitive])

func estTokens(_ text: String) -> Double { Double(text.pyLen) / 3.6 + 4 }

/// re.findall(r"\s+|\w+|[^\w\s]", s): runs of whitespace, runs of word characters, single other characters.
func diffTokens(_ s: String, keepSpace: Bool = true) -> [Scalars] {
    let a = s.sc
    var out: [Scalars] = [], i = 0
    while i < a.count {
        let j0 = i
        if a[i].pySpace {
            while i < a.count && a[i].pySpace { i += 1 }
            if keepSpace { out.append(Array(a[j0..<i])) }
        } else if a[i].pyWord {
            while i < a.count && a[i].pyWord { i += 1 }
            out.append(Array(a[j0..<i]))
        } else {
            i += 1
            out.append([a[j0]])
        }
    }
    return out
}

/// difflib.SequenceMatcher(a=, b=, autojunk=False): matching blocks, opcodes and ratio, the same algorithm.
struct SequenceMatcher<T: Hashable> {
    let a: [T], b: [T]
    private var b2j: [T: [Int]] = [:]

    init(_ a: [T], _ b: [T]) {
        self.a = a
        self.b = b
        for (i, e) in b.enumerated() { b2j[e, default: []].append(i) }
    }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
            }
            j2len = newj2len
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] { besti -= 1; bestj -= 1; bestsize += 1 }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] { bestsize += 1 }
        return (besti, bestj, bestsize)
    }

    func matchingBlocks() -> [(Int, Int, Int)] {
        var queue = [(0, a.count, 0, b.count)], blocks: [(Int, Int, Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let x = findLongestMatch(alo, ahi, blo, bhi)
            let (i, j, k) = x
            if k > 0 {
                blocks.append(x)
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        blocks.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2) }
        var (i1, j1, k1) = (0, 0, 0), out: [(Int, Int, Int)] = []
        for (i2, j2, k2) in blocks {
            if i1 + k1 == i2 && j1 + k1 == j2 { k1 += k2 }
            else {
                if k1 > 0 { out.append((i1, j1, k1)) }
                (i1, j1, k1) = (i2, j2, k2)
            }
        }
        if k1 > 0 { out.append((i1, j1, k1)) }
        out.append((a.count, b.count, 0))
        return out
    }

    func opcodes() -> [(String, Int, Int, Int, Int)] {
        var i = 0, j = 0, out: [(String, Int, Int, Int, Int)] = []
        for (ai, bj, size) in matchingBlocks() {
            var tag = ""
            if i < ai && j < bj { tag = "replace" } else if i < ai { tag = "delete" } else if j < bj { tag = "insert" }
            if !tag.isEmpty { out.append((tag, i, ai, j, bj)) }
            i = ai + size
            j = bj + size
            if size > 0 { out.append(("equal", ai, i, bj, j)) }
        }
        return out
    }

    func ratio() -> Double {
        let m = matchingBlocks().reduce(0) { $0 + $1.2 }
        let n = a.count + b.count
        return n > 0 ? 2.0 * Double(m) / Double(n) : 1.0
    }
}

/// Word-level edit script from a to b: [{"op": "equal"|"insert"|"delete"|"replace", "a": ..., "b": ...}].
func wordDiff(_ a: String, _ b: String) -> [[String: Any]] {
    let ta = diffTokens(a), tb = diffTokens(b)
    return SequenceMatcher(ta, tb).opcodes().map { op, i1, i2, j1, j2 in
        ["op": op, "a": String(scalars: ta[i1..<i2].joined()), "b": String(scalars: tb[j1..<j2].joined())]
    }
}

/// re.split(r"(\n[ \t]*\n\s*)", text): paragraphs at even indices, the separators at odd ones.
func splitParagraphs(_ text: String) -> [String] {
    let s = text.sc
    var parts: [String] = [], start = 0, i = 0
    while i < s.count {
        if s[i] == "\n" {
            var j = i + 1
            while j < s.count && (s[j] == " " || s[j] == "\t") { j += 1 }
            if j < s.count && s[j] == "\n" {
                var k = j + 1
                while k < s.count && s[k].pySpace { k += 1 }
                parts.append(String(scalars: s[start..<i]))
                parts.append(String(scalars: s[i..<k]))
                start = k
                i = k
                continue
            }
        }
        i += 1
    }
    parts.append(String(scalars: s[start...]))
    return parts
}

final class Proofreader {
    let cfg: () -> [String: Any]                             // the typing policy's config (shared with /settings)
    let user: UserPrompts
    var registered = Set<String>()
    var prefixTokens: [String: Int] = [:]                    // per registered profile, from predictd
    var contextSize: Int?                                    // the model's window on this Mac (4096 or 8192), from predictd
    let lock = NSLock()
    static let prompts: [String: Any] = readJSON(ROOT + "/ghost/proofread.json") as? [String: Any] ?? [:]
    static let modes = ["fix", "rewrite"]

    init(cfg: @escaping () -> [String: Any], user: UserPrompts) {
        self.cfg = cfg
        self.user = user
    }

    static func defaultPrompt(_ mode: String) -> [String: Any] {
        let p = prompts[mode] as? [String: Any] ?? [:]
        return ["instructions": p["instructions"] ?? "", "examples": p["examples"] ?? []]
    }

    /// The prompt in use: the user's version (instructions, and examples if they changed them), else the shipped one.
    func promptFor(_ mode: String) -> [String: Any] {
        let d = Proofreader.defaultPrompt(mode)
        guard let u = user.get("proofread-" + mode) else { return d }
        return ["instructions": u["instructions"] ?? "", "examples": u["examples"] ?? d["examples"] ?? []]
    }

    func profile(_ mode: String, _ prompt: [String: Any]? = nil) -> [String: Any] {
        let p = (prompt.map { $0.isEmpty ? nil : $0 } ?? nil) ?? promptFor(mode)
        let examples = (p["examples"] as? [[String: Any]] ?? []).map { ["prompt": $0["text"] ?? "", "response": $0["completion"] ?? ""] }
        var d: [String: Any] = ["instructions": p["instructions"] ?? "", "examples": examples,
                                "guardrails": cfg()["proofreadGuardrails"] ?? "permissive"]
        d["name"] = "proofread-\(mode)-" + sha1Hex(pyDumps(d)).prefix(8)
        return d
    }

    @discardableResult
    func ensureProfile(_ link: Link, _ mode: String, force: Bool = false, prompt: [String: Any]? = nil) throws -> String {
        var prof = profile(mode, prompt)
        let name = prof["name"] as! String
        lock.lock(); defer { lock.unlock() }
        if force || !registered.contains(name) {
            prof["op"] = "profile.set"
            prof["pin"] = false
            let r = try link.call(prof)
            if !truthy(r["ok"]) { throw PolicyError(kind: "RuntimeError", message: "profile.set failed: \(r["error"] ?? "None")") }
            registered.insert(name)
            prefixTokens[name] = intValue(r["prefix_tokens"])
        }
        return name
    }

    /// The longest paragraph (estimated tokens) a request takes: the knob, within the model's window on this Mac, which must hold
    /// the prefix, the paragraph and an answer of up to 1.6 times its length + 40 tokens.
    func inputLimit(_ link: Link, _ name: String) -> Int {
        let knob = intValue(cfg()["proofreadMaxInputTokens"]) ?? 2500
        lock.lock(); var ctx = contextSize; let prefix = max(prefixTokens[name] ?? 0, 0); lock.unlock()
        if ctx == nil, let r = try? link.call(["op": "ping"], timeout: 2), let c = intValue(r["contextSize"]) {
            ctx = c
            lock.lock(); contextSize = c; lock.unlock()
        }
        guard let ctx else { return knob }
        return min(knob, max(0, Int(Double(ctx - prefix - 40) / 2.6)))
    }

    func run(_ link: Link, _ text: String, mode: String = "fix", stream: String = "proofread", prompt: [String: Any]? = nil) throws -> [String: Any] {
        let t0 = now()
        guard Proofreader.modes.contains(mode) else { return ["ok": false, "error": "mode must be one of ['fix', 'rewrite']"] }
        if pyStrip(text).isEmpty { return ["ok": true, "text": text, "changed": false, "changes": [["op": "equal", "a": text, "b": text]]] }
        // one paragraph per request: the model then never sees (and drops) repeated passages, never hits the token cap on a long
        // text, and each request stays small; the profile's prefix is cached across them
        let parts = splitParagraphs(text)
        let name = try ensureProfile(link, mode, prompt: prompt)
        let limit = inputLimit(link, name)
        let longest = stride(from: 0, to: parts.count, by: 2).map { estTokens(pyStrip(parts[$0])) }.max() ?? 0
        if longest > Double(limit) { return ["ok": false, "error": "a paragraph is too long (about \(Int(longest)) tokens, at most \(limit))"] }
        var out: [String] = [], modelMs = 0.0, truncated = false, warnings: [String] = []
        var tokens: [String: Double] = ["in": 0, "cached": 0, "out": 0]
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 || pyStrip(part).isEmpty { out.append(part); continue }
            let core = pyStrip(part)
            let req: [String: Any] = ["op": "generate", "profile": name, "prompt": core, "maxTokens": Int(estTokens(core) * 1.6) + 40,
                                      "sampling": "greedy", "stream": stream]
            var resp = try link.call(req, timeout: 120)
            if resp["error"] as? String == "unknown_profile" {      // predictd restarted
                lock.lock(); registered.remove(name); lock.unlock()
                try ensureProfile(link, mode, prompt: prompt)
                resp = try link.call(req, timeout: 120)
            }
            if !truthy(resp["ok"]) {
                let err = resp["error"]
                return ["ok": false, "error": (err as? String == "guardrail" ? "the model declined this text" : err) ?? NSNull()]
            }
            let answer = resp["text"] as? String ?? ""
            var fixed = pyStrip(PREAMBLE.stringByReplacingMatches(in: answer, range: NSRange(answer.startIndex..., in: answer), withTemplate: ""))
            let fs = fixed.sc, quotes = Set("\"'“".unicodeScalars)
            if fs.count > 1 && fs[0] == fs[fs.count - 1] && quotes.contains(fs[0]) && !quotes.contains(core.unicodeScalars.first!) {   // quotes the model added
                fixed = pyStrip(String(scalars: fs[1..<(fs.count - 1)]))
            }
            if fixed.isEmpty { return ["ok": false, "error": "the model returned nothing"] }
            // a fix keeps about the same length, a rewrite may shorten; much less means the model dropped content
            if Double(fixed.pyLen) < Double(core.pyLen) * (mode == "fix" ? 0.8 : 0.4) {
                warnings.append("paragraph \(i / 2 + 1) came back much shorter: check it before replacing")
            }
            truncated = truncated || resp["finish"] as? String == "length"
            modelMs += num((resp["timing"] as? [String: Any])?["model_ms"]) ?? 0
            for k in ["in", "cached", "out"] { tokens[k]! += num((resp["tokens"] as? [String: Any])?[k]) ?? 0 }
            let ps = part.sc
            let lead = ps.prefix(ps.count - pyLStrip(part).pyLen), trail = ps.suffix(ps.count - pyRStrip(part).pyLen)
            out.append(String(scalars: lead) + fixed + String(scalars: trail))
        }
        let result = out.joined()
        if truncated { warnings.append("the answer was cut off: check the end before replacing") }
        return ["ok": true, "text": result, "changed": !pyEq(result, text), "changes": wordDiff(text, result), "mode": mode,
                "truncated": truncated, "warnings": warnings, "paragraphs": (parts.count + 1) / 2,
                "timing": ["model_ms": modelMs, "total_ms": perfMs(since: t0)],
                "tokens": tokens.mapValues { Int($0) }]
    }
}
