"""The engine from the Python developer tools (pred, the benchmarks): ghostd's HTTP API and predictd's socket, standard library only.

    Ghostd(socket, config, no_user)   a private ghostd on a free port (benchmarks, PRED_NO_USER=1); .post/.get/.close
    shared()                          the port of the shared ghostd (127.0.0.1:47321), started in the background if needed
    predictd_call(req, socket)        one request to predictd (stats, shutdown)
"""
import json, os, socket, subprocess, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
GHOSTD, PREDICTD = os.path.join(ROOT, "ghostd"), os.path.join(ROOT, "predictd")
SOCK = os.environ.get("PRED_SOCKET") or f"/tmp/predictd-{os.getuid()}.sock"   # PRED_SOCKET: another predictd (tests)
PREDICTD_LOG = f"/tmp/predictd-{os.getuid()}.log"
GHOSTD_LOG = f"/tmp/ghostd-{os.getuid()}.log"
NO_USER = os.environ.get("PRED_NO_USER") == "1"


def need_build():
    if not (os.access(GHOSTD, os.X_OK) and os.access(PREDICTD, os.X_OK)):
        sys.exit(f"no engine binaries in {ROOT}: run ./build.sh")


def http(port, path, body=None, timeout=120):
    """GET (body None) or POST JSON to ghostd; the answer as a dict (an HTTP error's JSON body too)."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except ValueError:
            return {"ok": False, "error": f"HTTP {e.code}"}


def config_port():
    """serverPort from ghost/config.json and the user's overrides (unless PRED_NO_USER=1)."""
    port = json.load(open(os.path.join(ROOT, "ghost", "config.json"))).get("serverPort", 47321)
    user = os.path.expanduser("~/.config/homeword/config.json")
    if not NO_USER and os.path.exists(user):
        try:
            port = json.load(open(user)).get("serverPort", port)
        except (OSError, ValueError):
            pass
    return port


def up(port, timeout=1):
    try:
        return http(port, "/health", timeout=timeout).get("ok", False)
    except OSError:
        return False


def shared(on_start=None):
    """The shared ghostd's port; starts it (detached, it starts predictd) when it is not running."""
    need_build()
    port = config_port()
    if up(port):
        return port
    if on_start:
        on_start()
    with open(GHOSTD_LOG, "ab") as f:
        subprocess.Popen([GHOSTD, "--port", str(port)], stdin=subprocess.DEVNULL, stdout=f, stderr=f, start_new_session=True)
    end = time.monotonic() + 60
    while time.monotonic() < end:
        if up(port):
            return port
        time.sleep(0.2)
    sys.exit(f"ghostd did not start (log {GHOSTD_LOG})")


class Ghostd:
    """A private ghostd on a free port, for one process: benchmarks, PRED_NO_USER=1. Talks to predictd on `socket` (started there
    if needed, without the user's overrides when no_user). Stopped by close() (predictd stays up unless stop_predictd)."""

    def __init__(self, socket_path=SOCK, config=None, no_user=True, log=None):
        need_build()
        args = [GHOSTD, "--port", "0", "--socket", socket_path] + (["--no-user"] if no_user else [])
        if config:
            args += ["--config", json.dumps(config)]
        self.log = log or GHOSTD_LOG
        err = open(self.log, "ab")
        self.proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=err, text=True)
        line = self.proc.stdout.readline()                     # "ghost server on 127.0.0.1:<port> (predictd <socket>)"
        if not line.startswith("ghost server on 127.0.0.1:"):
            self.proc.wait()
            sys.exit(f"ghostd did not start (log {self.log})")
        self.port = int(line.split(":")[1].split()[0])
        self.socket = socket_path

    def get(self, path, timeout=120):
        return http(self.port, path, timeout=timeout)

    def post(self, path, body=None, timeout=120):
        return http(self.port, path, body or {}, timeout=timeout)

    def close(self, stop_predictd=False):
        if self.proc.poll() is None:
            try:
                self.post("/shutdown", {"predictd": stop_predictd}, timeout=5)
            except OSError:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def predictd_call(req, socket_path=SOCK, timeout=5):
    """One newline-delimited JSON request to predictd; None when it is not running."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(socket_path)
    except OSError:
        return None
    with s:
        s.sendall((json.dumps(dict(req, id="pred")) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    try:
        return json.loads(buf.split(b"\n")[0])
    except ValueError:
        return None
