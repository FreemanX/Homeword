# input-predictor

Prototype of an input predictor on Apple's on-device model (FoundationModels, macOS 26+/27): given the app and the text
typed so far, predict the rest of the unfinished word plus the next ~5 words. `predictd` is a long-lived service that keeps
the model and one cached session ready; `bench/` is a mini benchmark to re-measure after every change.

Requirements: macOS 27+ with Apple Intelligence enabled, the Xcode command line tools (`swiftc`), and `python3` (standard library
only, so no virtualenv is needed).

```
./build.sh                       # swiftc -> ./predictd (and burns the slow first launch of a fresh binary)
./predictd &                     # listens on /tmp/predictd-<uid>.sock (--socket, --config, --prompt to override)
cd bench && python3 -I run.py --label mychange            # steady scenario against the running daemon
python3 -I run.py --spawn --config '{"shots":5}' --label shots5   # private daemon with config overrides
python3 -I compare.py results/<before>.json results/<after>.json
```

## Try it as you type

```
bin/pred try                  # starts the daemon if needed; type, watch the gray ghost text
bin/pred try --app mail --debounce 100
bin/pred ask "git sta"        # one prediction with timings;  bin/pred status | stop
```

`pred try` is an append-only line editor that asks for a ghost suggestion on every keystroke (`--debounce 0`; the daemon cancels the stale request at no cost). Answers are remembered by text, and while a ghost is shown the continuation after it is prefetched, so following or accepting a ghost extends it without a new wait. **Tab** accepts one word, **→** all of it, **Esc** dismisses, and typing the ghost's next character follows it instead of re-asking.
**Enter ends the round and prints its stats** (keystrokes, requests sent/answered/stale, suggestions shown/useful/accepted,
keystrokes saved, last-key-to-ghost latency p50/p90/max with the model share, prefix-cache share), then starts a fresh round with empty
context; Ctrl-C quits with session totals. `--log file` appends one JSON line per round (your typed text, so keep it private).
The daemon exits by itself after 30 idle minutes (`idleExitSec`). `bench/try_pty_test.py` drives the tool through a pty as a smoke test.

Files: `bin/pred` (CLI) · `predictd.swift` (service) · `config.json` (tunables) · `prompt.json` (system prompt + few-shot examples) ·
`bench/cases.json` (82 cases, from `bench/gen_cases.py`) · `bench/run.py` · `bench/compare.py` · `bench/client.py` ·
`bench/human_pty.py` (drives `pred try` with human-like typing; `ACCEPT=1` presses Tab when the ghost is right) · `bench/try_pty_test.py`.

## Pipeline (per request)

| Step | What | Parameters (config.json, overridable per request with `opts`) |
|---|---|---|
| 0 session | One long-lived `LanguageModelSession` (system prompt + few-shot turns) for every request (`sessionMode: reuse`). The model keeps a single prefix cache, system-wide, owned by whichever session prewarmed or generated last, so after each answer the session's transcript is restored (`session.transcript = base`, settable in macOS 27) and the next request matches the cache: the prefix and, while typing, almost all of the previous keystroke's text. A newer request cancels the running one and takes the session over (a cancelled request leaves the transcript untouched; measured free). A keep-alive re-prewarms it every `keepAliveSec` while idle (the cache expires after ~5-6 s). Another process using the model (another daemon, Apple Intelligence features) evicts the cache. `sessionMode: spare` is the older design (a fresh prewarmed session per request). | `sessionMode` reuse, `keepAliveSec` 3, `keepAliveMaxIdleSec` 300, `instructions` short, `shots` 6 |
| 1 trim | Keep the tail of the typed text that fits `textBudget` tokens, cut on a word boundary. Cheap char estimate (4.8 chars/token prose, 2.9 code/shell, 1.6 CJK); `exactTrim` refines with `tokenCount` (~25 ms per call). Hard ceiling: `hardCap` (4000) minus prefix, template, output cap, margin. | `textBudget` 100, `exactTrim` false, `hardCap` 4000, `margin` 60 |
| 3 model | `respond(to: "App: <app>\nText: <tail>", options: greedy + maximumResponseTokens)`, plain text out (`output: plain`), few-shot examples as plain prior transcript turns. About 0.4 s, versus 0.6 s with a `GenerationSchema` (`output: schema`, one field `completion`): the structured wrapper costs ~200 ms and was slightly less accurate. Streaming gives nothing earlier: `streamResponse` snapshots and the lower-level `SystemLanguageModel.Executor` channel both deliver a short answer as one piece at the end. When the answer hits `maxTokens` (read from the transcript entry's `finishReason` by reflection, not public API) its possibly unfinished last word is dropped. | `maxTokens` 6, `output` plain, `guardrails` permissive |
| 4 assemble | Suffix format: the model returns the remaining letters of the unfinished word, then the next words. The client glues `partial + piece`, spell-checks it (`NSSpellChecker`, also the capitalised form), re-spaces `the`+`project` when the model dropped the space, caps the word count, stops at the end of the first sentence (`oneSentence`; abbreviations, initials and numbers don't count, and it is off for terminal/code), and suppresses an invalid word (except in `lenientApps`: terminal, code). | `words` 5, `invalidPolicy` drop, `format` suffix |

## Protocol

Newline-delimited JSON on the unix socket. `{"op":"predict","id":"1","app":"mail","text":"…","stream":"k","opts":{…}}` returns
`suggestion` (what to show, appended to the text), `partial`, `first_word`, `valid`, `suppressed`, `timing` (trim, acquire, model,
assemble, total ms, session state), `tokens` (in, cached, out). In `schema` mode the model runs one generation at a time (single flight): a request that arrives
meanwhile waits, and a newer one on the same `stream` replaces it (in `plain` mode a newer request on the stream aborts the running one) (`{"ok":false,"error":"cancelled"}`). Aborting a running generation was tried and
measured worse (final answer 1.4 s, prefix cache lost). Other ops: `ping`, `stats`, `reload` (re-reads config and prompt), `cancel` (drops a waiting request), `settle_probe`, `shutdown`.

## Benchmark

`bench/run.py` scenarios: `steady` (1.2 s between requests), `burst` (back to back), `idle` (15 s gaps: does the keep-alive keep the
model loaded), `typing` (a request per keystroke on one stream, time from the last keystroke to its answer). Metrics: client-side
end-to-end time (p50/p90/max, by context size), model time, prefix-cache hit rate, and quality against what the user really typed
next: suggestion shown, first word right, completed-word exact match for mid-word cuts, leading words right, word overlap, echo,
misspelled words. Each run is saved to `bench/results/` with its rows, so two runs can be compared.
Quality is exact word match against one real continuation, so it is harsh on the next-word part; the mid-word completion number is
the most objective. Hand-written cases (52: mail, chat, notes, review, terminal, code) are short; the 30 generated ones are cut from `bench/corpus.md`
(a frozen copy of this README: technical English, hard to predict) at 4 context sizes. Re-generate with `python3 -I bench/gen_cases.py`.

## Latency: where the time goes and what was tried (M4 Pro, macOS 27.2)

Key → ghost in `pred try` = wait before sending (debounce) + model call (socket and JSON < 1 ms). Measured with `bench/human_pty.py`:

| Change | key → ghost p50 / p90 |
|---|---|
| debounce 200 ms, fresh prewarmed session per request | 582 / 809 ms (7 of 16 ghosts missed the prefix cache) |
| + a cancelled request's session is reused by the next one | 528 / 638 ms (0 misses) |
| + debounce 0 | 290 / 361 ms |
| + one reused session with transcript restore, short instructions, 100-token context | 263 / 326 ms |
| + `maxTokens` 6 (drop a cut-off word), answer memory + prefetch | 250-252 / 284-291 ms (one run at 344 ms) |

Model call anatomy (cached prefix): ~100 ms fixed per request, ~0.55 ms per input token even when cached (instructions and
examples count), ~2 ms per uncached input token, ~16 ms per output token. So: the shorter the prompt and the answer, the faster. A short
instruction (~45 tokens instead of ~140) was both faster and more accurate; fewer than 6 examples saved little and cost accuracy.
Not available: token streaming, stop sequences, a smaller model or turning guardrails off (permissive is the lightest).

Apple's docs ("Optimizing key-value caching in language model sessions") describe the KV cache as per session, with the capacity left
to the model provider. Measured behaviour of the on-device provider: only the session that prewarmed or generated last keeps its cache
(other sessions, also in other processes, evict it), and it expires after ~5-6 s idle. Run benchmarks with no other model user
(`bin/pred stop`; a running `pred try` restarts its daemon): with a concurrent `pred try`, a run had 43 cache misses and 9 of 20 raw
outputs differed. Alone, outputs are deterministic (a rerun matched an hour-old run 20/20).
