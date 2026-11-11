// The benchmark suite and its scoring: what POST /bench runs (Homeword's Prompts tab, bench/run.py --styles).
//
// The suite is every case of bench/cases.json (the fixed 80-case benchmark) plus bench/styles.json (per writing style, and
// terminal), at least 25 per category, each tagged with a category: chat, email, work, academic, code, general, terminal. A prompt
// runs on all of them, each case with its own app label (what the model is told the app is), and results are reported per
// category, so one run shows how a prompt does in chat, in email, and so on. A user's own cases (per prompt) form a separate "user"
// section. Proofreading prompts run on the proofread sentences of bench/styles.json and the user's cases.
//
// Prediction metrics: latency_p50/p90 (ms per suggestion, sequential requests on a warm prefix, like typing), next_word (share of
// cases whose first suggested word is what was typed next), words_right (mean number of leading suggested words that match),
// completions (share of mid-word cases whose completed word is right), shown (share with a suggestion). Proofreading: latency,
// `exact` (output equals the expected text), `word_match` (word-level similarity); rewriting has no single right answer: latency and
// `length_ratio` (output / input length).
//
// A case that shares text with one of the prompt's examples is skipped (counted as `skipped`): it would measure recall of the
// example, not prediction. bench/check_cases.py lists such overlaps for the shipped prompts.
import Foundation

let CASES = ROOT + "/bench/cases.json"
let STYLE_CASES = ROOT + "/bench/styles.json"
let PUNCT = " .,;:!?\"'()[]{}"
let CATEGORIES: [(String, String)] = [("chat", "Chat"), ("email", "Email"), ("work", "Work documents"), ("academic", "Academic"),
                                      ("code", "Code"), ("general", "General"), ("terminal", "Terminal")]
let TITLES: [String: String] = Dictionary(uniqueKeysWithValues: CATEGORIES).merging(
    ["user": "Your cases", "proofread": "Proofreading", "all": "All categories"]) { a, _ in a }
let APP_CATEGORY = ["mail": "email", "chat": "chat", "notes": "general", "editor": "general", "essay": "general",
                    "terminal": "terminal", "review": "code", "code": "code"]       // cases.json app labels
let STYLE_LABEL = ["general": "notes", "chat": "chat", "email": "mail", "work": "document", "academic": "paper", "code": "code"]

func norm(_ w: String) -> String { pyStrip(w, PUNCT).lowercased() }

/// Quality of one response against what the user actually typed next.
func score(_ c: [String: Any], _ r: [String: Any]) -> [String: Any] {
    let partial = r["partial"] as? String ?? ""
    let sug = r["suggestion"] as? String ?? ""
    let text = c["text"] as? String ?? "", rest = c["rest"] as? String ?? ""
    let pred = pySplit(partial + sug), truth = pySplit(partial + rest)
    var lead = 0
    for (a, b) in zip(pred, truth) {
        if !pyEq(norm(a), norm(b)) { break }
        lead += 1
    }
    let tset = Set(truth.map(norm))
    let bag = pred.isEmpty ? 0.0 : Double(pred.filter { tset.contains(norm($0)) }.count) / Double(pred.count)
    let last3 = pySplit(text).suffix(3).map(norm)
    let echo = last3.count == 3 && pyContains(pySplit(sug).map(norm).joined(separator: " "), last3.joined(separator: " "))
    let ts = text.sc
    let complete = !ts.isEmpty && !ts.last!.pySpace && pyStarts(rest, " ")
    let ss = sug.sc
    var cross = false                                            // re.search(r"[.!?]\s+\S", sug)
    for (i, ch) in ss.enumerated() where ".!?".unicodeScalars.contains(ch) {
        var j = i + 1
        while j < ss.count && ss[j].pySpace { j += 1 }
        if j > i + 1 && j < ss.count { cross = true; break }
    }
    return ["complete": complete, "space_ok": complete && (pyStarts(sug, " ") || pyStrip(sug).isEmpty), "shown": !pyStrip(sug).isEmpty,
            "cross": cross, "mid": !partial.isEmpty, "lead": lead, "acc1": lead >= 1,
            "word_ok": !pred.isEmpty && !truth.isEmpty && pyEq(norm(pred[0]), norm(truth[0])),
            "bag": bag, "n_words": pySplit(sug).count, "echo": echo,
            "truth": truth.prefix(8).joined(separator: " "), "pred": pred.joined(separator: " ")]
}

/// bench/styles.json: {style: [cases]} and "proofread".
func loadCases(_ path: String = STYLE_CASES) -> [String: [[String: Any]]] {
    (readJSON(path) as? [String: Any] ?? [:]).filter { !$0.key.hasPrefix("_") }.compactMapValues { $0 as? [[String: Any]] }
}

/// Every prediction case with its category and app label, in category order (stable, like Python's sorted).
func suite() -> [[String: Any]] {
    var out: [[String: Any]] = (readJSON(CASES) as? [[String: Any]] ?? []).map {
        let app = $0["app"] as? String ?? ""
        return ["text": $0["text"] ?? "", "rest": $0["rest"] ?? "", "app": app, "category": APP_CATEGORY[app] ?? "general"]
    }
    let labels = STYLE_LABEL.merging(["terminal": "terminal"]) { a, _ in a }   // styles.json keys: a style's cases, or terminal
    let cases = loadCases()
    for cat in topLevelKeys(STYLE_CASES) {
        guard let label = labels[cat], let cs = cases[cat] else { continue }
        out += cs.map { ["text": $0["text"] ?? "", "rest": $0["rest"] ?? "", "app": label, "category": cat] }
    }
    let order = CATEGORIES.map(\.0)
    return out.enumerated().sorted {
        let a = order.firstIndex(of: $0.element["category"] as! String)!, b = order.firstIndex(of: $1.element["category"] as! String)!
        return a != b ? a < b : $0.offset < $1.offset
    }.map(\.element)
}

/// A fingerprint of the cases a benchmark runs on: results from another version of the suite are not comparable.
func suiteID(_ kind: String = "predict") -> String {
    let cases = kind == "predict" ? suite() : (loadCases()["proofread"] ?? [])
    return String(sha1Hex(pyDumps(cases.map { [$0["text"] ?? "", $0["rest"] ?? $0["expected"] ?? NSNull()] })).prefix(10))
}

/// re.sub(r"\s+", " ", text).strip().lower()
private func overlapKey(_ text: String) -> Scalars {
    var out: Scalars = [], space = false
    for c in text.unicodeScalars {
        if c.pySpace { space = true; continue }
        if space && !out.isEmpty { out.append(" ") }
        space = false
        out.append(c)
    }
    return String(scalars: out).lowercased().sc
}

/// Whether a case's text shares text with an example: equal, the case's text inside the example (typed text + completion), the
/// example's typed text inside the case's, or the same first `n` characters. Pieces shorter than `least` characters ("git commit")
/// don't count.
func overlaps(_ text: String, _ examples: [[String: Any]], n: Int = 32, least: Int = 16) -> Bool {
    let a = overlapKey(text)
    for e in examples {
        let et = e["text"] as? String ?? ""
        let b = overlapKey(et), full = overlapKey(et + (e["completion"] as? String ?? ""))
        if a == b || (a.count >= least && pyFind(full, a) != nil) || (b.count >= least && pyFind(a, b) != nil)
            || (a.count >= n && b.count >= n && Array(a.prefix(n)) == Array(b.prefix(n))) { return true }
    }
    return false
}

private func mean(_ xs: [Double]) -> Any { xs.isEmpty ? NSNull() : pyRound(xs.reduce(0, +) / Double(xs.count), 3) }

private func summary(_ name: String, _ rows: [([String: Any], Double)], _ errors: Int, _ skipped: Int = 0) -> [String: Any] {
    let lat = rows.map(\.1), scores = rows.map(\.0)
    let mid = scores.filter { truthy($0["mid"]) }
    let b: (Any?) -> Double = { truthy($0) ? 1 : 0 }
    return ["name": name, "title": TITLES[name] ?? name, "cases": rows.count + errors, "errors": errors, "skipped": skipped,
            "latency_p50": pyRound(pct(lat, 50) ?? 0), "latency_p90": pyRound(pct(lat, 90) ?? 0),
            "next_word": mean(scores.map { b($0["acc1"]) }), "words_right": mean(scores.map { Double(intValue($0["lead"]) ?? 0) }),
            "completions": mean(mid.map { b($0["word_ok"]) }), "shown": mean(scores.map { b($0["shown"]) })]
}

/// Run a prediction prompt (default: the one in use for `style`) on the suite (scope "all") and/or the user's cases ({"text",
/// "rest"}, scope "all" or "user"); results per category, overall, and the user's section.
func benchPrompt(_ ghost: Ghost, _ link: Link, _ style: String, _ prompt: [String: Any]? = nil, userCases: [[String: Any]] = [],
                 scope: String = "all", progress: ((Int, Int) -> Void)? = nil, stream: String = "bench") throws -> [String: Any] {
    var cases = scope == "all" ? suite() : []
    var users: [[String: Any]] = userCases.map { ["text": $0["text"] ?? "", "rest": $0["rest"] ?? "", "app": ghost.styleLabel(style), "category": "user"] }
    let examples = ((prompt.map { $0.isEmpty ? nil : $0 } ?? nil) ?? ghost.promptFor(style))["examples"] as? [[String: Any]] ?? []
    var skipped: [String: Int] = [:]
    for c in cases + users where overlaps(c["text"] as? String ?? "", examples) { skipped[c["category"] as! String, default: 0] += 1 }
    cases = cases.filter { !overlaps($0["text"] as? String ?? "", examples) }
    users = users.filter { !overlaps($0["text"] as? String ?? "", examples) }
    let todo = cases + users
    if todo.isEmpty { return ["kind": "predict", "style": style, "scope": scope, "error": "no cases"] }
    _ = try ghost.predict(link, todo[0]["app"] as! String, todo[0]["text"] as! String, stream: stream, style: style, prompt: prompt, keepApp: true)   // warm the prefix
    var rows: [String: [([String: Any], Double)]] = [:], errors: [String: Int] = [:]
    for (i, c) in todo.enumerated() {
        let t0 = now()
        let r = try ghost.predict(link, c["app"] as! String, c["text"] as! String, stream: stream, style: style, prompt: prompt, keepApp: true)
        let cat = c["category"] as! String
        if truthy(r["ok"]) { rows[cat, default: []].append((score(c, r), perfMs(since: t0))) } else { errors[cat, default: 0] += 1 }
        progress?(i + 1, todo.count)
    }
    let cats = CATEGORIES.map(\.0).filter { rows[$0] != nil || errors[$0] != nil }.map { summary($0, rows[$0] ?? [], errors[$0] ?? 0, skipped[$0] ?? 0) }
    let ours = rows.filter { $0.key != "user" }.values.flatMap { $0 }
    let total: ([String: Int]) -> Int = { $0.filter { $0.key != "user" }.values.reduce(0, +) }
    return ["kind": "predict", "style": style, "scope": scope, "at": localStamp(), "suite": suiteID(), "categories": cats,
            "overall": cases.isEmpty ? NSNull() : summary("all", ours, total(errors), total(skipped)),
            "user": !users.isEmpty || skipped["user"] != nil ? summary("user", rows["user"] ?? [], errors["user"] ?? 0, skipped["user"] ?? 0) : NSNull()]
}

/// re.findall(r"\w+|[^\w\s]", s.replace("’", "'").lower())
private func words(_ s: String) -> [Scalars] { diffTokens(s.replacingOccurrences(of: "’", with: "'").lowercased(), keepSpace: false) }

private func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(), n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

private func proofSummary(_ name: String, _ rows: [[String: Double]], _ errors: Int, _ mode: String, _ skipped: Int = 0) -> [String: Any] {
    var res: [String: Any] = ["name": name, "title": TITLES[name] ?? name, "cases": rows.count + errors, "errors": errors, "skipped": skipped,
                              "latency_p50": pyRound(pct(rows.map { $0["lat"]! }, 50) ?? 0),
                              "latency_p90": pyRound(pct(rows.map { $0["lat"]! }, 90) ?? 0)]
    if mode == "fix" {
        res["exact"] = mean(rows.map { $0["exact"]! })
        res["word_match"] = mean(rows.map { $0["match"]! })
    } else {
        res["length_ratio"] = rows.isEmpty ? NSNull() : pyRound(median(rows.map { $0["ratio"]! }), 2)
    }
    return res
}

/// Proofreading or rewriting prompt on the proofread sentences (scope "all") and/or the user's cases ({"text", "rest"}: rest = the
/// expected output).
func benchProofread(_ proof: Proofreader, _ link: Link, _ mode: String, _ prompt: [String: Any]? = nil, userCases: [[String: Any]] = [],
                    scope: String = "all", progress: ((Int, Int) -> Void)? = nil, stream: String = "bench") throws -> [String: Any] {
    var ours: [[String: Any]] = scope == "all" ? (loadCases()["proofread"] ?? []).map { ["text": $0["text"] ?? "", "rest": $0["expected"] ?? "", "category": "proofread"] } : []
    let users: [[String: Any]] = userCases.map { ["text": $0["text"] ?? "", "rest": $0["rest"] ?? "", "category": "user"] }
    let examples = ((prompt.map { $0.isEmpty ? nil : $0 } ?? nil) ?? proof.promptFor(mode))["examples"] as? [[String: Any]] ?? []
    let skip = { (cs: [[String: Any]]) in cs.filter { overlaps($0["text"] as? String ?? "", examples) }.count }
    let skipped = ["proofread": skip(ours), "user": skip(users)]
    ours = ours.filter { !overlaps($0["text"] as? String ?? "", examples) }
    let todo = ours + users.filter { !overlaps($0["text"] as? String ?? "", examples) }
    if todo.isEmpty { return ["kind": mode, "scope": scope, "error": "no cases"] }
    _ = try proof.run(link, todo[0]["text"] as! String, mode: mode, stream: stream, prompt: prompt)   // warm the prefix
    var rows: [String: [[String: Double]]] = [:], errors: [String: Int] = [:]
    for (i, c) in todo.enumerated() {
        let t0 = now()
        let r = try proof.run(link, c["text"] as! String, mode: mode, stream: stream, prompt: prompt)
        let cat = c["category"] as! String
        if truthy(r["ok"]) {
            let out = pyStrip(r["text"] as? String ?? ""), rest = c["rest"] as? String ?? "", text = c["text"] as? String ?? ""
            let exact = pyEq(out.replacingOccurrences(of: "’", with: "'"), pyStrip(rest).replacingOccurrences(of: "’", with: "'"))
            rows[cat, default: []].append(["lat": perfMs(since: t0), "exact": exact ? 1 : 0,
                                           "match": SequenceMatcher(words(out), words(rest)).ratio(),
                                           "ratio": Double(out.pyLen) / Double(max(text.pyLen, 1))])
        } else {
            errors[cat, default: 0] += 1
        }
        progress?(i + 1, todo.count)
    }
    let cats: [[String: Any]] = ours.isEmpty ? [] : [proofSummary("proofread", rows["proofread"] ?? [], errors["proofread"] ?? 0, mode, skipped["proofread"]!)]
    return ["kind": mode, "scope": scope, "at": localStamp(), "suite": suiteID(mode), "categories": cats,
            "overall": cats.first ?? NSNull(),
            "user": users.isEmpty ? NSNull() : proofSummary("user", rows["user"] ?? [], errors["user"] ?? 0, mode, skipped["user"]!)]
}
