"""HTTP front end of the policies, for apps that are not written in Python (the pi extension, the Claude Code mod, the Mac app).

    POST /predict    {"app": "chat", "text": "See you tomor", "stream": "pi", "context": "chat", "opts": {...}}  ->  the ghost
                     answer (policy.py); `context`: a writing style (general, chat, email, work, academic, code; default general)
    POST /warm       {"context": "chat"}: the user is about to type in this style: pin and prewarm its prompt
    POST /proofread  {"text": "...", "mode": "fix" | "rewrite"}  ->  {"text", "changed", "changes", "warnings", ...} (proofread.py)
    GET  /prompts    -> {"prompts": [{"name", "group", "title", "prompt", "default", "custom", "hash", "result", "suite_cases",
                     ...}]}: every prompt (prediction per style, proofreading per mode), the one in use and the shipped one
                     (prompts.py), and the size of the benchmark it runs on
    POST /prompts    {"name": "predict-chat", "prompt": {"instructions", "examples"}} saves the user's version (and a history
                     entry), {"name": ..., "reset": true} restores the shipped one
    GET  /history?name=predict-chat  -> {"versions": [{"hash", "saved_at", "prompt", "result"}]}: the last saved versions
                     (results from another version of the suite are left out: they are not comparable)
    POST /tokens     {"name", "prompt"?}  ->  {"instructions": n, "prompt": n (instructions + examples as sent), "ms": est.}
    POST /bench      {"name", "prompt"?, "scope": "all" | "user"}  ->  {"job"}: benchmark that prompt (default: the one in use)
                     on the suite, per category (evaluate.py), and/or on the user's cases; runs in the background
    GET  /bench?job= -> {"state": "running" | "done" | "error", "done", "total", "result"}: progress, then the result, which is
                     also stored by the prompt's hash (history entries show it)
    GET  /suite?name=predict-chat  -> {"categories": [{"name", "title", "cases": [{"text", "rest", "skipped"}]}]}: the built-in
                     benchmark cases the prompt runs on, read-only; `skipped`: left out because it shares text with an example of
                     the prompt in use
    GET  /cases?name=  -> {"cases": [{"text", "rest"}]}: the user's own benchmark cases for a prompt
    POST /cases      {"name", "cases": [...]} saves them
    GET  /settings   -> {"words", "maxTokens"}      POST /settings {"words": 1-10}: how many words to suggest, saved to the user's
                     config overrides (maxTokens follows: words + 1 per 5 words)
    GET  /health     -> {"ok", "port", "model": true if predictd answers}     POST /shutdown

127.0.0.1 only. Requests on one `stream` replace each other (the older one answers {"ok": false, "error": "cancelled"}).
Exits after `serverIdleExitSec` without requests. Started by `pred start` / `pred serve`.
"""
import json, queue, threading, time, urllib.parse, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import evaluate, predictd
from .policy import Ghost, save_user_config, tokens_for_words
from .prompts import clean, prompt_hash
from .proofread import Proofreader

CACHED_MS_PER_TOKEN = 0.55               # measured cost of a cached prompt token per request (docs/PERFORMANCE.md)


def serve(port=None, socket_path=predictd.SOCK, quiet=False):
    ghost = Ghost()
    proof = Proofreader(ghost.cfg, ghost.user)
    port = port or ghost.cfg["serverPort"]
    pool, last = queue.LifoQueue(), [time.monotonic()]
    bench_lock = threading.Lock()
    jobs = {}                                            # benchmark jobs by id
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

    def with_link(fn):
        """Run fn(link) with a pooled connection; reconnect once when predictd went away (idle exit: it restarts on demand)."""
        r = {"ok": False, "error": "predictd unavailable"}
        for attempt in (0, 1):
            try:
                ln = link()
            except (OSError, TimeoutError) as e:          # cannot start predictd
                return {"ok": False, "error": f"predictd unavailable: {e}"}
            try:
                r = fn(ln)
                pool.put(ln)
                return r
            except (OSError, ConnectionError):
                ln.close()
                drain()                                  # the other pooled connections are dead too
                ghost.registered.clear()
                ghost.pinned = None
                proof.registered.clear()
            except Exception as e:                       # a timeout or a refused profile: answer, and drop the connection
                ln.close()
                return {"ok": False, "error": f"{type(e).__name__}: {e}"}
        return r

    # -- prompts: prediction per style ("predict-<style>"), proofreading per mode ("proofread-<mode>")

    def parse(name):
        kind, _, key = (name or "").partition("-")
        if kind == "predict" and key in ghost.style_names():
            return kind, key
        if kind == "proofread" and key in ("fix", "rewrite"):
            return kind, key
        raise ValueError(f"unknown prompt {name!r}")

    def current(name):
        kind, key = parse(name)
        return ghost.prompt_for(key) if kind == "predict" else proof.prompt_for(key)

    def default(name):
        kind, key = parse(name)
        return ghost.default_prompt(key) if kind == "predict" else proof.default_prompt(key)

    suite = evaluate.suite()
    sizes = {"predict": (len(suite), len({c["category"] for c in suite})), "proofread": (len(evaluate.load_cases()["proofread"]), 1)}

    suite_ids = {"predict": evaluate.suite_id(), "fix": evaluate.suite_id("fix"), "rewrite": evaluate.suite_id("rewrite")}

    def result(name, prompt, scope="all"):
        """A stored benchmark result, unless it ran on another version of the suite (a user-cases run has no suite part)."""
        kind, key = parse(name)
        r = ghost.user.result(name, prompt, scope)
        if r and scope == "all" and r.get("suite") != suite_ids["predict" if kind == "predict" else key]:
            return None
        return r

    def suite_view(name):
        kind, key = parse(name)
        examples = current(name)["examples"]
        mark = lambda c: {"text": c["text"], "rest": c["rest"], "skipped": evaluate.overlaps(c["text"], examples)}
        if kind == "proofread":
            return [{"name": "proofread", "title": evaluate.TITLES["proofread"],
                     "cases": [mark({"text": c["text"], "rest": c["expected"]}) for c in evaluate.load_cases()["proofread"]]}]
        return [{"name": k, "title": t, "cases": [mark(c) for c in suite if c["category"] == k]} for k, t in evaluate.CATEGORIES]

    def entry(name):
        kind, key = parse(name)
        p, d = current(name), default(name)
        return {"name": name, "group": "prediction" if kind == "predict" else "proofreading",
                "title": ghost.style_title(key) if kind == "predict" else {"fix": "Proofread", "rewrite": "Rewrite"}[key],
                "prompt": p, "default": d, "custom": ghost.user.get(name) is not None, "hash": prompt_hash(p),
                "default_hash": prompt_hash(d), "result": result(name, p), "default_result": result(name, d),
                "user_result": ghost.user.result(name, p, "user"), "user_cases": len(ghost.user.cases(name)),
                "labels": ["Typed text", "Continuation"] if kind == "predict" else ["Input", "Output"],
                "suite_cases": sizes[kind][0], "suite_categories": sizes[kind][1],
                "inherits": kind == "predict" and ghost.inherits(key) and ghost.user.get(name) is None,
                "note": (f"{{words}} becomes the number of words to suggest ({ghost.cfg['words']})." if kind == "predict"
                         else "The model gets one paragraph at a time.")}

    def catalog():
        return [entry("predict-" + s) for s in ghost.style_names()] + [entry("proofread-fix"), entry("proofread-rewrite")]

    def save(req):
        name = req.get("name", "")
        if name == "typing":                             # the first version's API: instructions only, general style
            name, req = "predict-general", {"prompt": {"instructions": req.get("text", ""), "examples": default("predict-general")["examples"]}, **req}
        parse(name)
        if req.get("reset") or (req.get("text") == "" and "prompt" not in req):
            ghost.user.set(name, None)
        else:
            p = clean(req.get("prompt"))
            ghost.user.set(name, None if p == default(name) else p)
        return {"ok": True, "prompts": catalog()}

    def profile_of(name, prompt):
        kind, key = parse(name)
        return ghost.profile(ghost.cfg, key, prompt) if kind == "predict" else proof.profile(key, prompt)

    def tokens(req):
        name = req.get("name", "")
        prompt = clean(req["prompt"]) if req.get("prompt") else current(name)
        prof = profile_of(name, prompt)

        def count(ln):
            ins = ln.call(op="tokens", text=prof["instructions"]).get("count", -1)
            r = ln.call(op="profile.set", **{**prof, "name": "tokens-probe", "pin": False})   # the prefix exactly as sent
            ln.call(op="profile.drop", name="tokens-probe")
            n = r.get("prefix_tokens", -1)
            return {"ok": True, "instructions": ins, "prompt": n, "ms": round(n * CACHED_MS_PER_TOKEN) if n > 0 else None}
        return with_link(count)

    def bench(req):
        """Start a benchmark job; GET /bench?job= reports progress and the result."""
        name = req.get("name", "")
        kind, key = parse(name)
        prompt = clean(req["prompt"]) if req.get("prompt") else current(name)
        scope = "user" if req.get("scope") == "user" else "all"
        user_cases = ghost.user.cases(name)
        if scope == "user" and not user_cases:
            return {"ok": False, "error": "no cases of your own yet"}
        if not bench_lock.acquire(blocking=False):
            return {"ok": False, "error": "a benchmark is already running"}
        job = uuid.uuid4().hex[:12]
        jobs[job] = {"state": "running", "done": 0, "total": 0, "name": name, "hash": prompt_hash(prompt)}

        def progress(done, total):
            jobs[job].update(done=done, total=total)

        def work():
            try:
                def run(ln):
                    if kind == "predict":
                        res = evaluate.bench_prompt(ghost, ln, key, prompt, user_cases, scope, progress)
                    else:
                        res = evaluate.bench_proofread(proof, ln, key, prompt, user_cases, scope, progress)
                    if ghost.pinned:                     # give the cache back to the prompt in use
                        ln.call(op="prewarm", profile=ghost.pinned)
                    return res
                res = with_link(run)
                if res.get("ok") is False or res.get("error"):
                    jobs[job].update(state="error", error=res.get("error", "failed"))
                    return
                ghost.user.save_result(name, prompt, res)
                jobs[job].update(state="done", result=res)
            except Exception as e:
                jobs[job].update(state="error", error=f"{type(e).__name__}: {e}")
            finally:
                bench_lock.release()
                for old in [j for j, v in jobs.items() if v["state"] != "running"][:-20]:
                    jobs.pop(old, None)
        threading.Thread(target=work, daemon=True).start()
        return {"ok": True, "job": job}

    def model_up():
        try:
            ln = predictd.Link(socket_path)
        except OSError:
            return False
        try:
            return ln.call(op="ping", timeout=1).get("ok", False)
        except Exception:
            return False
        finally:
            ln.close()

    class Handler(BaseHTTPRequestHandler):
        def reply(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            last[0] = time.monotonic()
            url = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(url.query)
            try:
                if url.path == "/health":
                    return self.reply({"ok": True, "port": port, "model": model_up()})
                if url.path == "/prompts":
                    return self.reply({"ok": True, "prompts": catalog(), "styles": [{"name": s, "title": ghost.style_title(s)} for s in ghost.style_names()]})
                if url.path == "/bench":
                    j = jobs.get((q.get("job") or [""])[0])
                    return self.reply({"ok": True, **j} if j else {"ok": False, "error": "unknown job"})
                if url.path == "/cases":
                    name = (q.get("name") or [""])[0]
                    parse(name)
                    return self.reply({"ok": True, "name": name, "cases": ghost.user.cases(name)})
                if url.path == "/suite":
                    name = (q.get("name") or [""])[0]
                    return self.reply({"ok": True, "name": name, "categories": suite_view(name)})
                if url.path == "/settings":
                    return self.reply({"ok": True, "words": ghost.cfg["words"], "maxTokens": ghost.cfg["maxTokens"]})
                if url.path == "/history":
                    name = (q.get("name") or [""])[0]
                    parse(name)
                    sid = suite_ids["predict" if name.startswith("predict-") else name.partition("-")[2]]
                    versions = [{**v, "result": v["result"] if (v.get("result") or {}).get("suite") == sid else None}
                                for v in ghost.user.history(name)]
                    return self.reply({"ok": True, "name": name, "versions": versions})
            except ValueError as e:
                return self.reply({"ok": False, "error": str(e)}, 400)
            self.reply({"ok": False, "error": "GET /health, /prompts, /history?name=, /cases?name= or /bench?job="}, 404)

        def do_POST(self):
            last[0] = time.monotonic()
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path == "/shutdown":
                self.reply({"ok": True})
                threading.Thread(target=server.shutdown, daemon=True).start()
                return
            try:
                req = json.loads(body or b"{}")
            except ValueError:
                return self.reply({"ok": False, "error": "body is not JSON"}, 400)
            try:
                if self.path == "/predict":
                    r = with_link(lambda ln: ghost.predict(ln, req.get("app", ""), req.get("text", ""), req.get("opts"),
                                                           stream=req.get("stream", "ghost-http"), style=req.get("context") or "general"))
                elif self.path == "/proofread":
                    r = with_link(lambda ln: proof.run(ln, req.get("text", ""), req.get("mode", "fix")))
                elif self.path == "/warm":
                    r = with_link(lambda ln: ghost.warm(ln, req.get("context") or "general"))
                elif self.path == "/prompts":
                    r = save(req)                        # no model involved
                elif self.path == "/tokens":
                    r = tokens(req)
                elif self.path == "/bench":
                    r = bench(req)
                elif self.path == "/settings":
                    w = req.get("words")
                    if not isinstance(w, int) or not 1 <= w <= 10:
                        raise ValueError("words must be a whole number from 1 to 10")
                    ghost.cfg.update(words=w, maxTokens=tokens_for_words(w))   # {words} is in the prompts: new profiles
                    save_user_config({"words": w, "maxTokens": ghost.cfg["maxTokens"]})
                    r = {"ok": True, "words": w, "maxTokens": ghost.cfg["maxTokens"]}
                elif self.path == "/cases":
                    parse(req.get("name", ""))
                    r = {"ok": True, "cases": ghost.user.set_cases(req["name"], req.get("cases"))}
                else:
                    return self.reply({"ok": False, "error": "POST /predict, /warm, /proofread, /prompts, /tokens, /bench, /cases or /settings"}, 404)
            except (ValueError, OSError) as e:
                return self.reply({"ok": False, "error": str(e)}, 400)
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
