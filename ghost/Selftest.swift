// `ghostd --selftest`: the policy's pure functions on JSON lines from stdin, one answer per line, for comparing this implementation
// with another one on the same inputs (no model, no network). A line: {"fn": name, "args": {...}}. Spell checks use a word list
// given once ({"fn": "words", "args": {"words": [...]}}): a word is right when it is in it.
import Foundation

private var wordList = Set<String>()

private func fakeSpell(_ ws: [String]) -> [Bool] { ws.map { wordList.contains($0) } }

func runSelftest() {
    while let line = readLine(strippingNewline: true) {
        guard let req = jsonObject(Data(line.utf8)) as? [String: Any], let fn = req["fn"] as? String else { print("{}"); continue }
        let a = req["args"] as? [String: Any] ?? [:]
        let s = { (k: String) in a[k] as? String ?? "" }
        var out: Any = NSNull()
        do {
            switch fn {
            case "words":
                wordList = Set(a["words"] as? [String] ?? [])
                out = wordList.count
            case "trim_tail":
                let (t, e, tr) = trimTail(s("text"), intValue(a["budget"]) ?? 100)
                out = [t, e, tr]
            case "trailing_partial": out = trailingPartial(s("text"))
            case "sentence_end": out = sentenceEnd(s("text")) as Any? ?? NSNull()
            case "cut_repeat":
                let (c, cut) = cutRepeat(s("text"), s("partial"), s("comp"), intValue(a["n"]) ?? 3, intValue(a["window"]) ?? 60)
                out = [c, cut]
            case "assemble":
                let x = try assemble(s("text"), s("completion"), s("app"), a["cfg"] as? [String: Any] ?? [:], truthy(a["truncated"]),
                                     Speller({ fakeSpell($0) }, a["cfg"] as? [String: Any] ?? [:]))
                out = ["shown": x.shown, "raw": x.raw, "partial": x.partial, "first_word": x.firstWord, "dropped_partial": x.droppedPartial,
                       "sentence_end": x.sentenceEnd, "glued": x.glued, "respaced": x.respaced, "valid": x.valid,
                       "suppressed": x.suppressed ?? NSNull(), "words": x.words, "misspelled": x.misspelled, "repeat_cut": x.repeatCut]
            case "dumps": out = pyDumps(a["value"], sortKeys: truthy(a["sort_keys"]), ascii: truthy(a["ascii"]))
            case "prompt_hash": out = promptHash(a["prompt"] ?? NSNull())
            case "split": out = pySplit(s("text"))
            case "strip": out = pyStrip(s("text"), a["chars"] as? String)
            case "lower": out = s("text").lowercased()
            case "norm_word": out = normWord(s("text"))
            case "split_paragraphs": out = splitParagraphs(s("text"))
            case "word_diff": out = wordDiff(s("a"), s("b"))
            case "ratio":
                let wa = diffTokens(s("a").replacingOccurrences(of: "’", with: "'").lowercased(), keepSpace: false)
                let wb = diffTokens(s("b").replacingOccurrences(of: "’", with: "'").lowercased(), keepSpace: false)
                out = SequenceMatcher(wa, wb).ratio()
            case "overlaps": out = overlaps(s("text"), a["examples"] as? [[String: Any]] ?? [])
            case "score":
                var sc = score(a["case"] as? [String: Any] ?? [:], a["resp"] as? [String: Any] ?? [:])
                sc["bag"] = pyRound(num(sc["bag"]) ?? 0, 9)
                out = sc
            case "preamble":
                let t = s("text")
                out = PREAMBLE.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            case "round": out = [pyRound(num(a["x"]) ?? 0), pyRound(num(a["x"]) ?? 0, intValue(a["n"]) ?? 2)]
            case "capitalize": out = pyCapitalize(s("text"))
            case "profile":
                let g = Ghost(overrides: a["cfg"] as? [String: Any] ?? [:], user: false)
                out = g.profile(g.cfg, s("style").isEmpty ? "general" : s("style"), a["prompt"] as? [String: Any])
            case "proof_profile":
                let p = Proofreader(cfg: { a["cfg"] as? [String: Any] ?? [:] }, user: UserPrompts(nil))
                out = p.profile(s("mode"), a["prompt"] as? [String: Any])
            case "request":
                let g = Ghost(user: false)
                let (r, _) = g.request(s("app"), s("text"), a["opts"] as? [String: Any], style: s("style").isEmpty ? "general" : s("style"),
                                       keepApp: truthy(a["keep_app"]))
                out = r ?? NSNull()
            case "suite": out = ["ids": [suiteID(), suiteID("fix"), suiteID("rewrite")], "cases": suite()]
            case "default_prompts":                  // every shipped prompt by name (bench/check_cases.py)
                let g = Ghost(user: false)
                var d: [String: Any] = [:]
                for st in g.styleNames() { d["predict-" + st] = g.defaultPrompt(st) }
                for m in Proofreader.modes { d["proofread-" + m] = Proofreader.defaultPrompt(m) }
                out = d
            case "clean":
                do { out = try cleanPrompt(a["prompt"]) } catch { out = ["error": "\(error)"] }
            default: out = ["error": "unknown fn \(fn)"]
            }
        } catch {
            out = ["error": "\(error)"]
        }
        FileHandle.standardOutput.write(jsonData(["out": out]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
