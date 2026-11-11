"""The typing-ghost policy: what to ask predictd while someone types, and how to turn the answer into ghost text.

predictd only hosts the model (profiles, warm sessions, generate). Everything specific to typing prediction is here:
  - the profile: instructions and few-shot examples from prompt.json, registered with predictd and pinned (kept warm)
  - per keystroke: keep the tail of the text that fits `textBudget`, format it with the template, ask for `maxTokens`
  - assemble: the model writes the rest of the unfinished word and the next words; glue, spell-check, re-space, stop at the end of
    the sentence, cap the words, suppress an invalid word

    ghost = Ghost()
    link = predictd.start()
    ghost.predict(link, "chat", "See you tomor")["suggestion"]        # 'row for coffee at the'

Asynchronous clients (pred try) use the two halves: `request()` gives the generate request, `finish()` turns its answer into
the suggestion.
"""
import copy, hashlib, json, os, re, threading, time

from .prompts import UserPrompts

HERE = os.path.dirname(os.path.realpath(__file__))
CONFIG = os.path.join(HERE, "config.json")
PROMPT = os.path.join(HERE, "prompt.json")
STYLES = os.path.join(HERE, "styles.json")
STRUCTURED_SCHEMA = {"title": "Prediction", "type": "object", "required": ["completion"],
                     "properties": {"completion": {"type": "string", "description": "how the text continues"}}}
# "friday" is only a word as "Friday"; but don't accept every name ("justine" is not "just in"), only days and months
CAPITAL_OK = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
              "may", "june", "july", "august", "september", "october", "november", "december"}
ABBR = {"mr", "mrs", "ms", "dr", "prof", "vs", "etc", "e.g", "i.e", "st", "no", "inc", "jr", "sr", "approx", "fig"}
STRIP = ",.;:!?\"')]}"
ATTACH = set(",.;:!?)]}'’")


def is_cjk(c):
    o = ord(c)
    return 0x3040 <= o <= 0x30FF or 0x3400 <= o <= 0x9FFF or 0xAC00 <= o <= 0xD7AF


def word_char(c):
    return (c.isalpha() and not is_cjk(c)) or c in "'’"


def trailing_partial(text):
    """The unfinished word at the end of text ("tomor" of "See you tomor"), or ""."""
    i = len(text)
    while i > 0 and word_char(text[i - 1]):
        i -= 1
    return text[i:]


def trim_tail(text, budget):
    """Keep the tail of text that fits `budget` estimated tokens, cut on a word boundary. Returns (tail, est_tokens, trimmed).
    chars/token measured on this model: prose ~4.8-5.1, code 2.9, shell 2.6, Chinese 1.6."""
    window = text[-(max(budget, 1) * 8):]
    sym = sum(1 for c in window if not c.isalpha() and not c.isspace())
    ratio = 2.9 if sym / max(len(window), 1) > 0.08 else 4.8
    cost, cut = 0.0, len(window)
    while cut > 0:
        c = 1 / 1.6 if is_cjk(window[cut - 1]) else 1 / ratio
        if cost + c > budget:
            break
        cost += c
        cut -= 1
    whole = cut == 0 and len(window) == len(text)
    if not whole and 0 < cut < len(window):                     # do not start mid-word
        while cut < len(window) and not window[cut - 1].isspace() and not window[cut].isspace():
            cut += 1
        if cut < len(window) and not window[cut - 1].isspace():
            cut += 1
    return window[cut:], cost, not whole


def norm_word(w):
    return w.strip(STRIP + "([{“‘").lower()


def cut_repeat(text, partial, comp, n, window):
    """Cut comp before the first word that would complete an n-gram already in the last `window` words of text (or earlier in
    comp). The model likes to echo recent phrases, and accepting the echo again and again loops ("timeline changes timeline
    adjustments timeline changes ..."). The completion of an unfinished word (`partial` + first piece) is always kept.
    Returns (comp, cut)."""
    ctx = [norm_word(w) for w in text.split()[-window:]]
    if partial and ctx:
        ctx.pop()                                               # the unfinished word is completed by the first piece
    spans = [(m.start(), m.end()) for m in re.finditer(r"\S+", comp)]
    words = [norm_word(comp[a:b]) for a, b in spans]
    if partial and words:
        words[0] = norm_word(partial + comp[spans[0][0]:spans[0][1]])
    seq = ctx + words
    seen = {tuple(seq[i:i + n]) for i in range(len(ctx) - n + 1)}
    for j in range(len(words)):
        p = len(ctx) + j
        if p < n - 1:
            continue
        g = tuple(seq[p - n + 1:p + 1])
        if g in seen and all(g) and not (partial and j == 0):
            return comp[:spans[j][0]].rstrip(), True
        seen.add(g)
    return comp, False


def sentence_end(s):
    """Index just after the end of the first sentence in s (. ! ? … followed by whitespace or the end, not an abbreviation,
    initial or number), or None."""
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if ch in "。！？":
            j = i + 1
            while j < n and s[j] in "」』）”":
                j += 1
            return j
        if ch in ".!?…":
            j = i + 1
            while j < n and s[j] in ".!?…":                     # "?!" "..."
                j += 1
            k = j
            while k < n and s[k] in "\"')]”’":                  # closing quote or bracket
                k += 1
            if k == n or s[k].isspace():
                if ch == ".":
                    tok = re.search(r"\S*$", s[:i]).group().lower().strip("\"'([“")
                    if tok in ABBR or (len(tok) == 1 and tok.isalpha()) or (tok and all(c.isnumeric() for c in tok)):
                        i = j
                        continue
                return k
            i = j
            continue
        i += 1
    return None


class Speller:
    """Word check through predictd's `spell` op (NSSpellChecker), batched and cached for one answer."""

    def __init__(self, ask, cfg):
        self.ask, self.cfg, self.known = ask, cfg, {}

    def prefetch(self, words):
        if not self.cfg["spellCheck"]:
            return
        want = set()
        for w in words:
            if self.checkable(w):
                want.add(w)
                if w.lower() in CAPITAL_OK:
                    want.add(w.capitalize())
        missing = sorted(want - self.known.keys())
        if missing:
            self.known.update(zip(missing, self.ask(missing)))

    @staticmethod
    def checkable(w):
        return bool(w) and all(c.isalpha() or c in "'’" for c in w) and not any(is_cjk(c) for c in w)

    def raw(self, w):
        if w not in self.known:
            self.prefetch([w])
        return self.known.get(w, True)

    def ok(self, w):
        if not self.cfg["spellCheck"] or not self.checkable(w):
            return True
        return self.raw(w) or (w.lower() in CAPITAL_OK and self.raw(w.capitalize()))


def assemble(text, completion, app, cfg, truncated, speller):
    """Turn the model's raw continuation into the ghost to show after `text`."""
    lenient = app in cfg["lenientApps"]
    a = {"shown": "", "raw": "", "partial": "", "first_word": "", "dropped_partial": False, "sentence_end": False, "glued": False,
         "respaced": False, "valid": True, "suppressed": None, "words": 0, "misspelled": 0, "repeat_cut": False}
    comp = completion.replace("\n", " ")
    partial = trailing_partial(text)
    a["partial"] = partial
    speller.prefetch([t.strip(STRIP + "([{") for t in (partial + comp).split()] + [t.strip(STRIP + "([{") for t in comp.split()] + [partial])
    if cfg["format"] == "fullword" and partial:                 # the model re-wrote the last word in full: cut the typed part off
        comp = comp.lstrip()
        if not comp.lower().startswith(partial.lower()):
            a.update(suppressed="prefix_mismatch", valid=False)
            return a
        comp = comp[len(partial):]
    if text and text[-1].isspace():
        comp = comp.lstrip()
    elif not partial and comp and not comp[0].isspace() and text and text[-1] in ",.;:!?)":
        comp = " " + comp
    elif partial and comp and not comp[0].isspace():
        a["glued"] = True
    # cut by the token cap: the last word may be unfinished ("for so" of "for some"), drop it unless it is the only one
    if truncated:
        trimmed = comp.strip()
        sp = max((i for i, c in enumerate(trimmed) if c.isspace()), default=-1)
        if sp >= 0:
            lead = comp[: len(comp) - len(comp.lstrip())]
            comp = lead + trimmed[:sp]
            a["dropped_partial"] = True
    # one sentence only: stop at the first sentence end (not for shell lines or code, where . ! ? are syntax)
    if cfg["oneSentence"] and not lenient:
        e = sentence_end(comp)
        if e is not None:
            comp = comp[:e]
            a["sentence_end"] = True
    # cap the number of words: the unfinished word counts as one, then `words` more
    limit = cfg["words"] + (1 if a["glued"] else 0)
    count, end, in_word = 0, 0, False
    for i, ch in enumerate(comp):
        if ch.isspace():
            if in_word:
                count += 1
                end = i
                in_word = False
                if count == limit:
                    break
        else:
            in_word = True
    if in_word and count < limit:
        count += 1
        end = len(comp)
    comp = comp[:end].rstrip()
    a["raw"], a["words"] = comp, count
    if a["glued"] and comp:
        piece = comp.split()[0] if comp.split() else comp
        core = (partial + piece).strip(STRIP)
        a["first_word"] = core
        a["valid"] = speller.ok(core)
        # The model cannot reliably write the leading space after a word that is already finished ("git" + "commit -m",
        # "with the" + "project"), so decide here whether the piece is the end of the typed word or a new word:
        #  - it starts with something that cannot continue a word (a flag, path, operator, an opening quote): new word
        #  - the glued word is not a word but the piece alone is (3+ letters): new word
        f = piece[0]
        separate = False
        if not f.isalpha() and not f.isnumeric() and f not in ATTACH:
            separate = text.count('"') % 2 == 0 if f == '"' else True   # a quote closes a word only inside an open quote
        word = piece.strip(STRIP)
        # a capital right after lowercase letters is a new sentence/word in prose ("out" + "I would"), camelCase only in code
        if not separate and f.isupper() and partial and partial[-1].islower() and not lenient:
            separate = True
        short = len(word) < 3   # "to", "a", "I": only when the typed part is itself a finished word ("have" + "to")
        if (not separate and not a["valid"] and word and all(c.isalpha() for c in word) and speller.ok(word)
                and speller.ok(partial)   # an unfinished typed word ("fri") must not be split off from the model's next word
                # a 2-letter piece only after a typed word of 3+ letters ("have" + "to"), not after "ru" + "un" (which wanted "run")
                and (not short or ((len(word) == 2 or word.lower() in ("a", "i")) and len(partial) >= 3))):
            separate = True
        if separate:
            a.update(glued=False, valid=True, respaced=True, first_word=piece)
            comp = " " + comp
    else:
        a["first_word"] = comp.split()[0] if comp.split() else ""
        # a new word must be a word too ("adjustments" + tab + "ments"); lowercase only, so names and acronyms pass
        w = norm_word(a["first_word"])
        if w and w == a["first_word"].strip(STRIP + "([{“‘") and not lenient and not speller.ok(w):
            a["valid"] = False
    if cfg.get("repeatNgram", 0) > 0 and comp.strip():
        comp, a["repeat_cut"] = cut_repeat(text, partial if a["glued"] else "", comp, cfg["repeatNgram"], cfg.get("repeatWindow", 60))
        a["words"] = len(comp.split())
    a["misspelled"] = sum(1 for t in (partial + comp).split() if not speller.ok(t.strip(",.;:!?\"'()[]{}")))
    a["shown"] = comp
    if not a["valid"] and cfg["invalidPolicy"] == "drop" and not lenient:
        a["shown"], a["suppressed"] = "", "invalid_word"
    elif a["repeat_cut"] and not comp.strip():
        a["shown"], a["suppressed"] = "", "repetition"
    return a


def user_dir():
    """The user's config directory, outside the repo: config.json (knob overrides), prompts.json, prompt-history.json,
    test-cases.json. The project's earlier name was input-predictor: that directory is moved here once."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    d, old = os.path.join(base, "homeword"), os.path.join(base, "input-predictor")
    if not os.path.exists(d) and os.path.isdir(old):
        try:
            os.rename(old, d)
        except OSError:
            return old
    return d


def load_config(path=CONFIG, user=True):
    """config.json, then the user's overrides of its knobs (user_dir()/config.json), unless `user` is False (benchmarks)."""
    cfg = json.load(open(path))
    if user:
        try:
            u = json.load(open(os.path.join(user_dir(), "config.json")))
        except (OSError, ValueError):
            u = {}
        if isinstance(u, dict):
            cfg.update({k: v for k, v in u.items() if k in cfg})
    return cfg


def save_user_config(updates):
    """Write knobs to the user's overrides (user_dir()/config.json), keeping the others there."""
    from .prompts import _read, _write
    path = os.path.join(user_dir(), "config.json")
    d = _read(path)
    d = d if isinstance(d, dict) else {}
    d.update(updates)
    _write(path, d)


def tokens_for_words(words):
    """The output cap for `words` suggested words: the unfinished word's rest + the words, ~1.2 tokens per word (5 -> 6)."""
    return words + -(-words // 5)


class Ghost:
    """The policy. `overrides` change config.json for this instance; per-request `opts` change it for one request.
    `user=False` ignores the user's config overrides and prompts (benchmarks run on the shipped ones)."""

    def __init__(self, config=CONFIG, prompt=PROMPT, overrides=None, user=None, styles=STYLES):
        if user is None:                                        # benchmarks set PRED_NO_USER=1 for the processes they start
            user = os.environ.get("PRED_NO_USER") != "1"
        self.cfg = load_config(config, user)
        self.cfg.update(overrides or {})
        self.prompt = json.load(open(prompt))
        self.styles = {k: v for k, v in json.load(open(styles)).items() if not k.startswith("_")}
        self.user = UserPrompts(os.path.expanduser(self.cfg.get("userPrompts") or os.path.join(user_dir(), "prompts.json")) if user else None)
        self.registered = set()
        self.pinned = None                                      # the profile predictd keeps warm for us
        self.lock = threading.Lock()

    def config(self, opts=None):
        c = copy.deepcopy(self.cfg)
        c.update(opts or {})
        return c

    def template(self, app, text):
        t = self.prompt.get("template", "App: {app}\nText: {text}")
        return t.replace("{app}", app).replace("{text}", text)

    # -- writing styles: general is prompt.json (with its research knobs), the others are styles.json

    def style_names(self):
        return ["general"] + list(self.styles)

    def style_title(self, style):
        return "General" if style == "general" else self.styles[style]["title"]

    def style_label(self, style):
        return "notes" if style == "general" else self.styles[style]["label"]

    def default_instructions(self, cfg):
        """The instructions prompt.json gives this configuration (`{words}` not yet filled in)."""
        p = self.prompt
        return p["instructions_fullword"] if cfg["format"] == "fullword" else p["instructions_short"] if cfg["instructions"] == "short" else p["instructions"]

    def inherits(self, style):
        """True when the style has no examples of its own and uses general's whole prompt."""
        return style != "general" and "shots" not in self.styles[style]

    def default_prompt(self, style="general", cfg=None):
        """The shipped prompt of a style: {"instructions", "examples": [{"text", "completion", "app"?}]}. A style without its
        own prompt defaults to general's prompt in use (the user's version, if any)."""
        cfg = cfg or self.cfg
        if self.inherits(style):
            return self.prompt_for("general", cfg)
        if style == "general":
            return {"instructions": self.default_instructions(cfg),
                    "examples": [{"text": s["text"], "completion": s["completion"], "app": s["app"]} for s in self.prompt["shots"][: cfg["shots"]]]}
        st = self.styles[style]
        examples = [{k: s[k] for k in ("text", "completion", "app") if k in s} for s in st["shots"]]   # app: else the style's label
        return {"instructions": st.get("instructions") or self.default_instructions(cfg), "examples": examples}

    def prompt_for(self, style="general", cfg=None):
        """The prompt in use: the user's version (instructions, and examples if they changed them), else the shipped one."""
        d = self.default_prompt(style, cfg)
        u = self.user.get("predict-" + style)
        if not u:
            return d
        return {"instructions": u["instructions"], "examples": u["examples"] if "examples" in u else d["examples"]}

    def profile(self, cfg, style="general", prompt=None):
        """The predictd profile for this configuration and style: instructions + examples. Its name is a hash of its content,
        so a request that changes the prompt (other `shots`, `instructions`, a user's edit, ...) gets its own profile instead of
        a stale one."""
        full, structured = cfg["format"] == "fullword", cfg["output"] == "structured"
        p = prompt or self.prompt_for(style, cfg)
        examples = []
        for s in p["examples"]:
            comp = s["completion"]
            if full and s["text"] and not s["text"][-1].isspace():   # fullword format: the answer re-writes the last word, completed
                comp = trailing_partial(s["text"]) + comp
            examples.append({"prompt": self.template(s.get("app") or self.style_label(style), s["text"]),
                             "response": {"completion": comp} if structured else comp})
        d = {"instructions": p["instructions"].replace("{words}", str(cfg["words"])), "examples": examples, "guardrails": cfg["guardrails"]}
        if structured:
            d["schema"] = STRUCTURED_SCHEMA
        return {"name": "ghost-" + hashlib.sha1(json.dumps(d, sort_keys=True).encode()).hexdigest()[:8], **d}

    def ensure_profile(self, link, cfg=None, pin=False, force=False, style="general", prompt=None):
        prof = self.profile(cfg or self.cfg, style, prompt)
        with self.lock:
            # re-send when the pinned profile changes too (another style, a prompt edited and reset): profile.set of a known
            # profile is free
            if force or prof["name"] not in self.registered or (pin and self.pinned != prof["name"]):
                r = link.call(op="profile.set", pin=pin, **prof)
                if not r.get("ok"):
                    raise RuntimeError(f"profile.set failed: {r.get('error')}")
                self.registered.add(prof["name"])
                if pin:
                    self.pinned = prof["name"]
        return prof["name"]

    def warm(self, link, style="general"):
        """The user is about to type in this style (they switched apps): pin its profile and have predictd prewarm it now, so
        the first keystroke hits the cache (prewarming needs ~1 s of lead time)."""
        name = self.ensure_profile(link, style=style if style in self.styles else "general", pin=True)
        r = link.call(op="prewarm", profile=name)
        return {"ok": r.get("ok", False), "profile": name, "prewarmed": r.get("prewarmed", False)}

    def request(self, app, text, opts=None, style="general", prompt=None, keep_app=False):
        """The generate request for this text, and the context `finish` needs; (None, ctx) when there is nothing to ask.
        `style`: a writing style (general = `app` is sent as is; others send their own label). `prompt`: try this prompt
        instead of the one in use (benchmarks)."""
        t0 = time.perf_counter()
        cfg = self.config(opts)
        if style not in self.styles:
            style = "general"
        if style != "general" and not keep_app:          # benchmarks keep each case's own app label
            app = self.style_label(style)
        tail, est, trimmed = trim_tail(text, max(16, cfg["textBudget"]))
        ctx = {"cfg": cfg, "app": app, "text": text, "tail": tail, "est": est, "trimmed": trimmed, "t0": t0, "style": style,
               "prompt": prompt, "profile": self.profile(cfg, style, prompt)["name"]}
        ctx["trim_ms"] = (time.perf_counter() - t0) * 1000
        if not tail.strip():
            return None, ctx
        req = {"op": "generate", "profile": ctx["profile"], "prompt": self.template(app, tail), "maxTokens": cfg["maxTokens"],
               "sampling": cfg["sampling"]}
        if cfg["sampling"] != "greedy":
            req.update(topK=cfg["topK"], topP=cfg["topP"], temperature=cfg["temperature"], seed=cfg["seed"])
        if cfg["output"] == "structured":
            req["schema"] = True
        return req, ctx

    def finish(self, ctx, resp, spell):
        """Turn predictd's answer into the ghost. `spell(words) -> [bool]` checks words (predictd's `spell` op)."""
        cfg, text = ctx["cfg"], ctx["text"]
        if not resp.get("ok"):
            if resp.get("error") == "guardrail":                    # a false positive even when permissive: just show nothing
                return {"id": resp.get("id"), "ok": True, "suggestion": "", "suppressed": "guardrail", "partial": "",
                        "timing": {"total_ms": 0, "session": resp.get("state")}}
            return {"id": resp.get("id"), "ok": False, "error": resp.get("error")}
        t1 = time.perf_counter()
        completion = resp["text"] if "text" in resp else (resp.get("content") or {}).get("completion", "")
        truncated = resp.get("finish") == "length"
        a = assemble(text, completion, ctx["app"], cfg, truncated, Speller(lambda ws: spell(ws, cfg["spellLanguage"]), cfg))
        asm_ms = (time.perf_counter() - t1) * 1000
        t, tok = resp.get("timing", {}), resp.get("tokens", {})
        return {"id": resp.get("id"), "ok": True, "suggestion": a["shown"], "raw_suggestion": a["raw"], "model_completion": completion,
                "partial": a["partial"], "first_word": a["first_word"], "sentence_end": a["sentence_end"], "truncated": truncated,
                "dropped_partial": a["dropped_partial"], "glued": a["glued"], "respaced": a["respaced"], "repeat_cut": a["repeat_cut"], "valid": a["valid"],
                "suppressed": a["suppressed"], "words": a["words"], "misspelled": a["misspelled"],
                "timing": {"trim_ms": ctx["trim_ms"], "wait_ms": t.get("wait_ms", 0), "model_ms": t.get("model_ms", 0),
                           "assemble_ms": asm_ms, "daemon_ms": t.get("total_ms", 0),
                           "total_ms": ctx["trim_ms"] + t.get("total_ms", 0) + asm_ms, "session": resp.get("state")},
                "tokens": {**tok, "text_est": ctx["est"], "budget": cfg["textBudget"], "trimmed": ctx["trimmed"],
                           "text_chars_in": len(text), "text_chars_used": len(ctx["tail"])}}

    def predict(self, link, app, text, opts=None, stream=None, style="general", prompt=None, keep_app=False):
        """Blocking: one suggestion for `text`. Registers the profile when predictd does not know it (first use, or the daemon
        restarted)."""
        req, ctx = self.request(app, text, opts, style, prompt, keep_app)
        if req is None:
            return {"ok": True, "suggestion": "", "partial": "", "timing": {"total_ms": ctx["trim_ms"]}}
        if stream:
            req["stream"] = stream
        pin = not opts and prompt is None                       # the prompt in use is pinned, per-request variants are not
        self.ensure_profile(link, ctx["cfg"], pin=pin, style=ctx["style"], prompt=prompt)
        resp = link.call(**req)
        if resp.get("error") == "unknown_profile":
            self.registered.discard(ctx["profile"])
            self.ensure_profile(link, ctx["cfg"], pin=pin, style=ctx["style"], prompt=prompt)
            resp = link.call(**req)
        return self.finish(ctx, resp, lambda ws, lang: link.call(op="spell", words=ws, language=lang)["valid"])
