// The user's own prompts, their history and benchmark results, so a user can tune the prompts without editing the repo.
//
// A prompt is {"instructions": str, "examples": [{"text": str, "completion": str}, ...]}. Prediction prompts are named
// "predict-<style>" (general, chat, email, ...; `{words}` in the instructions becomes the `words` knob), proofreading ones
// "proofread-fix" and "proofread-rewrite" (examples: text = input, completion = output).
//
// Files, in the directory of the `userPrompts` knob (default ~/.config/homeword/, mode 0600, outside the repo: what a user writes
// there is theirs):
//   prompts.json          {name: prompt}: the overrides in use (an older form, {name: "instructions"}, still loads)
//   prompt-history.json   {"versions": {name: [{"hash", "saved_at", "prompt"}]}, "results": {hash: {name: result}}}: the last
//                         `HISTORY` saved versions per prompt, and benchmark results by prompt content hash (a run on the user's
//                         cases only is kept under "<name>#user", so it does not replace a full run)
//   test-cases.json       {name: [{"text", "rest"}]}: the user's own benchmark cases per prompt (rest = what comes next, or the
//                         expected output for proofreading)
// A changed prompt makes a new predictd profile (profiles are named by a hash of their content), so the change applies to the next
// request; the first one after it is uncached.
import Foundation

let MAX_CHARS = 6000                          // instructions + examples + input must fit the smallest window (4096 tokens)
let MAX_EXAMPLES = 12
let HISTORY = 20
let MAX_CASES = 200

struct ClientError: Error, CustomStringConvertible {          // ValueError: answered with 400 and the message
    let description: String
    init(_ s: String) { description = s }
}

func promptHash(_ prompt: Any) -> String { String(sha1Hex(pyDumps(prompt, ascii: false)).prefix(10)) }

/// Validate and normalise a prompt from a client.
func cleanPrompt(_ prompt: Any?) throws -> [String: Any] {
    guard let p = prompt as? [String: Any], let rawIns = p["instructions"] as? String else {
        throw ClientError("a prompt is {\"instructions\": text, \"examples\": [{\"text\", \"completion\"}]}")
    }
    let ins = pyStrip(rawIns)
    if ins.isEmpty { throw ClientError("the instructions are empty") }
    var examples: [[String: Any]] = []
    for e in p["examples"] as? [Any] ?? [] {
        guard let e = e as? [String: Any], let t = e["text"] as? String, let c = e["completion"] as? String else {
            throw ClientError("each example needs text and completion")
        }
        if !pyStrip(t).isEmpty && !pyStrip(c).isEmpty {
            var x: [String: Any] = [:]
            for k in ["text", "completion", "app"] { if let v = e[k] as? String { x[k] = v } }
            examples.append(x)
        }
    }
    if examples.count > MAX_EXAMPLES { throw ClientError("at most \(MAX_EXAMPLES) examples") }
    let chars = ins.pyLen + examples.reduce(0) { $0 + ($1["text"] as! String).pyLen + ($1["completion"] as! String).pyLen }
    if chars > MAX_CHARS { throw ClientError("the prompt is too long (at most \(MAX_CHARS) characters with its examples)") }
    return ["instructions": ins, "examples": examples]
}

/// `path`: the prompts.json file, or nil for none (benchmarks run on the shipped prompts).
final class UserPrompts {
    let path: String?, historyPath: String?, casesPath: String?
    private let lock = NSLock()
    private var stamp: (Int, Int)?
    private var data: [String: [String: Any]] = [:]

    init(_ path: String?) {
        self.path = path
        let dir = path.map { ($0 as NSString).deletingLastPathComponent }
        historyPath = dir.map { $0 + "/prompt-history.json" }
        casesPath = dir.map { $0 + "/test-cases.json" }
    }

    private func load() {
        guard let path else { return }
        var st = stat()
        guard stat(path, &st) == 0 else { stamp = nil; data = [:]; return }
        let s = (Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_nsec), Int(st.st_size))
        if stamp.map({ $0 != s }) ?? true {                   // changed by another process (pred, a text editor)
            data = [:]
            for (k0, v0) in readJSON(path) as? [String: Any] ?? [:] {
                let k = k0 == "typing" ? "predict-general" : k0    // the first version's name for the general prediction prompt
                var v = v0
                if let s = v as? String, !pyStrip(s).isEmpty { v = ["instructions": s] }   // instructions only: default examples
                if let d = v as? [String: Any], d["instructions"] is String { data[k] = d }
            }
            stamp = s
        }
    }

    /// The user's version (instructions, maybe examples) or nil.
    func get(_ name: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        load()
        return data[name]
    }

    /// Save the user's version (nil restores the default) and record it in the history.
    func set(_ name: String, _ prompt: [String: Any]?) throws {
        guard let path, let historyPath else { throw ClientError("no user prompt file configured") }
        lock.lock(); defer { lock.unlock() }
        load()
        if let prompt { data[name] = prompt } else { data[name] = nil }
        try writeJSONFile(path, data)
        stamp = nil
        if let prompt {
            var h = history()
            var all = h["versions"] as? [String: Any] ?? [:]
            let hash = promptHash(prompt)
            var versions = (all[name] as? [[String: Any]] ?? []).filter { $0["hash"] as? String != hash }
            versions.append(["hash": hash, "saved_at": localStamp(), "prompt": prompt])
            all[name] = Array(versions.suffix(HISTORY))
            h["versions"] = all
            prune(&h)
            try writeJSONFile(historyPath, h)
        }
    }

    private func history() -> [String: Any] {
        var h = historyPath.flatMap { readJSON($0) as? [String: Any] } ?? [:]
        if h["versions"] == nil { h["versions"] = [String: Any]() }
        if h["results"] == nil { h["results"] = [String: Any]() }
        return h
    }

    /// Keep results only for versions still in the history (and anything benchmarked in the last week, e.g. defaults).
    private func prune(_ h: inout [String: Any]) {
        let keep = Set((h["versions"] as? [String: Any] ?? [:]).values.flatMap { ($0 as? [[String: Any]] ?? []).compactMap { $0["hash"] as? String } })
        let cutoff = localStamp(Date().addingTimeInterval(-7 * 86400))
        h["results"] = (h["results"] as? [String: Any] ?? [:]).filter { k, r in
            keep.contains(k) || (r as? [String: Any] ?? [:]).values.contains { (($0 as? [String: Any])?["at"] as? String ?? "") >= cutoff }
        }
    }

    /// Saved versions of `name`, newest first, each with its benchmark result if one was run.
    func history(_ name: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let h = history()
        let results = h["results"] as? [String: Any] ?? [:]
        return ((h["versions"] as? [String: Any])?[name] as? [[String: Any]] ?? []).reversed().map { v in
            var x = v
            x["result"] = ((results[v["hash"] as? String ?? ""] as? [String: Any])?[name]) ?? NSNull()
            return x
        }
    }

    func result(_ name: String, _ prompt: Any, scope: String = "all") -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let results = history()["results"] as? [String: Any] ?? [:]
        return (results[promptHash(prompt)] as? [String: Any])?[scope == "all" ? name : name + "#user"] as? [String: Any]
    }

    func saveResult(_ name: String, _ prompt: Any, _ result: [String: Any]) throws {
        guard let historyPath else { return }
        lock.lock(); defer { lock.unlock() }
        var h = history()
        var results = h["results"] as? [String: Any] ?? [:]
        let hash = promptHash(prompt)
        var byName = results[hash] as? [String: Any] ?? [:]
        byName[result["scope"] as? String == "all" ? name : name + "#user"] = result
        results[hash] = byName
        h["results"] = results
        prune(&h)
        try writeJSONFile(historyPath, h)
    }

    // -- the user's own benchmark cases, per prompt

    func cases(_ name: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return (casesPath.flatMap { readJSON($0) as? [String: Any] })?[name] as? [[String: Any]] ?? []
    }

    /// Save the user's cases for a prompt: pairs with both sides non-empty (the text keeps its spaces: they matter).
    func setCases(_ name: String, _ cases: Any?) throws -> [[String: Any]] {
        guard let casesPath else { throw ClientError("no user prompt file configured") }
        var clean: [[String: Any]] = []
        for c in cases as? [Any] ?? [] {
            guard let c = c as? [String: Any], let t = c["text"] as? String, let r = c["rest"] as? String else {
                throw ClientError("each case needs text and rest")
            }
            if !pyStrip(t).isEmpty && !pyStrip(r).isEmpty { clean.append(["text": t, "rest": r]) }
        }
        if clean.count > MAX_CASES { throw ClientError("at most \(MAX_CASES) cases") }
        lock.lock(); defer { lock.unlock() }
        var d = readJSON(casesPath) as? [String: Any] ?? [:]
        if clean.isEmpty { d[name] = nil } else { d[name] = clean }
        try writeJSONFile(casesPath, d)
        return clean
    }
}
