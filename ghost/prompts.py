"""User overrides of the policies' instructions (system prompts), so a user can tune them without editing the repo.

Stored as {"name": "instructions", ...} in the file named by the `userPrompts` knob (default ~/.config/input-predictor/prompts.json,
mode 0600, outside the repo: what a user writes there is theirs). Names: "typing" (the typing policy's active instructions; `{words}`
becomes the `words` knob), "proofread-fix", "proofread-rewrite". The examples stay in prompt.json and proofread.py.
A changed prompt makes a new predictd profile (profiles are named by a hash of their content), so the change applies to the next
request; the first one after it is uncached.
"""
import json, os, tempfile, threading

NAMES = ("typing", "proofread-fix", "proofread-rewrite")
MAX_CHARS = 4000                          # instructions + examples + input must fit the 8192-token window


class UserPrompts:
    def __init__(self, path):
        self.path = os.path.expanduser(path)
        self.lock = threading.Lock()
        self.stamp, self.data = None, {}

    def _load(self):
        try:
            st = os.stat(self.path)
            stamp = (st.st_mtime_ns, st.st_size)
        except OSError:
            self.stamp, self.data = None, {}
            return
        if stamp != self.stamp:                                 # changed by another process (pred try, a text editor)
            try:
                d = json.load(open(self.path))
                self.data = {k: v for k, v in d.items() if k in NAMES and isinstance(v, str) and v.strip()}
            except (OSError, ValueError):
                self.data = {}
            self.stamp = stamp

    def get(self, name, default):
        with self.lock:
            self._load()
            return self.data.get(name, default)

    def custom(self, name):
        with self.lock:
            self._load()
            return name in self.data

    def set(self, name, text):
        """Save an override; empty text restores the default."""
        if name not in NAMES:
            raise ValueError(f"name must be one of {list(NAMES)}")
        if len(text) > MAX_CHARS:
            raise ValueError(f"at most {MAX_CHARS} characters")
        with self.lock:
            self._load()
            if text.strip():
                self.data[name] = text
            else:
                self.data.pop(name, None)
            os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path), prefix=".prompts-")
            with os.fdopen(fd, "w") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
            os.replace(tmp, self.path)                          # mkstemp files are 0600
            self.stamp = None

    def reset(self, name):
        self.set(name, "")
