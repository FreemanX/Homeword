# Benchmark results

How the benchmarks work and how to run them: [docs/PERFORMANCE.md](../docs/PERFORMANCE.md). Every result file records the
machine it ran on; the files below are in [`baselines/`](baselines/).

## Machines

| Machine | CPU | GPU | Memory | macOS |
|---|---|---|---|---|
| Apple M4 Pro | 12 cores (8P + 4E) | 16-core | 48 GB | 27.2 (26B123) |
| Apple M4 Max | 14 cores (10P + 4E) | 32-core | 36 GB | 27.0.1 (26A434) |

All runs: on AC power, nothing else using the model, the typing policy as committed (`ghost/config.json`: 6 examples, short
instructions, `textBudget` 100, `maxTokens` 6, greedy, plain output).

## Steady benchmark

`bench/run.py --spawn`: 80 cases (52 short hand-written, 28 cut from a document at four context sizes), one request every 1.2 s.
Latency is client-side end to end. All three runs are in the same model mode (fingerprint `d4c6a5e1`).

| Machine | macOS | Date (commit) | p50 | p90 | max | Short cases p50 | Data |
|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | 2026-11-07 (`b245066`) | 329 ms | 426 ms | 477 ms | 302 ms | [steady](baselines/2026-11-07-steady.json) |
| Apple M4 Pro | 27.2 | 2026-11-09 (`4a0b80c`) | 331 ms | 422 ms | 483 ms | 305 ms | [steady](baselines/2026-11-09-steady-split.json) |
| Apple M4 Max | 27.0.1 | 2026-11-09 (`1511ffb`) | 295 ms | 408 ms | 446 ms | 278 ms | [steady](baselines/2026-11-09-steady-m4max.json) |

| Machine | macOS | Suggestion shown | First word right | Mid-word completed exactly | Leading words right | Word overlap | Space after a finished word | Cache misses |
|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | 96% | 45% | 58% | 0.61 | 30.5% | 8/8 | 0 |
| Apple M4 Max | 27.0.1 | 96% | 45% | 58% | 0.61 | 29.7% | 8/8 | 0 |

Quality is identical for both Apple M4 Pro runs. The model's raw completions are the same in all three runs; on macOS 27.0.1 the
suggestions differ in 27 of 80 cases (see [macOS versions](#macos-versions)).

## Typing simulation

`bench/human_pty.py`, seed 1: 8 sentences typed into `pred try` with human timing (~5.5 keys/s, pauses at word and sentence ends).
Key → ghost is the time from the last keystroke to the ghost on screen. "Tab when right" presses Tab whenever the ghost's next word
is the one being typed (`ACCEPT=1`).

| Machine | macOS | Run | Key → ghost p50 | p90 | Model p50 | Ghosts shown | Cache misses | Tab accepts | Keystrokes saved | Data |
|---|---|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | typing only | 259 ms | 284 ms | 257 ms | 57 | 0 | – | – | [typing](baselines/2026-11-07-typing-sim-seed1.json) |
| Apple M4 Pro | 27.2 | Tab when right | 259 ms | 294 ms | 257 ms | 66 | 0 | 40 | 136 of 491 | [accept](baselines/2026-11-07-typing-sim-accept-seed1.json) |
| Apple M4 Max | 27.0.1 | typing only | 258 ms | 291 ms | 257 ms | 56 | 0 | – | – | [typing](baselines/2026-11-09-typing-sim-seed1-m4max.json) |
| Apple M4 Max | 27.0.1 | Tab when right | 255 ms | 289 ms | 253 ms | 60 | 0 | 42 | 149 of 491 | [accept](baselines/2026-11-09-typing-sim-accept-seed1-m4max.json) |

The Apple M4 Max typing-only run had 1 failed request out of 303.

## Writing styles

`run.py --spawn --styles`: each prompt on the whole suite, 164 cases from `bench/cases.json` and `bench/styles.json`, each case with
its category's app label; sequential requests on a warm prefix. Next word right per category, and over all cases. The same
benchmark runs in Homeword's Prompts tab.

| Machine | macOS | Prompt | Chat | Email | Work | Academic | Code | General | Terminal | All | p50 | Data |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | general | 77% | 87% | 71% | 79% | 90% | 33% | 53% | 63% | 265 ms | [suite](baselines/2026-11-10-styles-suite.json) |
| Apple M4 Pro | 27.2 | chat | **81%** | 83% | 64% | 71% | 79% | 33% | 53% | 61% | 305 ms | [suite](baselines/2026-11-10-styles-suite.json) |
| Apple M4 Pro | 27.2 | email | 77% | **83%** | 64% | 86% | 74% | 33% | 37% | 59% | 285 ms | [suite](baselines/2026-11-10-styles-suite.json) |
| Apple M4 Pro | 27.2 | work | 42% | 74% | **79%** | 79% | 74% | 29% | 21% | 50% | 310 ms | [suite](baselines/2026-11-10-styles-suite.json) |
| Apple M4 Pro | 27.2 | academic | 73% | 87% | 64% | **86%** | 84% | 33% | 47% | 62% | 281 ms | [suite](baselines/2026-11-10-styles-suite.json) |
| Apple M4 Pro | 27.2 | code | 69% | 78% | 57% | 71% | **90%** | 31% | 32% | 56% | 286 ms | [suite](baselines/2026-11-10-styles-suite.json) |

Cases per category: chat 26, email 23, work 14, academic 14, code 19, general 49, terminal 19. Bold: the style's own category. On
it, the style's prompt is within one or two cases of general's (work +1 case, academic +1, chat +1, code 0, email -1).

| Machine | macOS | Prompt | Cases | p50 | Fully corrected | Word match | Length vs. input | Data |
|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | proofread | 12 | 370 ms | 75% | 0.98 | – | [suite](baselines/2026-11-10-styles-suite.json) |
| Apple M4 Pro | 27.2 | rewrite | 12 | 368 ms | – | – | 1.0 | [suite](baselines/2026-11-10-styles-suite.json) |

**Examples for a style** (Apple M4 Pro, macOS 27.2, 2026-11-10, two runs each, identical; no data file). General's instructions in
all variants; next word right on the style's own category, its cases labeled with the style:

| Style | General's 6 examples | 6 examples of the style | General's 6 + 2 of the style (shipped) |
|---|---|---|---|
| chat | 77% | 77% | 85% |
| email | 78% | 78% | 83% |
| academic | 93% | 86% | 86% |
| code | 79% | 68% | 79% |

Style-only examples broke word completions in code ("indepen" → "indepenently"). Prompts written entirely for a style (their own
instructions too) did worse still in an earlier round. Work documents does best with its own instructions and examples.

Outputs and latency depend on the model's mode, which the system switches on its own: the same prompt measured 78% and 87% next
word right on email in two runs in different modes. Compare prompts only within one run (`--styles` runs all of them together; the
Prompts tab's Run Default next to your run).

## Reading the numbers

- **Steady vs typing.** Steady cases are unrelated texts, so only the instructions and examples are cached. While typing, the
  previous keystroke's text is cached too, so key → ghost is lower than steady latency.
- **Model modes.** The system switches on its own between two ways of running the model, with different (but deterministic) outputs
  and speed. Compare runs only when their fingerprints match (`compare.py` warns). Typing-simulation fingerprints depend on the
  scenario and seed; compare like with like.

  | Mode (Apple M4 Pro, macOS 27.2) | Steady p50 | Typing key → ghost p50 | Steady fingerprint |
  |---|---|---|---|
  | fast | 320-330 ms | 250-260 ms | `d4c6a5e1` |
  | slow | 390-396 ms | 305-345 ms | `4e44d1b6` |

  The trigger is unknown (not idle unload, not power state). Within one mode, outputs repeat exactly between runs.

### macOS versions

macOS 27.0.1 does not expose the finish reason on the transcript entry (`Transcript.Response.finishReason`, read by reflection), so
predictd reports every answer as `stop` and the policy keeps a word cut by the 6-token cap instead of dropping it. On the same raw
completions:

| | macOS 27.2 | macOS 27.0.1 |
|---|---|---|
| Answers cut by the token cap | 39 of 80 | not detected |
| Suggestions | last cut-off word dropped | 27 of 80 keep the cut-off word |
| First word right, mid-word completed exactly | 45%, 58% | 45%, 58% |
| Word overlap | 30.5% | 29.7% |

For the same reason the typing-simulation fingerprints differ between the two macOS versions: a longer ghost changes the text of
later requests. The first 8 raw outputs of the typing-only runs match.

## Latency history

How key → ghost went from 582 ms to ~250 ms: [docs/PERFORMANCE.md](../docs/PERFORMANCE.md#latency-history).
