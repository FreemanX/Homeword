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
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AppsTab().tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag("apps")
            PromptsView().tabItem { Label("Prompts", systemImage: "text.bubble") }.tag("prompts")
            StatsTab().tabItem { Label("Statistics", systemImage: "chart.bar") }.tag("stats")
            EngineTab().tabItem { Label("Engine", systemImage: "cpu") }.tag("engine")
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
    @StateObject private var keys = ShortcutsModel()

    var body: some View {
        Form {
            Section("Next-word suggestions") {
                Toggle("Suggest while typing", isOn: $predictions)
                Picker("Pop-up position", selection: $position) {
                    Text("Below the cursor").tag("below")
                    Text("Next to the cursor").tag("beside")
                }
                Stepper("Start after \(minChars) characters", value: $minChars, in: 1...20)
                Toggle("Support Chrome-based browsers and Electron apps", isOn: $chromium)
                Text("Tab inserts the highlighted word, Esc dismisses. Typing the suggestion's next letters keeps it. The writing style "
                     + "follows the app you type in (Apps tab).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Proofreading") {
                Toggle("Proofread and rewrite selected text", isOn: $proofreading)
                ShortcutRow(title: "Proofread selection", model: keys.proofread, other: keys.rewrite, fallback: .defaultProofread)
                ShortcutRow(title: "Rewrite selection", model: keys.rewrite, other: keys.proofread, fallback: .defaultRewrite)
                Text("Proofread fixes typos and grammar; rewrite makes the text clearer. Both keep your meaning. Return replaces the "
                     + "selection, ⌘C copies the result, Esc cancels.")
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
                Button("Default") { model.reset(to: fallback) }
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
            Text("Homeword picks a writing style for the app you type in, and for web apps in browsers (Gmail is Email, Google Docs is "
                 + "Work documents). Change it per app here, or turn suggestions off for an app.")
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
                            Text("Automatic (\(Style.title(row.automatic)))").tag("auto")
                            Divider()
                            ForEach(Style.all, id: \.self) { Text(Style.title($0)).tag($0) }
                            Divider()
                            Text("Off").tag("off")
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
                    Button("Choose an App…") { model.choose() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a running app, or choose one from Applications")
                Button { model.removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(model.selection.map { Style.userChoices[$0] == nil } ?? true)
                    .help("Remove your setting for the selected app (built-in apps go back to Automatic)")
                Spacer()
                Text("Apps not listed use Automatic.").font(.caption).foregroundStyle(.secondary)
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
                Section("Suggestions") {
                    row("Suggestions shown", "\(s.shown)")
                    row("Accepted (at least one word)", s.shown > 0 ? "\(s.accepted) (\(pct(s.accepted, s.shown)))" : "–")
                    row("Words accepted", "\(s.acceptedWords)")
                    row("Keystrokes saved", s.keys > 0 ? "\(s.acceptedChars - s.acceptedWords) of \(s.keys + s.acceptedChars - s.acceptedWords) (\(pct(s.acceptedChars - s.acceptedWords, s.keys + s.acceptedChars - s.acceptedWords)))" : "–")
                    row("Characters typed along a suggestion", "\(s.typedAlong)")
                    row("Key → pop-up, p50 / p90", ms(MetricsSummary.pct(s.latencies, 50)) + " / " + ms(MetricsSummary.pct(s.latencies, 90)))
                    row("Model time, p50", ms(MetricsSummary.pct(s.models, 50)))
                    row("Requests with nothing to show / errors", "\(s.empty) / \(s.errors)")
                }
                if !s.perStyle.isEmpty {
                    Section("By writing style") {
                        ForEach(s.perStyle.sorted { $0.value.shown > $1.value.shown }, id: \.key) { st, v in
                            row(Style.title(st), "\(v.shown) shown, \(pct(v.accepted, v.shown)) accepted, p50 \(ms(MetricsSummary.pct(v.latencies, 50)))")
                        }
                    }
                }
                if !s.perApp.isEmpty {
                    Section("By app") {
                        ForEach(s.perApp.sorted { $0.value.shown > $1.value.shown }.prefix(8), id: \.key) { app, v in
                            row(AppInfo.of(app).name, "\(v.shown) shown, \(pct(v.accepted, v.shown)) accepted")
                        }
                    }
                }
                Section("Proofreading") {
                    row("Requests", "\(s.proofreads)")
                    row("Replaced / copied / cancelled / failed", "\(s.replaced) / \(s.copied) / \(s.cancelled) / \(s.failed)")
                    row("Answer time, p50", ms(MetricsSummary.pct(s.proofLatencies, 50)))
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Counts and timings only, never your text. Stored on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal File") { NSWorkspace.shared.activateFileViewerSelecting([Metrics.shared.url]) }
                Button("Reset…") { confirmReset() }
                Button("Refresh") { model.refresh() }
            }
            .padding(.horizontal, 8)
        }
        .onAppear { model.refresh() }
    }

    private func confirmReset() {
        let a = NSAlert()
        a.messageText = "Delete all collected statistics?"
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            Metrics.shared.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.refresh() }
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).monospacedDigit().foregroundStyle(.secondary) }
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
        case .running: return "Runs Apple's on-device model on this Mac. Nothing you type leaves it."
        case .starting: return "Loading the on-device model…"
        case .stopping: return "Stopping…"
        case .unknown: return "Checking…"
        case .stopped: return stoppedByUser ? "Stopped. Suggestions and proofreading are paused until you start it."
            : "Not running. It shuts down after 30 idle minutes and starts again when you type."
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
            message = "Restarting the engine on the new ports…"
        } catch {
            message = "Could not save: \(error.localizedDescription)"
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
                    Text(model.state.rawValue).bold()
                    Spacer()
                    if model.state == .stopped {
                        Button("Start") { Services.shared.start(force: true); model.refresh() }
                    } else {
                        Button("Stop") { Services.shared.stop(); model.refresh() }
                            .disabled(model.state == .stopping || model.state == .starting)
                        Button("Restart") { Services.shared.restart(); model.refresh() }
                            .disabled(model.state == .stopping || model.state == .starting)
                    }
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", text: $model.port).frame(width: 80).multilineTextAlignment(.trailing).labelsHidden()
                }
                Text("Used by Homeword and the pred command line tool. The pi and Claude Code integrations have their own port setting.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Engine")
            }
            Section {
                HStack(spacing: 8) {
                    StatusDot(color: model.apiUp ? .green : (model.state == .starting ? .yellow : .red))
                    Text(model.apiUp ? "Available" : "Not available").bold()
                    Spacer()
                }
                copyRow("Base URL", baseURL)
                copyRow("Model", "apple-on-device")
                copyRow("API key", "any text")
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", text: $model.apiPort).frame(width: 80).multilineTextAlignment(.trailing).labelsHidden()
                }
                Text("Point any OpenAI-compatible app or agent at the base URL to use Apple's on-device model. Local only: other "
                     + "machines cannot reach it. The model's context window is 8,192 tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("OpenAI-compatible API")
            }
            if model.portsChanged || !model.message.isEmpty {
                HStack {
                    Text(model.portsValid ? model.message : "Ports must be different numbers between 1024 and 65535.")
                        .font(.caption).foregroundStyle(model.portsValid ? Color.secondary : Color.red)
                    Spacer()
                    Button("Revert") { model.port = String(EngineConfig.port); model.apiPort = String(EngineConfig.apiPort); model.message = "" }
                        .disabled(!model.portsChanged)
                    Button("Apply and Restart") { model.applyPorts() }
                        .disabled(!model.portsChanged || !model.portsValid)
                }
            }
            Section("Permissions") {
                HStack(spacing: 8) {
                    StatusDot(color: model.ax ? .green : .red)
                    Text("Accessibility: \(model.ax ? "allowed" : "not allowed")")
                    Spacer()
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Text("Needed to read the text field you type in, see key presses and insert words.")
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
                .help("Copy")
        }
    }
}
