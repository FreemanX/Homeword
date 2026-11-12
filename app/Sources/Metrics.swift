// Usage metrics, to improve the app: latency, how often suggestions are shown and accepted, proofreading outcomes. One JSON object
// per line in ~/Library/Application Support/Homeword/metrics.jsonl. Never any typed or selected text: only counts, lengths,
// timings, the writing style and the app's bundle identifier. bench/app_metrics.py summarises the file.
import Foundation

final class Metrics {
    static let shared = Metrics()
    let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Homeword")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metrics.jsonl")
    }()
    private let queue = DispatchQueue(label: "metrics")
    private var keys: [String: Int] = [:]          // keystrokes in text fields per app, flushed every minute
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.flushKeys() }
    }

    func log(_ kind: String, _ fields: [String: Any]) {
        var o = fields
        o["kind"] = kind
        o["t"] = ISO8601DateFormatter().string(from: Date())
        queue.async {
            guard var line = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
            line.append(10)
            if let h = try? FileHandle(forWritingTo: self.url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: self.url)
            }
        }
    }

    func keystrokes(_ n: Int, app: String) { keys[app, default: 0] += n }

    func flushKeys() {
        for (app, n) in keys where n > 0 { log("keys", ["app": app, "n": n]) }
        keys = [:]
    }

    func reset() {
        queue.async { try? FileManager.default.removeItem(at: self.url) }
        keys = [:]
    }

    /// All events so far (for the statistics window).
    func load() -> [[String: Any]] {
        flushKeys()
        return queue.sync {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }
}

/// One shown suggestion, from the moment it appears until it is used up, replaced or dismissed.
final class SuggestionRecord {
    let app: String, style: String, source: String              // source: "field" (read from the app) or "typed" (keys typed)
    let latency: Double, model: Double
    let words: Int, chars: Int
    var acceptedWords = 0, acceptedChars = 0, typedAlong = 0
    init(app: String, style: String, latency: Double, model: Double, suggestion: String, source: String = "field") {
        self.app = app; self.style = style; self.latency = latency; self.model = model; self.source = source
        words = suggestion.split(whereSeparator: \.isWhitespace).count; chars = suggestion.count
    }
    func finish(_ how: String) {
        let outcome = acceptedWords > 0 ? (acceptedChars >= chars ? "accepted_all" : "accepted_part") : typedAlong >= 2 ? "typed_along" : how
        Metrics.shared.log("suggestion", ["app": app, "style": style, "source": source, "latency_ms": Int(latency), "model_ms": Int(model), "words": words,
                                          "chars": chars, "accepted_words": acceptedWords, "accepted_chars": acceptedChars,
                                          "typed_along": typedAlong, "outcome": outcome])
    }
}

/// Aggregates for the statistics window (bench/app_metrics.py computes the same from the file).
struct MetricsSummary {
    var shown = 0, accepted = 0, acceptedWords = 0, acceptedChars = 0, typedAlong = 0, keys = 0
    var latencies: [Double] = [], models: [Double] = []
    var empty = 0, errors = 0
    var perApp: [String: (shown: Int, accepted: Int)] = [:]
    var perStyle: [String: (shown: Int, accepted: Int, latencies: [Double])] = [:]
    var proofreads = 0, replaced = 0, copied = 0, cancelled = 0, failed = 0, proofLatencies: [Double] = []

    init(_ events: [[String: Any]]) {
        for e in events {
            let app = e["app"] as? String ?? "?"
            switch e["kind"] as? String {
            case "suggestion":
                shown += 1
                let w = e["accepted_words"] as? Int ?? 0
                if w > 0 { accepted += 1 }
                acceptedWords += w; acceptedChars += e["accepted_chars"] as? Int ?? 0; typedAlong += e["typed_along"] as? Int ?? 0
                if let l = e["latency_ms"] as? Double { latencies.append(l) }
                if let m = e["model_ms"] as? Double { models.append(m) }
                var a = perApp[app] ?? (0, 0); a.shown += 1; if w > 0 { a.accepted += 1 }; perApp[app] = a
                let st = e["style"] as? String ?? "general"
                var b = perStyle[st] ?? (0, 0, []); b.shown += 1; if w > 0 { b.accepted += 1 }
                if let l = e["latency_ms"] as? Double { b.latencies.append(l) }
                perStyle[st] = b
            case "request":
                if (e["outcome"] as? String ?? "").hasPrefix("error") { errors += 1 } else { empty += 1 }
            case "keys": keys += e["n"] as? Int ?? 0
            case "proofread":
                proofreads += 1
                switch e["outcome"] as? String { case "replaced": replaced += 1; case "copied": copied += 1; case "failed": failed += 1; default: cancelled += 1 }
                if let l = e["latency_ms"] as? Double { proofLatencies.append(l) }
            default: break
            }
        }
    }
    static func pct(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((p / 100 * Double(s.count - 1)).rounded()))]
    }
}
