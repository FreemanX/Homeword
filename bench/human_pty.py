"""Drive `pred try` through a pty with human-like typing (jittered key intervals, pauses at word ends), never accepting.
Prints pred's session stats. Usage: python3 -I human_pty.py [extra pred try args...]   e.g. --debounce 100
Timing model: ~5.5 keys/s (lognormal around 170 ms), 25% of word ends get a 250-700 ms pause, sentence ends 800 ms."""
import os, pty, random, re, select, sys, time, pathlib, fcntl, termios, struct, json, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
LINES = [
    "Hi Sarah, thanks for the update on the budget. I will review the numbers and get back to you tomorrow.",
    "git commit -m \"fix the login timeout\"",
    "Could you please send me the slides from the meeting so I can share them with the team?",
    "We are planning a trip to Portugal next summer and want to visit Lisbon and Porto.",
    "docker compose up -d --build",
    "I think the main problem with the current design is that it does not scale well.",
    "Let me know if you have any questions about the schedule.",
    "ls -la ~/Downloads",
]
rng = random.Random(int(os.environ.get("SEED", "1")))
logf = tempfile.mktemp(suffix=".jsonl")
ghostf = tempfile.mktemp(suffix=".json")
ACCEPT = os.environ.get("ACCEPT") == "1"      # press Tab when the ghost's next word is what the user meant to type
os.environ["PRED_GHOST_FILE"] = ghostf
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(sys.executable, [sys.executable, str(root / "bin" / "pred"), "try", "--log", logf] + sys.argv[1:])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
buf = b""
def pump(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: return
pump(8)
def ghost():
    try: return json.load(open(ghostf))
    except Exception: return {"text": "", "ghost": ""}
tabs = 0
for line in LINES:
    i = 0
    while i < len(line):
        if ACCEPT:
            g = ghost()
            if g["text"] == line[:i] and g["ghost"]:
                gw = g["ghost"]
                j = 0
                while j < len(gw) and gw[j].isspace(): j += 1
                while j < len(gw) and not gw[j].isspace(): j += 1
                piece = gw[:j]
                if piece.strip() and line[i:].startswith(piece):
                    os.write(fd, b"\t"); tabs += 1; i += len(piece)
                    pump(min(0.6, rng.lognormvariate(-1.2, 0.3)))     # a Tab press takes a moment of reading (~300 ms)
                    continue
        ch = line[i]; i += 1
        os.write(fd, ch.encode())
        d = min(0.45, rng.lognormvariate(-1.8, 0.35))               # median ~165 ms
        if ch == " " and rng.random() < 0.25: d += rng.uniform(0.25, 0.7)
        if ch in ".?!": d += 0.8
        pump(d)
    pump(1.2)
    os.write(fd, b"\r"); pump(0.6)
os.write(fd, b"\x04"); pump(1.5)
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", buf.decode("utf-8", "replace"))
i = text.rfind("── session")
print(text[i:].strip())
rows = [json.loads(l) for l in open(logf)]
parts = [p for r in rows for p in r["parts"]]
k2g = [k for r in rows for k in r["key_to_ghost_ms"]]
os.unlink(logf)
if os.path.exists(ghostf): os.unlink(ghostf)
def pct(x, p):
    x = sorted(x); return x[min(len(x) - 1, int(round(p / 100 * (len(x) - 1))))] if x else float("nan")
inst = [k for k in k2g if k <= 5]
print(f"\nSUMMARY tabs {tabs} · instant ghosts {len(inst)}/{len(k2g)} · key→ghost p50 {pct(k2g,50):.0f} p90 {pct(k2g,90):.0f} | wait p50 {pct([p['wait'] for p in parts],50):.0f} | model p50 {pct([p['model'] for p in parts],50):.0f} "
      f"p90 {pct([p['model'] for p in parts],90):.0f} | cache misses {sum(p['cached']<0.5 for p in parts)}/{len(parts)} | sessions {dict((s, sum(p['session']==s for p in parts)) for s in set(p['session'] for p in parts))}")
