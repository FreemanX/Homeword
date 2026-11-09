# Benchmark results

Every result file records its machine (`bench/machine.py`). The raw files for the runs below are in `bench/baselines/`;
`bench/results/` (git-ignored) holds every local run.

## This laptop (2026-11-09)

Apple M4 Max (10P+4E CPU, 32-core GPU), 36 GB RAM, macOS 27.0.1 (26A434), on AC power. Policy as committed
(`ghost/config.json`: one reused session, short instructions, 6 examples, `textBudget` 100, `maxTokens` 6, plain output).
`./build.sh` produced predictd 0.2. Nothing else was using the model (`bin/pred stop` first, no other `predictd`).

| Run | Scenario | Mode fingerprint | Latency p50 / p90 | Notes |
|---|---|---|---|---|
| `2026-11-09-steady-m4max.json` | `run.py` steady, 80 cases, 1.2 s apart | d4c6a5e1 | 295 / 408 ms (xs contexts 278 ms) | first word right 45%, mid-word completed exactly 58%, space after a finished word 8/8, 0 cache misses |
| `2026-11-09-typing-sim-seed1-m4max.json` | `human_pty.py`, typing only, seed 1 | a01bb227 | key → ghost 258 / 291 ms | 56 ghosts shown, 0 cache misses, 1 request error in 303 |
| `2026-11-09-typing-sim-accept-seed1-m4max.json` | `human_pty.py`, `ACCEPT=1`, seed 1 | 4391a18f | key → ghost 255 / 289 ms | 42 Tab accepts saved 149 of 491 keystrokes |

The steady fingerprint is the M4 Pro fast mode, and all 80 raw completions match `2026-11-09-steady-split.json`. On this OS
`Transcript.Response.finishReason` is not on the transcript entry (Mirror shows `id`, `assetIDs`, `citations`,
`contentAdvisories`, `_metadata`, `segments`), so `hitTokenCap` was false for every case. On macOS 27.2 the same completions
were `truncated` on 39 of 80 cases and the cut-off last word was dropped. Here that word is kept, which changes 27 suggestions.
First-word and mid-word accuracy are the same. Word overlap is 29.7% here and 30.5% on the 27.2 run. The typing-sim fingerprints
differ from the M4 Pro files for the same reason: a longer ghost changes the text of later requests. The first 8 raw outputs of
the typing-only run still match.

Steady cases are unrelated texts, so only the instructions and examples are cached. While typing, the previous keystroke's text
is cached too, which is why key → ghost is lower than the steady latency.

## M4 Pro baseline (2026-11-07, commit after e31abc2)

Machine: Apple M4 Pro (8P+4E CPU, 16-core GPU), 48 GB RAM, macOS 27.2 (26B123), on AC power.

Config: the policy as committed (`ghost/config.json` today; one reused session, short instructions, 6 examples, `textBudget` 100, `maxTokens` 6, plain output).

| Run | Scenario | Mode fingerprint | Latency p50 / p90 | Notes |
|---|---|---|---|---|
| `2026-11-07-steady.json` | `run.py` steady, 80 cases, 1.2 s apart | d4c6a5e1 | 329 / 426 ms (short cases 294 ms) | first word right 45%, mid-word completed exactly 58%, space after a finished word 8/8, 0 cache misses |
| `2026-11-07-typing-sim-seed1.json` | `human_pty.py`, typing only, seed 1 | ecac46d3 | key → ghost 259 / 284 ms | 57 ghosts shown, 0 cache misses |
| `2026-11-07-typing-sim-accept-seed1.json` | `human_pty.py`, `ACCEPT=1`, seed 1 | 260df743 | key → ghost 259 / 294 ms | 40 Tab accepts saved 136 of ~490 keystrokes |

**2026-11-09, mechanism/policy split** (predictd = model host, ghost/ = typing policy): `2026-11-09-steady-split.json`, same
fingerprint d4c6a5e1, identical quality, 331 / 422 ms (the run just before the split: 331 / 431 ms).

## Model modes

The system switches on its own between (at least) two ways of running the model: same assets, AC power, no other model user. Within
one mode greedy outputs are deterministic (82/82 identical between runs, on an earlier 82-case set); across modes only ~25% match and latency differs.
The bands below are the M4 Pro. On the M4 Max the same fast-mode fingerprint measured 295 ms steady p50 and 255-258 ms key → ghost.

| Mode | steady p50 | typing-sim key → ghost p50 | steady fingerprint |
|---|---|---|---|
| fast | ~320-330 ms | ~250-260 ms | d4c6a5e1 |
| slow | ~390-396 ms | ~305-345 ms | 4e44d1b6 |

The trigger is unknown (not idle unload, not power state); it switched within minutes on 2026-11-07. Compare runs only when their
fingerprints match (`compare.py` warns). Typing-sim fingerprints depend on the scenario and seed, compare like with like.

## How latency got here (typing simulation, key → ghost p50 / p90)

Measured on the M4 Pro:

| Change | Result |
|---|---|
| debounce 200 ms, fresh prewarmed session per request, schema output | 582 / 809 ms |
| next request reuses the cancelled request's session | 528 / 638 ms |
| debounce 0 | 290 / 361 ms |
| one session for everything with transcript restore, short instructions, 100-token context | 263 / 326 ms |
| `maxTokens` 6 (drop a cut-off word), client answer memory + prefetch | 250-259 / 284-294 ms |
