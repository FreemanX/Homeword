"""The typing workload through the three interfaces on the running services: predictd's native `generate` op, its
OpenAI-compatible API, and the ghost server (`POST :47321/predict`, the policy on top of the native op).

  python3 -I bench/openai_compare.py [n_cases]      (bin/pred start first; nothing else should use the model)

Steady: the same prompts (ghost profile, greedy, 6 tokens), 1.2 s apart, per path: client-side latency and whether the model's raw
output matches the native one. The ghost server also trims the text, spell-checks and assembles the suggestion.
Burst: 12 keystrokes 40 ms apart, time from the last one to its answer: native and ghost requests share a `stream` (the newest
cancels the older ones), the OpenAI API has no such thing, so every request runs to the end.
"""
import json, pathlib, sys, threading, time, urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from ghost import predictd
from ghost.policy import Ghost, trim_tail

URL = "http://127.0.0.1:47320/v1/chat/completions"
GHOST = "http://127.0.0.1:47321/predict"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 40

ghost, link = Ghost(), predictd.start()
name = ghost.ensure_profile(link, pin=True)
prof = ghost.profile(ghost.cfg)
cases = json.load(open(pathlib.Path(__file__).parent / "cases.json"))[:N]
examples = [{"role": "system", "content": prof["instructions"]}]
for ex in prof["examples"]:
    examples += [{"role": "user", "content": ex["prompt"]}, {"role": "assistant", "content": ex["response"]}]


def prompt(c):
    return ghost.template(c["app"], trim_tail(c["text"], ghost.cfg["textBudget"])[0])


def native(c, ln=link, stream=None):
    r = ln.call(op="generate", profile=name, prompt=prompt(c), maxTokens=6, sampling="greedy", **({"stream": stream} if stream else {}))
    return r.get("text")


def openai(model, with_examples):
    def ask(c):
        msgs = (examples if with_examples else []) + [{"role": "user", "content": prompt(c)}]
        body = {"model": model, "messages": msgs, "max_tokens": 6, "temperature": 0}
        with urllib.request.urlopen(urllib.request.Request(URL, data=json.dumps(body).encode())) as f:
            return json.load(f)["choices"][0]["message"]["content"]
    return ask


def ghost_server(c, stream=None):
    body = {"app": c["app"], "text": c["text"], **({"stream": stream} if stream else {})}
    with urllib.request.urlopen(urllib.request.Request(GHOST, data=json.dumps(body).encode())) as f:
        return json.load(f).get("model_completion")


def pct(xs, p):
    xs = sorted(xs)
    return xs[int(round(p / 100 * (len(xs) - 1)))]


paths = [("native generate", native), ("openai, permissive model", openai("apple-on-device-permissive", True)),
         ("openai, profile as model", openai(name, False)), ("openai, default guardrails", openai("apple-on-device", True)),
         ("ghost server /predict", ghost_server)]
outs = {}
for label, fn in paths:
    fn(cases[0])
    time.sleep(1)
    lat, outs[label] = [], []
    for c in cases:
        time.sleep(1.2)
        t = time.perf_counter()
        outs[label].append(fn(c))
        lat.append((time.perf_counter() - t) * 1000)
    same = sum(a == b for a, b in zip(outs[paths[0][0]], outs[label]))
    print(f"{label:28} p50 {pct(lat, 50):4.0f} ms  p90 {pct(lat, 90):4.0f} ms  raw outputs identical to native {same}/{len(cases)}")

text = "Could you please send me the final version of the document before the meeting tomorrow"


def burst(fn):
    got, threads, t_last = {}, [], 0.0
    for k in range(12):
        c = {"app": "mail", "text": text[: len(text) - 11 + k]}
        th = threading.Thread(target=lambda k=k, c=c: got.__setitem__(k, (fn(k, c), time.perf_counter())))
        th.start()
        threads.append(th)
        t_last = time.perf_counter()
        time.sleep(0.04)
    for th in threads:
        th.join()
    return (got[11][1] - t_last) * 1000


links = [predictd.Link() for _ in range(12)]
time.sleep(2)
print(f"burst, last key -> answer: native, one stream (newest wins) {burst(lambda k, c: native(c, links[k], 'burst')):5.0f} ms")
time.sleep(2)
print(f"burst, last key -> answer: ghost server, one stream         {burst(lambda k, c: ghost_server(c, 'burst')):5.0f} ms")
time.sleep(2)
ask = openai("apple-on-device-permissive", True)
print(f"burst, last key -> answer: openai (every request runs)      {burst(lambda k, c: ask(c)):5.0f} ms")
