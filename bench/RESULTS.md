# Benchmark results

How the benchmarks work and how to run them: [docs/PERFORMANCE.md](../docs/PERFORMANCE.md). Every result file records the
machine it ran on; the files below are in [`baselines/`](baselines/). One result per machine and benchmark: the best run.
Machines run one of two versions of Apple's on-device model (Model column, "Model variants" below): quality numbers compare only
between machines with the same model.

## Machines

| Machine | CPU | GPU | Memory | macOS | Model | Context |
|---|---|---|---|---|---|---|
| Apple M4 Pro | 12 cores (8P + 4E) | 16-core | 48 GB | 27.2 (26B123) | AFM 3 Core Advanced | 8,192 |
| Apple M4 Max | 14 cores (10P + 4E) | 32-core | 36 GB | 27.0.1 (26A434) | AFM 3 Core Advanced * | not checked |
| Apple M1 Pro | 8 cores (6P + 2E) | 14-core | 16 GB | 27.2 (26B123) | AFM 3 Core | 4,096 |
| Apple M1 Pro | 8 cores (6P + 2E) | 14-core | 16 GB | 27.2.1 (26B131) | AFM 3 Core | 4,096 |
| Apple M2 | 8 cores (4P + 4E) | 8-core | 16 GB | 27.2.1 (26B131) | AFM 3 Core | 8,192 |

Model and Context (the context window in tokens) as `./predictd --model` reports them. \* Inferred from the outputs: the run gives
the same 80 steady answers as the Apple M4 Pro. The window depends on the chip: the Apple M1 Pro and Apple M2 on macOS 27.2.1
(26B131) run the same model and differ; every benchmark prompt here fits in 4,096 tokens. Result files record the model (`machine.model`) and the window
(`machine.context`) from 2026-11-13 on.

All runs: on AC power, nothing else using the model, the typing policy as committed (`ghost/config.json`: 6 examples, short
instructions, `textBudget` 100, `maxTokens` 6, greedy, plain output).

## Steady benchmark

`bench/run.py --spawn`: 80 cases (52 short hand-written, 28 cut from a document at four context sizes), one request every 1.2 s.
Latency is client-side end to end. The two Apple M4 runs (AFM 3 Core Advanced) are in the same model mode (fingerprint
`d4c6a5e1`); the Apple M1 Pro (both macOS versions) and Apple M2 runs (AFM 3 Core) have fingerprint `609ddd4f`.

| Machine | macOS | Date (commit) | p50 | p90 | max | Short cases p50 | Data |
|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | 2026-11-07 (`b245066`) | 329 ms | 426 ms | 477 ms | 302 ms | [steady](baselines/2026-11-07-steady.json) |
| Apple M4 Max | 27.0.1 | 2026-11-09 (`1511ffb`) | 295 ms | 408 ms | 446 ms | 278 ms | [steady](baselines/2026-11-09-steady-m4max.json) |
| Apple M1 Pro | 27.2 | 2026-11-11 (`5d4d904`) | 517 ms | 634 ms | 684 ms | 468 ms | [steady](baselines/2026-11-11-steady-m1pro.json) |
| Apple M1 Pro | 27.2.1 | 2026-11-13 (`62798c6`) | 500 ms | 632 ms | 715 ms | 474 ms | [steady](baselines/2026-11-13-steady-m1pro.json) |
| Apple M2 | 27.2.1 | 2026-11-12 (`cd24648`) | 286 ms | 357 ms | 425 ms | 256 ms | [steady](baselines/2026-11-12-steady-m2.json) |

| Machine | macOS | Suggestion shown | First word right | Mid-word completed exactly | Leading words right | Word overlap | Space after a finished word | Cache misses |
|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | 96% | 45% | 58% | 0.61 | 30.5% | 8/8 | 0 |
| Apple M4 Max | 27.0.1 | 96% | 45% | 58% | 0.61 | 29.7% | 8/8 | 0 |
| Apple M1 Pro | 27.2 | 99% | 45% | 55% | 0.57 | 42.8% | 7/8 | 0 |
| Apple M1 Pro | 27.2.1 | 99% | 45% | 55% | 0.57 | 42.8% | 7/8 | 0 |
| Apple M2 | 27.2.1 | 99% | 45% | 55% | 0.57 | 42.8% | 7/8 | 0 |

Model time split into a fixed part and a part per output token (`model_cost` in a result's summary, a least-squares fit over the
80 requests), with the answers' mean length:

| Machine | Model | Output tokens per answer | Model time |
|---|---|---|---|
| Apple M4 Pro | AFM 3 Core Advanced | 10.0 | 194 ms + 14.6 ms per token |
| Apple M4 Max | AFM 3 Core Advanced | 10.0 | 175 ms + 13.7 ms per token |
| Apple M1 Pro (macOS 27.2) | AFM 3 Core | 8.7 | 368 ms + 16.7 ms per token |
| Apple M1 Pro (macOS 27.2.1) | AFM 3 Core | 8.7 | 352 ms + 18.7 ms per token |
| Apple M2 | AFM 3 Core | 8.7 | 178 ms + 12.1 ms per token |

The raw completions are the same within each model: both Apple M4 runs give the same 80, and so do the Apple M1 Pro (macOS 27.2
and 27.2.1: the same 80 suggestions too) and Apple M2 runs. Across the two models only 7 of 80 agree, with the same prompt
(profile `ghost-295db2ba`) and the same input tokens ("Model variants" below). On macOS 27.0.1 the Apple M4 Max's suggestions differ in 27 of 80 cases from the same completions (see
[macOS versions](#macos-versions)). Core's suggestions are shorter: 2.5 words on average vs 3.4 (Apple M4 Pro) and 3.75 (Apple
M4 Max).

What the latency columns compare: within a model, the hardware (Apple M4 Max vs Apple M4 Pro, Apple M2 vs Apple M1 Pro: the
Apple M2 is about 1.8 times as fast with fewer GPU cores, which suggests the model runs mainly on the Neural Engine). Across models, a Mac
with its own model: Core is lighter, not only shorter. On the 36 cases where all four machines' answers have the same number of
tokens, model p50 is 363 ms (Apple M4 Pro), 339 ms (Apple M4 Max), 548 ms (Apple M1 Pro) and 306 ms (Apple M2).

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
| Apple M1 Pro | 27.2 | typing only | 354 ms | 416 ms | 352 ms | 33 | 0 | – | – | [typing](baselines/2026-11-11-typing-sim-seed1-m1pro.json) |
| Apple M1 Pro | 27.2 | Tab when right | 357 ms | 413 ms | 354 ms | 35 | 0 | 16 | 60 of 491 | [accept](baselines/2026-11-11-typing-sim-accept-seed1-m1pro.json) |
| Apple M1 Pro | 27.2.1 | typing only | 352 ms | 419 ms | 348 ms | 34 | 0 | – | – | [typing](baselines/2026-11-13-typing-sim-seed1-m1pro.json) |
| Apple M1 Pro | 27.2.1 | Tab when right | 350 ms | 434 ms | 348 ms | 34 | 0 | 30 | 133 of 491 | [accept](baselines/2026-11-13-typing-sim-accept-seed1-m1pro.json) |
| Apple M2 | 27.2.1 | typing only | 256 ms | 412 ms | 252 ms | 46 | 0 | – | – | [typing](baselines/2026-11-12-typing-sim-seed1-m2.json) |
| Apple M2 | 27.2.1 | Tab when right | 268 ms | 364 ms | 282 ms | 53 | 0 | 39 | 149 of 491 | [accept](baselines/2026-11-12-typing-sim-accept-seed1-m2.json) |

The Apple M4 Max typing-only run had 1 failed request out of 303. On the Apple M1 Pro a model call (~355 ms) is longer than the
gap between keys, so most requests are superseded by the next keystroke (69 of 441 answered, vs 147 of 297 on the Apple M4 Pro):
fewer ghosts, and which keystrokes get an answer varies with timing, so the fingerprint differs between otherwise equal runs.
On the Apple M2 the recorded typing-only run answered 90 of 390 requests (model p50 252 ms); its two runs differ in fingerprint
for the same reason. On the Apple M1 Pro with macOS 27.2.1 the two Tab-when-right runs saved 133 and 61 keystrokes at the same
latency: which ghosts arrive before the next key decides what can be accepted.

## Writing styles

`run.py --spawn --styles`: each prompt on the whole suite, 200 cases from `bench/cases.json` and `bench/styles.json` (at least 25
per category; none of them in any prompt's examples), each case with its category's app label; sequential requests on a warm
prefix. Next word right per category, and over all cases. The same benchmark runs in Homeword's Prompts tab.

| Machine | macOS | Prompt | Chat | Email | Work | Academic | Code | General | Terminal | All | p50 | Data |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | general | 77% | 88% | 76% | 64% | 80% | 33% | 44% | 62% | 268 ms | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M4 Pro | 27.2 | chat | **73%** | 72% | 52% | 64% | 56% | 22% | 28% | 49% | 295 ms | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M4 Pro | 27.2 | email | 62% | **76%** | 68% | 56% | 56% | 33% | 4% | 48% | 230 ms | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M4 Pro | 27.2 | work | 42% | 76% | **80%** | 72% | 64% | 29% | 16% | 51% | 298 ms | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M4 Pro | 27.2 | academic | 46% | 76% | 72% | **68%** | 40% | 20% | 20% | 46% | 256 ms | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M4 Pro | 27.2 | code | 73% | 72% | 68% | 64% | **72%** | 31% | 24% | 55% | 258 ms | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M1 Pro | 27.2 | general | 73% | 76% | 72% | 72% | 72% | 33% | 52% | 60% | 320 ms | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2 | chat | **73%** | 72% | 60% | 68% | 40% | 35% | 40% | 53% | 364 ms | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2 | email | 58% | **76%** | 64% | 68% | 56% | 37% | 28% | 53% | 312 ms | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2 | work | 54% | 76% | **72%** | 72% | 60% | 35% | 32% | 55% | 366 ms | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2 | academic | 50% | 60% | 60% | **64%** | 56% | 33% | 28% | 48% | 353 ms | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2 | code | 73% | 76% | 72% | 72% | **76%** | 31% | 48% | 60% | 328 ms | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | general | 73% | 76% | 72% | 72% | 72% | 33% | 52% | 60% | 327 ms | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | chat | **73%** | 72% | 60% | 68% | 40% | 35% | 40% | 53% | 373 ms | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | email | 58% | **76%** | 64% | 68% | 56% | 37% | 28% | 53% | 322 ms | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | work | 54% | 76% | **72%** | 72% | 60% | 35% | 32% | 55% | 379 ms | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | academic | 50% | 60% | 60% | **64%** | 56% | 33% | 28% | 48% | 349 ms | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | code | 73% | 76% | 72% | 72% | **76%** | 31% | 48% | 60% | 329 ms | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M2 | 27.2.1 | general | 73% | 76% | 72% | 72% | 72% | 33% | 52% | 60% | 211 ms | [suite](baselines/2026-11-12-styles-suite200-m2.json) |
| Apple M2 | 27.2.1 | chat | **73%** | 72% | 60% | 68% | 40% | 35% | 40% | 53% | 246 ms | [suite](baselines/2026-11-12-styles-suite200-m2.json) |
| Apple M2 | 27.2.1 | email | 58% | **76%** | 64% | 68% | 56% | 37% | 28% | 53% | 206 ms | [suite](baselines/2026-11-12-styles-suite200-m2.json) |
| Apple M2 | 27.2.1 | work | 54% | 76% | **72%** | 72% | 60% | 35% | 32% | 55% | 253 ms | [suite](baselines/2026-11-12-styles-suite200-m2.json) |
| Apple M2 | 27.2.1 | academic | 50% | 60% | 60% | **64%** | 56% | 33% | 28% | 48% | 229 ms | [suite](baselines/2026-11-12-styles-suite200-m2.json) |
| Apple M2 | 27.2.1 | code | 73% | 76% | 72% | 72% | **76%** | 31% | 48% | 60% | 216 ms | [suite](baselines/2026-11-12-styles-suite200-m2.json) |

Cases per category: chat 26, email 25, work 25, academic 25, code 25, general 49, terminal 25. Bold: the style's own category. Apple M4
Pro: two runs, identical, in the fast mode. Apple M1 Pro (commit `5d4d904`): two runs, identical in quality; the outputs match
neither Apple M4 Pro mode, so the mode is not named. Apple M2 (commit `cd24648`): four runs, identical quality, the same category
scores as the Apple M1 Pro. General-prompt p50 was 261, 234, 217 and 211 ms; the recorded run is the lowest. Apple M1 Pro,
macOS 27.2.1 (commit `62798c6`): two runs, identical quality, the same scores as on macOS 27.2; general-prompt p50 328 and 327 ms.

| Machine | macOS | Prompt | Cases | p50 | Fully corrected | Word match | Length vs. input | Data |
|---|---|---|---|---|---|---|---|---|
| Apple M4 Pro | 27.2 | proofread | 12 | 356 ms | 75% | 0.98 | – | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M4 Pro | 27.2 | rewrite | 12 | 348 ms | – | – | 1.0 | [suite](baselines/2026-11-10-styles-suite200.json) |
| Apple M1 Pro | 27.2 | proofread | 12 | 405 ms | 92% | 0.99 | – | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2 | rewrite | 12 | 385 ms | – | – | 0.98 | [suite](baselines/2026-11-11-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | proofread | 12 | 397 ms | 92% | 0.99 | – | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M1 Pro | 27.2.1 | rewrite | 12 | 366 ms | – | – | 0.98 | [suite](baselines/2026-11-13-styles-suite200-m1pro.json) |
| Apple M2 | 27.2.1 | proofread | 12 | 282 ms | 92% | 0.99 | – | [suite](baselines/2026-11-12-styles-suite200-m2.json) |
| Apple M2 | 27.2.1 | rewrite | 12 | 248 ms | – | – | 0.98 | [suite](baselines/2026-11-12-styles-suite200-m2.json) |

**Style prompts on their own category in both model modes** (Apple M4 Pro, macOS 27.2, 2026-11-10; slow mode: two runs each,
identical, no data file). Next word right, general's prompt vs the shipped style prompt:

| Style | Cases | General, fast mode | Style, fast mode | General, slow mode | Style, slow mode | Shipped style prompt |
|---|---|---|---|---|---|---|
| chat | 26 | 77% | 73% | 77% | 81% | general's instructions + a line about chat, 6 chat examples |
| email | 25 | 88% | 76% | 80% | 80% | own instructions, 6 email examples |
| work | 25 | 76% | 80% | 68% | 88% | own instructions, 6 work examples |
| academic | 25 | 64% | 68% | 76% | 76% | own instructions, 6 academic examples |
| code | 25 | 80% | 72% | 72% | 72% | general's instructions, 4 of its mixed examples, 2 code examples |

One case is 4 points. Only work gains in both modes; chat and academic are even over the two, email (-3 cases) and code (-2) lose
in the fast mode. The style prompts were chosen on separate tuning cases (`bench/styles-dev.json`, 30 per style, slow mode) among:
general's prompt, general's 6 examples + 2 of the style, own instructions and examples, general's instructions + a line about the
style + 6 style examples, and 12-example mixes (about 100 ms slower per request, no better). Six code-only examples lost to mixed
ones in every run (56% vs 72% held out, 60% vs 67% tuning). An earlier round chosen on 16 tuning cases did not hold up on the suite.

Outputs and latency depend on the model's mode, which the system switches on its own: the same prompt measured 88% and 80% next
word right on email in the two modes. Compare prompts only within one run (`--styles` runs all of them together; the Prompts tab's
Run Default next to your run).

## Reading the numbers

- **Steady vs typing.** Steady cases are unrelated texts, so only the instructions and examples are cached. While typing, the
  previous keystroke's text is cached too, so key → ghost is lower than steady latency.
- **Model variants.** macOS 27 runs one of two versions of the model behind the same API (`SystemLanguageModel.default.variant`):
  "AFM 3 Core Advanced" on the M4 Macs, "AFM 3 Core" on the M1 Pro and M2. With the same prompt and greedy decoding they answer
  differently: the M4 Pro and M4 Max give the same 80 steady answers, the M1 Pro and M2 the same 80, and across the two pairs only
  7 of 80 agree (Core's answers are shorter, so more suggestions are shown, 99% against 96%, and word overlap is higher). Latency
  differs too: the lighter Core model makes the 8-core-GPU M2 faster than the M4 Pro. Compare quality only within a variant, and
  latency across variants only as "this Mac with its model". The context window depends on the chip, not on the variant or the
  macOS build: 4,096 tokens on the Apple M1 Pro, 8,192 on the Apple M2, both on macOS 27.2.1 (26B131) with the same Core model.
  On that same build and model the Apple M2 is also much faster (steady p50 286 against 500 ms, model time 178 against 352 ms
  fixed), so the speed gap between those two is the hardware too.

  | Variant | Machines | Steady fingerprint |
  |---|---|---|
  | AFM 3 Core Advanced | Apple M4 Pro, Apple M4 Max | `d4c6a5e1` (fast mode) |
  | AFM 3 Core | Apple M1 Pro, Apple M2 | `609ddd4f` |

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

macOS 27.2 → 27.2.1 (Apple M1 Pro) changed nothing measurable: the same 80 steady completions and suggestions, the same writing
style and proofreading scores, latency within a few percent, the same context window (4,096 tokens).

## Latency history

How key → ghost went from 582 ms to ~250 ms: [docs/PERFORMANCE.md](../docs/PERFORMANCE.md#latency-history).
