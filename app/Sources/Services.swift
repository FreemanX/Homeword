// Preferences, and the local services the app talks to: the policy server (`pred serve`, 127.0.0.1:47321) for predictions and
// proofreading, which in turn uses predictd. The app holds no prediction or proofreading logic itself.
import AppKit

enum Pref {
    static let predictions = "predictionsEnabled", proofreading = "proofreadingEnabled", minChars = "minChars"
    static let position = "popupPosition", excluded = "excludedApps", chromium = "chromiumSupport", server = "serverURL"

    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable",
        "io.alacritty", "com.github.wez.wezterm", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ].joined(separator: "\n")

    static func register() {
        UserDefaults.standard.register(defaults: [
            predictions: true, proofreading: true, minChars: 3, position: "below", excluded: defaultExcluded,
            chromium: true, server: "http://127.0.0.1:47321",
        ])
    }
    static var d: UserDefaults { .standard }
    static var excludedApps: Set<String> {
        Set((d.string(forKey: excluded) ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

/// The label the typing policy gets for an app: the prompt's examples are keyed on these.
func appLabel(_ bundle: String) -> String {
    let mail = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.google.Chrome.app.gmail"]
    let chat = ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "net.whatsapp.WhatsApp",
                "ru.keepcoder.Telegram", "com.facebook.archon", "com.hnc.Discord", "us.zoom.xos", "com.facebook.Workplace"]
    let code = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.intellij", "dev.zed.Zed",
                "com.sublimetext.4", "com.panic.Nova"]
    if mail.contains(bundle) { return "mail" }
    if chat.contains(bundle) { return "chat" }
    if code.contains(bundle) { return "code" }
    return "notes"
}

let chromiumApps: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
                                 "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.chromium.Chromium"]

final class Services {
    static let shared = Services()
    enum State: String { case unknown = "checking…", running = "running", starting = "starting…", unavailable = "not running" }
    private(set) var state: State = .unknown { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var lastStart = Date.distantPast

    var base: String { Pref.d.string(forKey: Pref.server) ?? "http://127.0.0.1:47321" }
    /// The repo this app was built from (bin/pred starts predictd and the policy server).
    var repo: String? { Bundle.main.object(forInfoDictionaryKey: "IPRepoPath") as? String }

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
                    self.state = .unavailable
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

    func check() {
        guard let url = URL(string: base + "/health") else { return }
        session.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { data, _, _ in
            let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ok"] as? Bool ?? false
            DispatchQueue.main.async {
                if ok { self.state = .running } else { self.state = .unavailable; self.start() }
            }
        }.resume()
    }

    /// Run `bin/pred start` (predictd + the policy server). At most once every 10 s; they exit after 30 idle minutes.
    func start(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastStart) > 10, let repo else { return }
        lastStart = Date()
        state = .starting
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", repo + "/bin/pred", "start"]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in DispatchQueue.main.async { self.check() } }
        do { try p.run() } catch { state = .unavailable }
    }
}
