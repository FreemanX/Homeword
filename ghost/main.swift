// ghostd: the HTTP front end of the policies (typing prediction, proofreading) for the apps: Homeword, pred, the pi extension, the
// Claude Code mod, the benchmarks. It talks to predictd (the model host) over its unix socket and starts it when needed.
//
//     POST /predict    {"app": "chat", "text": "See you tomor", "stream": "pi", "context": "chat", "opts": {...}}  ->  the ghost
//                      answer (Policy.swift); `context`: a writing style (general, chat, email, work, academic, code; default general)
//     POST /warm       {"context": "chat"}: the user is about to type in this style: pin and prewarm its prompt
//     POST /proofread  {"text": "...", "mode": "fix" | "rewrite"}  ->  {"text", "changed", "changes", "warnings", ...}
//     GET  /prompts    -> {"prompts": [{"name", "group", "title", "prompt", "default", "custom", "hash", "result", "suite_cases",
//                      ...}]}: every prompt (prediction per style, proofreading per mode), the one in use and the shipped one
//                      (Prompts.swift), and the size of the benchmark it runs on
//     POST /prompts    {"name": "predict-chat", "prompt": {"instructions", "examples"}} saves the user's version (and a history
//                      entry), {"name": ..., "reset": true} restores the shipped one
//     GET  /history?name=predict-chat  -> {"versions": [{"hash", "saved_at", "prompt", "result"}]}: the last saved versions
//                      (results from another version of the suite are left out: they are not comparable)
//     POST /tokens     {"name", "prompt"?}  ->  {"instructions": n, "prompt": n (instructions + examples as sent), "ms": est.}
//     POST /bench      {"name", "prompt"?, "scope": "all" | "user"}  ->  {"job"}: benchmark that prompt (default: the one in use)
//                      on the suite, per category (Evaluate.swift), and/or on the user's cases; runs in the background
//     GET  /bench?job= -> {"state": "running" | "done" | "error", "done", "total", "result"}: progress, then the result, which is
//                      also stored by the prompt's hash (history entries show it)
//     GET  /suite?name=predict-chat  -> {"categories": [{"name", "title", "cases": [{"text", "rest", "skipped"}]}]}: the built-in
//                      benchmark cases the prompt runs on, read-only; `skipped`: left out because it shares text with an example of
//                      the prompt in use
//     GET  /cases?name=  -> {"cases": [{"text", "rest"}]}: the user's own benchmark cases for a prompt     POST /cases saves them
//     GET  /settings   -> {"words", "maxTokens"}      POST /settings {"words": 1-10}: how many words to suggest, saved to the user's
//                      config overrides (maxTokens follows: words + 1 per 5 words)
//     GET  /config     -> {"config"}: the policy's knobs in effect (pred status, the benchmarks' records)
//     POST /request    {"app", "text", "context"?, "opts"?, "keep_app"?}  ->  {"profile", "generate"}: the profile and the generate
//                      request a prediction would use, without running it (bench/openai_compare.py)
//     GET  /health     -> {"ok", "port", "model": true if predictd answers, "availability": "available" or why the on-device
//                      model is not (device_not_eligible, apple_intelligence_off, model_not_ready)}
//     POST /shutdown   {"predictd": true?}: exit (and stop predictd too)
//
// 127.0.0.1 only. Requests on one `stream` replace each other (the older one answers {"ok": false, "error": "cancelled"}).
// Exits after `serverIdleExitSec` without requests. One ghostd per port: started while one is running, it exits at once
// (status 0, "already running"), so any app can start it without checking first.
//
// Usage: ghostd [--port N] [--socket PATH] [--config JSON] [--no-user] [--quiet]
//   --port 0: any free port; the ready line on stdout ("ghost server on 127.0.0.1:<port> ...") names it; --config: policy overrides (ghost/config.json keys); --no-user (or PRED_NO_USER=1): ignore the user's config, prompts and
//   predictd overrides (benchmarks); --socket: predictd's socket (default /tmp/predictd-<uid>.sock)
import Foundation

let CACHED_MS_PER_TOKEN = 0.55               // measured cost of a cached prompt token per request (docs/PERFORMANCE.md)

// MARK: options

if CommandLine.arguments.dropFirst().first == "--selftest" { runSelftest(); exit(0) }   // Selftest.swift: parity checks

var argPort: Int?, socketPath = SOCK, overrides: [String: Any] = [:], quiet = false
var noUser = ProcessInfo.processInfo.environment["PRED_NO_USER"] == "1"
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--port": argPort = it.next().flatMap { Int($0) }
        case "--socket": socketPath = it.next() ?? SOCK
        case "--config": overrides = (it.next().flatMap { jsonObject(Data($0.utf8)) } as? [String: Any]) ?? [:]
        case "--no-user": noUser = true
        case "--quiet": quiet = true
        default:
            FileHandle.standardError.write(Data("usage: ghostd [--port N] [--socket PATH] [--config JSON] [--no-user] [--quiet]\n".utf8))
            exit(2)
        }
    }
}
signal(SIGPIPE, SIG_IGN)

let ghost = Ghost(overrides: overrides, user: !noUser)
let proof = Proofreader(cfg: { ghost.cfg }, user: ghost.user)
var port = argPort ?? intValue(ghost.cfg["serverPort"]) ?? 47321   // 0: any free port (printed)
var lastRequest = Date()

// MARK: the port, first: one ghostd per port. A second start (two apps starting the engine at once) exits here, before it
// touches predictd (registering and pinning profiles would take the warm cache from the running one).

/// Does a ghostd answer on 127.0.0.1:port?
func ghostdAnswers(_ port: Int) -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
    let done = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { data, _, _ in
        ok = (data.flatMap { jsonObject($0) } as? [String: Any]).map { truthy($0["ok"]) && $0["port"] != nil } ?? false
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 6)
    return ok
}

let listener = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = in_port_t(UInt16(port).bigEndian)
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard bound == 0, listen(listener, 64) == 0 else {
    let why = errno
    if why == EADDRINUSE && ghostdAnswers(port) {
        FileHandle.standardError.write(Data("ghostd: already running on 127.0.0.1:\(port)\n".utf8))
        exit(0)
    }
    FileHandle.standardError.write(Data("ghostd: cannot listen on 127.0.0.1:\(port): \(String(cString: strerror(why)))\n".utf8))
    exit(1)
}
if port == 0 {
    var got = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
    port = Int(UInt16(bigEndian: got.sin_port))
}

// MARK: predictd connections

let poolLock = NSLock()
var pool: [Link] = []

func takeLink() throws -> Link {
    poolLock.lock()
    if let l = pool.popLast() { poolLock.unlock(); return l }
    poolLock.unlock()
    return try startPredictd(socketPath, noUser: noUser)
}

func giveBack(_ l: Link) { poolLock.lock(); pool.append(l); poolLock.unlock() }

/// Run fn(link) with a pooled connection; reconnect once when predictd went away (idle exit: it restarts on demand).
func withLink(_ fn: (Link) throws -> [String: Any]) -> [String: Any] {
    var r: [String: Any] = ["ok": false, "error": "predictd unavailable"]
    for _ in 0..<2 {
        let ln: Link
        do { ln = try takeLink() } catch { return ["ok": false, "error": "predictd unavailable: \(error)"] }   // cannot start predictd
        do {
            r = try fn(ln)
            giveBack(ln)
            return r
        } catch is PredictdError {
            poolLock.lock(); pool.removeAll(); poolLock.unlock()   // the other pooled connections are dead too
            ghost.lock.lock(); ghost.registered.removeAll(); ghost.pinned = nil; ghost.lock.unlock()
            proof.lock.lock(); proof.registered.removeAll(); proof.lock.unlock()
        } catch {                                                  // a refused profile: answer, and drop the connection
            return ["ok": false, "error": "\(error)"]
        }
    }
    return r
}

do {
    let first = try startPredictd(socketPath, noUser: noUser)
    try ghost.ensureProfile(first, pin: true)
    giveBack(first)
} catch {
    FileHandle.standardError.write(Data("ghostd: \(error)\n".utf8))
    exit(1)
}

// MARK: prompts: prediction per style ("predict-<style>"), proofreading per mode ("proofread-<mode>")

func parse(_ name: String) throws -> (String, String) {
    let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let kind = parts.first ?? "", key = parts.count > 1 ? parts[1] : ""
    if kind == "predict" && ghost.styleNames().contains(key) { return (kind, key) }
    if kind == "proofread" && Proofreader.modes.contains(key) { return (kind, key) }
    throw ClientError("unknown prompt '\(name)'")
}

func current(_ name: String) throws -> [String: Any] {
    let (kind, key) = try parse(name)
    return kind == "predict" ? ghost.promptFor(key) : proof.promptFor(key)
}

func defaultOf(_ name: String) throws -> [String: Any] {
    let (kind, key) = try parse(name)
    return kind == "predict" ? ghost.defaultPrompt(key) : Proofreader.defaultPrompt(key)
}

let theSuite = suite()
let sizes = ["predict": (theSuite.count, Set(theSuite.map { $0["category"] as! String }).count),
             "proofread": ((loadCases()["proofread"] ?? []).count, 1)]
let suiteIDs = ["predict": suiteID(), "fix": suiteID("fix"), "rewrite": suiteID("rewrite")]

/// A stored benchmark result, unless it ran on another version of the suite (a user-cases run has no suite part).
func storedResult(_ name: String, _ prompt: [String: Any], scope: String = "all") throws -> Any {
    let (kind, key) = try parse(name)
    guard let r = ghost.user.result(name, prompt, scope: scope) else { return NSNull() }
    if scope == "all" && r["suite"] as? String != suiteIDs[kind == "predict" ? "predict" : key] { return NSNull() }
    return r
}

func suiteView(_ name: String) throws -> [[String: Any]] {
    let (kind, _) = try parse(name)
    let examples = try current(name)["examples"] as? [[String: Any]] ?? []
    let mark = { (t: Any?, r: Any?) -> [String: Any] in
        ["text": t ?? "", "rest": r ?? "", "skipped": overlaps(t as? String ?? "", examples)]
    }
    if kind == "proofread" {
        return [["name": "proofread", "title": TITLES["proofread"]!, "cases": (loadCases()["proofread"] ?? []).map { mark($0["text"], $0["expected"]) }]]
    }
    return CATEGORIES.map { k, t in ["name": k, "title": t, "cases": theSuite.filter { $0["category"] as? String == k }.map { mark($0["text"], $0["rest"]) }] }
}

func entry(_ name: String) throws -> [String: Any] {
    let (kind, key) = try parse(name)
    let p = try current(name), d = try defaultOf(name)
    let custom = ghost.user.get(name) != nil
    return ["name": name, "group": kind == "predict" ? "prediction" : "proofreading",
            "title": kind == "predict" ? ghost.styleTitle(key) : (key == "fix" ? "Proofread" : "Rewrite"),
            "prompt": p, "default": d, "custom": custom, "hash": promptHash(p),
            "default_hash": promptHash(d), "result": try storedResult(name, p), "default_result": try storedResult(name, d),
            "user_result": ghost.user.result(name, p, scope: "user") ?? NSNull(), "user_cases": ghost.user.cases(name).count,
            "labels": kind == "predict" ? ["Typed text", "Continuation"] : ["Input", "Output"],
            "suite_cases": sizes[kind]!.0, "suite_categories": sizes[kind]!.1,
            "inherits": kind == "predict" && ghost.inherits(key) && !custom,
            "note": kind == "predict" ? "{words} becomes the number of words to suggest (\(pyStr(ghost.cfg["words"])))."
                                      : "The model gets one paragraph at a time."]
}

func catalog() throws -> [[String: Any]] {
    try ghost.styleNames().map { try entry("predict-" + $0) } + [try entry("proofread-fix"), try entry("proofread-rewrite")]
}

func save(_ req: [String: Any]) throws -> [String: Any] {
    var name = req["name"] as? String ?? "", req = req
    if name == "typing" {                                     // the first version's API: instructions only, general style
        name = "predict-general"
        req["prompt"] = ["instructions": req["text"] as? String ?? "", "examples": try defaultOf(name)["examples"] ?? []]
    }
    _ = try parse(name)
    if truthy(req["reset"]) || (req["text"] as? String == "" && req["prompt"] == nil) {
        try ghost.user.set(name, nil)
    } else {
        let p = try cleanPrompt(req["prompt"])
        try ghost.user.set(name, pyDumps(p) == pyDumps(try defaultOf(name)) ? nil : p)
    }
    return ["ok": true, "prompts": try catalog()]
}

func profileOf(_ name: String, _ prompt: [String: Any]) throws -> [String: Any] {
    let (kind, key) = try parse(name)
    return kind == "predict" ? ghost.profile(ghost.cfg, key, prompt) : proof.profile(key, prompt)
}

func tokens(_ req: [String: Any]) throws -> [String: Any] {
    let name = req["name"] as? String ?? ""
    let prompt = truthy(req["prompt"]) ? try cleanPrompt(req["prompt"]) : try current(name)
    let prof = try profileOf(name, prompt)
    return withLink { ln in
        let ins = try ln.call(["op": "tokens", "text": prof["instructions"] ?? ""])["count"] ?? -1
        var probe = prof
        probe["op"] = "profile.set"; probe["name"] = "tokens-probe"; probe["pin"] = false   // the prefix exactly as sent
        let r = try ln.call(probe)
        _ = try ln.call(["op": "profile.drop", "name": "tokens-probe"])
        let n = intValue(r["prefix_tokens"]) ?? -1
        return ["ok": true, "instructions": ins, "prompt": n, "ms": n > 0 ? pyRound(Double(n) * CACHED_MS_PER_TOKEN) as Any : NSNull()]
    }
}

// MARK: benchmark jobs

let jobsLock = NSLock(), benchLock = NSLock()
var jobs: [String: [String: Any]] = [:], jobOrder: [String] = []

func updateJob(_ id: String, _ fields: [String: Any]) {
    jobsLock.lock(); defer { jobsLock.unlock() }
    for (k, v) in fields { jobs[id]?[k] = v }
}

/// Start a benchmark job; GET /bench?job= reports progress and the result.
func bench(_ req: [String: Any]) throws -> [String: Any] {
    let name = req["name"] as? String ?? ""
    let (kind, key) = try parse(name)
    let prompt = truthy(req["prompt"]) ? try cleanPrompt(req["prompt"]) : try current(name)
    let scope = req["scope"] as? String == "user" ? "user" : "all"
    let userCases = ghost.user.cases(name)
    if scope == "user" && userCases.isEmpty { return ["ok": false, "error": "no cases of your own yet"] }
    guard benchLock.try() else { return ["ok": false, "error": "a benchmark is already running"] }
    let job = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    jobsLock.lock()
    jobs[job] = ["state": "running", "done": 0, "total": 0, "name": name, "hash": promptHash(prompt)]
    jobOrder.append(job)
    jobsLock.unlock()
    let progress: (Int, Int) -> Void = { d, t in updateJob(job, ["done": d, "total": t]) }
    DispatchQueue.global().async {
        defer {
            benchLock.unlock()
            jobsLock.lock()
            let finished = jobOrder.filter { jobs[$0]?["state"] as? String != "running" }
            for old in finished.dropLast(20) { jobs[old] = nil; jobOrder.removeAll { $0 == old } }
            jobsLock.unlock()
        }
        let res = withLink { ln in
            let r = kind == "predict"
                ? try benchPrompt(ghost, ln, key, prompt, userCases: userCases, scope: scope, progress: progress)
                : try benchProofread(proof, ln, key, prompt, userCases: userCases, scope: scope, progress: progress)
            ghost.lock.lock(); let pinned = ghost.pinned; ghost.lock.unlock()
            if let pinned { _ = try ln.call(["op": "prewarm", "profile": pinned]) }   // give the cache back to the prompt in use
            return r
        }
        if res["ok"] as? Bool == false || res["error"] != nil {
            updateJob(job, ["state": "error", "error": res["error"] ?? "failed"])
            return
        }
        do {
            try ghost.user.saveResult(name, prompt, res)
            updateJob(job, ["state": "done", "result": res])
        } catch {
            updateJob(job, ["state": "error", "error": "\(error)"])
        }
    }
    return ["ok": true, "job": job]
}

/// (predictd answers, the on-device model's availability: "available" or why not; nil when predictd is down).
func modelState() -> (Bool, Any) {
    guard let ln = try? Link(socketPath), let r = try? ln.call(["op": "ping"], timeout: 1) else { return (false, NSNull()) }
    return (truthy(r["ok"]), r["model"] ?? NSNull())
}

// MARK: routes

func handleGET(_ path: String, _ q: [String: String]) -> (Int, [String: Any]) {
    do {
        switch path {
        case "/health":
            let (up, availability) = modelState()
            return (200, ["ok": true, "port": port, "model": up, "availability": availability])
        case "/prompts":
            return (200, ["ok": true, "prompts": try catalog(), "styles": ghost.styleNames().map { ["name": $0, "title": ghost.styleTitle($0)] }])
        case "/bench":
            jobsLock.lock(); let j = jobs[q["job"] ?? ""]; jobsLock.unlock()
            return (200, j.map { $0.merging(["ok": true]) { a, _ in a } } ?? ["ok": false, "error": "unknown job"])
        case "/cases":
            let name = q["name"] ?? ""
            _ = try parse(name)
            return (200, ["ok": true, "name": name, "cases": ghost.user.cases(name)])
        case "/suite":
            let name = q["name"] ?? ""
            return (200, ["ok": true, "name": name, "categories": try suiteView(name)])
        case "/settings":
            let c = ghost.cfg
            return (200, ["ok": true, "words": c["words"] ?? 5, "maxTokens": c["maxTokens"] ?? 6])
        case "/config":
            return (200, ["ok": true, "config": ghost.cfg])
        case "/history":
            let name = q["name"] ?? ""
            let (kind, key) = try parse(name)
            let sid = suiteIDs[kind == "predict" ? "predict" : key]
            let versions = ghost.user.history(name).map { v -> [String: Any] in
                var x = v
                if (v["result"] as? [String: Any])?["suite"] as? String != sid { x["result"] = NSNull() }
                return x
            }
            return (200, ["ok": true, "name": name, "versions": versions])
        default:
            return (404, ["ok": false, "error": "GET /health, /prompts, /history?name=, /cases?name= or /bench?job="])
        }
    } catch {
        return (400, ["ok": false, "error": "\(error)"])
    }
}

func handlePOST(_ path: String, _ body: Data) -> (Int, [String: Any]) {
    guard let req = (body.isEmpty ? [:] : jsonObject(body)) as? [String: Any] else { return (400, ["ok": false, "error": "body is not JSON"]) }
    do {
        switch path {
        case "/predict":
            if let t = req["text"], !(t is String) { throw ClientError("text must be a string") }
            return (200, withLink { ln in
                try ghost.predict(ln, req["app"] as? String ?? "", req["text"] as? String ?? "", req["opts"] as? [String: Any],
                                  stream: req["stream"] as? String ?? "ghost-http",
                                  style: (req["context"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general")
            })
        case "/proofread":
            return (200, withLink { ln in try proof.run(ln, req["text"] as? String ?? "", mode: req["mode"] as? String ?? "fix") })
        case "/warm":
            return (200, withLink { ln in try ghost.warm(ln, (req["context"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general") })
        case "/prompts":
            return (200, try save(req))
        case "/tokens":
            return (200, try tokens(req))
        case "/bench":
            return (200, try bench(req))
        case "/settings":
            guard let w = intValue(req["words"]), (1...10).contains(w) else { throw ClientError("words must be a whole number from 1 to 10") }
            var c = ghost.cfg
            c["words"] = w
            c["maxTokens"] = tokensForWords(w)                // {words} is in the prompts: new profiles
            ghost.cfg = c
            try saveUserConfig(["words": w, "maxTokens": tokensForWords(w)])
            return (200, ["ok": true, "words": w, "maxTokens": tokensForWords(w)])
        case "/cases":
            let name = req["name"] as? String ?? ""
            _ = try parse(name)
            return (200, ["ok": true, "cases": try ghost.user.setCases(name, req["cases"])])
        case "/request":
            let style = (req["context"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general"
            let (gen, ctx) = ghost.request(req["app"] as? String ?? "", req["text"] as? String ?? "", req["opts"] as? [String: Any],
                                           style: style, keepApp: truthy(req["keep_app"]))
            return (200, ["ok": true, "generate": gen ?? NSNull(), "profile": ghost.profile(ctx.cfg, ctx.style)])
        default:
            return (404, ["ok": false, "error": "POST /predict, /warm, /proofread, /prompts, /tokens, /bench, /cases, /settings or /request"])
        }
    } catch {
        return (400, ["ok": false, "error": "\(error)"])
    }
}

// MARK: HTTP

func reply(_ fd: Int32, _ code: Int, _ obj: [String: Any]) {
    let body = jsonData(obj)
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][code] ?? "Error"
    var data = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    data.append(body)
    data.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress! + off, p.count - off)
            if n <= 0 { break }
            off += n
        }
    }
}

func serve(_ fd: Int32) {
    defer { close(fd) }
    var buf = Data(), chunk = [UInt8](repeating: 0, count: 65536)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buf.append(contentsOf: chunk[0..<n])
        headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
        if buf.count > 1 << 20 { return }
    }
    let head = String(decoding: buf[..<headerEnd!.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count >= 2 else { return }
    let method = String(first[0]), target = String(first[1])
    var length = 0
    for l in lines.dropFirst() {
        let kv = l.split(separator: ":", maxSplits: 1)
        if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
            length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    var body = Data(buf[headerEnd!.upperBound...])
    while body.count < length {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        body.append(contentsOf: chunk[0..<n])
    }
    lastRequest = Date()
    let comps = URLComponents(string: target)
    let path = comps?.path ?? target
    var q: [String: String] = [:]
    for item in comps?.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
    if method == "GET" {
        let (code, obj) = handleGET(path, q)
        reply(fd, code, obj)
    } else if method == "POST" && path == "/shutdown" {
        reply(fd, 200, ["ok": true])
        if truthy((jsonObject(body) as? [String: Any])?["predictd"]), let ln = try? Link(socketPath) {
            _ = try? ln.call(["op": "shutdown"], timeout: 3)
        }
        exit(0)
    } else if method == "POST" {
        let (code, obj) = handlePOST(path, body)
        reply(fd, code, obj)
    } else {
        reply(fd, 404, ["ok": false, "error": "GET or POST"])
    }
}

let idle = num(ghost.cfg["serverIdleExitSec"]) ?? 1800
if idle > 0 {
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 5)
            if Date().timeIntervalSince(lastRequest) > idle { exit(0) }
        }
    }
}
if !quiet { print("ghost server on 127.0.0.1:\(port) (predictd \(socketPath))"); fflush(stdout) }
while true {
    let fd = accept(listener, nil, nil)
    if fd < 0 { continue }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    DispatchQueue.global().async { serve(fd) }
}
