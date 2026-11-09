// predictd: a model host for Apple's on-device language model (FoundationModels). Mechanism only: it holds named system-prompt
// profiles, keeps one of them warm, and generates plain text or structured output on request. It assumes nothing about what the
// text is for: policies (what to ask, how to use the answer) live in its clients, such as the typing predictor in ghost/.
// Protocol: newline-delimited JSON over a unix socket, the same requests over HTTP on 127.0.0.1. See docs/ARCHITECTURE.md.
import Foundation
import FoundationModels
import AppKit

let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func num(_ x: Any?) -> NSNumber? { x as? NSNumber }

// MARK: config (daemon-wide knobs; everything about a generation comes with the profile or the request)

struct Config {
    var socketPath = "/tmp/predictd-\(getuid()).sock", httpPort = 47320
    var keepAliveSec = 3.0, keepAliveMaxIdleSec = 300.0, idleExitSec = 1800.0, cacheTTLSec = 5.5, maxSessions = 32

    mutating func apply(_ d: [String: Any]) {
        socketPath = d["socketPath"] as? String ?? socketPath; httpPort = num(d["httpPort"])?.intValue ?? httpPort
        keepAliveSec = num(d["keepAliveSec"])?.doubleValue ?? keepAliveSec
        keepAliveMaxIdleSec = num(d["keepAliveMaxIdleSec"])?.doubleValue ?? keepAliveMaxIdleSec
        idleExitSec = num(d["idleExitSec"])?.doubleValue ?? idleExitSec
        cacheTTLSec = num(d["cacheTTLSec"])?.doubleValue ?? cacheTTLSec
        maxSessions = num(d["maxSessions"])?.intValue ?? maxSessions
    }
    func dict() -> [String: Any] {
        ["socketPath": socketPath, "httpPort": httpPort, "keepAliveSec": keepAliveSec, "keepAliveMaxIdleSec": keepAliveMaxIdleSec,
         "idleExitSec": idleExitSec, "cacheTTLSec": cacheTTLSec, "maxSessions": maxSessions]
    }
}

func loadJSON(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}
func jsonText(_ o: Any) -> String {
    guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "\(o)" }
    return String(decoding: d, as: UTF8.self)
}

// MARK: schemas: a JSON Schema subset -> GenerationSchema

/// Supported: object (properties, required, propertyOrder), array (items, minItems, maxItems), string (enum), integer, number, boolean.
/// JSON objects carry no key order, so properties are generated in `propertyOrder`, else `required`, else alphabetical order.
func dynamicSchema(_ s: [String: Any], name: String) throws -> DynamicGenerationSchema {
    let desc = s["description"] as? String
    if let choices = s["enum"] as? [String] { return DynamicGenerationSchema(name: name, description: desc, anyOf: choices) }
    switch s["type"] as? String ?? "string" {
    case "object":
        let props = s["properties"] as? [String: Any] ?? [:]
        let required = s["required"] as? [String]
        let order = (s["propertyOrder"] as? [String]) ?? required.map { r in r + props.keys.filter { !r.contains($0) }.sorted() } ?? props.keys.sorted()
        var out: [DynamicGenerationSchema.Property] = []
        for k in order {
            guard let p = props[k] as? [String: Any] else { continue }
            out.append(.init(name: k, description: p["description"] as? String, schema: try dynamicSchema(p, name: "\(name)_\(k)"),
                             isOptional: !(required ?? Array(props.keys)).contains(k)))
        }
        return DynamicGenerationSchema(name: s["title"] as? String ?? name, description: desc, properties: out)
    case "array":
        let items = s["items"] as? [String: Any] ?? ["type": "string"]
        return DynamicGenerationSchema(arrayOf: try dynamicSchema(items, name: "\(name)_item"),
                                       minimumElements: num(s["minItems"])?.intValue, maximumElements: num(s["maxItems"])?.intValue)
    case "integer": return DynamicGenerationSchema(type: Int.self)
    case "number": return DynamicGenerationSchema(type: Double.self)
    case "boolean": return DynamicGenerationSchema(type: Bool.self)
    case "string": return DynamicGenerationSchema(type: String.self)
    case let t: throw NSError(domain: "predictd", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported schema type \(t)"])
    }
}
func makeSchema(_ s: [String: Any]) throws -> GenerationSchema {
    try GenerationSchema(root: dynamicSchema(s, name: s["title"] as? String ?? "Output"), dependencies: [])
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

// MARK: profiles and sessions

/// A named system prompt: instructions, example turns (the cached prefix of every request), an optional schema for structured
/// answers, guardrails and default generation options.
struct Profile {
    let name: String, fingerprint: String
    let instructions: String
    let examples: [[String: Any]]
    let schemaJSON: [String: Any]?, schema: GenerationSchema?
    let guardrails: String
    let defaults: [String: Any]
    let model: SystemLanguageModel
    var prefixTokens = -1

    init(_ d: [String: Any]) throws {
        name = d["name"] as? String ?? ""
        guard !name.isEmpty else { throw NSError(domain: "predictd", code: 2, userInfo: [NSLocalizedDescriptionKey: "profile needs a name"]) }
        instructions = d["instructions"] as? String ?? ""
        examples = d["examples"] as? [[String: Any]] ?? []
        schemaJSON = d["schema"] as? [String: Any]
        schema = try schemaJSON.map(makeSchema)
        guardrails = d["guardrails"] as? String ?? "default"
        defaults = d["defaults"] as? [String: Any] ?? [:]
        model = guardrails == "permissive" ? SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
        var def = d; def["pin"] = nil; def["op"] = nil; def["id"] = nil
        fingerprint = jsonText(def)
    }

    func transcript() throws -> Transcript {
        var e: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: instructions))], toolDefinitions: []))]
        for x in examples {
            let prompt = x["prompt"] as? String ?? ""
            if let schema, let resp = x["response"], !(resp is String) {   // a structured example answer
                e.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))], responseFormat: Transcript.ResponseFormat(schema: schema))))
                let content = try GeneratedContent(json: jsonText(resp))
                e.append(.response(Transcript.Response(assetIDs: [], segments: [.structure(Transcript.StructuredSegment(schemaName: schemaJSON?["title"] as? String ?? "Output", content: content))])))
            } else {
                e.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
                e.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: x["response"] as? String ?? ""))])))
            }
        }
        return Transcript(entries: e)
    }

    func summary(pinned: Bool, sessions: [String]) -> [String: Any] {
        ["name": name, "pinned": pinned, "examples": examples.count, "structured": schema != nil, "guardrails": guardrails,
         "defaults": defaults, "prefix_tokens": prefixTokens, "sessions": sessions]
    }
}

/// One LanguageModelSession of a profile. The default session ("") is stateless: its transcript goes back to `base` after every
/// answer, so every request hits the cached prefix. A named session can keep its turns (`keep: true`) for a conversation.
final class Slot: @unchecked Sendable {
    let key: String, profile: String, name: String
    let session: LanguageModelSession
    let base: Transcript
    var usedAt = clock.now
    var fresh = true, conversation = false
    var tail: Task<Void, Never>? = nil     // the last generation queued on this session: generations on one session run in order
    init(profile: Profile, name: String) throws {
        self.profile = profile.name; self.name = name; key = profile.name + "/" + name
        let t = try profile.transcript()
        session = LanguageModelSession(model: profile.model, transcript: t)
        base = session.transcript
    }
}

// MARK: connection

final class Conn: @unchecked Sendable {
    let fd: Int32; let lock = NSLock(); let http: Bool
    init(_ fd: Int32, http: Bool = false) { self.fd = fd; self.http = http }
    func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(10)
        lock.lock(); defer { lock.unlock() }
        if http {   // one request, one response, then close
            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(d)
            out.withUnsafeBytes { p in
                var off = 0
                while off < out.count { let n = write(fd, p.baseAddress! + off, out.count - off); if n <= 0 { break }; off += n }
            }
            close(fd)
            return
        }
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count { let n = write(fd, p.baseAddress! + off, d.count - off); if n <= 0 { return }; off += n }
        }
    }
}

// MARK: engine

struct Stats { var requests = 0, cold = 0, cancelled = 0, errors = 0, guardrail = 0, keepAlives = 0 }

actor Engine {
    var cfg: Config
    let configPath: String
    var profiles: [String: Profile] = [:]
    var slots: [String: Slot] = [:]
    var pinned: String? = nil              // the profile kept warm; nil = the most recently used session
    var cacheOwner: String? = nil          // the session that prewarmed or generated last: the only one with a warm prefix cache
    var lastUsed: String? = nil
    var streams: [String: (id: String, task: Task<Void, Never>)] = [:]
    var inflight = 0, busy = 0
    var lastActivity = clock.now
    var stats = Stats()
    let started = clock.now

    init(cfg: Config, configPath: String) { self.cfg = cfg; self.configPath = configPath }

    func startup() {
        log("availability: \(SystemLanguageModel.default.availability)")
        Task { await self.keepAliveLoop() }
    }

    func slot(_ profile: Profile, _ name: String) throws -> Slot {
        let key = profile.name + "/" + name
        if let s = slots[key] { return s }
        let s = try Slot(profile: profile, name: name)
        slots[key] = s
        stats.cold += 1
        if slots.count > cfg.maxSessions {   // forget the least recently used idle session (never the pinned one)
            let keepKey = pinned.map { $0 + "/" }
            let victim = slots.values.filter { $0.key != key && $0.tail == nil && $0.key != keepKey }.min { $0.usedAt < $1.usedAt }
            if let v = victim { slots[v.key] = nil }
        }
        return s
    }

    // -- the cache: only one session in the whole system keeps a warm prefix. Keep the pinned profile (or the last used session)
    // warm while idle: prewarm it again when another session took the cache, or before the cache expires.
    func keepAliveLoop() async {
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            let idle = ms(clock.now - lastActivity) / 1000
            if cfg.idleExitSec > 0 && idle > cfg.idleExitSec && inflight == 0 { log("idle for \(Int(idle)) s, exiting"); unlink(cfg.socketPath); exit(0) }
            guard cfg.keepAliveSec > 0, idle <= cfg.keepAliveMaxIdleSec, inflight == 0 else { continue }
            var target: Slot? = nil
            if let p = pinned, let prof = profiles[p] { target = try? slot(prof, "") }
            else if let k = lastUsed { target = slots[k] }
            guard let s = target else { continue }
            if cacheOwner != s.key || ms(clock.now - s.usedAt) / 1000 >= cfg.keepAliveSec {
                if !s.conversation { s.session.transcript = s.base }
                s.session.prewarm(); s.usedAt = clock.now; cacheOwner = s.key; stats.keepAlives += 1
            }
        }
    }

    func options(_ r: [String: Any]) -> GenerationOptions {
        let seed: UInt64? = num(r["seed"]).flatMap { $0.int64Value >= 0 ? UInt64($0.int64Value) : nil }
        let sampling = r["sampling"] as? String ?? "greedy"
        let mode: GenerationOptions.SamplingMode = sampling == "topK" ? .random(top: num(r["topK"])?.intValue ?? 40, seed: seed)
            : sampling == "topP" ? .random(probabilityThreshold: num(r["topP"])?.doubleValue ?? 0.9, seed: seed) : .greedy
        let t = num(r["temperature"])?.doubleValue
        return GenerationOptions(samplingMode: mode, temperature: t.flatMap { $0 >= 0 ? $0 : nil }, maximumResponseTokens: num(r["maxTokens"])?.intValue)
    }

    // -- one generation on a session (runs after the session's previous generation)
    func generate(_ req: [String: Any], _ s: Slot, _ prof: Profile, queuedAt: ContinuousClock.Instant) async -> [String: Any] {
        let id = req["id"] ?? ""
        if Task.isCancelled { stats.cancelled += 1; return ["id": id, "ok": false, "error": "cancelled"] }
        let t0 = clock.now
        stats.requests += 1; lastActivity = t0; busy += 1
        defer { busy -= 1; lastActivity = clock.now }
        var r = prof.defaults; for (k, v) in req { r[k] = v }   // request fields override the profile's defaults
        let keep = r["keep"] as? Bool ?? false
        let state = s.fresh ? "cold" : cacheOwner != s.key ? "evicted" : ms(t0 - s.usedAt) / 1000 > cfg.cacheTTLSec ? "expired" : "warm"
        s.fresh = false; cacheOwner = s.key; lastUsed = s.key
        if keep { s.conversation = true }
        let before = s.session.transcript
        var schema: GenerationSchema? = nil
        if let sd = r["schema"] as? [String: Any] {
            do { schema = try makeSchema(sd) } catch { return ["id": id, "ok": false, "error": "schema: \(error.localizedDescription)"] }
        } else if r["schema"] as? Bool == true {
            guard let ps = prof.schema else { return ["id": id, "ok": false, "error": "profile \(prof.name) has no schema"] }
            schema = ps
        }
        var resp: [String: Any] = ["id": id, "ok": true]
        var usage: (Int, Int, Int) = (0, 0, 0)
        do {
            let o = options(r), prompt = r["prompt"] as? String ?? ""
            if let schema {
                let out = try await s.session.respond(to: prompt, schema: schema, includeSchemaInPrompt: r["schemaInPrompt"] as? Bool ?? false, options: o)
                let json = out.content.jsonString
                resp["content"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? json
                usage = (out.usage.input.totalTokenCount, out.usage.input.cachedTokenCount, out.usage.output.totalTokenCount)
            } else {
                let out = try await s.session.respond(to: prompt, options: o)
                resp["text"] = out.content
                usage = (out.usage.input.totalTokenCount, out.usage.input.cachedTokenCount, out.usage.output.totalTokenCount)
            }
            resp["finish"] = hitTokenCap(s.session.transcript) ? "length" : "stop"
        } catch {
            s.session.transcript = keep ? before : s.base; s.usedAt = clock.now
            if Task.isCancelled || error is CancellationError { stats.cancelled += 1; return ["id": id, "ok": false, "error": "cancelled"] }
            let msg = "\(error)"
            if msg.contains("sensitive or unsafe") || msg.lowercased().contains("guardrail") {
                stats.guardrail += 1
                return ["id": id, "ok": false, "error": "guardrail", "detail": String(msg.prefix(200))]
            }
            stats.errors += 1
            return ["id": id, "ok": false, "error": String(msg.prefix(200))]
        }
        let modelMs = ms(clock.now - t0)
        if !keep { s.session.transcript = s.base }
        s.usedAt = clock.now
        resp["tokens"] = ["in": usage.0, "cached": usage.1, "out": usage.2]
        resp["timing"] = ["wait_ms": ms(t0 - queuedAt), "model_ms": modelMs, "total_ms": ms(clock.now - queuedAt)]
        resp["state"] = state
        return resp
    }

    func finished(_ stream: String?, _ id: String, _ s: Slot, _ task: Task<Void, Never>) {
        inflight -= 1
        if let st = stream, streams[st]?.id == id { streams[st] = nil }
        if s.tail == task { s.tail = nil }
    }

    // -- protocol
    func handle(_ conn: Conn, _ req: [String: Any]) async {
        let id = req["id"] as? String ?? String(describing: req["id"] ?? "")
        func fail(_ e: String) { conn.send(["id": id, "ok": false, "error": e]) }
        switch req["op"] as? String ?? "generate" {
        case "ping": conn.send(["id": id, "ok": true, "pong": true])

        case "profile.set":
            do {
                var p = try Profile(req)
                if let old = profiles[p.name], old.fingerprint == p.fingerprint {   // same definition: keep its warm sessions
                    if req["pin"] as? Bool == true { pinned = old.name }
                    conn.send(["id": id, "ok": true, "name": old.name, "changed": false, "prefix_tokens": old.prefixTokens]); return
                }
                p.prefixTokens = (try? await p.model.tokenCount(for: p.transcript())) ?? -1
                for k in slots.keys where k.hasPrefix(p.name + "/") { slots[k] = nil }   // sessions of the old definition
                profiles[p.name] = p
                if req["pin"] as? Bool == true { pinned = p.name }
                if pinned == p.name, let s = try? slot(p, "") { s.session.prewarm(); s.usedAt = clock.now; cacheOwner = s.key }
                conn.send(["id": id, "ok": true, "name": p.name, "changed": true, "prefix_tokens": p.prefixTokens])
            } catch { fail("profile: \(error.localizedDescription)") }

        case "profile.pin":
            if let n = req["name"] as? String { guard profiles[n] != nil else { return fail("unknown_profile") }; pinned = n } else { pinned = nil }
            conn.send(["id": id, "ok": true, "pinned": pinned ?? NSNull()])

        case "profile.drop":
            let n = req["name"] as? String ?? ""
            profiles[n] = nil; if pinned == n { pinned = nil }
            for k in slots.keys where k.hasPrefix(n + "/") { slots[k] = nil }
            conn.send(["id": id, "ok": true])

        case "session.drop":
            slots[(req["profile"] as? String ?? "") + "/" + (req["session"] as? String ?? "")] = nil
            conn.send(["id": id, "ok": true])

        case "generate":
            guard let pn = req["profile"] as? String, let prof = profiles[pn] else { return fail("unknown_profile") }
            let sname = req["session"] as? String ?? ""
            if req["keep"] as? Bool == true && sname.isEmpty { return fail("keep needs a named session") }
            let s: Slot
            do { s = try slot(prof, sname) } catch { return fail("session: \(error.localizedDescription)") }
            let stream = req["stream"] as? String
            if let st = stream { streams[st]?.task.cancel() }   // the newest request on a stream replaces the older one
            let prev = s.tail, queuedAt = clock.now
            inflight += 1
            let task = Task {
                await prev?.value
                let r = await self.generate(req, s, prof, queuedAt: queuedAt)
                conn.send(r)
            }
            s.tail = task
            if let st = stream { streams[st] = (id, task) }
            Task { await task.value; self.finished(stream, id, s, task) }

        case "cancel":
            if let st = req["stream"] as? String { streams[st]?.task.cancel() }
            conn.send(["id": id, "ok": true])

        case "tokens":
            let n = try? await SystemLanguageModel.default.tokenCount(for: req["text"] as? String ?? "")
            conn.send(["id": id, "ok": n != nil, "count": n ?? -1])

        case "spell":
            let words = req["words"] as? [String] ?? [], lang = req["language"] as? String ?? "en"
            let valid = await MainActor.run {
                words.map { NSSpellChecker.shared.checkSpelling(of: $0, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
            }
            conn.send(["id": id, "ok": true, "valid": valid])

        case "stats":
            let list = profiles.values.sorted { $0.name < $1.name }.map { p in
                p.summary(pinned: pinned == p.name, sessions: slots.values.filter { $0.profile == p.name }.map(\.name).sorted())
            }
            conn.send(["id": id, "ok": true, "uptime_s": ms(clock.now - started) / 1000, "requests": stats.requests, "cold": stats.cold,
                       "cancelled": stats.cancelled, "errors": stats.errors, "guardrail": stats.guardrail, "keepalives": stats.keepAlives,
                       "profiles": list, "pinned": pinned ?? NSNull(), "warm": cacheOwner ?? NSNull(), "config": cfg.dict()])

        case "reload":
            var c = Config(); c.apply(loadJSON(configPath)); c.apply(req["config"] as? [String: Any] ?? [:])
            c.socketPath = cfg.socketPath; c.httpPort = cfg.httpPort   // the listeners stay where they are
            cfg = c
            conn.send(["id": id, "ok": true, "config": cfg.dict()])

        case "shutdown": conn.send(["id": id, "ok": true]); unlink(cfg.socketPath); exit(0)
        case let op: fail("unknown op \(op)")
        }
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

// MARK: HTTP (127.0.0.1 only): POST with the same JSON object as the socket protocol (op defaults to generate), GET /health.

func serveHTTP(port: Int, engine: Engine) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0, listen(fd, 32) == 0 else { log("http: cannot listen on 127.0.0.1:\(port) (errno \(errno)), HTTP disabled"); return }
    log("http on 127.0.0.1:\(port)")
    Thread {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { continue }
            Thread { handleHTTP(cfd, engine) }.start()
        }
    }.start()
}

func handleHTTP(_ cfd: Int32, _ engine: Engine) {
    var buf = Data(); var chunk = [UInt8](repeating: 0, count: 65536)
    var headerEnd: Range<Data.Index>? = nil
    while headerEnd == nil {
        let n = read(cfd, &chunk, chunk.count); if n <= 0 { close(cfd); return }
        buf.append(chunk, count: n); headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
        if buf.count > 1 << 20 { close(cfd); return }
    }
    let head = String(decoding: buf[buf.startIndex..<headerEnd!.lowerBound], as: UTF8.self)
    let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
    var length = 0
    for line in head.split(separator: "\r\n").dropFirst() {
        let kv = line.split(separator: ":", maxSplits: 1)
        if kv.count == 2, kv[0].lowercased() == "content-length" { length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
    }
    var body = Data(buf[headerEnd!.upperBound...])
    while body.count < length { let n = read(cfd, &chunk, chunk.count); if n <= 0 { break }; body.append(chunk, count: n) }
    let conn = Conn(cfd, http: true)
    if requestLine.hasPrefix("GET /health") { conn.send(["ok": true]); return }
    guard requestLine.hasPrefix("POST /"), var req = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        conn.send(["ok": false, "error": "POST a JSON object (see docs/ARCHITECTURE.md)"]); return
    }
    if req["op"] == nil { req["op"] = "generate" }
    if req["id"] == nil { req["id"] = UUID().uuidString }
    Task { await engine.handle(conn, req) }
}

@main struct Predictd {
    static func main() async {
        var configPath = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("predictd.json").path } ?? "predictd.json"
        var socket: String? = nil, httpPortArg: Int? = nil
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--config": configPath = args.removeFirst()
            case "--socket": socket = args.removeFirst()
            case "--http-port": httpPortArg = Int(args.removeFirst())
            case "--version": print("predictd 0.2"); return
            default: log("unknown argument \(a)"); exit(1)
            }
        }
        var cfg = Config(); cfg.apply(loadJSON(configPath))
        if let s = socket { cfg.socketPath = s }
        if let hp = httpPortArg { cfg.httpPort = hp }
        let engine = Engine(cfg: cfg, configPath: configPath)
        await engine.startup()
        serve(path: cfg.socketPath, engine: engine)
        if cfg.httpPort > 0 { serveHTTP(port: cfg.httpPort, engine: engine) }
        log("ready on \(cfg.socketPath)")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }
}
