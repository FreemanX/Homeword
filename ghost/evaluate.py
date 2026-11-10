"""Benchmarks of a prompt on the running model, per writing style: what the Mac app's Prompts tab runs (POST /bench) and
`bench/run.py --styles` reports. Cases: bench/styles.json (synthetic, ~14 per style, plus proofreading sentences with known
corrections).

Prediction metrics (the same as bench/run.py):
  latency_p50/p90   ms per suggestion, sequential requests on a warm prefix (like typing)
  next_word         share of cases whose first suggested word is what was typed next (acc1)
  words_right       mean number of leading suggested words that match (lead)
  completions       share of mid-word cases whose completed word is right (mid_word_ok)
  shown             share of cases with a suggestion
Proofreading: latency, `exact` (output equals the expected sentence), `word_match` (word-level similarity to it); rewriting has no
ground truth: latency and `length_ratio` (output / input length).
"""
import difflib, json, os, re, statistics, time

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
CASES = os.path.join(ROOT, "bench", "styles.json")
PUNCT = " .,;:!?\"'()[]{}"


def norm(w):
    return w.strip(PUNCT).lower()


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else None


def score(case, r):
    """Quality of one response against what the user actually typed next."""
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


def load_cases(path=CASES):
    return {k: v for k, v in json.load(open(path)).items() if not k.startswith("_")}


def _mean(xs):
    xs = list(xs)
    return round(sum(xs) / len(xs), 3) if xs else None


def bench_style(ghost, link, style, prompt=None, stream="bench", cases=None):
    """Run a style's cases with `prompt` (default: the prompt in use) and summarise."""
    cases = cases or load_cases()[style]
    label = ghost.style_label(style)
    ghost.predict(link, label, cases[0]["text"], style=style, prompt=prompt, stream=stream)   # warm the prefix, as when typing
    lat, scores, errors = [], [], 0
    for c in cases:
        t0 = time.perf_counter()
        r = ghost.predict(link, label, c["text"], style=style, prompt=prompt, stream=stream)
        if not r.get("ok"):
            errors += 1
            continue
        lat.append((time.perf_counter() - t0) * 1000)
        scores.append(score(c, r))
    mid = [s for s in scores if s["mid"]]
    return {"kind": "predict", "style": style, "cases": len(cases), "errors": errors, "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "latency_p50": round(pct(lat, 50) or 0), "latency_p90": round(pct(lat, 90) or 0),
            "next_word": _mean(s["acc1"] for s in scores), "words_right": _mean(s["lead"] for s in scores),
            "completions": _mean(s["word_ok"] for s in mid), "shown": _mean(s["shown"] for s in scores)}


def _words(s):
    return re.findall(r"\w+|[^\w\s]", s.replace("’", "'").lower())


def bench_proofread(proof, link, mode, prompt=None, stream="bench", cases=None):
    cases = cases or load_cases()["proofread"]
    proof.run(link, cases[0]["text"], mode, stream=stream, prompt=prompt)                    # warm the prefix
    lat, exact, match, ratio, errors = [], [], [], [], 0
    for c in cases:
        t0 = time.perf_counter()
        r = proof.run(link, c["text"], mode, stream=stream, prompt=prompt)
        if not r.get("ok"):
            errors += 1
            continue
        lat.append((time.perf_counter() - t0) * 1000)
        out = r["text"].strip()
        exact.append(out.replace("’", "'") == c["expected"])
        match.append(difflib.SequenceMatcher(a=_words(out), b=_words(c["expected"]), autojunk=False).ratio())
        ratio.append(len(out) / max(len(c["text"]), 1))
    res = {"kind": mode, "cases": len(cases), "errors": errors, "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
           "latency_p50": round(pct(lat, 50) or 0), "latency_p90": round(pct(lat, 90) or 0)}
    if mode == "fix":
        res.update(exact=_mean(exact), word_match=_mean(match))
    else:
        res.update(length_ratio=round(statistics.median(ratio), 2) if ratio else None)
    return res
