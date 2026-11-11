"""Mini benchmark for the typing predictor (ghostd on predictd). Run it after every change and compare result files.

  python3 -I run.py --spawn --label baseline                # private daemon, policy from ghost/config.json
  python3 -I run.py --spawn --label t200 --config '{"textBudget":200}'      # policy overrides (ghost/config.json keys)
  python3 -I run.py --spawn --daemon-config '{"keepAliveSec":0}' ...        # daemon overrides (predictd.json keys)
  python3 -I run.py --scenario burst|idle|typing ...        # other scenarios
Results: bench/results/<timestamp>-<label>.json (rows + summary). Compare: python3 -I compare.py a.json b.json
The policy runs in a private ghostd (HTTP) without the user's config overrides and prompts; latency is measured from here, so it
includes the local HTTP round trip (~1 ms).
"""
import argparse, hashlib, json, os, re, subprocess, sys, tempfile, threading, time, datetime, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from machine import machine_info, describe, model_users
from engine import Ghostd, predictd_call

HERE = pathlib.Path(__file__).parent
PUNCT = " .,;:!?\"'()[]{}"


def norm(w): return w.strip(PUNCT).lower()


def score(case, r):
    """Quality of one response against what the user actually typed next (the same as ghost/Evaluate.swift's score)."""
    partial = r.get("partial", "")
    sug = r.get("suggestion", "") or ""
    pred = (partial + sug).split()
    truth = (partial + case["rest"]).split()
    lead = 0
    for a, b in zip(pred, truth):
        if norm(a) != norm(b):
            break
        lead += 1
    tset = {norm(w) for w in truth}
    bag = sum(norm(w) in tset for w in pred) / len(pred) if pred else 0.0
    last3 = [norm(w) for w in case["text"].split()[-3:]]
    echo = len(last3) == 3 and " ".join(last3) in " ".join(norm(w) for w in sug.split())
    complete = bool(case["text"]) and not case["text"][-1].isspace() and case["rest"].startswith(" ")
    return {"complete": complete, "space_ok": complete and (sug.startswith(" ") or not sug.strip()), "shown": bool(sug.strip()),
            "cross": bool(re.search(r"[.!?]\s+\S", sug)), "mid": partial != "", "lead": lead, "acc1": lead >= 1,
            "word_ok": bool(pred) and bool(truth) and norm(pred[0]) == norm(truth[0]),
            "bag": bag, "n_words": len(sug.split()), "echo": echo,
            "truth": " ".join(truth[:8]), "pred": " ".join(pred)}


def predict(g, app, text, opts=None, stream=None):
    body = {"app": app, "text": text, "opts": opts or {}}
    if stream:
        body["stream"] = stream
    return g.post("/predict", body)


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


def run_cases(g, cases, gap, opts, scenario, idle_n=8):
    rows = []
    if scenario == "idle":
        cases = [x for x in cases if x["bucket"] in ("xs", "s")][:idle_n]
    for i, case in enumerate(cases):
        time.sleep(gap)
        t = time.perf_counter()
        r = predict(g, case["app"], case["text"], opts)
        e2e = (time.perf_counter() - t) * 1000
        row = {"case": case, "e2e_ms": e2e, "resp": r}
        if r.get("ok"):
            row["score"] = score(case, r)
        rows.append(row)
        print(f"\r  {i+1}/{len(cases)}", end="", flush=True)
    print()
    return rows


def run_typing(g, sock, cases, key_ms, nkeys=12, ncases=8):
    """Simulate typing: after every keystroke send the text so far on one stream (a new request supersedes the old one)
    and time how long the answer to the LAST keystroke takes. No client-side debounce, so this is the worst case."""
    rows, sent_n, superseded = [], 0, 0
    for case in [x for x in cases if x["bucket"] in ("xs", "s")][:ncases]:
        time.sleep(1.5)
        end = len(case["text"])
        got, threads, t_last = {}, [], time.perf_counter()

        def ask(k, text):
            r = predict(g, case["app"], text, stream="typing")
            got[k] = (r, time.perf_counter())
        for k in range(nkeys):
            th = threading.Thread(target=ask, args=(k, case["text"][: end - (nkeys - 1 - k)]), daemon=True)
            th.start()
            threads.append(th)
            t_last = time.perf_counter()
            sent_n += 1
            if k < nkeys - 1:
                time.sleep(key_ms / 1000)
        for th in threads:
            th.join(10)
        r, t_resp = got.get(nkeys - 1, ({"ok": False, "error": "timeout"}, time.perf_counter()))
        superseded += sum(1 for k in range(nkeys - 1) if got.get(k, ({},))[0].get("error") == "cancelled")
        row = {"case": case, "e2e_ms": (t_resp - t_last) * 1000, "resp": r}
        if r.get("ok"):
            row["score"] = score(case, r)
        rows.append(row)
    return rows, sent_n, superseded, predictd_call({"op": "stats"}, sock)


def other_daemons(proc):
    """predictd processes besides this run's private one. Another model host evicts this run's cache (one cached session per
    system) and makes the results invalid, e.g. the shared engine started by Homeword or an integration during the run."""
    if not proc:
        return []
    out = subprocess.run(["pgrep", "-x", "predictd"], capture_output=True, text=True).stdout.split()
    return [p for p in out if p != str(proc.pid)]


def concurrency_note(proc, g):
    others = [f"predictd (pid {p})" for p in other_daemons(proc)] if proc else []
    others += [u for u in model_users(mine=(g.proc.pid,)) if not u.startswith("predictd")] if proc else []
    if others:
        print(f"WARNING: other model users during this run ({'; '.join(others)}): results are invalid, quit Homeword and the "
              "integrations, run bin/pred stop and repeat")
    return bool(others)


def bench_job(g, name):
    """One prompt on the suite through ghostd's /bench (what Homeword's Prompts tab runs): the result per category."""
    r = g.post("/bench", {"name": name, "scope": "all"})
    if not r.get("ok"):
        sys.exit(f"{name}: {r.get('error')}")
    while True:
        time.sleep(0.5)
        j = g.get(f"/bench?job={r['job']}")
        if j.get("state") == "running":
            print(f"\r  {name} {j.get('done', 0)}/{j.get('total', 0)}", end="", file=sys.stderr, flush=True)
            continue
        print("\r\x1b[K", end="", file=sys.stderr, flush=True)
        if j.get("state") != "done":
            sys.exit(f"{name}: {j.get('error')}")
        return j["result"]


def run_styles(a, g, proc):
    """Every writing style's prompt on the whole suite (bench/cases.json + bench/styles.json), reported per category."""
    results = {}
    styles = [x["name"] for x in g.get("/prompts")["styles"]]
    print("next word right per category (cases), latency p50 over all cases")
    head = False
    for st in styles:
        r = results["predict-" + st] = bench_job(g, "predict-" + st)
        cats = [x["name"] for x in r["categories"]]
        if not head:
            print(f"{'prompt':18}" + "".join(f"{k:>10}" for k in cats) + f"{'all':>8}{'p50':>8}")
            head = True
        by = {x["name"]: x for x in r["categories"]}
        print(f"{'predict-' + st:18}" + "".join(f"{by[k]['next_word']:>9.0%} " if k in by else f"{'-':>10}" for k in cats)
              + f"{r['overall']['next_word']:>7.0%} {r['overall']['latency_p50']:>5} ms")
    print("cases:" + " " * 12 + "".join(f"{x['cases']:>10}" for x in r["categories"]))
    for mode in ("fix", "rewrite"):
        r = results["proofread-" + mode] = bench_job(g, "proofread-" + mode)
        o = r["overall"]
        q = f"fully corrected {o['exact']:.0%}, word match {o['word_match']:.2f}" if mode == "fix" else f"length ratio {o['length_ratio']}"
        print(f"{'proofread-' + mode:18} {o['cases']} cases, p50 {o['latency_p50']} ms, {q}")
    res = HERE / "results"
    res.mkdir(exist_ok=True)
    path = res / f"{datetime.datetime.now():%Y%m%d-%H%M%S}-{a.label}-styles.json"
    mach = machine_info()
    print("machine:", describe(mach))
    concurrent = concurrency_note(proc, g)
    json.dump({"label": a.label, "scenario": "styles", "machine": mach, "policy": g.get("/config")["config"], "results": results,
               "concurrent_daemon": concurrent}, open(path, "w"), indent=1)
    print("saved", path)


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
    proc, sock, tmp = None, a.socket, None
    if a.spawn:
        busy = model_users()
        if busy:
            sys.exit(f"other model users: {'; '.join(busy)}: they would evict this run's cache. Quit Homeword and the "
                     "integrations, run bin/pred stop, then retry")
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
    g = Ghostd(sock, config=json.loads(a.config), no_user=True,  # the shipped prompts and knobs, not the user's
               log=os.path.join(tmp, "ghostd.log") if a.spawn else None)
    try:
        run(a, g, sock, proc)
    finally:
        g.close()
        if proc:
            predictd_call({"op": "shutdown"}, sock, timeout=3)
            proc.terminate()


def run(a, g, sock, proc):
    if a.styles:
        return run_styles(a, g, proc)
    cases = json.load(open(a.cases))
    if a.limit:
        cases = cases[: a.limit]
    opts = json.loads(a.opts)
    gap = (a.gap_ms if a.gap_ms is not None else {"steady": 1200, "burst": 0, "idle": 15000, "typing": 0}[a.scenario]) / 1000
    for w in cases[:3]:                                   # warm-up, discarded
        predict(g, w["app"], w["text"], opts)
        time.sleep(1.0)
    extra = {}
    if a.scenario == "typing":
        rows, sent, sup, stats = run_typing(g, sock, cases, a.key_ms)
        extra = {"keystrokes_sent": sent, "superseded": sup, "key_ms": a.key_ms}
    else:
        rows = run_cases(g, cases, gap, opts, a.scenario)
        stats = predictd_call({"op": "stats"}, sock)
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
    policy = g.get("/config")["config"]
    print(f"policy: {json.dumps(policy, sort_keys=True)}")
    title = a.scenario + (f" (key every {a.key_ms:.0f} ms, {extra['superseded']}/{extra['keystrokes_sent']} requests superseded; e2e = last keystroke to answer)" if extra else f" (gap {gap*1000:.0f} ms)")
    report(S, title)
    samples(rows)
    res = HERE / "results"
    res.mkdir(exist_ok=True)
    path = res / f"{datetime.datetime.now():%Y%m%d-%H%M%S}-{a.label}.json"
    mach = machine_info()
    print("machine:", describe(mach))
    S["concurrent_daemon"] = concurrency_note(proc, g)
    json.dump({"label": a.label, "scenario": a.scenario, "machine": mach, "opts": opts, "policy": policy, "daemon": stats, "summary": S, "rows": rows}, open(path, "w"), indent=1, default=str)
    print("\nsaved", path)


if __name__ == "__main__":
    main()
