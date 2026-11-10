// The Settings window: General, Prompts (the policies' system prompts, editable, each with a reset to its default), Statistics
// (from the metrics file) and Services. The prompts live in the policy server (GET/POST /prompts); the app only edits them.
import AppKit
import SwiftUI

final class SettingsNav: ObservableObject {
    @Published var tab = "general"
}

struct SettingsView: View {
    @ObservedObject var nav: SettingsNav

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            PromptsTab().tabItem { Label("Prompts", systemImage: "text.bubble") }.tag("prompts")
            StatsTab().tabItem { Label("Statistics", systemImage: "chart.bar") }.tag("stats")
            ServicesTab().tabItem { Label("Services", systemImage: "server.rack") }.tag("services")
        }
        .padding(12)
        .frame(width: 640, height: 560)
    }
}

// MARK: General

struct GeneralTab: View {
    @AppStorage(Pref.predictions) var predictions = true
    @AppStorage(Pref.proofreading) var proofreading = true
    @AppStorage(Pref.minChars) var minChars = 3
    @AppStorage(Pref.position) var position = "below"
    @AppStorage(Pref.chromium) var chromium = true
    @AppStorage(Pref.excluded) var excluded = Pref.defaultExcluded

    var body: some View {
        Form {
            Section("Input prediction") {
                Toggle("Predict while typing", isOn: $predictions)
                Picker("Pop-up position", selection: $position) {
                    Text("Below the cursor").tag("below")
                    Text("Next to the cursor").tag("beside")
                }
                Stepper("Start after \(minChars) characters", value: $minChars, in: 1...20)
                Toggle("Support Chrome-based browsers and Electron apps", isOn: $chromium)
                Text("Tab inserts the highlighted word, Esc dismisses. Typing the suggestion's next letters keeps it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Proofreading") {
                Toggle("Proofread (⌃⌥P) and rewrite (⌃⌥R) the selection", isOn: $proofreading)
                Text("Return replaces the selection with the result, ⌘C copies it, Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never predict in these apps (bundle IDs, one per line)") {
                TextEditor(text: $excluded)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Prompts

final class PromptStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String, title: String, defaultText: String, note: String
        var text: String, custom: Bool
    }
    @Published var items: [Item] = []
    @Published var message = ""
    @Published var busy = false
    @Published var selected = "typing" { didSet { if selected != oldValue { draft = item?.text ?? "" } } }
    @Published var draft = ""
    var item: Item? { items.first { $0.id == selected } }

    func load() { busy = true; Services.shared.get("/prompts") { r, err in self.apply(r, err) } }
    func save(_ id: String, _ text: String) { send(["name": id, "text": text], done: "Saved. The next suggestion uses it.") }
    func reset(_ id: String) { send(["name": id, "reset": true], done: "Restored the default.") }

    private func send(_ body: [String: Any], done: String) {
        busy = true
        Services.shared.post("/prompts", body) { r, err in
            self.apply(r, err)
            if r?["ok"] as? Bool == true { self.message = done }
        }
    }

    private func apply(_ r: [String: Any]?, _ err: String?) {
        busy = false
        guard let r, r["ok"] as? Bool == true, let list = r["prompts"] as? [[String: Any]] else {
            message = (r?["error"] as? String) ?? err.map { "The policy server is not answering (\($0)). Start it in Services." } ?? "error"
            return
        }
        message = ""
        defer { draft = item?.text ?? "" }
        items = list.map {
            Item(id: $0["name"] as? String ?? "", title: $0["title"] as? String ?? "", defaultText: $0["default"] as? String ?? "",
                 note: $0["note"] as? String ?? "", text: $0["text"] as? String ?? "", custom: $0["custom"] as? Bool ?? false)
        }
    }
}

struct PromptsTab: View {
    @StateObject private var store = PromptStore()
    private var item: PromptStore.Item? { store.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The instructions the on-device model gets. Edit to change how it predicts, proofreads or rewrites.")
                .foregroundStyle(.secondary)
            Picker("", selection: $store.selected) {
                ForEach(store.items) { Text($0.title + ($0.custom ? " •" : "")).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(store.items.isEmpty)
            TextEditor(text: $store.draft)
                .font(.system(.body))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .disabled(item == nil)
            if let item {
                HStack(alignment: .top) {
                    Text(item.custom ? "Your prompt (custom)" : "Default prompt").bold()
                    Text(item.note).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.draft.count) characters").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }
            HStack {
                Button("Reset to Default") {
                    store.reset(store.selected)
                }
                .disabled(item == nil || (!(item?.custom ?? false) && store.draft == item?.defaultText))
                .help("Restore this prompt to the one the app ships with")
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Revert") { store.draft = item?.text ?? "" }
                    .disabled(store.draft == item?.text)
                Button("Save") { store.save(store.selected, store.draft) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(item == nil || store.draft == item?.text || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .onAppear { store.load() }
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
                Section("Predictions") {
                    row("Suggestions shown", "\(s.shown)")
                    row("Accepted (at least one word)", s.shown > 0 ? "\(s.accepted) (\(pct(s.accepted, s.shown)))" : "–")
                    row("Words accepted", "\(s.acceptedWords)")
                    row("Keystrokes saved", s.keys > 0 ? "\(s.acceptedChars - s.acceptedWords) of \(s.keys + s.acceptedChars - s.acceptedWords) (\(pct(s.acceptedChars - s.acceptedWords, s.keys + s.acceptedChars - s.acceptedWords)))" : "–")
                    row("Characters typed along a suggestion", "\(s.typedAlong)")
                    row("Key → pop-up, p50 / p90", ms(MetricsSummary.pct(s.latencies, 50)) + " / " + ms(MetricsSummary.pct(s.latencies, 90)))
                    row("Model time, p50", ms(MetricsSummary.pct(s.models, 50)))
                    row("Requests with nothing to show / errors", "\(s.empty) / \(s.errors)")
                }
                if !s.perApp.isEmpty {
                    Section("By app") {
                        ForEach(s.perApp.sorted { $0.value.shown > $1.value.shown }.prefix(8), id: \.key) { app, v in
                            row(app, "\(v.shown) shown, \(pct(v.accepted, v.shown)) accepted")
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
                Text("Counts and timings only, never your text.").font(.caption).foregroundStyle(.secondary)
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
        a.messageText = "Delete all collected metrics?"
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

// MARK: Services

struct ServicesTab: View {
    @AppStorage(Pref.server) var server = "http://127.0.0.1:47321"
    @StateObject private var model = ServicesModel()
    private var state: String { model.state }
    private var ax: Bool { model.ax }

    var body: some View {
        Form {
            Section("Policy server (predictions, proofreading, prompts)") {
                TextField("URL", text: $server)
                HStack {
                    Text("Status: \(state)")
                    Spacer()
                    Button("Check") { Services.shared.check() }
                    Button("Start Services") { Services.shared.start(force: true) }
                }
                Text("Started with bin/pred start from the repo this app was built in; it stops after 30 idle minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Text("Accessibility: \(ax ? "allowed" : "not allowed")")
                    Spacer()
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

final class ServicesModel: ObservableObject {
    @Published var state = Services.shared.state.rawValue
    @Published var ax = AX.trusted(prompt: false)
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.state = Services.shared.state.rawValue
            self?.ax = AX.trusted(prompt: false)
        }
    }
    deinit { timer?.invalidate() }
}
