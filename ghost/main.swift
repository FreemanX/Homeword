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
//     GET  /settings   -> {"words", "maxTokens", "languages", "languagesSet", "supported": [{"id", "name", "native"}]}
//     POST /settings   {"words": 1-10, "languages": ["fr-FR", ...]} (either or both), saved to the user's config overrides: how many
//                      words to suggest (maxTokens follows: words + 1 per 5 words), the languages the user writes in (Language.swift)
//     GET  /config     -> {"config"}: the policy's knobs in effect (pred status, the benchmarks' records)
//     POST /request    {"app", "text", "context"?, "opts"?, "keep_app"?}  ->  {"profile", "generate"}: the profile and the generate
//                      request a prediction would use, without running it (bench/openai_compare.py)
//     GET  /health     -> {"ok", "service": "ghostd", "version", "build", "pid", "started", "port", "model": true if predictd
//                      answers, "availability": "available" or why the on-device model is not (device_not_eligible,
//                      apple_intelligence_off, model_not_ready)}. Whether a ghostd runs on a port: "service" is "ghostd" (see
//                      isGhostd). `build`: when this binary was built (its modification time), so a client can tell a ghostd
//                      started before a rebuild; `version`: the VERSION file next to it; `started`: when this process started.
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

/// Who this process is, in every /health answer.
let identity: [String: Any] = {
    let built = (try? FileManager.default.attributesOfItem(atPath: EXECUTABLE)[.modificationDate]) as? Date
    let version = (try? String(contentsOfFile: ROOT + "/VERSION", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let iso = ISO8601DateFormatter()
    return ["service": "ghostd", "version": version ?? "unknown", "build": built.map { iso.string(from: $0) } ?? NSNull(),
            "pid": Int(getpid()), "started": iso.string(from: Date())]
}()

/// A /health answer from a ghostd (not another program on the port, not predictd's /health).
func isGhostd(_ health: Any?) -> Bool {
    guard let h = health as? [String: Any] else { return false }
    return truthy(h["ok"]) && h["service"] as? String == "ghostd"
}

/// Does a ghostd answer on 127.0.0.1:port?
func ghostdAnswers(_ port: Int) -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
    let done = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { data, _, _ in
        ok = isGhostd(data.flatMap { jsonObject($0) })
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

do {
    let first = try startPredictd(socketPath, noUser: noUser)
    Languages.load(first)                                            // the model's languages, the spell checker's dictionaries
    try ghost.ensureProfile(first, pin: true)
    giveBack(first)
} catch {
    FileHandle.standardError.write(Data("ghostd: \(error)\n".utf8))
    exit(1)
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
