// The Prompts tab: every prompt the engine uses (next-word suggestions per writing style, proofreading, rewriting), editable
// (instructions and examples), with token counts, a benchmark to compare versions, and the last saved versions. All of it lives
// in the engine (GET/POST /prompts, /tokens, /bench, /history); this view only edits.
import AppKit
import SwiftUI

struct PromptExample: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var completion: String
    var app: String?            // the general prompt's examples carry their own app label
    static func == (a: PromptExample, b: PromptExample) -> Bool { a.text == b.text && a.completion == b.completion && a.app == b.app }
}

struct PromptDraft: Equatable {
    var instructions = ""
    var examples: [PromptExample] = []

    init() {}
    init(_ d: [String: Any]?) {
        instructions = d?["instructions"] as? String ?? ""
        examples = (d?["examples"] as? [[String: Any]] ?? []).map {
            PromptExample(text: $0["text"] as? String ?? "", completion: $0["completion"] as? String ?? "", app: $0["app"] as? String)
        }
    }
    var json: [String: Any] {
        ["instructions": instructions,
         "examples": examples.map { e -> [String: Any] in
             var d: [String: Any] = ["text": e.text, "completion": e.completion]
             if let a = e.app { d["app"] = a }
             return d
         }]
    }
    var chars: Int { instructions.count + examples.reduce(0) { $0 + $1.text.count + $1.completion.count } }
}

struct PromptEntry {
    let name: String, group: String, title: String, note: String
    let prompt: PromptDraft, defaultPrompt: PromptDraft
    let custom: Bool, inherits: Bool
    let result: [String: Any]?, defaultResult: [String: Any]?
    let labels: [String]

    init(_ d: [String: Any]) {
        name = d["name"] as? String ?? ""
        group = d["group"] as? String ?? ""
        title = d["title"] as? String ?? ""
        note = d["note"] as? String ?? ""
        prompt = PromptDraft(d["prompt"] as? [String: Any])
        defaultPrompt = PromptDraft(d["default"] as? [String: Any])
        custom = d["custom"] as? Bool ?? false
        inherits = d["inherits"] as? Bool ?? false
        result = d["result"] as? [String: Any]
        defaultResult = d["default_result"] as? [String: Any]
        labels = d["labels"] as? [String] ?? ["Text", "Continuation"]
    }
}

struct PromptVersion: Identifiable {
    let id: String              // content hash
    let savedAt: String
    let prompt: PromptDraft
    let result: [String: Any]?
}

final class PromptsModel: ObservableObject {
    @Published var entries: [PromptEntry] = []
    @Published var selected = "predict-general" { didSet { if selected != oldValue { select() } } }
    @Published var draft = PromptDraft() { didSet { if draft != oldValue { draftResult = nil; scheduleTokens() } } }
    @Published var tokens: (instructions: Int, prompt: Int, ms: Int?)?
    @Published var draftResult: [String: Any]?
    @Published var running: String?             // what the benchmark is running on
    @Published var history: [PromptVersion] = []
    @Published var message = ""
    @Published var loaded = false
    private var tokenTimer: Timer?
    private var tokenSeq = 0

    var entry: PromptEntry? { entries.first { $0.name == selected } }
    var dirty: Bool { entry.map { draft != $0.prompt } ?? false }
    var isPrediction: Bool { selected.hasPrefix("predict-") }

    func load(keepDraft: Bool = false) {
        Services.shared.get("/prompts") { r, err in
            guard let list = r?["prompts"] as? [[String: Any]] else {
                self.message = "The engine is not running. Start it in the Engine tab."
                return
            }
            self.entries = list.map(PromptEntry.init)
            if !self.loaded, let n = UserDefaults(suiteName: UserDefaults.argumentDomain)?.string(forKey: "promptsSelect") {
                self.selected = n                               // for development: `-promptsSelect predict-chat`
            }
            self.loaded = true
            if !keepDraft { self.select() }
            self.loadHistory()
        }
    }

    private func select() {
        message = ""
        draft = entry?.prompt ?? PromptDraft()
        draftResult = nil
        loadHistory()
        scheduleTokens(now: true)
    }

    func loadHistory() {
        let name = selected
        Services.shared.get("/history?name=\(name)") { r, _ in
            guard name == self.selected else { return }
            self.history = (r?["versions"] as? [[String: Any]] ?? []).map {
                PromptVersion(id: $0["hash"] as? String ?? UUID().uuidString, savedAt: $0["saved_at"] as? String ?? "",
                              prompt: PromptDraft($0["prompt"] as? [String: Any]), result: $0["result"] as? [String: Any])
            }
        }
    }

    private func scheduleTokens(now: Bool = false) {
        tokenTimer?.invalidate()
        tokenTimer = Timer.scheduledTimer(withTimeInterval: now ? 0.05 : 0.6, repeats: false) { [weak self] _ in self?.countTokens() }
    }

    private func countTokens() {
        guard !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Predictor.paused else { return }
        tokenSeq += 1
        let seq = tokenSeq
        Services.shared.post("/tokens", ["name": selected, "prompt": draft.json], timeout: 10) { r, _ in
            guard seq == self.tokenSeq, r?["ok"] as? Bool == true else { return }
            self.tokens = (r?["instructions"] as? Int ?? -1, r?["prompt"] as? Int ?? -1, r?["ms"] as? Int)
        }
    }

    func save() {
        let name = selected
        Services.shared.post("/prompts", ["name": name, "prompt": draft.json]) { r, err in
            guard r?["ok"] as? Bool == true else { self.message = (r?["error"] as? String) ?? err ?? "Could not save"; return }
            self.entries = (r?["prompts"] as? [[String: Any]] ?? []).map(PromptEntry.init)
            self.message = "Saved. New suggestions use it."
            self.draft = self.entry?.prompt ?? self.draft
            self.loadHistory()
        }
    }

    func resetToDefault() {
        Services.shared.post("/prompts", ["name": selected, "reset": true]) { r, err in
            guard r?["ok"] as? Bool == true else { self.message = (r?["error"] as? String) ?? err ?? "Could not reset"; return }
            self.entries = (r?["prompts"] as? [[String: Any]] ?? []).map(PromptEntry.init)
            self.draft = self.entry?.prompt ?? PromptDraft()
            self.message = "Restored the default."
        }
    }

    func revert() { draft = entry?.prompt ?? draft }

    func addExample() { draft.examples.append(PromptExample(text: "", completion: "", app: nil)) }
    func removeExample(_ id: UUID) { draft.examples.removeAll { $0.id == id } }

    /// Benchmark the draft (or the prompt in use when nothing changed), or the shipped default.
    func bench(defaultPrompt: Bool) {
        guard running == nil, let e = entry else { return }
        let p = defaultPrompt ? e.defaultPrompt : draft
        let wasDirty = dirty
        running = defaultPrompt ? "default" : (wasDirty ? "draft" : "current")
        message = ""
        Predictor.paused = true                                 // the model has one cache: no suggestions meanwhile
        Services.shared.post("/bench", ["name": selected, "prompt": p.json], timeout: 180) { r, err in
            Predictor.paused = false
            self.running = nil
            guard r?["ok"] as? Bool == true, let res = r?["result"] as? [String: Any] else {
                self.message = (r?["error"] as? String) ?? err ?? "The benchmark failed"
                return
            }
            if !defaultPrompt && wasDirty && self.draft == p { self.draftResult = res }
            self.load(keepDraft: true)
        }
    }

    func use(_ v: PromptVersion) {
        draft = v.prompt
        message = "Loaded the version saved \(PromptsModel.date(v.savedAt)). Save to use it."
        draftResult = v.result
    }

    static func date(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

struct PromptsView: View {
    @StateObject private var model = PromptsModel()

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selected) {
                Section("Suggestions") {
                    ForEach(model.entries.filter { $0.group == "prediction" }, id: \.name) { e in
                        Label(e.title + (e.custom ? " •" : ""), systemImage: icon(e.name)).tag(e.name)
                    }
                }
                Section("Proofreading") {
                    ForEach(model.entries.filter { $0.group == "proofreading" }, id: \.name) { e in
                        Label(e.title + (e.custom ? " •" : ""), systemImage: icon(e.name)).tag(e.name)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            if let e = model.entry {
                ScrollViewReader { proxy in
                    ScrollView { editor(e).padding(14) }
                        .onAppear {   // for development: `--args -show prompts -promptsAnchor bench` shows the benchmark
                            if let a = UserDefaults(suiteName: UserDefaults.argumentDomain)?.string(forKey: "promptsAnchor") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(a, anchor: .top) }
                            }
                        }
                }
            } else {
                VStack {
                    Spacer()
                    Text(model.message.isEmpty ? "Loading…" : model.message).foregroundStyle(.secondary)
                    if !model.message.isEmpty { Button("Try Again") { model.load() } }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { model.load() }
    }

    private func icon(_ name: String) -> String {
        ["predict-general": "text.cursor", "predict-chat": "bubble.left.and.bubble.right", "predict-email": "envelope",
         "predict-work": "doc.text", "predict-academic": "graduationcap", "predict-code": "chevron.left.forwardslash.chevron.right",
         "proofread-fix": "checkmark.circle", "proofread-rewrite": "wand.and.stars"][name] ?? "text.bubble"
    }

    @ViewBuilder private func editor(_ e: PromptEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.title).font(.title2.bold())
                Text(e.custom ? "Your version" : (e.inherits ? "Same as General" : "Default")).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Text(e.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Instructions").font(.headline)
            TextEditor(text: $model.draft.instructions)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 90)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Text("Examples").font(.headline)
                Text("the model imitates these more than the instructions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addExample() } label: { Label("Add", systemImage: "plus") }
                    .disabled(model.draft.examples.count >= 12)
            }
            HStack {
                Text(e.labels.first ?? "").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text(e.labels.last ?? "").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 24)
            }
            ForEach($model.draft.examples) { $ex in
                HStack(alignment: .top) {
                    TextField(e.labels.first ?? "", text: $ex.text, axis: .vertical).lineLimit(1...4)
                    TextField(e.labels.last ?? "", text: $ex.completion, axis: .vertical).lineLimit(1...4)
                    Button { model.removeExample(ex.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).frame(width: 20)
                }
                .textFieldStyle(.roundedBorder)
            }
            if model.isPrediction {
                Text("A continuation starts with the rest of an unfinished word (no space), or with a space when the text ends with a "
                     + "whole word.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Text("\(model.draft.chars) characters").monospacedDigit()
                if let t = model.tokens {
                    Text("instructions \(t.instructions) tokens").monospacedDigit()
                    Text("whole prompt \(t.prompt) tokens").monospacedDigit()
                    if let ms = t.ms { Text("≈ \(ms) ms of every suggestion").monospacedDigit() }
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Reset to Default") { model.resetToDefault() }
                    .disabled(!e.custom && !model.dirty)
                Spacer()
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Revert") { model.revert() }.disabled(!model.dirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.dirty || model.draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()
            benchmark(e).id("bench")
            Divider()
            historyList()
        }
    }

    // MARK: benchmark

    private struct Column { let title: String; let key: String; let kind: Kind; enum Kind { case ms, pct, num } }

    private func columns(_ name: String) -> [Column] {
        if name == "proofread-fix" {
            return [Column(title: "Latency p50", key: "latency_p50", kind: .ms), Column(title: "Fully corrected", key: "exact", kind: .pct),
                    Column(title: "Word match", key: "word_match", kind: .pct)]
        }
        if name == "proofread-rewrite" {
            return [Column(title: "Latency p50", key: "latency_p50", kind: .ms), Column(title: "Length vs. original", key: "length_ratio", kind: .num)]
        }
        return [Column(title: "Latency p50", key: "latency_p50", kind: .ms), Column(title: "Next word right", key: "next_word", kind: .pct),
                Column(title: "Words right", key: "words_right", kind: .num), Column(title: "Word completions", key: "completions", kind: .pct),
                Column(title: "Shown", key: "shown", kind: .pct)]
    }

    private func cell(_ r: [String: Any]?, _ c: Column) -> String {
        guard let v = (r?[c.key] as? NSNumber)?.doubleValue else { return "–" }
        switch c.kind {
        case .ms: return "\(Int(v)) ms"
        case .pct: return "\(Int((v * 100).rounded()))%"
        case .num: return String(format: "%.2f", v)
        }
    }

    @ViewBuilder private func benchmark(_ e: PromptEntry) -> some View {
        let cols = columns(e.name)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Benchmark").font(.headline)
                Text(benchDescription(e.name)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let r = model.running {
                    ProgressView().controlSize(.small)
                    Text("Running on the \(r) prompt…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Run Default") { model.bench(defaultPrompt: true) }.disabled(model.running != nil)
                Button(model.dirty ? "Run Draft" : "Run") { model.bench(defaultPrompt: false) }.disabled(model.running != nil)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Version").bold()
                    ForEach(cols, id: \.key) { Text($0.title).bold() }
                }
                .font(.caption)
                benchRow("Default", e.defaultResult, cols)
                if e.custom { benchRow("Your saved version", e.result, cols) }
                if model.dirty { benchRow("This draft", model.draftResult, cols) }
            }
            Text("Measured on this Mac with sequential requests, as when typing. Latency can differ by ~70 ms between runs (the "
                 + "system switches model modes), so compare versions benchmarked one after the other. Suggestions pause while it runs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func benchRow(_ label: String, _ r: [String: Any]?, _ cols: [Column]) -> some View {
        GridRow {
            Text(label)
            ForEach(cols, id: \.key) { Text(cell(r, $0)).monospacedDigit() }
        }
    }

    private func benchDescription(_ name: String) -> String {
        switch name {
        case "proofread-fix": return "12 sentences with known mistakes"
        case "proofread-rewrite": return "12 sentences; no single right answer, so speed and length only"
        default:
            let st = String(name.dropFirst("predict-".count))
            return "14 \(Style.title(st).lowercased()) texts: does it guess what was typed next?"
        }
    }

    // MARK: history

    @ViewBuilder private func historyList() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved versions").font(.headline)
            if model.history.isEmpty {
                Text("None yet. Every Save keeps a version here (the last 20), with its benchmark result if you ran one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.history) { v in
                HStack {
                    Text(PromptsModel.date(v.savedAt)).monospacedDigit()
                    Text(v.prompt.instructions).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    Spacer()
                    Text(summary(v.result)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if v.prompt == model.entry?.prompt { Text("in use").font(.caption).foregroundStyle(.green) }
                    Button("Load") { model.use(v) }.disabled(v.prompt == model.draft)
                }
            }
        }
    }

    private func summary(_ r: [String: Any]?) -> String {
        guard let r else { return "not benchmarked" }
        let lat = (r["latency_p50"] as? NSNumber).map { "\($0.intValue) ms" } ?? "–"
        if let n = (r["next_word"] as? NSNumber)?.doubleValue { return "\(lat) · next word \(Int((n * 100).rounded()))%" }
        if let x = (r["exact"] as? NSNumber)?.doubleValue { return "\(lat) · corrected \(Int((x * 100).rounded()))%" }
        return lat
    }
}
