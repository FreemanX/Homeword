"""The benchmark suite and its scoring: what bench/run.py --styles and Homeword's Prompts tab (POST /bench) run.

The suite is every case of bench/cases.json (the fixed 80-case benchmark) plus bench/styles.json (14 per writing style), each tagged
with a category: chat, email, work, academic, code, general, terminal. A prompt runs on all of them, each case with its own app label
(what the model is told the app is), and results are reported per category, so one run shows how a prompt does in chat, in email,
and so on. A user's own cases (per prompt) form a separate "user" section. Proofreading prompts run on the proofread sentences of
bench/styles.json and the user's cases.

Prediction metrics (as bench/run.py):
  latency_p50/p90   ms per suggestion, sequential requests on a warm prefix (like typing)
  next_word         share of cases whose first suggested word is what was typed next (acc1)
  words_right       mean number of leading suggested words that match (lead)
  completions       share of mid-word cases whose completed word is right (mid_word_ok)
  shown             share of cases with a suggestion
Proofreading: latency, `exact` (output equals the expected text), `word_match` (word-level similarity); rewriting has no single
right answer: latency and `length_ratio` (output / input length).
"""
import difflib, json, os, re, statistics, time

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
CASES = os.path.join(ROOT, "bench", "cases.json")
STYLE_CASES = os.path.join(ROOT, "bench", "styles.json")
PUNCT = " .,;:!?\"'()[]{}"
CATEGORIES = [("chat", "Chat"), ("email", "Email"), ("work", "Work documents"), ("academic", "Academic"), ("code", "Code"),
              ("general", "General"), ("terminal", "Terminal")]
TITLES = dict(CATEGORIES) | {"user": "Your cases", "proofread": "Proofreading", "all": "All (ours)"}
APP_CATEGORY = {"mail": "email", "chat": "chat", "notes": "general", "editor": "general", "essay": "general",
                "terminal": "terminal", "review": "code", "code": "code"}      # cases.json app labels
STYLE_LABEL = {"general": "notes", "chat": "chat", "email": "mail", "work": "document", "academic": "paper", "code": "code"}


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


def load_cases(path=STYLE_CASES):
    """bench/styles.json: {style: [cases]} and "proofread"."""
    return {k: v for k, v in json.load(open(path)).items() if not k.startswith("_")}


def suite():
    """Every prediction case with its category and app label."""
    out = [{"text": c["text"], "rest": c["rest"], "app": c["app"], "category": APP_CATEGORY.get(c["app"], "general")}
           for c in json.load(open(CASES))]
    for style, cases in load_cases().items():
        if style in STYLE_LABEL:
            out += [{"text": c["text"], "rest": c["rest"], "app": STYLE_LABEL[style], "category": style} for c in cases]
    order = [k for k, _ in CATEGORIES]
    return sorted(out, key=lambda c: order.index(c["category"]))


def _mean(xs):
    xs = list(xs)
    return round(sum(xs) / len(xs), 3) if xs else None


def _summary(name, rows, errors):
    lat = [r[1] for r in rows]
    scores = [r[0] for r in rows]
    mid = [s for s in scores if s["mid"]]
    return {"name": name, "title": TITLES.get(name, name), "cases": len(rows) + errors, "errors": errors,
            "latency_p50": round(pct(lat, 50) or 0), "latency_p90": round(pct(lat, 90) or 0),
            "next_word": _mean(s["acc1"] for s in scores), "words_right": _mean(s["lead"] for s in scores),
            "completions": _mean(s["word_ok"] for s in mid), "shown": _mean(s["shown"] for s in scores)}


def bench_prompt(ghost, link, style, prompt=None, user_cases=(), scope="all", progress=None, stream="bench"):
    """Run a prediction prompt (default: the one in use for `style`) on the suite (scope "all") and/or the user's cases
    ({"text", "rest"}, scope "all" or "user"); results per category, overall, and the user's section."""
    cases = suite() if scope == "all" else []
    users = [{"text": c["text"], "rest": c["rest"], "app": ghost.style_label(style), "category": "user"} for c in user_cases]
    todo = cases + users
    if not todo:
        return {"kind": "predict", "style": style, "scope": scope, "error": "no cases"}
    ghost.predict(link, todo[0]["app"], todo[0]["text"], style=style, prompt=prompt, stream=stream, keep_app=True)   # warm the prefix
    rows, errors = {}, {}
    for i, c in enumerate(todo):
        t0 = time.perf_counter()
        r = ghost.predict(link, c["app"], c["text"], style=style, prompt=prompt, stream=stream, keep_app=True)
        if r.get("ok"):
            rows.setdefault(c["category"], []).append((score(c, r), (time.perf_counter() - t0) * 1000))
        else:
            errors[c["category"]] = errors.get(c["category"], 0) + 1
        if progress:
            progress(i + 1, len(todo))
    cats = [_summary(k, rows.get(k, []), errors.get(k, 0)) for k, _ in CATEGORIES if k in rows or k in errors]
    ours = [r for k, v in rows.items() if k != "user" for r in v]
    return {"kind": "predict", "style": style, "scope": scope, "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "categories": cats,
            "overall": _summary("all", ours, sum(v for k, v in errors.items() if k != "user")) if cases else None,
            "user": _summary("user", rows.get("user", []), errors.get("user", 0)) if users else None}


def _words(s):
    return re.findall(r"\w+|[^\w\s]", s.replace("’", "'").lower())


def _proof_summary(name, rows, errors, mode):
    res = {"name": name, "title": TITLES.get(name, name), "cases": len(rows) + errors, "errors": errors,
           "latency_p50": round(pct([r["lat"] for r in rows], 50) or 0), "latency_p90": round(pct([r["lat"] for r in rows], 90) or 0)}
    if mode == "fix":
        res.update(exact=_mean(r["exact"] for r in rows), word_match=_mean(r["match"] for r in rows))
    else:
        res.update(length_ratio=round(statistics.median([r["ratio"] for r in rows]), 2) if rows else None)
    return res


def bench_proofread(proof, link, mode, prompt=None, user_cases=(), scope="all", progress=None, stream="bench"):
    """Proofreading or rewriting prompt on the proofread sentences (scope "all") and/or the user's cases ({"text", "rest"}:
    rest = the expected output)."""
    ours = [{"text": c["text"], "rest": c["expected"], "category": "proofread"} for c in load_cases()["proofread"]] if scope == "all" else []
    todo = ours + [{"text": c["text"], "rest": c["rest"], "category": "user"} for c in user_cases]
    if not todo:
        return {"kind": mode, "scope": scope, "error": "no cases"}
    proof.run(link, todo[0]["text"], mode, stream=stream, prompt=prompt)                     # warm the prefix
    rows, errors = {}, {}
    for i, c in enumerate(todo):
        t0 = time.perf_counter()
        r = proof.run(link, c["text"], mode, stream=stream, prompt=prompt)
        if r.get("ok"):
            out = r["text"].strip()
            rows.setdefault(c["category"], []).append({
                "lat": (time.perf_counter() - t0) * 1000, "exact": out.replace("’", "'") == c["rest"].strip().replace("’", "'"),
                "match": difflib.SequenceMatcher(a=_words(out), b=_words(c["rest"]), autojunk=False).ratio(),
                "ratio": len(out) / max(len(c["text"]), 1)})
        else:
            errors[c["category"]] = errors.get(c["category"], 0) + 1
        if progress:
            progress(i + 1, len(todo))
    cats = [_proof_summary("proofread", rows.get("proofread", []), errors.get("proofread", 0), mode)] if ours else []
    return {"kind": mode, "scope": scope, "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "categories": cats,
            "overall": cats[0] if cats else None,
            "user": _proof_summary("user", rows.get("user", []), errors.get("user", 0), mode) if len(todo) > len(ours) else None}
