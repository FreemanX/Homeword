"""The user's own prompts, their history and benchmark results, so a user can tune the prompts without editing the repo.

A prompt is {"instructions": str, "examples": [{"text": str, "completion": str}, ...]}. Prediction prompts are named
"predict-<style>" (general, chat, email, ...; `{words}` in the instructions becomes the `words` knob), proofreading ones
"proofread-fix" and "proofread-rewrite" (examples: text = input, completion = output).

Files, in the directory of the `userPrompts` knob (default ~/.config/input-predictor/, mode 0600, outside the repo: what a user
writes there is theirs):
  prompts.json          {name: prompt}: the overrides in use (an older form, {name: "instructions"}, still loads)
  prompt-history.json   {"versions": {name: [{"hash", "saved_at", "prompt"}]}, "results": {hash: {name: result}}}: the last
                        `HISTORY` saved versions per prompt, and benchmark results by prompt content hash (a run on the user's
                        cases only is kept under "<name>#user", so it does not replace a full run)
  test-cases.json       {name: [{"text", "rest"}]}: the user's own benchmark cases per prompt (rest = what comes next, or the
                        expected output for proofreading)
A changed prompt makes a new predictd profile (profiles are named by a hash of their content), so the change applies to the next
request; the first one after it is uncached.
"""
import hashlib, json, os, tempfile, threading, time

MAX_CHARS = 6000                          # instructions + examples + input must fit the 8192-token window
MAX_EXAMPLES = 12
HISTORY = 20
MAX_CASES = 200


def prompt_hash(prompt):
    return hashlib.sha1(json.dumps(prompt, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:10]


def clean(prompt):
    """Validate and normalise a prompt from a client; raises ValueError."""
    if not isinstance(prompt, dict) or not isinstance(prompt.get("instructions"), str):
        raise ValueError("a prompt is {\"instructions\": text, \"examples\": [{\"text\", \"completion\"}]}")
    ins = prompt["instructions"].strip()
    if not ins:
        raise ValueError("the instructions are empty")
    examples = []
    for e in prompt.get("examples") or []:
        if not isinstance(e, dict) or not isinstance(e.get("text"), str) or not isinstance(e.get("completion"), str):
            raise ValueError("each example needs text and completion")
        if e["text"].strip() and e["completion"].strip():
            examples.append({k: e[k] for k in ("text", "completion", "app") if isinstance(e.get(k), str)})
    if len(examples) > MAX_EXAMPLES:
        raise ValueError(f"at most {MAX_EXAMPLES} examples")
    if len(ins) + sum(len(e["text"]) + len(e["completion"]) for e in examples) > MAX_CHARS:
        raise ValueError(f"the prompt is too long (at most {MAX_CHARS} characters with its examples)")
    return {"instructions": ins, "examples": examples}


def _read(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def _write(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)                                       # mkstemp files are 0600


class UserPrompts:
    """`path`: the prompts.json file, or None for none (benchmarks run on the shipped prompts)."""

    def __init__(self, path):
        self.path = os.path.expanduser(path) if path else None
        self.history_path = os.path.join(os.path.dirname(self.path), "prompt-history.json") if self.path else None
        self.cases_path = os.path.join(os.path.dirname(self.path), "test-cases.json") if self.path else None
        self.lock = threading.Lock()
        self.stamp, self.data = None, {}

    def _load(self):
        if not self.path:
            return
        try:
            st = os.stat(self.path)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            self.stamp, self.data = None, {}
            return
        if stamp != self.stamp:                                 # changed by another process (pred try, a text editor)
            d = _read(self.path) or {}
            self.data = {}
            for k, v in d.items():
                if k == "typing":                               # the first version's name for the general prediction prompt
                    k = "predict-general"
                if isinstance(v, str) and v.strip():
                    v = {"instructions": v}                     # instructions only: examples stay the default ones
                if isinstance(v, dict) and isinstance(v.get("instructions"), str):
                    self.data[k] = v
            self.stamp = stamp

    def get(self, name):
        """The user's version (instructions, maybe examples) or None."""
        with self.lock:
            self._load()
            return self.data.get(name)

    def set(self, name, prompt):
        """Save the user's version (None restores the default) and record it in the history."""
        if not self.path:
            raise ValueError("no user prompt file configured")
        with self.lock:
            self._load()
            if prompt is None:
                self.data.pop(name, None)
            else:
                self.data[name] = prompt
            _write(self.path, self.data)
            self.stamp = None
            if prompt is not None:
                h = self._history()
                versions = [v for v in h["versions"].get(name, []) if v["hash"] != prompt_hash(prompt)]
                versions.append({"hash": prompt_hash(prompt), "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "prompt": prompt})
                h["versions"][name] = versions[-HISTORY:]
                self._prune(h)
                _write(self.history_path, h)

    def _history(self):
        h = _read(self.history_path) if self.history_path else None
        if not isinstance(h, dict):
            h = {}
        h.setdefault("versions", {})
        h.setdefault("results", {})
        return h

    def _prune(self, h):
        """Keep results only for versions still in the history (and anything benchmarked in the last week, e.g. defaults)."""
        keep = {v["hash"] for vs in h["versions"].values() for v in vs}
        cutoff = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 7 * 86400))
        h["results"] = {k: r for k, r in h["results"].items()
                        if k in keep or any(x.get("at", "") >= cutoff for x in r.values())}

    def history(self, name):
        """Saved versions of `name`, newest first, each with its benchmark result if one was run."""
        with self.lock:
            h = self._history()
            return [{**v, "result": h["results"].get(v["hash"], {}).get(name)} for v in reversed(h["versions"].get(name, []))]

    def result(self, name, prompt, scope="all"):
        with self.lock:
            return self._history()["results"].get(prompt_hash(prompt), {}).get(name if scope == "all" else name + "#user")

    def save_result(self, name, prompt, result):
        if not self.history_path:
            return
        with self.lock:
            h = self._history()
            h["results"].setdefault(prompt_hash(prompt), {})[name if result.get("scope") == "all" else name + "#user"] = result
            self._prune(h)
            _write(self.history_path, h)

    # -- the user's own benchmark cases, per prompt

    def cases(self, name):
        with self.lock:
            d = _read(self.cases_path) if self.cases_path else None
            return (d or {}).get(name, []) if isinstance(d, dict) else []

    def set_cases(self, name, cases):
        """Save the user's cases for a prompt: pairs with both sides non-empty (the text keeps its spaces: they matter)."""
        if not self.cases_path:
            raise ValueError("no user prompt file configured")
        clean_cases = []
        for c in cases or []:
            if not isinstance(c, dict) or not isinstance(c.get("text"), str) or not isinstance(c.get("rest"), str):
                raise ValueError("each case needs text and rest")
            if c["text"].strip() and c["rest"].strip():
                clean_cases.append({"text": c["text"], "rest": c["rest"]})
        if len(clean_cases) > MAX_CASES:
            raise ValueError(f"at most {MAX_CASES} cases")
        with self.lock:
            d = _read(self.cases_path)
            d = d if isinstance(d, dict) else {}
            if clean_cases:
                d[name] = clean_cases
            else:
                d.pop(name, None)
            _write(self.cases_path, d)
        return clean_cases
