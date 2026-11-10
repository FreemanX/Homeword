"""The proofreading policy: fix typos and grammar in a selected text, or rewrite it more clearly, keeping its meaning and intent.

    pr = Proofreader()
    link = predictd.start()
    pr.run(link, "i dont think we shoud ship this befor friday", mode="fix")["text"]
    # "I don't think we should ship this before Friday."

Like the typing policy it is a client of predictd: one profile per mode (instructions + examples, not pinned: proofreading is
occasional, the typing profile keeps the warm cache), one `generate` per request. The answer comes with a word-level diff for
display.
"""
import difflib, hashlib, json, os, re, threading, time

from .prompts import UserPrompts

INSTRUCTIONS = {
    "fix": "You proofread text. Fix spelling mistakes, typos, grammar and punctuation. Keep the meaning, the tone, the language, "
           "the formatting and the line breaks. Change as little as possible: do not rephrase correct sentences, do not add or "
           "remove content, keep names, numbers, links and code as they are. Reply with the corrected text only.",
    "rewrite": "You improve text. Rewrite it so it reads clearly and naturally, and fix spelling and grammar. Keep the meaning, the "
               "intent, the tone, the language and about the same length. Keep names, numbers, links and code as they are. "
               "Reply with the rewritten text only.",
}
EXAMPLES = {
    "fix": [
        ("i dont think we shoud ship this befor friday, their are still to many open bugs.",
         "I don't think we should ship this before Friday, there are still too many open bugs."),
        ("Thanks for the quick reply! Can you send me the slides from yesterdays meeting?",
         "Thanks for the quick reply! Can you send me the slides from yesterday's meeting?"),
        ("The test are failing becuase the config file is missing, see build.log",
         "The tests are failing because the config file is missing, see build.log"),
    ],
    "rewrite": [
        ("so basically the thing is we cant really finish it on time because of the stuff with the api that broke last week",
         "We can't finish on time because the API broke last week."),
        ("Hi, just wanted to check if you maybe had some time to look at my PR, no rush tho",
         "Hi, do you have time to look at my PR? No rush."),
    ],
}
PREAMBLE = re.compile(r"^\s*(here(?:'s| is) (?:the |your )?(?:corrected|revised|rewritten|improved|proofread)[^:\n]*:|"
                      r"(?:corrected|revised|rewritten) (?:text|version)\s*:)\s*", re.I)
CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")   # proofread* knobs


def est_tokens(text):
    return len(text) / 3.6 + 4


def diff(a, b):
    """Word-level edit script from a to b: [{"op": "equal"|"insert"|"delete"|"replace", "a": ..., "b": ...}]."""
    ta, tb = re.findall(r"\s+|\w+|[^\w\s]", a), re.findall(r"\s+|\w+|[^\w\s]", b)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=ta, b=tb, autojunk=False).get_opcodes():
        out.append({"op": op, "a": "".join(ta[i1:i2]), "b": "".join(tb[j1:j2])})
    return out


class Proofreader:
    def __init__(self, cfg=None, user=None):
        self.cfg = cfg or json.load(open(CONFIG))
        self.user = user or UserPrompts(self.cfg.get("userPrompts", "~/.config/input-predictor/prompts.json"))
        self.registered = set()
        self.lock = threading.Lock()

    def profile(self, mode):
        examples = [{"prompt": a, "response": b} for a, b in EXAMPLES[mode]]
        d = {"instructions": self.user.get("proofread-" + mode, INSTRUCTIONS[mode]), "examples": examples, "guardrails": self.cfg.get("proofreadGuardrails", "permissive")}
        return {"name": f"proofread-{mode}-" + hashlib.sha1(json.dumps(d, sort_keys=True).encode()).hexdigest()[:8], **d}

    def ensure_profile(self, link, mode, force=False):
        prof = self.profile(mode)
        with self.lock:
            if force or prof["name"] not in self.registered:
                r = link.call(op="profile.set", pin=False, **prof)
                if not r.get("ok"):
                    raise RuntimeError(f"profile.set failed: {r.get('error')}")
                self.registered.add(prof["name"])
        return prof["name"]

    def run(self, link, text, mode="fix", stream="proofread"):
        t0 = time.perf_counter()
        if mode not in INSTRUCTIONS:
            return {"ok": False, "error": f"mode must be one of {sorted(INSTRUCTIONS)}"}
        if not text.strip():
            return {"ok": True, "text": text, "changed": False, "changes": [{"op": "equal", "a": text, "b": text}]}
        # one paragraph per request: the model then never sees (and drops) repeated passages, never hits the token cap on a long
        # text, and each request stays small; the profile's prefix is cached across them
        parts = re.split(r"(\n[ \t]*\n\s*)", text)            # paragraphs at even indices, separators at odd ones
        limit = self.cfg.get("proofreadMaxInputTokens", 2500)
        longest = max(est_tokens(p.strip()) for p in parts[::2])
        if longest > limit:
            return {"ok": False, "error": f"a paragraph is too long (about {int(longest)} tokens, at most {limit})"}
        name = self.ensure_profile(link, mode)
        out, model_ms, tokens, truncated, warnings = [], 0.0, {"in": 0, "cached": 0, "out": 0}, False, []
        for i, part in enumerate(parts):
            if i % 2 or not part.strip():
                out.append(part)
                continue
            core = part.strip()
            req = {"op": "generate", "profile": name, "prompt": core, "maxTokens": int(est_tokens(core) * 1.6) + 40,
                   "sampling": "greedy", "stream": stream}
            resp = link.call(timeout=120, **req)
            if resp.get("error") == "unknown_profile":        # predictd restarted
                self.registered.discard(name)
                self.ensure_profile(link, mode)
                resp = link.call(timeout=120, **req)
            if not resp.get("ok"):
                err = resp.get("error")
                return {"ok": False, "error": "the model declined this text" if err == "guardrail" else err}
            fixed = PREAMBLE.sub("", resp.get("text", "")).strip()
            if len(fixed) > 1 and fixed[0] == fixed[-1] and fixed[0] in "\"'“" and core[0] not in "\"'“":   # quotes the model added
                fixed = fixed[1:-1].strip()
            if not fixed:
                return {"ok": False, "error": "the model returned nothing"}
            # a fix keeps about the same length, a rewrite may shorten; much less means the model dropped content
            if len(fixed) < len(core) * (0.8 if mode == "fix" else 0.4):
                warnings.append(f"paragraph {i // 2 + 1} came back much shorter: check it before replacing")
            truncated = truncated or resp.get("finish") == "length"
            model_ms += resp.get("timing", {}).get("model_ms", 0)
            for k in tokens:
                tokens[k] += resp.get("tokens", {}).get(k, 0)
            out.append(part[: len(part) - len(part.lstrip())] + fixed + part[len(part.rstrip()):])
        result = "".join(out)
        if truncated:
            warnings.append("the answer was cut off: check the end before replacing")
        return {"ok": True, "text": result, "changed": result != text, "changes": diff(text, result), "mode": mode,
                "truncated": truncated, "warnings": warnings, "paragraphs": len(parts[::2]),
                "timing": {"model_ms": model_ms, "total_ms": (time.perf_counter() - t0) * 1000}, "tokens": tokens}
