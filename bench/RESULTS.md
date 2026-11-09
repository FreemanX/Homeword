# Benchmark results

Machine: Apple M4 Pro (8P+4E CPU, 16-core GPU), 48 GB RAM, macOS 27.2 (26B123), on AC power. Every result file records its machine
(`bench/machine.py`). The raw result files of the runs below are in `bench/baselines/`; `bench/results/` (git-ignored) holds every local run.

## Current baseline (2026-11-07, commit after e31abc2)

Config: the policy as committed (`ghost/config.json` today; one reused session, short instructions, 6 examples, `textBudget` 100, `maxTokens` 6, plain output).

| Run | Scenario | Mode fingerprint | Latency p50 / p90 | Notes |
|---|---|---|---|---|
| `2026-11-07-steady.json` | `run.py` steady, 80 cases, 1.2 s apart | d4c6a5e1 | 329 / 426 ms (short cases 294 ms) | first word right 45%, mid-word completed exactly 58%, space after a finished word 8/8, 0 cache misses |
| `2026-11-07-typing-sim-seed1.json` | `human_pty.py`, typing only, seed 1 | ecac46d3 | key → ghost 259 / 284 ms | 57 ghosts shown, 0 cache misses |
| `2026-11-07-typing-sim-accept-seed1.json` | `human_pty.py`, `ACCEPT=1`, seed 1 | 260df743 | key → ghost 259 / 294 ms | 40 Tab accepts saved 136 of ~490 keystrokes |

**2026-11-09, mechanism/policy split** (predictd = model host, ghost/ = typing policy): `2026-11-09-steady-split.json`, same
fingerprint d4c6a5e1, identical quality, 331 / 422 ms (the run just before the split: 331 / 431 ms).

Steady cases are unrelated texts, so only the instructions and examples are cached; while typing, the previous keystroke's text is
cached too, which is why key → ghost is lower than the steady latency.

## Model modes

The system switches on its own between (at least) two ways of running the model: same assets, AC power, no other model user. Within
one mode greedy outputs are deterministic (82/82 identical between runs); across modes only ~25% match and latency differs:

| Mode | steady p50 | typing-sim key → ghost p50 | steady fingerprint |
|---|---|---|---|
| fast | ~320-330 ms | ~250-260 ms | d4c6a5e1 |
| slow | ~390-396 ms | ~305-345 ms | 4e44d1b6 |

The trigger is unknown (not idle unload, not power state); it switched within minutes on 2026-11-07. Compare runs only when their
fingerprints match (`compare.py` warns). Typing-sim fingerprints depend on the scenario and seed, compare like with like.

## How latency got here (typing simulation, key → ghost p50 / p90)

| Change | Result |
|---|---|
| debounce 200 ms, fresh prewarmed session per request, schema output | 582 / 809 ms |
| next request reuses the cancelled request's session | 528 / 638 ms |
| debounce 0 | 290 / 361 ms |
| one session for everything with transcript restore, short instructions, 100-token context | 263 / 326 ms |
| `maxTokens` 6 (drop a cut-off word), client answer memory + prefetch | 250-259 / 284-294 ms |
