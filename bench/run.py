"""Mini benchmark for the typing-ghost policy (ghost/) on predictd. Run it after every change and compare result files.

  python3 -I run.py --spawn --label baseline                # private daemon, policy from ghost/config.json
  python3 -I run.py --spawn --label t200 --config '{"textBudget":200}'      # policy overrides (ghost/config.json keys)
  python3 -I run.py --spawn --daemon-config '{"keepAliveSec":0}' ...        # daemon overrides (predictd.json keys)
  python3 -I run.py --scenario burst|idle|typing ...        # other scenarios
Results: bench/results/<timestamp>-<label>.json (rows + summary). Compare: python3 -I compare.py a.json b.json
"""
import argparse, hashlib, json, os, re, subprocess, sys, tempfile, threading, time, datetime, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
from machine import machine_info, describe
from ghost import predictd
from ghost.policy import Ghost
from ghost.evaluate import score  # noqa: F401  (shared with the app's benchmark)

HERE = pathlib.Path(__file__).parent
PUNCT = " .,;:!?\"'()[]{}"


def norm(w): return w.strip(PUNCT).lower()


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else float("nan")


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def lat(sub):
    e = [r["e2e_ms"] for r in sub]
    m = [r["resp"]["timing"]["model_ms"] for r in sub if "model_ms" in r["resp"].get("timing", {})]
    o = [r["e2e_ms"] - r["resp"]["timing"]["total_ms"] for r in sub if "total_ms" in r["resp"].get("timing", {})]
    return {"n": len(sub), "e2e_p50": pct(e, 50), "e2e_p90": pct(e, 90), "e2e_max": max(e) if e else float("nan"),
            "model_p50": pct(m, 50), "ipc_p50": pct(o, 50)}


def qual(sub):
    mid = [s for s in sub if s["mid"]]
    return {"n": len(sub), "shown": mean(s["shown"] for s in sub), "acc1": mean(s["acc1"] for s in sub),
            "lead_mean": mean(s["lead"] for s in sub), "bag": mean(s["bag"] for s in sub),
            "n_words_mean": mean(s["n_words"] for s in sub), "echo": mean(s["echo"] for s in sub), "cross": sum(s["cross"] for s in sub),
            "comp_n": sum(s["complete"] for s in sub), "comp_space_ok": mean(s["space_ok"] for s in sub if s["complete"]) if any(s["complete"] for s in sub) else float("nan"),
            "mid_n": len(mid), "mid_word_ok": mean(s["word_ok"] for s in mid) if mid else float("nan"),
            "mid_shown": mean(s["shown"] for s in mid) if mid else float("nan")}


def summarize(rows):
    ok = [r for r in rows if r["resp"].get("ok")]
    S = {"n": len(rows), "errors": len(rows) - len(ok)}
    keys = lambda k: list(dict.fromkeys(r["case"][k] for r in ok))
    S["latency"] = lat(ok)
    S["latency_by_bucket"] = {b: lat([r for r in ok if r["case"]["bucket"] == b]) for b in keys("bucket")}
    sess = {}
    for r in ok:
        k = r["resp"]["timing"].get("session", "?")
        sess[k] = sess.get(k, 0) + 1
    S["sessions"] = sess
    toks = [r["resp"]["tokens"] for r in ok if "tokens" in r["resp"]]
    # a request "missed the cache" when fewer than 60% of its input tokens came from the cached prefix
    S["cache"] = {"cached_ratio": mean(t["cached"] / max(t["in"], 1) for t in toks),
                  "misses": sum(t["cached"] < 0.6 * t["in"] * 0.9 for t in toks) if toks else 0,
                  "in_p50": pct([t["in"] for t in toks], 50), "out_p50": pct([t["out"] for t in toks], 50),
                  "out_max": max([t["out"] for t in toks] or [0]), "trimmed": sum(t["trimmed"] for t in toks)}
    sc = [r["score"] for r in ok if "score" in r]
    S["quality"] = qual(sc)
    S["quality_by_bucket"] = {b: qual([r["score"] for r in ok if r["case"]["bucket"] == b]) for b in keys("bucket")}
    S["quality_by_app"] = {a: qual([r["score"] for r in ok if r["case"]["app"] == a]) for a in keys("app")}
    S["misspelled_per_req"] = mean(r["resp"].get("misspelled", 0) for r in ok)
    S["suppressed_invalid"] = sum(1 for r in ok if r["resp"].get("suppressed"))
    S["respaced"] = sum(1 for r in ok if r["resp"].get("respaced"))
    return S


def f(x, w=6, d=0):
    return f"{x:{w}.{d}f}" if x == x else "nan".rjust(w)


def report(S, title):
    L = S["latency"]
    print(f"\n== {title}: {S['n']} requests, {S['errors']} errors; session state at request time: {S['sessions']}")
    print(f"latency (client-side e2e, ms)   p50 {f(L['e2e_p50'])}  p90 {f(L['e2e_p90'])}  max {f(L['e2e_max'])}   | model p50 {f(L['model_p50'])}  socket+json p50 {f(L['ipc_p50'], 6, 1)}")
    print("  by context size:")
    for b, l in S["latency_by_bucket"].items():
        print(f"    {b:>3} n={l['n']:<3} e2e p50 {f(l['e2e_p50'])}  p90 {f(l['e2e_p90'])}  max {f(l['e2e_max'])}   model p50 {f(l['model_p50'])}")
    C = S["cache"]
    print(f"cache: {C['cached_ratio']*100:.0f}% of input tokens cached on average, {C['misses']} requests missed the prefix cache; input tokens p50 {C['in_p50']:.0f}, output tokens p50 {C['out_p50']:.0f} (max {C['out_max']}); {C['trimmed']} contexts trimmed")
    Q = S["quality"]
    if Q["n"]:
        print(f"quality vs what the user actually typed next ({Q['n']} cases):")
        print(f"    suggestion shown {Q['shown']*100:.0f}% | first word right {Q['acc1']*100:.0f}% | mean leading words right {Q['lead_mean']:.2f} | word overlap {Q['bag']*100:.0f}% | words/suggestion {Q['n_words_mean']:.1f} | echo {Q['echo']*100:.0f}% | crossing a sentence end {Q['cross']}")
        print(f"    mid-word cuts (n={Q['mid_n']}): completed word exactly right {Q['mid_word_ok']*100:.0f}%, shown {Q['mid_shown']*100:.0f}% | invalid words suppressed {S['suppressed_invalid']} | re-spaced {S['respaced']} | misspelled words/request {S['misspelled_per_req']:.2f}")
        print(f"    finished word at the end, no trailing space (n={Q['comp_n']}): space inserted correctly {Q['comp_space_ok']*100:.0f}%")
        for k, name in (("quality_by_bucket", "context"), ("quality_by_app", "app")):
            print("    by " + name + ": " + "; ".join(f"{b} n={q['n']} first-word {q['acc1']*100:.0f}% lead {q['lead_mean']:.1f}" for b, q in S[k].items()))


def samples(rows, n=14):
    print("\nsamples (…typed | predicted | actual):")
    for r in rows[:: max(1, len(rows) // n)][:n]:
        if "score" not in r:
            continue
        t = r["case"]["text"][-34:].replace("\n", "⏎")
        print(f"  [{r['case']['id']:>4} {r['e2e_ms']:5.0f}ms] …{t!r:38} | {r['score']['pred'][:44]!r:48} | {r['score']['truth'][:44]!r}")


def run_cases(c, ghost, cases, gap, opts, scenario, idle_n=8):
    rows = []
    if scenario == "idle":
        cases = [x for x in cases if x["bucket"] in ("xs", "s")][:idle_n]
    for i, case in enumerate(cases):
        time.sleep(gap)
        t = time.perf_counter()
        r = ghost.predict(c, case["app"], case["text"], opts)
        e2e = (time.perf_counter() - t) * 1000
        row = {"case": case, "e2e_ms": e2e, "resp": r}
        if r.get("ok"):
            row["score"] = score(case, r)
        rows.append(row)
        print(f"\r  {i+1}/{len(cases)}", end="", flush=True)
    print()
    return rows


def run_typing(c, aux, ghost, cases, key_ms, nkeys=12, ncases=8):
    """Simulate typing: after every keystroke send the text so far on one stream (a new request supersedes the old one)
    and time how long the answer to the LAST keystroke takes. No client-side debounce, so this is the worst case."""
    got = {}

    def reader():
        while True:
            try:
                ms_ = c.read(0.05)
            except Exception:
                return
            for r in ms_:
                got[r["id"]] = (r, time.perf_counter())
    threading.Thread(target=reader, daemon=True).start()
    rows, sent_n, superseded = [], 0, 0
    for case in [x for x in cases if x["bucket"] in ("xs", "s")][:ncases]:
        time.sleep(1.5)
        end = len(case["text"])
        ids, ctxs, t_last = [], {}, time.perf_counter()
        for k in range(nkeys):
            text = case["text"][: end - (nkeys - 1 - k)]
            gen, ctx = ghost.request(case["app"], text)
            rid = c.send(stream="typing", **gen)
            ids.append(rid)
            ctxs[rid] = ctx
            t_last = time.perf_counter()
            sent_n += 1
            if k < nkeys - 1:
                time.sleep(key_ms / 1000)
        while ids[-1] not in got and time.perf_counter() - t_last < 10:
            time.sleep(0.005)
        time.sleep(0.2)
        r, t_resp = got.get(ids[-1], ({"ok": False, "error": "timeout"}, time.perf_counter()))
        t_fin = time.perf_counter()
        r = ghost.finish(ctxs[ids[-1]], r, lambda ws, lang: aux.call(op="spell", words=ws, language=lang)["valid"])
        t_resp += time.perf_counter() - t_fin
        superseded += sum(1 for i in ids[:-1] if got.get(i, ({},))[0].get("error") == "cancelled")
        row = {"case": case, "e2e_ms": (t_resp - t_last) * 1000, "resp": r}
        if r.get("ok"):
            row["score"] = score(case, r)
        rows.append(row)
    return rows, sent_n, superseded, aux.call(op="stats")


def run_styles(a, c, ghost, proc):
    """Every writing style's prompt on the whole suite (bench/cases.json + bench/styles.json), reported per category."""
    from ghost.evaluate import CATEGORIES, bench_proofread, bench_prompt
    from ghost.proofread import Proofreader
    results = {}
    cats = [k for k, _ in CATEGORIES]
    print("next word right per category (cases), latency p50 over all cases")
    print(f"{'prompt':18}" + "".join(f"{k:>10}" for k in cats) + f"{'all':>8}{'p50':>8}")
    for st in ghost.style_names():
        r = results["predict-" + st] = bench_prompt(ghost, c, st)
        by = {x["name"]: x for x in r["categories"]}
        print(f"{'predict-' + st:18}" + "".join(f"{by[k]['next_word']:>9.0%} " if k in by else f"{'-':>10}" for k in cats)
              + f"{r['overall']['next_word']:>7.0%} {r['overall']['latency_p50']:>5} ms")
    print("cases:" + " " * 12 + "".join(f"{x['cases']:>10}" for x in r["categories"]))
    proof = Proofreader(ghost.cfg)
    for mode in ("fix", "rewrite"):
        r = results["proofread-" + mode] = bench_proofread(proof, c, mode)
        o = r["overall"]
        q = f"fully corrected {o['exact']:.0%}, word match {o['word_match']:.2f}" if mode == "fix" else f"length ratio {o['length_ratio']}"
        print(f"{'proofread-' + mode:18} {o['cases']} cases, p50 {o['latency_p50']} ms, {q}")
    res = HERE / "results"
    res.mkdir(exist_ok=True)
    path = res / f"{datetime.datetime.now():%Y%m%d-%H%M%S}-{a.label}-styles.json"
    mach = machine_info()
    print("machine:", describe(mach))
    json.dump({"label": a.label, "scenario": "styles", "machine": mach, "policy": ghost.cfg, "results": results}, open(path, "w"), indent=1)
    print("saved", path)
    if proc:
        proc.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="run")
    ap.add_argument("--socket", default=f"/tmp/predictd-{os.getuid()}.sock")
    ap.add_argument("--spawn", action="store_true", help="start a private daemon for this run")
    ap.add_argument("--config", default="{}", help="JSON policy overrides (ghost/config.json keys)")
    ap.add_argument("--daemon-config", default="{}", help="JSON overrides for the spawned daemon (predictd.json keys)")
    ap.add_argument("--opts", default="{}", help="JSON per-request policy overrides (words, maxTokens, textBudget, ...)")
    ap.add_argument("--scenario", default="steady", choices=["steady", "burst", "idle", "typing"])
    ap.add_argument("--gap-ms", type=float, default=None)
    ap.add_argument("--key-ms", type=float, default=150)
    ap.add_argument("--cases", default=str(HERE / "cases.json"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--styles", action="store_true", help="every writing style's shipped prompt on the whole suite (cases.json + "
                    "styles.json), per category, and proofreading (what Homeword's Prompts tab runs)")
    a = ap.parse_args()
    proc, sock = None, a.socket
    if a.spawn:
        cfg = json.load(open(HERE.parent / "predictd.json"))
        cfg["httpPort"] = 0                                 # private daemon: leave the shared HTTP port to the main one
        cfg.update(json.loads(a.daemon_config))
        tmp = tempfile.mkdtemp()
        cfgp, sock, logp = os.path.join(tmp, "predictd.json"), os.path.join(tmp, "p.sock"), os.path.join(tmp, "log")
        json.dump(cfg, open(cfgp, "w"))
        proc = subprocess.Popen([str(HERE.parent / "predictd"), "--config", cfgp, "--user-config", "", "--socket", sock],
                                stderr=open(logp, "w"), stdout=subprocess.DEVNULL)
        for _ in range(300):
            if "ready on" in open(logp).read():
                break
            time.sleep(0.1)
        else:
            sys.exit("daemon did not start: " + open(logp).read())
    c, aux = predictd.Link(sock), predictd.Link(sock)
    ghost = Ghost(overrides=json.loads(a.config), user=False)     # the shipped prompts and knobs, not the user's
    if a.styles:
        return run_styles(a, c, ghost, proc)
    ghost.ensure_profile(aux, pin=True)
    cases = json.load(open(a.cases))
    if a.limit:
        cases = cases[: a.limit]
    opts = json.loads(a.opts)
    gap = (a.gap_ms if a.gap_ms is not None else {"steady": 1200, "burst": 0, "idle": 15000, "typing": 0}[a.scenario]) / 1000
    for w in cases[:3]:                                   # warm-up, discarded
        ghost.predict(c, w["app"], w["text"], opts)
        time.sleep(1.0)
    extra = {}
    if a.scenario == "typing":
        rows, sent, sup, stats = run_typing(c, aux, ghost, cases, a.key_ms)
        extra = {"keystrokes_sent": sent, "superseded": sup, "key_ms": a.key_ms}
    else:
        rows = run_cases(c, ghost, cases, gap, opts, a.scenario)
        stats = aux.call(op="stats")
    stats.get("config", {}).pop("socketPath", None)       # a temp path on this machine: keep it out of shared results
    S = summarize(rows)
    S.update(extra)
    # The system runs the model in (at least) two modes that give different but deterministic greedy outputs and different speed
    # (seen: ~325 vs ~393 ms p50, 21/82 identical outputs between modes, 82/82 within one, on an earlier 82-case set). Fingerprint the raw outputs so runs
    # from different modes are not compared as if a code change caused the difference.
    raw = "|".join(str(r["resp"].get("model_completion")) for r in rows[:20])
    S["mode_fingerprint"] = hashlib.md5(raw.encode()).hexdigest()[:8]
    print(f"model mode fingerprint (raw outputs of the first 20 cases): {S['mode_fingerprint']}")
    prefix = {p["name"]: p["prefix_tokens"] for p in stats["profiles"]}
    print(f"\ndaemon stats: generations {stats['requests']} new sessions {stats['cold']} cancelled {stats['cancelled']} errors {stats['errors']} keepalives {stats['keepalives']}; profile prefix tokens {prefix}")
    print(f"policy: {json.dumps(ghost.cfg, sort_keys=True)}")
    title = a.scenario + (f" (key every {a.key_ms:.0f} ms, {extra['superseded']}/{extra['keystrokes_sent']} requests superseded; e2e = last keystroke to answer)" if extra else f" (gap {gap*1000:.0f} ms)")
    report(S, title)
    samples(rows)
    res = HERE / "results"
    res.mkdir(exist_ok=True)
    path = res / f"{datetime.datetime.now():%Y%m%d-%H%M%S}-{a.label}.json"
    mach = machine_info()
    print("machine:", describe(mach))
    json.dump({"label": a.label, "scenario": a.scenario, "machine": mach, "opts": opts, "policy": ghost.cfg, "daemon": stats, "summary": S, "rows": rows}, open(path, "w"), indent=1, default=str)
    print("\nsaved", path)
    if proc:
        try:
            aux.call(op="shutdown", timeout=3)
        except Exception:
            pass
        proc.terminate()


if __name__ == "__main__":
    main()
