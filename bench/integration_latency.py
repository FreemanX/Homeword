"""Measure an integration in a real terminal app: type phrases into a tmux pane like a person (one key at a time, 85-170 ms
apart), then time last keystroke -> ghost text on screen, by polling capture-pane for the app's ghost colour after the typed text.

  python3 -I bench/integration_latency.py <tmux target> <ghost escape sequence> [clear keys, comma separated]
  pi:          python3 -I bench/integration_latency.py mysession:pi $'\x1b[90m' C-u,C-u
  Claude Code: python3 -I bench/integration_latency.py mysession:cc $'\x1b[38;5;246m' C-e,C-u
Start the app in that pane first (pi -e integrations/pi/ghost-editor.ts, or claude --plugin-dir integrations/claude-code)."""
import subprocess, sys, time, random, statistics
import shutil
TM = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
target, marker_re = sys.argv[1], sys.argv[2]          # marker: escape sequence that starts the ghost in this app
clear_keys = sys.argv[3].split(",") if len(sys.argv) > 3 else ["C-u", "C-u"]
phrases = ["Could you explain why the test is fail", "Please add a short summary of the changes to the READ",
           "I think we should move the helper into a sepa", "Can you check whether the config file is miss",
           "Let me know if anything is unclear about the requ", "Run the benchmark again and compare the res",
           "Why does the build take so long on the first ru", "Rename the function so that the name matches what it "]
def cap(): return subprocess.run([TM, "capture-pane", "-p", "-e", "-t", target], capture_output=True, text=True).stdout
res = []
for ph in phrases:
    for k in clear_keys: subprocess.run([TM, "send-keys", "-t", target, k]); time.sleep(0.15)
    time.sleep(0.8)
    for ch in ph:
        subprocess.run([TM, "send-keys", "-t", target, "-l", ch]); time.sleep(0.12 * random.uniform(0.7, 1.4))
    t0 = time.perf_counter(); seen = None
    while time.perf_counter() - t0 < 3:
        s = cap()
        line = next((l for l in s.splitlines() if ph[-12:] in l), "")
        if marker_re in line.split(ph[-12:])[-1]: seen = (time.perf_counter() - t0) * 1000; break
        time.sleep(0.01)
    import re
    ghost = re.sub(r"\x1b\[[0-9;]*m|\x1b_[^\x07]*\x07", "", line.split(ph[-12:])[-1]).strip() if seen else ""
    res.append(seen); print(f"{'%5.0f ms' % seen if seen else '  none  '}  …{ph[-26:]!r} -> {ghost[:40]!r}")
ok = [r for r in res if r]
if not ok:
    sys.exit("no ghost seen: is the daemon running, the integration loaded and the cursor at the end of the draft?")
print(f"\nghost shown {len(ok)}/{len(res)}; last key -> ghost on screen p50 {statistics.median(ok):.0f} ms, max {max(ok):.0f} ms (includes ~10 ms polling)")
