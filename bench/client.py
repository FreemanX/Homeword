"""Minimal client for predictd (newline-delimited JSON over a unix socket)."""
import json, socket, time, itertools

_ids = itertools.count(1)

class Client:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.buf = b""

    def _read(self):
        while b"\n" not in self.buf:
            d = self.s.recv(65536)
            if not d:
                raise ConnectionError("daemon closed the connection")
            self.buf += d
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def send(self, **req):
        req.setdefault("id", str(next(_ids)))
        self.s.sendall((json.dumps(req) + "\n").encode())
        return req["id"]

    def call(self, **req):
        """Send one request, wait for its response; returns (response, client-side e2e ms)."""
        t = time.perf_counter()
        rid = self.send(**req)
        while True:
            r = self._read()
            if r.get("id") == rid:
                return r, (time.perf_counter() - t) * 1000

    def recv(self):
        return self._read()
