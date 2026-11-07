"""Drive `pred try` through a pty like a person typing, and print what the terminal would show (smoke test for the CLI)."""
import os, pty, re, select, sys, time, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(sys.executable, [sys.executable, str(root / "bin" / "pred"), "try", "--debounce", "200"])
import fcntl, termios, struct
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 110, 0, 0))
buf = b""
def pump(t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: return
def typ(s, per=0.09):
    for ch in s:
        os.write(fd, ch.encode()); pump(per)
pump(6)                                   # daemon start + banner
typ("git commit"); pump(2.0)
os.write(fd, b"\t"); pump(1.5)              # Tab: accept ONE word
os.write(fd, b"\t"); pump(1.0)              # and another
os.write(fd, b"\r"); pump(0.5)              # round 1 ends
typ("Thanks for letting me know about"); pump(2.0)   # finished word at the end: ghost must start with a space
os.write(fd, b"\x1b[C"); pump(1.0)          # Right: accept all
os.write(fd, b"\r"); pump(0.5)
typ("I think we should go to the"); pump(2.0)
os.write(fd, b"\r"); pump(0.5)
os.write(fd, b"\x04"); pump(1.0)
text = buf.decode("utf-8", "replace")
text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", lambda m: "" if m.group()[-1] in "CDAK" else m.group(), text)
text = text.replace("\r\x1b", "\r")
# show only the last redraw of each line plus the stats blocks
out = []
for line in re.split(r"\n", text.replace("\r", "\n")):
    line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
    if line and (line.startswith(("──", " ", "pred try")) or line.startswith("[")):
        out.append(line)
# collapse consecutive redraws of the prompt line
res = []
for l in out:
    if res and l.startswith("[") and res[-1].startswith("[") and l.split("›")[0] == res[-1].split("›")[0]:
        res[-1] = l
    else:
        res.append(l)
print("\n".join(res))
