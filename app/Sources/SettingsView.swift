// The Settings window: General (prediction, proofreading, shortcuts), Apps (a writing style per app, or off), Prompts
// (PromptsView.swift), Statistics (from the metrics file) and Engine (the local service, the OpenAI-compatible API, permissions).
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsNav: ObservableObject {
    @Published var tab = "general"
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsNav

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralTab().tabItem { Label(L("General"), systemImage: "gearshape") }.tag("general")
            AppsTab().tabItem { Label(L("Apps"), systemImage: "square.grid.2x2") }.tag("apps")
            PromptsView().tabItem { Label(L("Prompts"), systemImage: "text.bubble") }.tag("prompts")
            StatsTab().tabItem { Label(L("Statistics"), systemImage: "chart.bar") }.tag("stats")
            EngineTab().tabItem { Label(L("Engine"), systemImage: "cpu") }.tag("engine")
        }
        .padding(12)
        .frame(width: 880, height: 660)
    }
}

/// A colored status dot: green = running, yellow = in between, red = stopped.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 10, height: 10) }
}

// MARK: General

/// Words to suggest: an engine setting (GET/POST /settings), so pred and the integrations use it too.
final class WordsModel: ObservableObject {
    @Published var words = 5
    @Published var available = false
    init() { load() }
    func load(tries: Int = 30) {
        Services.shared.get("/settings") { r, _ in
            if let w = r?["words"] as? Int { self.words = w; self.available = true; return }
            self.available = false
            if tries > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.load(tries: tries - 1) } }   // the engine is starting
        }
    }
    /// The latency effect against the default, from the measured cost of an output token (docs/PERFORMANCE.md): the output cap
    /// is words + 1 per 5 words (ghost/Policy.swift tokensForWords), ~16 ms per token.
    var cost: String {
        let tokens = { (w: Int) in w + (w + 4) / 5 }
        let ms = (tokens(words) - tokens(5)) * 16
        if ms == 0 { return L("The default. Each word more or fewer changes every suggestion's time by up to about 20 ms.") }
        return ms > 0 ? L("Up to about %d ms slower per suggestion than the default (5 words); longer suggestions are right all the way "
                          + "less often.", ms)
            : L("Up to about %d ms faster per suggestion than the default (5 words).", -ms)
    }

    func set(_ w: Int) {
        let w = min(max(w, 1), 10)
        words = w
        Services.shared.post("/settings", ["words": w]) { r, _ in
            if let w = r?["words"] as? Int { self.words = w }
        }
    }
}

/// The languages the user writes in: an engine setting (GET/POST /settings: `languages`, and `supported`, the model's), so pred and
/// the integrations use it too. The engine detects which of them a text is in, among those only.
final class LanguagesModel: ObservableObject {
    struct Option: Identifiable { let id: String, name: String, native: String }
    @Published var chosen: [String] = []
    @Published var options: [Option] = []
    @Published var isDefault = true             // nothing chosen yet: the system's language (or English)
    @Published var available = false
    @Published var editing = false
    @Published var interface = Interface.chosen ?? ""      // "" = the system's
    let startInterface = Interface.chosen ?? ""
    init() { load() }

    func load(tries: Int = 30) {
        Services.shared.get("/settings") { r, _ in
            guard let langs = r?["languages"] as? [String], let sup = r?["supported"] as? [[String: Any]] else {
                self.available = false
                if tries > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.load(tries: tries - 1) } }   // the engine is starting
                return
            }
            let ids = sup.compactMap { $0["id"] as? String }
            self.options = sup.compactMap { o in
                (o["id"] as? String).map {
                    Option(id: $0, name: LanguageNames.display($0, among: ids), native: LanguageNames.display($0, among: ids, in: Locale(identifier: $0)))
                }
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.chosen = langs
            self.isDefault = !(r?["languagesSet"] as? Bool ?? false)
            self.available = true
            if UserDefaults(suiteName: UserDefaults.argumentDomain)?.object(forKey: "languagesSheet") != nil {
                self.editing = true                             // for development: `-languagesSheet 1` opens the list
            }
        }
    }

    func name(_ id: String) -> String { options.first { $0.id == id }?.name ?? id }
    var summary: String { ListFormatter.localizedString(byJoining: chosen.map(name)) }

    private var sending = false, pending = false

    /// Add or remove a language; at least one stays.
    func toggle(_ id: String, _ on: Bool) {
        var l = chosen.filter { $0 != id }
        if on { l.append(id) }
        guard !l.isEmpty else { return }
        chosen = l
        send()
    }

    /// One request at a time, the latest list last (quick clicks must not arrive out of order).
    private func send() {
        guard !sending else { pending = true; return }
        sending = true
        Services.shared.post("/settings", ["languages": chosen]) { r, _ in
            self.sending = false
            if self.pending { self.pending = false; self.send(); return }
            if let l = r?["languages"] as? [String] { self.chosen = l; self.isDefault = false }
        }
    }

    func setInterface(_ id: String) {
        interface = id
        Interface.chosen = id.isEmpty ? nil : id
    }
}

struct LanguagesSheet: View {
    @ObservedObject var model: LanguagesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Languages you write in")).font(.title3.bold())
                Spacer()
                Button(L("Done")) { model.editing = false }.keyboardShortcut(.defaultAction)
            }
            Text(L("Choose every language you type in, and only those. Homeword works out which of them you are typing and suggests "
                   + "in that language; a short list keeps it from mixing up similar languages (Danish and Norwegian, Spanish and "
                   + "Portuguese)."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.options) { o in
                Toggle(isOn: Binding(get: { model.chosen.contains(o.id) }, set: { model.toggle(o.id, $0) })) {
                    HStack {
                        Text(o.name)
                        if o.native.caseInsensitiveCompare(o.name) != .orderedSame { Text(o.native).foregroundStyle(.secondary) }
                    }
                }
                .disabled(model.chosen == [o.id])                   // the last one stays
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
        .padding(16)
        .frame(width: 440, height: 520)
    }
}

/// Whether macOS's own inline predictive text is on, checked again whenever the app comes back to the front (after a visit to
/// System Settings).
final class InlinePredictionModel: ObservableObject {
    @Published var on = InlinePrediction.isOn
    private var observer: Any?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.on = InlinePrediction.isOn
        }
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }
}

final class ShortcutsModel: ObservableObject {
    let proofread = HotkeyRecorderModel(key: Pref.proofreadKey)
    let rewrite = HotkeyRecorderModel(key: Pref.rewriteKey)
}

struct GeneralTab: View {
    @AppStorage(Pref.predictions) var predictions = true
    @AppStorage(Pref.proofreading) var proofreading = true
    @AppStorage(Pref.minChars) var minChars = 3
    @AppStorage(Pref.position) var position = "below"
    @AppStorage(Pref.chromium) var chromium = true
    @AppStorage(Pref.spaceAfterWord) var spaceAfterWord = true
    @AppStorage(Pref.typedFallback) var typedFallback = true
    @StateObject private var keys = ShortcutsModel()
    @StateObject private var words = WordsModel()
    @StateObject private var languages = LanguagesModel()
    @StateObject private var inline = InlinePredictionModel()

    var body: some View {
        Form {
            Section(L("Next-word suggestions")) {
                if inline.on {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(L("macOS inline predictive text is on"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(L("Open Keyboard Settings")) { InlinePrediction.openSettings() }
                        }
                        Text(L("macOS shows its own inline suggestions in many apps. With both on you see two suggestions, and Tab may "
                               + "go to either. In Keyboard settings, open Text Input and turn off \"Show inline predictive text\"."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(L("Suggest while typing"), isOn: $predictions)
                Picker(L("Pop-up position"), selection: $position) {
                    Text(L("Below the cursor")).tag("below")
                    Text(L("Next to the cursor")).tag("beside")
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("Words to suggest"))
                        InfoTip(L("How many words a suggestion can have after the word you are typing. Every word costs model time on "
                                + "each suggestion (about 16 ms per token, ~1.2 tokens per word), and words further ahead are right "
                                + "less often. The model stops earlier at the end of a sentence, so the cost is a maximum."))
                        Spacer()
                        Text(L("up to %d words", words.words)).monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: Binding(get: { words.words }, set: { words.set($0) }), in: 1...10).labelsHidden()
                    }
                    Text(words.available ? words.cost : L("Start the engine to change this."))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .disabled(!words.available)
                HStack {                                        // the value right next to its stepper
                    Text(L("Start suggesting after"))
                    Spacer()
                    Text(L("%d characters", minChars)).monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: $minChars, in: 1...20).labelsHidden()
                }
                Toggle(L("Add a space after a word taken with Tab"), isOn: $spaceAfterWord)
                Toggle(isOn: $typedFallback) {
                    HStack {
                        Text(L("Suggest in apps whose text can't be read"))
                        InfoTip(L("Some apps draw their text themselves and don't share it (Google Docs, Figma, Sublime Text, games). "
                                + "There Homeword uses what you typed since your last click instead, kept in memory only. It starts "
                                + "after the first word, resets on clicks, arrows, Return and shortcuts, and is off while an input "
                                + "method is active. The pop-up shows where you last clicked."))
                    }
                }
                Toggle(L("Support Chrome-based browsers and Electron apps"), isOn: $chromium)
                Text(L("Tab inserts the highlighted word, Esc dismisses. Typing the suggestion's next letters keeps it. The writing style "
                       + "follows the app you type in (Apps tab)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Languages")) {
                Picker(L("Homeword's language"), selection: Binding(get: { languages.interface }, set: { languages.setInterface($0) })) {
                    Text(L("System default")).tag("")
                    Divider()
                    ForEach(Interface.languages, id: \.self) { Text(Interface.nativeName($0)).tag($0) }
                }
                if languages.interface != languages.startInterface {
                    HStack {
                        Text(L("Homeword shows the new language after it restarts.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Restart Homeword")) { Interface.relaunch() }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(L("Languages you write in"))
                        InfoTip(L("Suggestions come in the language you are typing, out of these. Homeword detects it as you type; "
                                  + "listing only the languages you use makes that more accurate. Apple's on-device model supports "
                                  + "these languages. By default: your system's language, or English if the model doesn't support it."))
                        Spacer()
                        Text(languages.available ? languages.summary : "–").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Button(L("Choose…")) { languages.editing = true }
                    }
                    if !languages.available {
                        Text(L("Start the engine to change this.")).font(.caption).foregroundStyle(.secondary)
                    } else if languages.isDefault {
                        Text(L("The default: your system's language, or English. Add the other languages you write in.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!languages.available)
                .sheet(isPresented: $languages.editing) { LanguagesSheet(model: languages) }
            }
            Section(L("Proofreading")) {
                Toggle(L("Proofread and rewrite selected text"), isOn: $proofreading)
                ShortcutRow(title: L("Proofread selection"), model: keys.proofread, other: keys.rewrite, fallback: .defaultProofread)
                ShortcutRow(title: L("Rewrite selection"), model: keys.rewrite, other: keys.proofread, fallback: .defaultRewrite)
                Text(L("Proofread fixes typos and grammar; rewrite makes the text clearer. Both keep your meaning. Return replaces the "
                       + "selection, ⌘C copies the result, Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRow: View {
    let title: String
    @ObservedObject var model: HotkeyRecorderModel
    @ObservedObject var other: HotkeyRecorderModel
    let fallback: Hotkey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                HotkeyRecorder(model: model)
                Button(L("Default")) { model.reset(to: fallback) }
                    .disabled(model.hotkey == fallback)
            }
            if let w = model.hotkey.warning(other: other.hotkey) {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: Apps

final class AppsModel: ObservableObject {
    struct Row: Identifiable {
        let info: AppInfo
        var choice: String          // "auto", a style, or "off"
        var id: String { info.bundle }
        var automatic: String { Style.automatic(bundle: info.bundle, host: nil) }
        var builtIn: Bool { Style.builtIn[info.bundle] != nil }
    }
    @Published var rows: [Row] = []
    @Published var selection: String?

    init() { reload() }

    func reload() {
        let choices = Style.userChoices
        var bundles = Set(choices.keys)
        for b in Style.builtIn.keys where NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil { bundles.insert(b) }
        rows = bundles.map { Row(info: AppInfo.of($0), choice: choices[$0] ?? "auto") }
            .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    func set(_ bundle: String, _ choice: String) {
        var c = Style.userChoices
        if choice == "auto" && Style.builtIn[bundle] != nil { c[bundle] = nil } else { c[bundle] = choice }   // "auto" keeps a listed app
        Style.userChoices = c
        reload()
    }

    func add(_ bundle: String) {
        guard !bundle.isEmpty, bundle != Bundle.main.bundleIdentifier else { return }
        var c = Style.userChoices
        if c[bundle] == nil && Style.builtIn[bundle] == nil { c[bundle] = "auto" }
        Style.userChoices = c
        reload()
        selection = bundle
    }

    func removeSelected() {
        guard let b = selection else { return }
        var c = Style.userChoices
        c[b] = nil
        Style.userChoices = c
        reload()
        selection = nil
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { if let b = Bundle(url: url)?.bundleIdentifier { add(b) } }
        }
    }

    var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }
}

struct AppsTab: View {
    @StateObject private var model = AppsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Homeword picks a writing style for the app you type in, and for web apps in browsers (Gmail is Email, Google Docs is "
                   + "Work documents). Change it per app here, or turn suggestions off for an app."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $model.selection) {
                ForEach(model.rows) { row in
                    HStack(spacing: 10) {
                        if let icon = row.info.icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 22, height: 22).foregroundStyle(.secondary)
                        }
                        Text(row.info.name).foregroundStyle(row.info.installed ? Color.primary : Color.secondary)
                        Spacer()
                        Picker("", selection: Binding(get: { row.choice }, set: { model.set(row.id, $0) })) {
                            Text(L("Automatic (%@)", Style.title(row.automatic))).tag("auto")
                            Divider()
                            ForEach(Style.all, id: \.self) { Text(Style.title($0)).tag($0) }
                            Divider()
                            Text(L("Off")).tag("off")
                        }
                        .labelsHidden()
                        .frame(width: 250, alignment: .trailing)
                    }
                    .help(row.info.bundle)
                    .tag(row.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 4) {
                Menu {
                    ForEach(model.running, id: \.processIdentifier) { app in
                        Button {
                            model.add(app.bundleIdentifier ?? "")
                        } label: {
                            if let icon = app.icon { Image(nsImage: icon) }
                            Text(app.localizedName ?? app.bundleIdentifier ?? "")
                        }
                    }
                    Divider()
                    Button(L("Choose an App…")) { model.choose() }
                } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Add a running app, or choose one from Applications"))
                Button { model.removeSelected() } label: { Image(systemName: "minus").frame(width: 16, height: 16) }  // same size as +
                    .disabled(model.selection.map { Style.userChoices[$0] == nil } ?? true)
                    .help(L("Remove your setting for the selected app (built-in apps go back to Automatic)"))
                Spacer()
                Text(L("Apps not listed use Automatic.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .onAppear { model.reload() }
    }
}

// MARK: Statistics

final class StatsModel: ObservableObject {
    @Published var summary = MetricsSummary([])
    func refresh() { summary = MetricsSummary(Metrics.shared.load()) }
}

struct StatsTab: View {
    @StateObject private var model = StatsModel()
    private var s: MetricsSummary { model.summary }

    var body: some View {
        VStack(spacing: 8) {
            Form {
                Section(L("Suggestions")) {
                    row(L("Suggestions shown"), "\(s.shown)")
                    row(L("Accepted (at least one word)"), s.shown > 0 ? "\(s.accepted) (\(pct(s.accepted, s.shown)))" : "–",
                        info: L("Suggestions of which you took at least one word with Tab, out of all shown."))
                    row(L("Words accepted"), "\(s.acceptedWords)")
                    row(L("Keystrokes saved"), s.keys > 0 ? L("%d of %d (%@)", s.acceptedChars - s.acceptedWords, s.keys + s.acceptedChars - s.acceptedWords, pct(s.acceptedChars - s.acceptedWords, s.keys + s.acceptedChars - s.acceptedWords)) : "–",
                        info: L("Characters that accepted words typed for you (minus the Tab per word), out of all "
                                + "characters that went into the text while suggestions were on."))
                    row(L("Characters typed along a suggestion"), "\(s.typedAlong)",
                        info: L("Characters you typed that matched the suggestion shown: it was right, but you typed instead of accepting."))
                    row(L("Key → pop-up, p50 / p90"), ms(MetricsSummary.pct(s.latencies, 50)) + " / " + ms(MetricsSummary.pct(s.latencies, 90)),
                        info: L("Time from a key press to the suggestion on screen. p50: half were faster; p90: 9 in 10 were faster."))
                    row(L("Model time, p50"), ms(MetricsSummary.pct(s.models, 50)), info: L("The part of that time the model took to answer (median)."))
                    row(L("Requests with nothing to show / errors"), "\(s.empty) / \(s.errors)",
                        info: L("Requests whose answer had no usable suggestion, and requests that failed (e.g. the engine was not running)."))
                }
                if !s.perStyle.isEmpty {
                    Section(L("By writing style")) {
                        ForEach(s.perStyle.sorted { $0.value.shown > $1.value.shown }, id: \.key) { st, v in
                            row(Style.title(st), L("%d shown, %@ accepted, p50 %@", v.shown, pct(v.accepted, v.shown), ms(MetricsSummary.pct(v.latencies, 50))))
                        }
                    }
                }
                if !s.perApp.isEmpty {
                    Section(L("By app")) {
                        ForEach(s.perApp.sorted { $0.value.shown > $1.value.shown }.prefix(8), id: \.key) { app, v in
                            row(AppInfo.of(app).name, L("%d shown, %@ accepted", v.shown, pct(v.accepted, v.shown)))
                        }
                    }
                }
                Section(L("Proofreading")) {
                    row(L("Requests"), "\(s.proofreads)")
                    row(L("Replaced / copied / cancelled / failed"), "\(s.replaced) / \(s.copied) / \(s.cancelled) / \(s.failed)",
                        info: L("What happened to each proofread or rewrite: put into the text, copied, closed without using it, or failed."))
                    row(L("Answer time, p50"), ms(MetricsSummary.pct(s.proofLatencies, 50)))
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(L("Counts and timings only, never your text. Stored on this Mac.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Reveal File")) { NSWorkspace.shared.activateFileViewerSelecting([Metrics.shared.url]) }
                Button(L("Reset…")) { confirmReset() }
                Button(L("Refresh")) { model.refresh() }
            }
            .padding(.horizontal, 8)
        }
        .onAppear { model.refresh() }
    }

    private func confirmReset() {
        let a = NSAlert()
        a.messageText = L("Delete all collected statistics?")
        a.addButton(withTitle: L("Delete"))
        a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            Metrics.shared.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.refresh() }
        }
    }
    private func row(_ k: String, _ v: String, info: String? = nil) -> some View {
        HStack {
            Text(k)
            if let info { InfoTip(info) }
            Spacer()
            Text(v).monospacedDigit().foregroundStyle(.secondary)
        }
    }
    private func pct(_ a: Int, _ b: Int) -> String { b > 0 ? "\(Int((Double(a) / Double(b) * 100).rounded()))%" : "–" }
    private func ms(_ x: Double?) -> String { x.map { "\(Int($0)) ms" } ?? "–" }
}

// MARK: Engine

final class EngineModel: ObservableObject {
    @Published var state = Services.State.unknown
    @Published var stoppedByUser = false
    @Published var apiUp = false
    @Published var ax = AX.trusted(prompt: false)
    @Published var port = String(EngineConfig.port)
    @Published var apiPort = String(EngineConfig.apiPort)
    @Published var message = ""
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        let s = Services.shared
        if s.state != .starting && s.state != .stopping { s.check(autostart: false) }
        state = s.state
        stoppedByUser = s.stoppedByUser
        ax = AX.trusted(prompt: false)
        s.checkAPI { self.apiUp = $0 }
    }

    var color: Color {
        switch state {
        case .running: return .green
        case .starting, .stopping, .unknown: return .yellow
        case .stopped: return .red
        }
    }
    var detail: String {
        switch state {
        case .running: return L("Runs Apple's on-device model on this Mac. Nothing you type leaves it.")
        case .starting: return L("Loading the on-device model…")
        case .stopping: return L("Stopping…")
        case .unknown: return L("Checking…")
        case .stopped: return stoppedByUser ? L("Stopped. Suggestions and proofreading are paused until you start it.")
            : L("Not running. It shuts down after 30 idle minutes and starts again when you type.")
        }
    }

    var savedPorts: (Int, Int) { (EngineConfig.port, EngineConfig.apiPort) }
    var portsChanged: Bool { (Int(port) ?? -1, Int(apiPort) ?? -1) != savedPorts }
    var portsValid: Bool {
        guard let a = Int(port), let b = Int(apiPort) else { return false }
        return (1024...65535).contains(a) && (1024...65535).contains(b) && a != b
    }

    func applyPorts() {
        guard portsValid, let a = Int(port), let b = Int(apiPort) else { return }
        do {
            try Services.shared.setPorts(engine: a, api: b)
            message = L("Restarting the engine on the new ports…")
        } catch {
            message = L("Could not save: %@", error.localizedDescription)
        }
    }
}

struct EngineTab: View {
    @StateObject private var model = EngineModel()

    private var baseURL: String { "http://127.0.0.1:\(EngineConfig.apiPort)/v1" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    StatusDot(color: model.color)
                    Text(model.state.title).bold()
                    Spacer()
                    if model.state == .stopped {
                        Button(L("Start")) { Services.shared.start(force: true); model.refresh() }
                    } else {
                        Button(L("Stop")) { Services.shared.stop(); model.refresh() }
                            .disabled(model.state == .stopping || model.state == .starting)
                        Button(L("Restart")) { Services.shared.restart(); model.refresh() }
                            .disabled(model.state == .stopping || model.state == .starting)
                    }
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
                if let problem = Services.shared.availabilityProblem, model.state == .running {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(L("Port"))
                    Spacer()
                    TextField("", text: $model.port).frame(width: 80).multilineTextAlignment(.trailing).labelsHidden()
                }
                Text(L("Used by Homeword and the pred command line tool. The pi and Claude Code integrations have their own port setting."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L("Engine"))
            }
            Section {
                HStack(spacing: 8) {
                    StatusDot(color: model.apiUp ? .green : (model.state == .starting ? .yellow : .red))
                    Text(model.apiUp ? L("Available") : L("Not available")).bold()
                    Spacer()
                }
                copyRow(L("Base URL"), baseURL)
                copyRow(L("Model"), "apple-on-device")
                copyRow(L("API key"), L("any text"))
                HStack {
                    Text(L("Port"))
                    Spacer()
                    TextField("", text: $model.apiPort).frame(width: 80).multilineTextAlignment(.trailing).labelsHidden()
                }
                Text(L("Point any OpenAI-compatible app or agent at the base URL to use Apple's on-device model. Local only: other "
                       + "machines cannot reach it. The model's context window is 8,192 tokens."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L("OpenAI-compatible API"))
            }
            if model.portsChanged || !model.message.isEmpty {
                HStack {
                    Text(model.portsValid ? model.message : L("Ports must be different numbers between 1024 and 65535."))
                        .font(.caption).foregroundStyle(model.portsValid ? Color.secondary : Color.red)
                    Spacer()
                    Button(L("Revert")) { model.port = String(EngineConfig.port); model.apiPort = String(EngineConfig.apiPort); model.message = "" }
                        .disabled(!model.portsChanged)
                    Button(L("Apply and Restart")) { model.applyPorts() }
                        .disabled(!model.portsChanged || !model.portsValid)
                }
            }
            Section(L("Permissions")) {
                HStack(spacing: 8) {
                    StatusDot(color: model.ax ? .green : .red)
                    Text(model.ax ? L("Accessibility: allowed") : L("Accessibility: not allowed"))
                    Spacer()
                    Button(L("Open Accessibility Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Text(L("Needed to read the text field you type in, see key presses and insert words."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(L("Copy"))
        }
    }
}
