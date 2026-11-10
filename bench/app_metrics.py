"""Summarise the Mac app's (Homeword) usage metrics (app/README.md): suggestion latency, acceptance, keystrokes saved, writing
styles, proofreading.

  python3 -I bench/app_metrics.py [metrics.jsonl] [--since YYYY-MM-DD] [--json]

The file holds counts, lengths, timings and app bundle identifiers, never text. Default location:
~/Library/Application Support/Homeword/metrics.jsonl. It stays on the machine: don't commit it or its per-app breakdown.
"""
import collections, json, pathlib, sys

DEFAULT = pathlib.Path.home() / "Library/Application Support/Homeword/metrics.jsonl"


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, round(p / 100 * (len(s) - 1)))]


def summarise(events):
    sug = [e for e in events if e.get("kind") == "suggestion"]
    req = [e for e in events if e.get("kind") == "request"]
    proof = [e for e in events if e.get("kind") == "proofread"]
    keys = sum(e.get("n", 0) for e in events if e.get("kind") == "keys")
    accepted = [e for e in sug if e.get("accepted_words", 0) > 0]
    chars = sum(e.get("accepted_chars", 0) for e in sug)
    tabs = sum(e.get("accepted_words", 0) for e in sug)
    lat = [e["latency_ms"] for e in sug if "latency_ms" in e]
    per_app = collections.defaultdict(lambda: {"shown": 0, "accepted": 0, "words": 0})
    per_style = collections.defaultdict(lambda: {"shown": 0, "accepted": 0, "latencies": []})
    for e in sug:
        st = per_style[e.get("style", "general")]
        st["shown"] += 1
        st["accepted"] += e.get("accepted_words", 0) > 0
        if "latency_ms" in e:
            st["latencies"].append(e["latency_ms"])
    for e in sug:
        a = per_app[e.get("app", "?")]
        a["shown"] += 1
        a["accepted"] += e.get("accepted_words", 0) > 0
        a["words"] += e.get("accepted_words", 0)
    return {
        "suggestions": {
            "shown": len(sug),
            "accepted": len(accepted),
            "acceptance_rate": round(len(accepted) / len(sug), 3) if sug else None,
            "outcomes": dict(collections.Counter(e.get("outcome", "?") for e in sug).most_common()),
            "words_shown": sum(e.get("words", 0) for e in sug),
            "words_accepted": tabs,
            "words_per_accepted": round(tabs / len(accepted), 2) if accepted else None,
            "chars_accepted": chars,
            "chars_typed_along": sum(e.get("typed_along", 0) for e in sug),
            "latency_ms": {"p50": pct(lat, 50), "p90": pct(lat, 90), "p99": pct(lat, 99)},
            "model_ms_p50": pct([e["model_ms"] for e in sug if e.get("model_ms")], 50),
        },
        "keystrokes": {
            "typed": keys,
            "saved": chars - tabs,  # characters Tab inserted, minus the Tab presses
            "saved_share": round((chars - tabs) / (keys + chars - tabs), 3) if keys + chars else None,
        },
        "requests_without_suggestion": dict(collections.Counter(e.get("outcome", "?").split(":")[0] for e in req).most_common()),
        "per_app": dict(sorted(per_app.items(), key=lambda kv: -kv[1]["shown"])),
        "per_style": {k: {"shown": v["shown"], "accepted": v["accepted"], "latency_p50": pct(v["latencies"], 50)}
                      for k, v in sorted(per_style.items(), key=lambda kv: -kv[1]["shown"])},
        "proofread": {
            "requests": len(proof),
            "by_mode": dict(collections.Counter(e.get("mode", "?") for e in proof)),
            "outcomes": dict(collections.Counter(e.get("outcome", "?") for e in proof).most_common()),
            "latency_ms_p50": pct([e["latency_ms"] for e in proof if e.get("outcome") != "cancelled"], 50),
            "edits_p50": pct([e.get("edits", 0) for e in proof if e.get("outcome") in ("replaced", "copied")], 50),
        },
    }


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    since = args[args.index("--since") + 1] if "--since" in args else ""
    files = [a for a in args if a.endswith(".jsonl")]
    path = pathlib.Path(files[0]) if files else DEFAULT
    if not path.exists():
        sys.exit(f"no metrics yet: {path}")
    events = []
    for line in path.read_text().splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("t", "") >= since:
            events.append(e)
    s = summarise(events)
    if as_json:
        print(json.dumps(s, indent=2))
        return
    g, k, p = s["suggestions"], s["keystrokes"], s["proofread"]
    fmt = lambda x, unit="": "–" if x is None else f"{x}{unit}"
    print(f"suggestions   {g['shown']} shown, {g['accepted']} accepted ({fmt(g['acceptance_rate'] and round(g['acceptance_rate'] * 100), '%')})")
    print(f"              outcomes {g['outcomes']}")
    print(f"              {g['words_accepted']} words accepted of {g['words_shown']} shown, {fmt(g['words_per_accepted'])} per accepted suggestion")
    print(f"latency       key → pop-up p50 {fmt(g['latency_ms']['p50'], ' ms')}, p90 {fmt(g['latency_ms']['p90'], ' ms')}, "
          f"p99 {fmt(g['latency_ms']['p99'], ' ms')}; model p50 {fmt(g['model_ms_p50'], ' ms')}")
    print(f"keystrokes    {k['typed']} typed in text fields, {k['saved']} saved ({fmt(k['saved_share'] and round(k['saved_share'] * 100, 1), '%')})")
    print(f"no suggestion {s['requests_without_suggestion']}")
    for st, a in s["per_style"].items():
        print(f"  style {st:34} {a['shown']:5} shown {a['accepted']:5} accepted   p50 {fmt(a['latency_p50'], ' ms')}")
    for app, a in list(s["per_app"].items())[:10]:
        print(f"  {app:40} {a['shown']:5} shown {a['accepted']:5} accepted {a['words']:5} words")
    print(f"proofread     {p['requests']} {p['by_mode']}, outcomes {p['outcomes']}, "
          f"answer p50 {fmt(p['latency_ms_p50'], ' ms')}, edits p50 {fmt(p['edits_p50'])}")


if __name__ == "__main__":
    main()
