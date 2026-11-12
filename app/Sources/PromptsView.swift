// The Prompts tab: every prompt the engine uses (next-word suggestions per writing style, proofreading, rewriting), editable
// (instructions, and examples as line-paired text), with token counts, the benchmark suite reported per category plus the user's
// own test cases, and the last saved versions. All of it lives in the engine (GET/POST /prompts, /tokens, /bench, /cases,
// /history); this view only edits.
import AppKit
import SwiftUI

/// A prompt being edited: instructions, and its examples as two line-paired texts (line i left = typed text, right = continuation).
struct PromptDraft: Equatable {
    var instructions = ""
    var left = ""
    var right = ""
    var apps: [String: String] = [:]    // typed text → app label: the general prompt's examples carry their own

    init() {}
    init(_ d: [String: Any]?) {
        instructions = d?["instructions"] as? String ?? ""
        let ex = d?["examples"] as? [[String: Any]] ?? []
        left = ex.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
        right = ex.map { $0["completion"] as? String ?? "" }.joined(separator: "\n")
        for e in ex { if let a = e["app"] as? String, let t = e["text"] as? String { apps[t] = a } }
    }
    var pairs: [(String, String)] { LinePairs.split(left, right).pairs }
    var incomplete: [Int] { LinePairs.split(left, right).incomplete }
    var json: [String: Any] {
        ["instructions": instructions,
         "examples": pairs.map { p -> [String: Any] in
             var d: [String: Any] = ["text": p.0, "completion": p.1]
             if let a = apps[p.0] { d["app"] = a }
             return d
         }]
    }
    var chars: Int { instructions.count + pairs.reduce(0) { $0 + $1.0.count + $1.1.count } }
    static func == (a: PromptDraft, b: PromptDraft) -> Bool {
        a.instructions == b.instructions && a.pairs.map { $0.0 + "\u{1}" + $0.1 } == b.pairs.map { $0.0 + "\u{1}" + $0.1 }
    }
}

struct PromptEntry {
    let name: String, group: String, title: String, note: String
    let prompt: PromptDraft, defaultPrompt: PromptDraft
    let custom: Bool, inherits: Bool
    let result: [String: Any]?, defaultResult: [String: Any]?, userResult: [String: Any]?
    let labels: [String]
    let suiteCases: Int, suiteCategories: Int

    init(_ d: [String: Any]) {
        name = d["name"] as? String ?? ""
        group = d["group"] as? String ?? ""
        title = PromptEntry.title(name, d["title"] as? String ?? "")
        note = PromptEntry.note(group, d["note"] as? String ?? "")
        prompt = PromptDraft(d["prompt"] as? [String: Any])
        defaultPrompt = PromptDraft(d["default"] as? [String: Any])
        custom = d["custom"] as? Bool ?? false
        inherits = d["inherits"] as? Bool ?? false
        result = d["result"] as? [String: Any]
        defaultResult = d["default_result"] as? [String: Any]
        userResult = d["user_result"] as? [String: Any]
        let names = ["Typed text": L("Typed text"), "Continuation": L("Continuation"), "Input": L("Input"), "Output": L("Output")]
        labels = (d["labels"] as? [String] ?? ["Typed text", "Continuation"]).map { names[$0] ?? $0 }   // the engine's English names
        suiteCases = d["suite_cases"] as? Int ?? 0
        suiteCategories = d["suite_categories"] as? Int ?? 0
    }

    /// The engine names prompts and categories in English: here they are named in the interface language, by their id.
    static func title(_ name: String, _ engine: String) -> String {
        if name.hasPrefix("predict-") { return Style.titles[String(name.dropFirst(8))] ?? engine }
        return ["proofread-fix": L("Proofread"), "proofread-rewrite": L("Rewrite")][name] ?? engine
    }

    static func note(_ group: String, _ engine: String) -> String {
        guard group == "prediction" else { return L("The model gets one paragraph at a time.") }
        let words = engine.split(separator: "(").last?.prefix { $0.isNumber } ?? "5"   // "... to suggest (5)."
        return L("{words} becomes the number of words to suggest (%@).", String(words))
    }

    static func categoryTitle(_ name: String, _ engine: String) -> String {
        if name.hasPrefix("lang-") { return LanguageNames.category(String(name.dropFirst(5))) }
        if let t = Style.titles[name] { return t }
        return ["terminal": L("Terminal"), "user": L("Your cases"), "proofread": L("Proofreading"), "all": L("All categories")][name] ?? engine
    }
}

/// A category of the built-in benchmark cases, as two line-paired texts for the read-only viewer.
struct SuiteCategory: Identifiable {
    let id: String, title: String, left: String, right: String, count: Int
    let skipped: [Int]                      // line numbers left out for this prompt (they share text with its examples)

    init(_ d: [String: Any]) {
        let cases = d["cases"] as? [[String: Any]] ?? []
        id = d["name"] as? String ?? ""
        title = PromptEntry.categoryTitle(id, d["title"] as? String ?? "")
        left = cases.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
        right = cases.map { $0["rest"] as? String ?? "" }.joined(separator: "\n")
        count = cases.count
        skipped = cases.enumerated().filter { $0.element["skipped"] as? Bool == true }.map { $0.offset + 1 }
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
    @Published var progress: (done: Int, total: Int) = (0, 0)
    @Published var history: [PromptVersion] = []
    @Published var casesLeft = "" { didSet { if casesLeft != oldValue { scheduleCasesSave() } } }
    @Published var casesRight = "" { didSet { if casesRight != oldValue { scheduleCasesSave() } } }
    @Published var savedCases = 0
    @Published var message = ""
    @Published var loaded = false
    @Published var suite: [SuiteCategory] = []
    @Published var suiteShown = false
    @Published var suiteCategory = ""
    private var tokenTimer: Timer?, casesTimer: Timer?, pollTimer: Timer?
    private var tokenSeq = 0
    private var loadingCases = false

    var entry: PromptEntry? { entries.first { $0.name == selected } }
    var dirty: Bool { entry.map { draft != $0.prompt } ?? false }
    var isPrediction: Bool { selected.hasPrefix("predict-") }
    var casePairs: [(String, String)] { LinePairs.split(casesLeft, casesRight).pairs }

    func load(keepDraft: Bool = false) {
        Services.shared.get("/prompts") { r, err in
            guard let list = r?["prompts"] as? [[String: Any]] else {
                self.message = L("The engine is not running. Start it in the Engine tab.")
                return
            }
            self.entries = list.map(PromptEntry.init)
            if !self.loaded, let n = UserDefaults(suiteName: UserDefaults.argumentDomain)?.string(forKey: "promptsSelect") {
                self.selected = n                               // for development: `-promptsSelect predict-chat`
            }
            let first = !self.loaded
            self.loaded = true
            if !keepDraft { self.select() }
            if first, UserDefaults(suiteName: UserDefaults.argumentDomain)?.object(forKey: "promptsSuite") != nil {
                self.openSuite()                                // for development: `-promptsSuite 1` opens the built-in cases
            }
            self.loadHistory()
        }
    }

    private func select() {
        message = ""
        draft = entry?.prompt ?? PromptDraft()
        draftResult = nil
        loadHistory()
        loadCases()
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

    // MARK: the user's test cases

    private func loadCases() {
        let name = selected
        Services.shared.get("/cases?name=\(name)") { r, _ in
            guard name == self.selected else { return }
            let cases = r?["cases"] as? [[String: Any]] ?? []
            self.loadingCases = true
            self.casesLeft = cases.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
            self.casesRight = cases.map { $0["rest"] as? String ?? "" }.joined(separator: "\n")
            self.savedCases = cases.count
            self.loadingCases = false
        }
    }

    private func scheduleCasesSave() {
        guard !loadingCases else { return }
        casesTimer?.invalidate()
        casesTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.saveCases() }
    }

    private func saveCases(then: (() -> Void)? = nil) {
        let cases = casePairs.map { ["text": $0.0, "rest": $0.1] }
        Services.shared.post("/cases", ["name": selected, "cases": cases]) { r, err in
            if let saved = r?["cases"] as? [[String: Any]] { self.savedCases = saved.count }
            else { self.message = (r?["error"] as? String) ?? err ?? L("Could not save the cases") }
            then?()
        }
    }

    // MARK: the built-in cases (read-only)

    /// Load the built-in cases this prompt runs on and show them, starting with the prompt's own category.
    func openSuite() {
        let name = selected
        Services.shared.get("/suite?name=\(name)") { r, err in
            guard name == self.selected, let list = r?["categories"] as? [[String: Any]] else {
                self.message = (r?["error"] as? String) ?? err ?? L("Could not load the test cases")
                return
            }
            self.suite = list.map(SuiteCategory.init)
            let own = name.hasPrefix("predict-") ? String(name.dropFirst("predict-".count)) : ""
            self.suiteCategory = self.suite.contains { $0.id == own } ? own : (self.suite.first?.id ?? "")
            self.suiteShown = true
        }
    }

    // MARK: tokens, save, reset

    private func scheduleTokens(now: Bool = false) {
        tokenTimer?.invalidate()
        tokenTimer = Timer.scheduledTimer(withTimeInterval: now ? 0.05 : 0.6, repeats: false) { [weak self] _ in self?.countTokens() }
    }

    private func countTokens() {
        guard !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, running == nil else { return }
        tokenSeq += 1
        let seq = tokenSeq
        Services.shared.post("/tokens", ["name": selected, "prompt": draft.json], timeout: 10) { r, _ in
            guard seq == self.tokenSeq, r?["ok"] as? Bool == true else { return }
            self.tokens = (r?["instructions"] as? Int ?? -1, r?["prompt"] as? Int ?? -1, r?["ms"] as? Int)
        }
    }

    func save() {
        Services.shared.post("/prompts", ["name": selected, "prompt": draft.json]) { r, err in
            guard r?["ok"] as? Bool == true else { self.message = (r?["error"] as? String) ?? err ?? L("Could not save"); return }
            self.entries = (r?["prompts"] as? [[String: Any]] ?? []).map(PromptEntry.init)
            self.message = L("Saved. New suggestions use it.")
            self.draft = self.entry?.prompt ?? self.draft
            self.loadHistory()
        }
    }

    func resetToDefault() {
        Services.shared.post("/prompts", ["name": selected, "reset": true]) { r, err in
            guard r?["ok"] as? Bool == true else { self.message = (r?["error"] as? String) ?? err ?? L("Could not reset"); return }
            self.entries = (r?["prompts"] as? [[String: Any]] ?? []).map(PromptEntry.init)
            self.draft = self.entry?.prompt ?? PromptDraft()
            self.message = L("Restored the default.")
        }
    }

    func revert() { draft = entry?.prompt ?? draft }

    // MARK: benchmark

    /// Run the benchmark: `scope` "all" (the suite + the user's cases) or "user"; on the draft (or the saved prompt when nothing
    /// changed), or on the shipped default.
    func bench(scope: String, defaultPrompt: Bool = false) {
        guard running == nil, let e = entry else { return }
        let p = defaultPrompt ? e.defaultPrompt : draft
        let wasDirty = dirty && !defaultPrompt
        running = defaultPrompt ? L("The default prompt") : (wasDirty ? L("This draft") : L("This prompt"))
        progress = (0, 0)
        message = ""
        Predictor.paused = true                                 // the model has one cache: no suggestions meanwhile
        casesTimer?.invalidate()
        saveCases {                                             // the cases as typed, then the run
            Services.shared.post("/bench", ["name": self.selected, "prompt": p.json, "scope": scope], timeout: 10) { r, err in
                guard let job = r?["job"] as? String else {
                    self.finish((r?["error"] as? String) ?? err ?? L("The benchmark did not start"))
                    return
                }
                self.poll(job) { res in
                    if wasDirty && self.draft == p, let res {
                        var merged = self.draftResult ?? [:]    // a run on the user's cases only keeps the suite's numbers
                        if scope == "user" { merged["user"] = res["user"] } else { merged = res }
                        self.draftResult = merged
                    }
                }
            }
        }
    }

    private func poll(_ job: String, done: @escaping ([String: Any]?) -> Void) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            Services.shared.get("/bench?job=\(job)", timeout: 3) { r, _ in
                guard let self, let r else { return }
                self.progress = (r["done"] as? Int ?? 0, r["total"] as? Int ?? 0)
                switch r["state"] as? String {
                case "done":
                    t.invalidate()
                    done(r["result"] as? [String: Any])
                    self.finish(nil)
                case "error", nil:
                    t.invalidate()
                    self.finish(r["error"] as? String ?? L("The benchmark failed"))
                default: break
                }
            }
        }
    }

    private func finish(_ error: String?) {
        Predictor.paused = false
        running = nil
        if let error { message = error }
        load(keepDraft: true)
    }

    func use(_ v: PromptVersion) {
        draft = v.prompt
        message = L("Loaded the version saved %@. Save to use it.", PromptsModel.date(v.savedAt))
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
                Section(L("Suggestions")) {
                    ForEach(model.entries.filter { $0.group == "prediction" }, id: \.name) { e in
                        Label(e.title + (e.custom ? " •" : ""), systemImage: icon(e.name)).tag(e.name)
                    }
                }
                Section(L("Proofreading")) {
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
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(a, anchor: .top) }
                            }
                        }
                }
            } else {
                VStack {
                    Spacer()
                    Text(model.message.isEmpty ? L("Loading…") : model.message).foregroundStyle(.secondary)
                    if !model.message.isEmpty { Button(L("Try Again")) { model.load() } }
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

    private func header(_ title: String, _ hint: String, info: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            InfoTip(info)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func title(_ t: String, _ info: String, font: Font = .headline) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(t).font(font)
            InfoTip(info)
        }
    }

    private func columnLabels(_ a: String, _ b: String) -> some View {
        HStack {
            Text(a).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
            Text(b).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func editor(_ e: PromptEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.title).font(.title2.bold())
                Text(e.custom ? L("Your version") : L("Default")).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Text(e.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            title(L("Instructions"), Tips.instructions)
            TextEditor(text: $model.draft.instructions)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            header(L("Examples"), L("one per line, left and right paired by line number; the model imitates these closely"), info: Tips.examples)
            columnLabels(e.labels.first ?? "", e.labels.last ?? "")
            PairedLinesEditor(left: $model.draft.left, right: $model.draft.right).frame(height: 150)
            if !model.draft.incomplete.isEmpty {
                Label(L("Left out (only one side filled in): line %@", model.draft.incomplete.map(String.init).joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if model.isPrediction {
                Text(L("A continuation starts with the rest of an unfinished word (no space), or with a space when the typed text ends "
                       + "with a whole word. Shaded = a space at the start or end of a line."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Text(L("%d examples", model.draft.pairs.count) + " · " + L("%d characters", model.draft.chars)).monospacedDigit()
                if let t = model.tokens {
                    Text(L("instructions %d tokens · whole prompt %d tokens", t.instructions, t.prompt)).monospacedDigit()
                    if let ms = t.ms { Text(L("≈ %d ms of every request", ms)).monospacedDigit() }
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(L("Reset to Default")) { model.resetToDefault() }
                    .disabled(!e.custom && !model.dirty)
                Spacer()
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button(L("Revert")) { model.revert() }.disabled(!model.dirty)
                Button(L("Save")) { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.dirty || model.draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()
            benchmark(e).id("bench")
                .sheet(isPresented: $model.suiteShown) { SuiteSheet(model: model) }
            Divider()
            historyList()
        }
    }

    // MARK: benchmark

    private struct Column { let title: String; let key: String; let kind: Kind; let info: String; enum Kind { case ms, pct, num, int } }

    private func columns(_ name: String) -> [Column] {
        let cases = Column(title: L("Cases"), key: "cases", kind: .int, info: Tips.cases_),
            lat = Column(title: L("Latency p50"), key: "latency_p50", kind: .ms, info: Tips.latency)
        if name == "proofread-fix" {
            return [cases, Column(title: L("Fully corrected"), key: "exact", kind: .pct, info: Tips.exact),
                    Column(title: L("Word match"), key: "word_match", kind: .pct, info: Tips.wordMatch), lat]
        }
        if name == "proofread-rewrite" { return [cases, Column(title: L("Length vs. original"), key: "length_ratio", kind: .num, info: Tips.length), lat] }
        return [cases, Column(title: L("Next word right"), key: "next_word", kind: .pct, info: Tips.nextWord),
                Column(title: L("Words right"), key: "words_right", kind: .num, info: Tips.wordsRight),
                Column(title: L("Completions"), key: "completions", kind: .pct, info: Tips.completions),
                Column(title: L("Shown"), key: "shown", kind: .pct, info: Tips.shown), lat]
    }

    private func value(_ r: [String: Any]?, _ key: String) -> Double? { (r?[key] as? NSNumber)?.doubleValue }

    private func cell(_ r: [String: Any]?, _ base: [String: Any]?, _ c: Column) -> Text {
        let v = value(r, c.key)
        let text: String = {
            guard let v else { return "–" }
            switch c.kind {
            case .ms: return "\(Int(v)) ms"
            case .pct: return "\(Int((v * 100).rounded()))%"
            case .num: return String(format: "%.2f", v)
            case .int: return "\(Int(v))"
            }
        }()
        // the difference to the default prompt's result in the same category (quality columns only)
        var delta = Text("")
        if let v, let b = value(base, c.key), c.kind == .pct || c.kind == .num {
            let d = c.kind == .pct ? (v - b) * 100 : v - b
            if abs(d) >= (c.kind == .pct ? 0.5 : 0.005) {
                let s = c.kind == .pct ? String(format: "%+.0f", d) : String(format: "%+.2f", d)
                delta = Text(" " + s).font(.caption2).foregroundColor(d > 0 ? .green : .red)
            }
        }
        return Text("\(Text(text).monospacedDigit())\(delta)")
    }

    private func rows(_ r: [String: Any]?) -> [[String: Any]] { r?["categories"] as? [[String: Any]] ?? [] }
    private func row(_ r: [String: Any]?, _ name: String) -> [String: Any]? { rows(r).first { $0["name"] as? String == name } }

    @ViewBuilder private func benchmark(_ e: PromptEntry) -> some View {
        let cols = columns(e.name)
        // what the table shows: this draft's run, else the saved prompt's, else the default's
        let showDraft = model.dirty
        let shown: [String: Any]? = showDraft ? model.draftResult : (e.custom ? e.result : e.defaultResult)
        let base: [String: Any]? = (showDraft || e.custom) ? e.defaultResult : nil
        let userRow: [String: Any]? = {                         // the newer of the full run's and a cases-only run's
            let a = shown?["user"] as? [String: Any]
            if showDraft { return a }
            let b = e.userResult?["user"] as? [String: Any]
            if (e.userResult?["at"] as? String ?? "") > (shown?["at"] as? String ?? "") { return b ?? a }
            return a ?? b
        }()
        VStack(alignment: .leading, spacing: 10) {
            header(L("Benchmark"), model.isPrediction ? L("does the prompt guess what was typed next?")
                   : (e.name == "proofread-rewrite" ? L("no single right answer: length and speed only") : L("does it correct known mistakes?")),
                   info: Tips.benchmark)

            HStack(alignment: .firstTextBaseline) {
                title(L("Built-in test cases"), model.isPrediction ? Tips.builtIn : Tips.builtInProofread, font: .subheadline.bold())
                Text(model.isPrediction ? L("%d texts", e.suiteCases) + " · " + L("%d categories", e.suiteCategories) : L("%d sentences with known mistakes", e.suiteCases))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("View…")) { model.openSuite() }
                    .controlSize(.small)
                    .help(L("See the built-in test cases (read-only)"))
                Spacer()
            }

            title(L("Your test cases"), Tips.cases, font: .subheadline.bold())
            columnLabels(model.isPrediction ? L("Typed text") : L("Text"),
                         e.name == "proofread-fix" ? L("Corrected text") : (e.name == "proofread-rewrite" ? L("A good rewrite") : L("What comes next")))
            PairedLinesEditor(left: $model.casesLeft, right: $model.casesRight).frame(height: 110)
            Text(L("%d cases saved for this prompt (kept on this Mac, outside the repo). They run as their own section.", model.savedCases))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                if model.running != nil {
                    ProgressView(value: Double(model.progress.done), total: Double(max(model.progress.total, 1))).frame(width: 160)
                    Text(L("%@: %d of %d", model.running ?? "", model.progress.done, model.progress.total)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Run Default")) { model.bench(scope: "all", defaultPrompt: true) }.disabled(model.running != nil)
                    .help(L("The shipped prompt on the full benchmark, for comparison"))
                Button(L("Run Your Cases")) { model.bench(scope: "user") }.disabled(model.running != nil || model.casePairs.isEmpty)
                Button(L("Run Full Benchmark")) { model.bench(scope: "all") }.disabled(model.running != nil)
                    .help(L("The built-in test cases and yours"))
            }

            HStack(alignment: .firstTextBaseline) {
                title(showDraft ? L("Results for this draft") : (e.custom ? L("Results for your saved version") : L("Results for the default prompt")),
                      Tips.results, font: .subheadline.bold())
                if base != nil { Text(L("green/red: the difference to the default")).font(.caption).foregroundStyle(.secondary) }
            }
            if shown == nil && userRow == nil {
                Text(L("Not run yet.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        HStack(spacing: 3) { Text(L("Category")).bold(); InfoTip(Tips.category) }
                        ForEach(cols, id: \.key) { c in HStack(spacing: 3) { Text(c.title).bold(); InfoTip(c.info) } }
                    }
                    .font(.caption)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows(shown).enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(PromptEntry.categoryTitle(r["name"] as? String ?? "", r["title"] as? String ?? ""))
                            ForEach(cols, id: \.key) { c in cell(r, row(base, r["name"] as? String ?? ""), c) }
                        }
                    }
                    if let all = shown?["overall"] as? [String: Any], rows(shown).count > 1 {
                        GridRow {
                            HStack(spacing: 3) { Text(L("All categories")).bold(); InfoTip(Tips.all) }
                            ForEach(cols, id: \.key) { c in cell(all, base?["overall"] as? [String: Any], c).bold() }
                        }
                    }
                    if let u = userRow {
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(spacing: 3) { Text(L("Your cases")).bold(); InfoTip(Tips.yours) }
                            ForEach(cols, id: \.key) { c in cell(u, nil, c) }
                        }
                    }
                }
            }
            let skipped = (rows(shown) + [userRow].compactMap { $0 }).reduce(0) { $0 + ($1["skipped"] as? Int ?? 0) }
            if skipped > 0 {
                Label(L("%d cases were left out: they share text with this prompt's examples, so they would test recall, not prediction.",
                        skipped), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text(L("Measured on this Mac with sequential requests, as when typing. Each case keeps its category's app label, so a prompt is "
                   + "tested on every kind of text. Latency can differ by ~70 ms between runs (the system switches model modes). A full run "
                   + "takes about a minute; suggestions pause meanwhile."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: history

    @ViewBuilder private func historyList() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title(L("Saved versions"), Tips.versions)
            if model.history.isEmpty {
                Text(L("None yet. Every Save keeps a version here (the last 20), with its benchmark result if you ran one."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.history) { v in
                HStack {
                    Text(PromptsModel.date(v.savedAt)).monospacedDigit()
                    Text(v.prompt.instructions).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    Spacer()
                    Text(summary(v.result)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if v.prompt == model.entry?.prompt { Text(L("in use")).font(.caption).foregroundStyle(.green) }
                    Button(L("Load")) { model.use(v) }.disabled(v.prompt == model.draft)
                }
            }
        }
    }

    private func summary(_ r: [String: Any]?) -> String {
        guard let o = r?["overall"] as? [String: Any] else { return L("not benchmarked") }
        let lat = (o["latency_p50"] as? NSNumber).map { "\($0.intValue) ms" } ?? "–"
        if let n = (o["next_word"] as? NSNumber)?.doubleValue { return lat + " · " + L("next word %d%% (all)", Int((n * 100).rounded())) }
        if let x = (o["exact"] as? NSNumber)?.doubleValue { return lat + " · " + L("corrected %d%%", Int((x * 100).rounded())) }
        return lat
    }
}

/// What each section and column of the Prompts tab means, shown when the pointer rests on its ⓘ.
enum Tips {
    static let instructions = L("What the model is told to do, sent before every request. {words} becomes the number of words to "
        + "suggest (General tab). Shorter instructions are faster: every token here costs time on each keystroke.")
    static let examples = L("Sample inputs with the answer the model should give. The model copies their form closely: length, tone, "
        + "and how a continuation starts. Each example adds to every request's time.")
    static let benchmark = L("Runs the prompt on test cases and compares its answers with the expected ones, so you can see how a "
        + "change to the prompt affects accuracy and speed before you rely on it.")
    static let builtIn = L("Example texts that come with Homeword (written for testing, no personal data), each cut at a point, with "
        + "what was typed next. They cover chat, email, work documents, academic writing, code, general notes and terminal "
        + "commands, plus 10 texts in each other language you write in, and results are shown per category. None of them is in "
        + "a default prompt's examples. View… shows them.")
    static let builtInProofread = L("Sentences with known mistakes that come with Homeword, and their corrected versions. The prompt "
        + "runs on each and its output is compared with the correction. View… shows them.")
    static let cases = L("Your own texts, as left = typed so far, right = what you would type next. They run as a separate section, "
        + "so you can check a prompt on the kind of text you write. Stored on this Mac only.")
    static let results = L("The last benchmark run of the prompt shown: your draft, your saved version, or the default. Small, noisy "
        + "samples: a difference of one case is several percent.")
    static let versions = L("Every Save keeps a version (the last 20) with its benchmark result, if you ran one. Load one to edit or "
        + "compare it.")
    static let category = L("The kind of text: chat messages, email, work documents, academic writing, code comments and commits, "
        + "general notes, terminal commands; and each other language you write in.")
    static let all = L("All the built-in test cases together (your own cases are shown separately).")
    static let yours = L("Your own test cases.")
    static let cases_ = L("How many texts ran in this row.")
    static let nextWord = L("How often the first suggested word is exactly the word that was typed next (or the right end of an "
        + "unfinished word). The main accuracy number.")
    static let wordsRight = L("How many suggested words in a row match what was typed, on average. Higher = more of a suggestion "
        + "is worth accepting.")
    static let completions = L("Of the texts that end mid-word, how often the suggestion finishes that word correctly.")
    static let shown = L("How often there was a suggestion at all (the model may answer with nothing usable).")
    static let latency = L("The median time from request to suggestion, in milliseconds: half of the suggestions came faster.")
    static let exact = L("How often the output equals the corrected sentence exactly.")
    static let wordMatch = L("How similar the output is to the corrected sentence, word by word (100% = identical).")
    static let length = L("The output's length divided by the input's. Around 1.0 keeps the length; much lower means text was dropped.")
}

/// An ⓘ that explains something when the pointer rests on it.
struct InfoTip: View {
    let text: String
    @StateObject private var hover = Hover()
    init(_ text: String) { self.text = text }

    final class Hover: ObservableObject {
        @Published var shown = false
        var task: DispatchWorkItem?
    }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .onHover { inside in
                hover.task?.cancel()
                let shown = inside
                let w = DispatchWorkItem { hover.shown = shown }
                hover.task = w
                DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.25 : 0.1), execute: w)
            }
            .popover(isPresented: $hover.shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            .accessibilityLabel(text)
            .onAppear {     // for development: `-infoTip "How often the first"` opens the tip whose text starts with it
                if let t = UserDefaults(suiteName: UserDefaults.argumentDomain)?.string(forKey: "infoTip"), text.hasPrefix(t) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { hover.shown = true }
                }
            }
    }
}

/// The built-in test cases of the selected prompt, per category, read-only.
struct SuiteSheet: View {
    @ObservedObject var model: PromptsModel

    var body: some View {
        let cat = model.suite.first { $0.id == model.suiteCategory } ?? model.suite.first
        let proof = !model.isPrediction
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Built-in test cases")).font(.title3.bold())
                Text(model.entry?.title ?? "").foregroundStyle(.secondary)
                Spacer()
                Button(L("Done")) { model.suiteShown = false }.keyboardShortcut(.defaultAction)
            }
            if model.suite.count > 1 {
                HStack {                                    // a menu: 7 categories plus one per writing language never fit as segments
                    Picker(L("Category"), selection: $model.suiteCategory) {
                        ForEach(model.suite) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
            }
            Text(proof ? L("Read-only. Left: a sentence with mistakes; right: the corrected sentence the output is compared with.")
                       : L("Read-only. Left: the text typed so far; right: what was typed next. A suggestion counts as right when it "
                           + "matches the right side."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let split: CGFloat = proof ? 0.5 : 0.7                 // typed texts are long, continuations short
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Text(proof ? L("Text") : L("Typed text")).frame(width: (geo.size.width - 8) * split, alignment: .leading).padding(.leading, 34)
                    Text(proof ? L("Corrected text") : L("What comes next")).padding(.leading, 8)
                    Spacer()
                }
            }
            .frame(height: 14)
            .font(.caption).foregroundStyle(.secondary)
            PairedLinesEditor(left: .constant(cat?.left ?? ""), right: .constant(cat?.right ?? ""), editable: false, split: split)
            HStack {
                Text(L("%d cases", cat?.count ?? 0)).monospacedDigit()
                if let c = cat, !c.skipped.isEmpty {
                    Text("· " + L("Left out for this prompt (they share text with its examples): line %@", c.skipped.map(String.init).joined(separator: ", ")))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 840, height: 560)
    }
}
