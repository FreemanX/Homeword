"""Client for predictd, the model host: newline-delimited JSON over its unix socket. Generic, not tied to any policy.

    link = start()                                    # connect, or start the daemon first
    link.call(op="profile.set", name="demo", instructions="Answer in one word.", pin=True)
    link.call(op="generate", profile="demo", prompt="Capital of France?", maxTokens=4)["text"]
"""
import itertools, json, os, select, socket, subprocess, time

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SOCK = f"/tmp/predictd-{os.getuid()}.sock"
LOG = f"/tmp/predictd-{os.getuid()}.log"
_ids = itertools.count(1)


class Link:
    """One connection to the daemon. `send` writes a request and returns its id; `read` returns the messages that have arrived
    (non-blocking); `call` sends and waits for the answer with the same id, queueing other messages for `read`."""

    def __init__(self, path=SOCK):
        self.path = path
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.s.setblocking(False)
        self.buf, self.queue = b"", []

    def fileno(self):
        return self.s.fileno()

    def send(self, **req):
        req.setdefault("id", f"r{next(_ids)}")
        self.s.setblocking(True)
        try:
            self.s.sendall((json.dumps(req) + "\n").encode())
        finally:
            self.s.setblocking(False)
        return req["id"]

    def _pull(self, timeout):
        select.select([self.s], [], [], timeout)
        try:
            d = self.s.recv(1 << 16)
        except BlockingIOError:
            d = None
        if d == b"":
            raise ConnectionError("predictd closed the connection")
        if d:
            self.buf += d
        out = []
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            out.append(json.loads(line))
        return out

    def read(self, timeout=0):
        out, self.queue = self.queue + self._pull(timeout), []
        return out

    def call(self, timeout=30, **req):
        rid = self.send(**req)
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for m in self._pull(0.05):
                if m.get("id") == rid:
                    return m
                self.queue.append(m)
        raise TimeoutError(f"no answer from predictd to {req.get('op')}")

    def close(self):
        self.s.close()


def start(path=SOCK, config=None, http_port=None, log=LOG, wait=40, on_spawn=None):
    """Connect to the daemon on `path`, starting it first if nobody answers there."""
    try:
        return Link(path)
    except OSError:
        pass
    binary = os.path.join(ROOT, "predictd")
    if not os.path.exists(binary):
        raise FileNotFoundError(f"{binary} not found: run {ROOT}/build.sh first")
    if on_spawn:
        on_spawn()
    args = [binary, "--socket", path] + (["--config", config] if config else []) + (["--http-port", str(http_port)] if http_port is not None else [])
    if os.environ.get("PRED_NO_USER") == "1":           # benchmarks: the shipped predictd.json, not the user's overrides
        args += ["--user-config", ""]
    with open(log, "ab") as f:
        subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        time.sleep(0.1)
        try:
            return Link(path)
        except OSError:
            continue
    raise TimeoutError(f"predictd did not come up, see {log}")
