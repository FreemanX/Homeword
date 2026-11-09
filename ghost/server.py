"""HTTP front end of the ghost policy, for apps that are not written in Python (the pi extension, the Claude Code mod).

    POST /predict  {"app": "chat", "text": "See you tomor", "stream": "pi", "opts": {...}}  ->  the ghost answer (see policy.py)
    GET  /health   POST /shutdown

127.0.0.1 only. Requests on one `stream` replace each other (the older one answers {"ok": false, "error": "cancelled"}).
Exits after `serverIdleExitSec` without requests. Started by `pred start` / `pred serve`.
"""
import json, queue, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import predictd
from .policy import Ghost


def serve(port=None, socket_path=predictd.SOCK, quiet=False):
    ghost = Ghost()
    port = port or ghost.cfg["serverPort"]
    pool, last = queue.LifoQueue(), [time.monotonic()]
    first = predictd.start(socket_path)
    ghost.ensure_profile(first, pin=True)
    pool.put(first)

    def link():
        try:
            return pool.get_nowait()
        except queue.Empty:
            return predictd.start(socket_path)

    def drain():
        while True:
            try:
                pool.get_nowait().close()
            except queue.Empty:
                return

    class Handler(BaseHTTPRequestHandler):
        def reply(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.reply({"ok": True} if self.path == "/health" else {"ok": False, "error": "GET /health"}, 200 if self.path == "/health" else 404)

        def do_POST(self):
            last[0] = time.monotonic()
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path == "/shutdown":
                self.reply({"ok": True})
                threading.Thread(target=server.shutdown, daemon=True).start()
                return
            if self.path != "/predict":
                return self.reply({"ok": False, "error": "POST /predict"}, 404)
            try:
                req = json.loads(body or b"{}")
            except ValueError:
                return self.reply({"ok": False, "error": "body is not JSON"}, 400)
            r = {"ok": False, "error": "predictd unavailable"}
            for attempt in (0, 1):
                try:
                    ln = link()
                except (OSError, TimeoutError) as e:          # cannot start predictd
                    r = {"ok": False, "error": f"predictd unavailable: {e}"}
                    break
                try:
                    r = ghost.predict(ln, req.get("app", ""), req.get("text", ""), req.get("opts"), stream=req.get("stream", "ghost-http"))
                    pool.put(ln)
                    break
                except (OSError, ConnectionError):           # predictd went away (idle exit): reconnect, it restarts on demand
                    ln.close()
                    drain()                                  # the other pooled connections are dead too
                    ghost.registered.clear()
                except Exception as e:                       # a timeout or a refused profile: answer, and drop the connection
                    ln.close()
                    r = {"ok": False, "error": f"{type(e).__name__}: {e}"}
                    break
            self.reply(r)

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True

    def watchdog():
        idle = ghost.cfg["serverIdleExitSec"]
        while idle > 0:
            time.sleep(5)
            if time.monotonic() - last[0] > idle:
                server.shutdown()
                return
    threading.Thread(target=watchdog, daemon=True).start()
    if not quiet:
        print(f"ghost server on 127.0.0.1:{port} (predictd {socket_path})", flush=True)
    server.serve_forever()
