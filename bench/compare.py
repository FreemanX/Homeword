"""Compare two result files: python3 -I compare.py before.json after.json"""
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
def row(name, x, y, fmt="{:.0f}", better="low"):
    d = y - x; good = (d < 0) == (better == "low") if d else None
    print(f"  {name:34} {fmt.format(x):>8} {fmt.format(y):>8}  {'+' if d>=0 else ''}{fmt.format(d)}  {'' if good is None else ('better' if good else 'WORSE')}")
print(f"{a['label']} ({a['scenario']}) vs {b['label']} ({b['scenario']})\n  {'metric':34} {'before':>8} {'after':>8}")
A, B = a["summary"], b["summary"]
ma, mb = a.get("machine", {}).get("model"), b.get("machine", {}).get("model")
if ma and mb and ma != mb:
    print(f"  WARNING: different on-device models ({ma} vs {mb}): they answer differently; compare quality within one model")
fa, fb = A.get("mode_fingerprint"), B.get("mode_fingerprint")
if fa and fb and fa != fb and a["rows"][0]["case"]["id"] == b["rows"][0]["case"]["id"]:
    print(f"  WARNING: different output fingerprints ({fa} vs {fb}): another model mode or model variant, outside the code; compare within one")
for k in ("e2e_p50", "e2e_p90", "e2e_max", "model_p50"): row("latency " + k, A["latency"][k], B["latency"][k])
for bk in A["latency_by_bucket"]:
    if bk in B["latency_by_bucket"]: row(f"e2e p50, context {bk}", A["latency_by_bucket"][bk]["e2e_p50"], B["latency_by_bucket"][bk]["e2e_p50"])
for k, n in (("shown", "suggestion shown"), ("acc1", "first word right"), ("lead_mean", "leading words right"), ("bag", "word overlap"), ("mid_word_ok", "mid-word completed right")):
    row(n, A["quality"][k], B["quality"][k], "{:.2f}", "high")
row("cache misses", A["cache"]["misses"], B["cache"]["misses"]); row("errors", A["errors"], B["errors"])
