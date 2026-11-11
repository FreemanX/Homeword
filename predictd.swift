// predictd: a model host for Apple's on-device language model (FoundationModels). Mechanism only: it holds named system-prompt
// profiles, keeps one of them warm, and generates plain text or structured output on request. It assumes nothing about what the
// text is for: policies (what to ask, how to use the answer) live in its clients, such as the typing predictor in ghost/.
// Protocol: newline-delimited JSON over a unix socket, the same requests over HTTP on 127.0.0.1, and an OpenAI-compatible chat API
// (/v1/models, /v1/chat/completions) on the same HTTP port. See docs/ARCHITECTURE.md.
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
    var followRecentSec = 30.0   // keep the most recently used session warm this long after its last generation, then the pinned one

    mutating func apply(_ d: [String: Any]) {
        socketPath = d["socketPath"] as? String ?? socketPath; httpPort = num(d["httpPort"])?.intValue ?? httpPort
        keepAliveSec = num(d["keepAliveSec"])?.doubleValue ?? keepAliveSec
        keepAliveMaxIdleSec = num(d["keepAliveMaxIdleSec"])?.doubleValue ?? keepAliveMaxIdleSec
        idleExitSec = num(d["idleExitSec"])?.doubleValue ?? idleExitSec
        cacheTTLSec = num(d["cacheTTLSec"])?.doubleValue ?? cacheTTLSec
        maxSessions = num(d["maxSessions"])?.intValue ?? maxSessions
        followRecentSec = num(d["followRecentSec"])?.doubleValue ?? followRecentSec
    }
    func dict() -> [String: Any] {
        ["socketPath": socketPath, "httpPort": httpPort, "keepAliveSec": keepAliveSec, "keepAliveMaxIdleSec": keepAliveMaxIdleSec,
         "idleExitSec": idleExitSec, "cacheTTLSec": cacheTTLSec, "maxSessions": maxSessions, "followRecentSec": followRecentSec]
    }
}

func loadJSON(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}
/// The config file, then the user's overrides (a file outside the repo; "" = none).
func loadConfig(_ path: String, user: String) -> Config {
    var c = Config(); c.apply(loadJSON(path))
    if !user.isEmpty { c.apply(loadJSON(user)) }
    return c
}
let defaultUserConfig: String = {
    let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
    let dir = base + "/homeword", old = base + "/input-predictor"         // the project's earlier name: moved once
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir) && fm.fileExists(atPath: old) && (try? fm.moveItem(atPath: old, toPath: dir)) == nil {
        return old + "/predictd.json"
    }
    return dir + "/predictd.json"
}()
/// Whether the system's on-device model can be used now: "available", or why not (an OS fact every client needs to explain).
func modelAvailability() -> String {
    switch SystemLanguageModel.default.availability {
    case .available: return "available"
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return "device_not_eligible"
        case .appleIntelligenceNotEnabled: return "apple_intelligence_off"
        case .modelNotReady: return "model_not_ready"
        @unknown default: return "unavailable"
        }
    }
}
func jsonText(_ o: Any) -> String {
    guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "\(o)" }
    return String(decoding: d, as: UTF8.self)
}

// MARK: schemas: a JSON Schema subset -> GenerationSchema

/// Supported: object (properties, required, propertyOrder), array (items, minItems, maxItems), string (enum), integer, number, boolean,
/// anyOf/oneOf, nullable types (["string", "null"]). Anything else (refs, formats) is generated as a string.
/// JSON objects carry no key order, so properties are generated in `propertyOrder`, else `required`, else alphabetical order.
func dynamicSchema(_ s: [String: Any], name: String) throws -> DynamicGenerationSchema {
    let desc = s["description"] as? String
    if let choices = s["enum"] as? [String] { return DynamicGenerationSchema(name: name, description: desc, anyOf: choices) }
    if let alts = (s["anyOf"] ?? s["oneOf"]) as? [[String: Any]] {
        let real = alts.filter { ($0["type"] as? String) != "null" }
        if real.count == 1 { return try dynamicSchema(real[0], name: name) }
        if real.count > 1 {
            var opts: [DynamicGenerationSchema] = []
            for (i, a) in real.enumerated() { opts.append(try dynamicSchema(a, name: "\(name)_\(i)")) }
            return DynamicGenerationSchema(name: name, description: desc, anyOf: opts)
        }
    }
    var type = s["type"] as? String
    if let ts = s["type"] as? [String] { type = ts.first { $0 != "null" } }
    switch type ?? (s["properties"] != nil ? "object" : s["items"] != nil ? "array" : "string") {
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
    default: return DynamicGenerationSchema(type: String.self)
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

/// What went wrong in a generation, from the framework's typed errors (message text as a fallback).
enum Failure { case guardrail, context, refusal, rateLimited, empty, other }
func classify(_ e: Error) -> Failure {
    if let g = e as? LanguageModelSession.GenerationError {
        switch g {
        case .exceededContextWindowSize: return .context
        case .guardrailViolation: return .guardrail
        case .decodingFailure where "\(g)".lowercased().contains("empty response"): return .empty
        case .refusal: return .refusal
        case .rateLimited, .concurrentRequests: return .rateLimited
        default: return .other
        }
    }
    if let l = e as? LanguageModelError {
        switch l {
        case .contextSizeExceeded: return .context
        case .guardrailViolation: return .guardrail
        case .refusal: return .refusal
        case .rateLimited: return .rateLimited
        default: return .other
        }
    }
    let m = "\(e)".lowercased()
    if m.contains("empty response") { return .empty }   // e.g. a token limit too small for a single token of text
    if m.contains("context") && m.contains("exceed") { return .context }
    if m.contains("unsafe") || m.contains("guardrail") { return .guardrail }
    return .other
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
    let catcher: ToolCatcher?              // OpenAI-style sessions: records the tool calls the model makes
    init(profile: Profile, name: String) throws {
        self.profile = profile.name; self.name = name; key = profile.name + "/" + name
        let t = try profile.transcript()
        session = LanguageModelSession(model: profile.model, transcript: t)
        base = session.transcript; catcher = nil
    }
    /// A session of the OpenAI-compatible API: its transcript is replaced by each request's messages.
    init(key: String, session: LanguageModelSession, catcher: ToolCatcher) {
        self.key = key; profile = "openai"; name = key; self.session = session; base = session.transcript; self.catcher = catcher
        conversation = true
    }
}

// MARK: connection

final class Conn: @unchecked Sendable {
    let fd: Int32; let lock = NSLock(); let http: Bool
    init(_ fd: Int32, http: Bool = false) { self.fd = fd; self.http = http }
    private func writeAll(_ d: Data) -> Bool {
        var ok = true
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count { let n = write(fd, p.baseAddress! + off, d.count - off); if n <= 0 { ok = false; return }; off += n }
        }
        return ok
    }
    func send(_ obj: [String: Any]) {
        if http { return respond(status: 200, obj) }   // one request, one response, then close
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(10)
        lock.lock(); defer { lock.unlock() }
        _ = writeAll(d)
    }
    // -- HTTP
    func respond(status: Int, _ obj: Any) {
        var body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        body.append(10)
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "Error"
        lock.lock(); defer { lock.unlock() }
        _ = writeAll(Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
        close(fd)
    }
    func beginStream() {   // server-sent events, as OpenAI streams
        lock.lock(); defer { lock.unlock() }
        _ = writeAll(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
    }
    /// One event; false when the client has gone away.
    @discardableResult func event(_ obj: Any) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return true }
        lock.lock(); defer { lock.unlock() }
        return writeAll(Data("data: ".utf8) + d + Data("\n\n".utf8))
    }
    func endStream() {
        lock.lock(); defer { lock.unlock() }
        _ = writeAll(Data("data: [DONE]\n\n".utf8))
        close(fd)
    }
}

// MARK: engine

struct Stats { var requests = 0, chat = 0, cold = 0, cancelled = 0, errors = 0, guardrail = 0, keepAlives = 0 }

actor Engine {
    var cfg: Config
    let configPath: String, userConfigPath: String
    var profiles: [String: Profile] = [:]
    var slots: [String: Slot] = [:]
    var pinned: String? = nil              // the profile kept warm; nil = the most recently used session
    var cacheOwner: String? = nil          // the session that prewarmed or generated last: the only one with a warm prefix cache
    var lastUsed: String? = nil, recentAt = clock.now   // the session that generated last, and when
    var streams: [String: (id: String, task: Task<Void, Never>)] = [:]
    var inflight = 0, busy = 0
    var lastActivity = clock.now
    var stats = Stats()
    let started = clock.now

    init(cfg: Config, configPath: String, userConfigPath: String) { self.cfg = cfg; self.configPath = configPath; self.userConfigPath = userConfigPath }

    func startup() {
        log("availability: \(SystemLanguageModel.default.availability)")
        Task { await self.keepAliveLoop() }
    }

    func slot(_ profile: Profile, _ name: String) throws -> Slot {
        let key = profile.name + "/" + name
        if let s = slots[key] { return s }
        let s = try Slot(profile: profile, name: name)
        remember(s)
        return s
    }
    func remember(_ s: Slot) {
        slots[s.key] = s
        stats.cold += 1
        if slots.count > cfg.maxSessions {   // forget the least recently used idle session (never the pinned one)
            let keepKey = pinned.map { $0 + "/" }
            let victim = slots.values.filter { $0.key != s.key && $0.tail == nil && $0.key != keepKey }.min { $0.usedAt < $1.usedAt }
            if let v = victim { slots[v.key] = nil }
        }
    }

    // -- the cache: only one session in the whole system keeps a warm prefix. While idle, keep the session that generated last warm
    // for `followRecentSec` (an agent loop between turns), then the pinned profile (or still the last used session if none is
    // pinned): prewarm it again when another session took the cache, or before the cache expires.
    func keepAliveLoop() async {
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            let idle = ms(clock.now - lastActivity) / 1000
            if cfg.idleExitSec > 0 && idle > cfg.idleExitSec && inflight == 0 { log("idle for \(Int(idle)) s, exiting"); unlink(cfg.socketPath); exit(0) }
            guard cfg.keepAliveSec > 0, idle <= cfg.keepAliveMaxIdleSec, inflight == 0 else { continue }
            var target: Slot? = nil
            let recent = lastUsed.flatMap { slots[$0] }
            if let r = recent, ms(clock.now - recentAt) / 1000 < cfg.followRecentSec { target = r }
            else if let p = pinned, let prof = profiles[p] { target = try? slot(prof, "") }
            else { target = recent }
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
            switch classify(error) {
            case .guardrail: stats.guardrail += 1; return ["id": id, "ok": false, "error": "guardrail", "detail": String(msg.prefix(200))]
            case .context: stats.errors += 1; return ["id": id, "ok": false, "error": "context_length_exceeded", "detail": String(msg.prefix(200))]
            default: stats.errors += 1; return ["id": id, "ok": false, "error": String(msg.prefix(200))]
            }
        }
        let modelMs = ms(clock.now - t0)
        if !keep { s.session.transcript = s.base }
        s.usedAt = clock.now; recentAt = clock.now
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
        case "ping": conn.send(["id": id, "ok": true, "pong": true, "model": modelAvailability()])

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

        case "prewarm":   // warm a profile's default session now and keep it warm as the most recently used one (a client knows
                          // what comes next, e.g. the user switched to another kind of text); skipped while a generation runs
            guard let n = req["profile"] as? String, let p = profiles[n] else { return fail("unknown_profile") }
            guard inflight == 0 else { conn.send(["id": id, "ok": true, "prewarmed": false]); return }
            guard let s = try? slot(p, "") else { return fail("no session") }
            if !s.conversation { s.session.transcript = s.base }
            s.session.prewarm(); s.usedAt = clock.now; cacheOwner = s.key; lastUsed = s.key; recentAt = clock.now
            stats.keepAlives += 1
            conn.send(["id": id, "ok": true, "prewarmed": true])

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
            conn.send(["id": id, "ok": true, "uptime_s": ms(clock.now - started) / 1000, "requests": stats.requests, "chat": stats.chat, "cold": stats.cold,
                       "cancelled": stats.cancelled, "errors": stats.errors, "guardrail": stats.guardrail, "keepalives": stats.keepAlives,
                       "profiles": list, "pinned": pinned ?? NSNull(), "warm": cacheOwner ?? NSNull(), "config": cfg.dict()])

        case "reload":
            var c = loadConfig(configPath, user: userConfigPath); c.apply(req["config"] as? [String: Any] ?? [:])
            c.socketPath = cfg.socketPath; c.httpPort = cfg.httpPort   // the listeners stay where they are
            cfg = c
            conn.send(["id": id, "ok": true, "config": cfg.dict()])

        case "shutdown": conn.send(["id": id, "ok": true]); unlink(cfg.socketPath); exit(0)
        case let op: fail("unknown op \(op)")
        }
    }
}

// MARK: OpenAI-compatible API (GET /v1/models, POST /v1/chat/completions) on the HTTP port
//
// A translation onto the same mechanism, so agent harnesses can use the on-device model as an OpenAI endpoint. Each request's
// messages become the session transcript: system/developer -> instructions (with the tools as tool definitions), earlier turns ->
// prompt, response, tool-call and tool-output entries; the last user message (or nothing, after tool results) is the prompt.
// Tools are not run here: a client tool records the model's call and stops the generation, and the call goes back to the caller,
// which runs it and sends the result in the next request, as with OpenAI. One session per model and tool set: consecutive turns
// of a conversation extend its transcript, so they hit the prefix cache.

final class ToolCatcher: @unchecked Sendable {
    private let lock = NSLock(); private var calls: [(name: String, args: String)] = []
    func add(_ name: String, _ args: String) { lock.lock(); calls.append((name, args)); lock.unlock() }
    func take() -> [(name: String, args: String)] { lock.lock(); defer { calls = []; lock.unlock() }; return calls }
}
struct ToolCallCaught: Error {}
struct ClientTool: Tool {
    let name: String, description: String, parameters: GenerationSchema, catcher: ToolCatcher
    func call(arguments: GeneratedContent) async throws -> String { catcher.add(name, arguments.jsonString); throw ToolCallCaught() }
}

struct APIError: Error {
    let status: Int, message: String, code: String?
    var body: [String: Any] { ["error": ["message": message, "type": status >= 500 ? "server_error" : "invalid_request_error", "param": NSNull(), "code": code.map { $0 as Any } ?? NSNull()]] }
}

/// The text of an OpenAI message content: a string, or an array of parts of which only text is supported.
func contentText(_ c: Any?) throws -> String {
    if c == nil || c is NSNull { return "" }
    if let s = c as? String { return s }
    if let parts = c as? [[String: Any]] {
        var out: [String] = []
        for p in parts {
            guard ["text", "input_text"].contains(p["type"] as? String ?? "text") else { throw APIError(status: 400, message: "only text content is supported", code: "unsupported_content") }
            out.append(p["text"] as? String ?? "")
        }
        return out.joined(separator: "\n")
    }
    throw APIError(status: 400, message: "content must be a string or an array of text parts", code: nil)
}

struct ChatRequest {
    var model = "", key = ""
    var guardrails = "default"
    var specs: [(name: String, description: String, schema: GenerationSchema)] = []
    var entries: [Transcript.Entry] = []
    var prompt = ""
    var options = GenerationOptions()
    var schema: GenerationSchema? = nil
    var stop: [String] = []
    var stream = false, includeUsage = false
}

func firstStop(_ text: String, _ stops: [String]) -> String.Index? {
    stops.compactMap { $0.isEmpty ? nil : text.range(of: $0)?.lowerBound }.min()
}

extension Engine {
    static let baseModels = ["apple-on-device": "default", "apple-on-device-permissive": "permissive"]

    func openai(_ method: String, _ path: String, _ body: Data, _ conn: Conn) {
        lastActivity = clock.now
        switch (method, path) {
        case ("GET", "/v1/models"): conn.respond(status: 200, ["object": "list", "data": modelList()])
        case ("GET", _) where path.hasPrefix("/v1/models/"):
            let id = String(path.dropFirst("/v1/models/".count))
            if let m = modelList().first(where: { $0["id"] as? String == id }) { conn.respond(status: 200, m) }
            else { conn.respond(status: 404, APIError(status: 404, message: "model \(id) not found", code: "model_not_found").body) }
        case ("POST", "/v1/chat/completions"):
            guard let b = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return conn.respond(status: 400, APIError(status: 400, message: "the body must be a JSON object", code: nil).body)
            }
            chat(b, conn)
        default:
            conn.respond(status: 404, APIError(status: 404, message: "\(method) \(path) is not supported: use GET /v1/models or POST /v1/chat/completions", code: "not_found").body)
        }
    }

    func modelList() -> [[String: Any]] {
        let ctx = SystemLanguageModel.default.contextSize
        return Engine.baseModels.keys.sorted().map { ["id": $0, "object": "model", "created": 0, "owned_by": "apple", "context_window": ctx] }
            + profiles.keys.sorted().map { ["id": $0, "object": "model", "created": 0, "owned_by": "predictd-profile", "context_window": ctx] }
    }

    func parseChat(_ b: [String: Any]) throws -> ChatRequest {
        var r = ChatRequest()
        r.model = b["model"] as? String ?? "apple-on-device"
        let prof = profiles[r.model]
        guard prof != nil || Engine.baseModels[r.model] != nil else {
            throw APIError(status: 404, message: "model \(r.model) not found: GET /v1/models lists them", code: "model_not_found")
        }
        r.guardrails = prof?.guardrails ?? Engine.baseModels[r.model]!
        if let n = num(b["n"])?.intValue, n != 1 { throw APIError(status: 400, message: "only n = 1 is supported", code: nil) }
        guard let msgs = b["messages"] as? [[String: Any]], !msgs.isEmpty else { throw APIError(status: 400, message: "messages is required", code: nil) }

        // tools: OpenAI function definitions -> client tools (a forced tool_choice keeps only that function)
        var forced: String? = nil
        if let c = b["tool_choice"] as? [String: Any], let f = c["function"] as? [String: Any] { forced = f["name"] as? String }
        for t in b["tools"] as? [[String: Any]] ?? [] {
            guard (t["type"] as? String ?? "function") == "function", let f = t["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            if let fn = forced, fn != name { continue }
            var params = f["parameters"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
            params["title"] = name + "_arguments"
            do { r.specs.append((name, f["description"] as? String ?? "", try makeSchema(params))) }
            catch { throw APIError(status: 400, message: "tool \(name): \(error.localizedDescription)", code: "invalid_tool_schema") }
        }

        // messages -> transcript entries
        var system: [String] = [], turns: [Transcript.Entry] = [], user: [String] = [], names: [String: String] = [:]
        func flushUser() {
            if !user.isEmpty { turns.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: user.joined(separator: "\n\n")))]))); user = [] }
        }
        for m in msgs {
            switch m["role"] as? String ?? "" {
            case "system", "developer": system.append(try contentText(m["content"]))
            case "user": user.append(try contentText(m["content"]))
            case "assistant":
                flushUser()
                let text = try contentText(m["content"])
                if !text.isEmpty { turns.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: text))]))) }
                if let calls = m["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    var tc: [Transcript.ToolCall] = []
                    for c in calls {
                        let f = c["function"] as? [String: Any] ?? [:]
                        let id = c["id"] as? String ?? UUID().uuidString, name = f["name"] as? String ?? ""
                        names[id] = name
                        let args = (try? GeneratedContent(json: f["arguments"] as? String ?? "{}")) ?? (try! GeneratedContent(json: "{}"))
                        tc.append(Transcript.ToolCall(id: id, toolName: name, arguments: args))
                    }
                    turns.append(.toolCalls(Transcript.ToolCalls(tc)))
                }
            case "tool":
                flushUser()
                let id = m["tool_call_id"] as? String ?? ""
                turns.append(.toolOutput(Transcript.ToolOutput(id: id, toolName: names[id] ?? m["name"] as? String ?? "",
                                                               segments: [.text(Transcript.TextSegment(content: try contentText(m["content"])))])))
            case let role: throw APIError(status: 400, message: "unsupported role \(role)", code: nil)
            }
        }
        if !user.isEmpty { r.prompt = user.joined(separator: "\n\n") }                   // answer the last user message
        else if case .toolOutput = turns.last { r.prompt = "" }                           // continue after tool results
        else { throw APIError(status: 400, message: "the last message must come from the user or a tool", code: nil) }

        // response format
        var instructions = ([prof?.instructions ?? ""] + system).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if let rf = b["response_format"] as? [String: Any] {
            switch rf["type"] as? String {
            case "json_schema":
                let js = rf["json_schema"] as? [String: Any] ?? [:]
                var sc = js["schema"] as? [String: Any] ?? ["type": "object"]
                sc["title"] = sc["title"] ?? js["name"] ?? "Output"
                do { r.schema = try makeSchema(sc) } catch { throw APIError(status: 400, message: "response_format: \(error.localizedDescription)", code: nil) }
            case "json_object": instructions += (instructions.isEmpty ? "" : "\n\n") + "Respond with a single JSON object."
            default: break
            }
        }
        if !instructions.isEmpty || !r.specs.isEmpty {
            r.entries.append(.instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: r.specs.map { Transcript.ToolDefinition(name: $0.name, description: $0.description, parameters: $0.schema) })))
        }
        if let prof { r.entries += Array(try prof.transcript()).dropFirst() }             // a profile's example turns
        r.entries += turns

        // options
        let temp = num(b["temperature"])?.doubleValue, topP = num(b["top_p"])?.doubleValue
        let seed: UInt64? = num(b["seed"]).map { UInt64(max(0, $0.int64Value)) }
        var mode: GenerationOptions.SamplingMode? = nil
        if temp == 0 { mode = .greedy }
        else if let p = topP, p < 1 { mode = .random(probabilityThreshold: p, seed: seed) }
        else if seed != nil { mode = .random(probabilityThreshold: 1.0, seed: seed) }
        var toolMode: GenerationOptions.ToolCallingMode? = nil
        if !r.specs.isEmpty {
            switch b["tool_choice"] as? String { case "none": toolMode = .disallowed; case "required": toolMode = .required; default: toolMode = forced != nil ? .required : .allowed }
        }
        r.options = GenerationOptions(samplingMode: mode, temperature: temp == 0 ? nil : temp,
                                      maximumResponseTokens: num(b["max_completion_tokens"])?.intValue ?? num(b["max_tokens"])?.intValue, toolCallingMode: toolMode)
        // reasoning_effort is accepted and ignored: the on-device model has no reasoning mode (asking for one fails the request)
        if let st = b["stop"] as? String { r.stop = [st] } else { r.stop = b["stop"] as? [String] ?? [] }
        r.stream = b["stream"] as? Bool ?? false
        r.includeUsage = (b["stream_options"] as? [String: Any])?["include_usage"] as? Bool ?? false
        // one session per model (and profile definition: its guardrails fix the session's model) and tool set
        r.key = "openai/\(r.model)/\(prof?.fingerprint.hashValue ?? 0)/\(jsonText((b["tools"] ?? []) as Any).hashValue)/\(forced ?? "")"
        return r
    }

    func chat(_ b: [String: Any], _ conn: Conn) {
        let r: ChatRequest
        do { r = try parseChat(b) }
        catch let e as APIError { return conn.respond(status: e.status, e.body) }
        catch { return conn.respond(status: 400, APIError(status: 400, message: "\(error)", code: nil).body) }
        let s: Slot
        if let old = slots[r.key] { s = old }
        else {
            let catcher = ToolCatcher()
            let tools: [any Tool] = r.specs.map { ClientTool(name: $0.name, description: $0.description, parameters: $0.schema, catcher: catcher) }
            let model = r.guardrails == "permissive" ? SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
            s = Slot(key: r.key, session: LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: r.entries)), catcher: catcher)
            remember(s)
        }
        let prev = s.tail
        inflight += 1
        let task = Task { await prev?.value; await self.runChat(r, s, conn) }
        s.tail = task
        Task { await task.value; self.finished(nil, "", s, task) }
    }

    func runChat(_ r: ChatRequest, _ s: Slot, _ conn: Conn) async {
        let t0 = clock.now
        stats.requests += 1; stats.chat += 1; lastActivity = t0; busy += 1
        defer { busy -= 1; lastActivity = clock.now }
        s.fresh = false; cacheOwner = s.key; lastUsed = s.key
        s.session.transcript = Transcript(entries: r.entries)
        _ = s.catcher?.take()
        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        let created = Int(Date().timeIntervalSince1970)
        func chunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
            ["id": id, "object": "chat.completion.chunk", "created": created, "model": r.model,
             "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull(), "logprobs": NSNull()]]]
        }
        var text = "", finish = "stop", usage = (0, 0, 0), stopped = false, calls: [[String: Any]] = []
        var failure: APIError? = nil
        if r.stream { conn.beginStream(); conn.event(chunk(["role": "assistant", "content": ""])) }
        do {
            if let schema = r.schema {
                let out = try await s.session.respond(to: r.prompt, schema: schema, includeSchemaInPrompt: true, options: r.options)
                text = out.content.jsonString
                usage = (out.usage.input.totalTokenCount, out.usage.input.cachedTokenCount, out.usage.output.totalTokenCount)
                if r.stream { conn.event(chunk(["content": text])) }
            } else if r.stream {
                var sent = ""
                for try await snap in s.session.streamResponse(to: r.prompt, options: r.options) {
                    var full = snap.content
                    if let cut = firstStop(full, r.stop) { full = String(full[..<cut]); stopped = true }
                    if full.hasPrefix(sent), full.count > sent.count {
                        if !conn.event(chunk(["content": String(full.dropFirst(sent.count))])) { stopped = true }   // client went away
                        sent = full
                    }
                    usage = (snap.usage.input.totalTokenCount, snap.usage.input.cachedTokenCount, snap.usage.output.totalTokenCount)
                    if stopped { break }
                }
                text = sent
            } else {
                let out = try await s.session.respond(to: r.prompt, options: r.options)
                text = out.content
                usage = (out.usage.input.totalTokenCount, out.usage.input.cachedTokenCount, out.usage.output.totalTokenCount)
                if let cut = firstStop(text, r.stop) { text = String(text[..<cut]); stopped = true }
            }
            if !stopped && hitTokenCap(s.session.transcript) { finish = "length" }
        } catch {
            let caught = s.catcher?.take() ?? []
            let msg = "\(error)"
            if !caught.isEmpty {   // the model called tools: hand the calls back to the caller
                finish = "tool_calls"
                calls = caught.enumerated().map { i, c in
                    ["index": i, "id": "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24), "type": "function",
                     "function": ["name": c.name, "arguments": c.args]]
                }
                usage.0 = (try? await SystemLanguageModel.default.tokenCount(for: r.entries)) ?? 0
            } else {
                switch classify(error) {
                case .guardrail, .refusal: stats.guardrail += 1; finish = "content_filter"; text = ""
                case .empty: finish = "length"; text = ""
                case .context:
                    stats.errors += 1
                    failure = APIError(status: 400, message: "the conversation does not fit the model's context window of \(SystemLanguageModel.default.contextSize) tokens", code: "context_length_exceeded")
                case .rateLimited: stats.errors += 1; failure = APIError(status: 429, message: String(msg.prefix(300)), code: "rate_limit_exceeded")
                case .other: stats.errors += 1; failure = APIError(status: 500, message: String(msg.prefix(300)), code: nil)
                }
            }
        }
        s.usedAt = clock.now; recentAt = clock.now
        let u: [String: Any] = ["prompt_tokens": usage.0, "completion_tokens": usage.2, "total_tokens": usage.0 + usage.2,
                                "prompt_tokens_details": ["cached_tokens": usage.1]]
        if r.stream {
            if let f = failure { conn.event(f.body) }
            else {
                if !calls.isEmpty { conn.event(chunk(["tool_calls": calls])) }
                conn.event(chunk([:], finish: finish))
                if r.includeUsage { conn.event(["id": id, "object": "chat.completion.chunk", "created": created, "model": r.model, "choices": [Any](), "usage": u]) }
            }
            return conn.endStream()
        }
        if let f = failure { return conn.respond(status: f.status, f.body) }
        var message: [String: Any] = ["role": "assistant", "content": calls.isEmpty || !text.isEmpty ? text : NSNull()]
        if !calls.isEmpty { message["tool_calls"] = calls.map { c in c.filter { $0.key != "index" } } }
        conn.respond(status: 200, ["id": id, "object": "chat.completion", "created": created, "model": r.model,
                                   "choices": [["index": 0, "message": message, "finish_reason": finish, "logprobs": NSNull()]], "usage": u])
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

// MARK: HTTP (127.0.0.1 only): POST with the same JSON object as the socket protocol (op defaults to generate), GET /health
// ({"ok", "service": "predictd", "version", "pid"}).

let PREDICTD_VERSION = "0.2"

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
    let parts = requestLine.split(separator: " ")
    let method = parts.first.map(String.init) ?? "", path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
    if path.hasPrefix("/v1/") { Task { await engine.openai(method, path, body, conn) }; return }
    if requestLine.hasPrefix("GET /health") { conn.send(["ok": true, "service": "predictd", "version": PREDICTD_VERSION, "pid": Int(getpid())]); return }
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
        var socket: String? = nil, httpPortArg: Int? = nil, userConfig = defaultUserConfig
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--config": configPath = args.removeFirst()
            case "--user-config": userConfig = args.removeFirst()      // "" = ignore the user's overrides (benchmarks)
            case "--socket": socket = args.removeFirst()
            case "--http-port": httpPortArg = Int(args.removeFirst())
            case "--version": print("predictd \(PREDICTD_VERSION)"); return
            default: log("unknown argument \(a)"); exit(1)
            }
        }
        var cfg = loadConfig(configPath, user: userConfig)
        if let s = socket { cfg.socketPath = s }
        if let hp = httpPortArg { cfg.httpPort = hp }
        let engine = Engine(cfg: cfg, configPath: configPath, userConfigPath: userConfig)
        await engine.startup()
        serve(path: cfg.socketPath, engine: engine)
        if cfg.httpPort > 0 { serveHTTP(port: cfg.httpPort, engine: engine) }
        log("ready on \(cfg.socketPath)")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }
}
