// Preferences, and the local engine the app talks to: the HTTP server of the typing and proofreading policies (ghostd,
// 127.0.0.1:<port>) on top of predictd, which hosts Apple's on-device model and also serves the OpenAI-compatible API. The app holds
// no prediction or proofreading logic itself. Users see all of it as one "Engine".
import AppKit

enum Pref {
    static let predictions = "predictionsEnabled", proofreading = "proofreadingEnabled", minChars = "minChars"
    static let position = "popupPosition", chromium = "chromiumSupport", appStyles = "appStyles"
    static let proofreadKey = "proofreadShortcut", rewriteKey = "rewriteShortcut", stoppedByUser = "engineStoppedByUser"

    static func register() {
        UserDefaults.standard.register(defaults: [
            predictions: true, proofreading: true, minChars: 3, position: "below", chromium: true,
            proofreadKey: Hotkey.defaultProofread.dict, rewriteKey: Hotkey.defaultRewrite.dict,
        ])
    }
    static var d: UserDefaults { .standard }

    /// First launch under the new name: take over the settings and metrics of the app's first version (InputPredictor).
    static func migrate() {
        guard !d.bool(forKey: "migratedFromInputPredictor") else { return }
        d.set(true, forKey: "migratedFromInputPredictor")
        if let old = UserDefaults(suiteName: "dev.inputpredictor.menubar") {
            for k in [predictions, proofreading, minChars, position, chromium] where old.object(forKey: k) != nil {
                d.set(old.object(forKey: k), forKey: k)
            }
            let excluded = (old.string(forKey: "excludedApps") ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && Style.builtIn[$0] != "off" }
            var choices = Style.userChoices
            for b in excluded { choices[b] = "off" }
            Style.userChoices = choices
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent("InputPredictor"), to = support.appendingPathComponent("Homeword")
        if FileManager.default.fileExists(atPath: from.path) && !FileManager.default.fileExists(atPath: to.path) {
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }
}

/// A release build carries the engine inside the app (Resources/engine: ghostd, predictd and their data; app/release.sh). It is not notarized, so a downloaded copy
/// has every file quarantined: once the user allowed the app (Open Anyway), its own helpers are still blocked (killed at launch)
/// until the quarantine mark is removed from them, which the app may do for files in its own bundle.
enum Bundled {
    static func prepare() {
        guard let res = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: res.appendingPathComponent("engine").path) else { return }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {        // opened from the download: a read-only copy
            let a = NSAlert()
            a.messageText = "Move Homeword to your Applications folder"
            a.informativeText = "macOS runs Homeword from a temporary read-only copy until it is in Applications. Drag it there from "
                + "the disk image, then open it again."
            a.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        let engine = res.appendingPathComponent("engine")
        for case let rel as String in FileManager.default.enumerator(atPath: engine.path) ?? .init() {
            removexattr(engine.appendingPathComponent(rel).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}

let chromiumApps: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
                                 "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.chromium.Chromium"]

/// The engine's settings that live outside the app, shared with `pred`: ~/.config/homeword/config.json (the policies'
/// knobs, `serverPort`, `words`) and predictd.json (`httpPort`, the OpenAI-compatible API). Missing = the shipped defaults.
enum EngineConfig {
    static let dir: URL = {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let dir = base.appendingPathComponent("homeword"), old = base.appendingPathComponent("input-predictor")   // earlier name
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) && fm.fileExists(atPath: old.path) && (try? fm.moveItem(at: old, to: dir)) == nil {
            return old
        }
        return dir
    }()
    static func read(_ file: String) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(file)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    static func set(_ file: String, _ key: String, _ value: Any?) throws {
        var o = read(file)
        o[key] = value
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(file), options: .atomic)
    }
    static var port: Int { read("config.json")["serverPort"] as? Int ?? 47321 }
    static var apiPort: Int { read("predictd.json")["httpPort"] as? Int ?? 47320 }
}

final class Services {
    static let shared = Services()
    enum State: String { case unknown = "Checking…", running = "Running", starting = "Starting…", stopping = "Stopping…", stopped = "Stopped" }
    private(set) var state: State = .unknown { didSet { if state != oldValue { onChange?() } } }
    private(set) var modelUp = false
    /// The on-device model: "available", or why not (device_not_eligible, apple_intelligence_off, model_not_ready); nil = unknown.
    private(set) var availability: String?
    /// What to tell the user when the model cannot be used, else nil.
    var availabilityProblem: String? {
        switch availability {
        case nil, "available": return nil
        case "apple_intelligence_off": return "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri."
        case "model_not_ready": return "Apple's on-device model is still downloading. Suggestions start when it is ready."
        case "device_not_eligible": return "This Mac can't run Apple Intelligence (it needs Apple silicon, and a supported language and region)."
        default: return "Apple's on-device model is not available on this Mac right now."
        }
    }
    var onChange: (() -> Void)?
    private var lastStart = Date.distantPast
    private(set) var port = EngineConfig.port

    var base: String { "http://127.0.0.1:\(port)" }
    /// Stopped with the Stop button: no automatic restarts until Start.
    var stoppedByUser: Bool {
        get { Pref.d.bool(forKey: Pref.stoppedByUser) }
        set { Pref.d.set(newValue, forKey: Pref.stoppedByUser); onChange?() }
    }
    /// The engine's server: inside the app (a release build: Resources/engine/ghostd), else in the repo this app was built from
    /// (a development build, after ./build.sh). It starts predictd next to it.
    var ghostd: String? {
        let repo = Bundle.main.object(forInfoDictionaryKey: "HomewordRepoPath") as? String ?? ""
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("engine/ghostd").path, repo.isEmpty ? nil : repo + "/ghostd"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 130
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c)
    }()

    /// POST a JSON object; the completion runs on the main thread with the decoded answer or an error message.
    @discardableResult
    func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 10, done: @escaping ([String: Any]?, String?) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: base + path), let data = try? JSONSerialization.data(withJSONObject: body) else { done(nil, "bad request"); return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let task = session.dataTask(with: req) { data, _, error in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                if let error = error as NSError?, error.code == NSURLErrorCancelled { return done(nil, "cancelled") }
                if obj == nil {
                    if self.state == .running { self.state = .stopped }
                    self.start()
                    return done(nil, error?.localizedDescription ?? "no answer")
                }
                self.state = .running
                done(obj, nil)
            }
        }
        task.resume()
        return task
    }

    /// GET a JSON object (completion on the main thread).
    func get(_ path: String, timeout: TimeInterval = 5, done: @escaping ([String: Any]?, String?) -> Void) {
        guard let url = URL(string: base + path) else { return done(nil, "bad URL") }
        session.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { data, _, error in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(obj, obj == nil ? (error?.localizedDescription ?? "no answer") : nil) }
        }.resume()
    }

    /// Ask the engine how it is; start it if it is down (unless the user stopped it).
    func check(autostart: Bool = true) {
        port = EngineConfig.port
        get("/health", timeout: 2) { r, _ in
            let ok = r?["ok"] as? Bool ?? false
            self.modelUp = r?["model"] as? Bool ?? false
            self.availability = r?["availability"] as? String
            if ok {
                self.state = .running
            } else if self.state != .starting && self.state != .stopping {
                self.state = .stopped
                if autostart { self.start() }
            }
            self.onChange?()
        }
    }

    /// Is the OpenAI-compatible API answering?
    func checkAPI(done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(EngineConfig.apiPort)/v1/models") else { return done(false) }
        session.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { data, _, _ in
            let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["data"] != nil
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    /// Start the engine (ghostd, which starts predictd). Automatic starts (a request found it down) happen at most every 10 s and
    /// never after the user pressed Stop; `force` (the Start button) always runs.
    func start(force: Bool = false) {
        if force { stoppedByUser = false }
        guard force || (!stoppedByUser && Date().timeIntervalSince(lastStart) > 10), state != .starting else { return }
        lastStart = Date()
        launch()
    }

    func stop() {
        stoppedByUser = true
        shutdown(port) { self.state = .stopped }
    }

    func restart() {
        stoppedByUser = false
        shutdown(port) { self.lastStart = Date(); self.launch() }
    }

    /// Run ghostd in the background (it outlives the app and exits after 30 idle minutes), then wait until it answers. Nothing to
    /// run when an engine already answers (started by `pred`, pi or an earlier run of the app); a second ghostd on a taken port
    /// would exit at once anyway.
    private func launch() {
        guard ghostd != nil else { state = .stopped; return }
        state = .starting
        port = EngineConfig.port
        get("/health", timeout: 2) { r, _ in
            if r?["ok"] as? Bool == true {
                self.state = .unknown
                self.check(autostart: false)
            } else {
                self.spawn()
            }
        }
    }

    private func spawn() {
        guard let exe = ghostd else { state = .stopped; return }
        let logPath = "/tmp/ghostd-\(getuid()).log"
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--port", String(port)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        do { try p.run() } catch { state = .stopped; return }
        waitUp(p, until: Date().addingTimeInterval(60))
    }

    private func waitUp(_ p: Process, until: Date) {
        get("/health", timeout: 1) { r, _ in
            // up, or it failed; exit status 0 = another engine took the port first (it is still starting): keep waiting for it
            if r?["ok"] as? Bool == true || (!p.isRunning && p.terminationStatus != 0) || Date() > until {
                self.state = .unknown
                self.check(autostart: false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.waitUp(p, until: until) }
            }
        }
    }

    /// Stop the engine on `port` (ghostd and predictd); `then` runs on the main thread once it is gone.
    private func shutdown(_ port: Int, then: @escaping () -> Void) {
        state = .stopping
        guard let url = URL(string: "http://127.0.0.1:\(port)/shutdown") else { return then() }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"predictd": true}"#.utf8)
        session.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.port = EngineConfig.port; then() }   // let it exit
        }.resume()
    }

    /// Save new ports for the engine and the OpenAI-compatible API (outside the app, so `pred` uses them too), then restart the
    /// engine on them. The old engine is stopped on the old port first.
    func setPorts(engine: Int, api: Int) throws {
        let oldPort = port
        try EngineConfig.set("config.json", "serverPort", engine == 47321 ? nil : engine)
        try EngineConfig.set("predictd.json", "httpPort", api == 47320 ? nil : api)
        stoppedByUser = false
        shutdown(oldPort) { self.lastStart = Date(); self.launch() }
    }
}
