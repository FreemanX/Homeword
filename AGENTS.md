# AGENTS.md: working on input-predictor

Context for an AI agent (or a human) who develops, benchmarks or extends this project. [README.md](README.md) documents the pipeline,
protocol and CLI; [bench/RESULTS.md](bench/RESULTS.md) the current numbers. Read both before changing anything.

## What this is

A research prototype of a typing predictor on Apple's on-device language model (FoundationModels framework, macOS 27): given the app
and the text typed so far, show a gray "ghost" with the rest of the unfinished word plus up to 5 more words, within one sentence. The
owner works experiment-first: measure, then decide. It runs in `pred try` and in two coding agents (pi, Claude Code); a system-wide
surface is not designed yet.

- `predictd.swift` → `./predictd`: long-lived daemon, newline-delimited JSON over a unix socket (`/tmp/predictd-<uid>.sock`), and
  the same requests over HTTP on `127.0.0.1:47321` (`POST /predict`, `GET /health`) for the integrations.
- `bin/pred`: CLI. `pred try` (interactive line editor, Enter = new round with stats), `pred ask`, `pred status|start|stop`.
- `prompt.json` (instructions + few-shot examples), `config.json` (tunables, also overridable per request with `opts`).
- `bench/`: `run.py` (fixed 80-case benchmark), `human_pty.py` (drives `pred try` like a typist), `compare.py`, `gen_cases.py` +
  `corpus.md` → `cases.json`, `machine.py`, `try_pty_test.py` (smoke test), `integration_latency.py` (keystroke → ghost in a real
  terminal app via tmux), `baselines/` (shared results), `RESULTS.md`.
- `integrations/pi/ghost-editor.ts`: pi extension (a `CustomEditor` subclass drawing the ghost in the fake cursor and padding).
- `integrations/claude-code/`: Claude Code mod (`prompt.edit` hook + `$.prompt.fill` decorations; Tab/→ through two commands bound in
  `keybindings.json`, since keys that do nothing at the end of the draft never reach the hook). Validate with `claude plugin validate`.

## Build and run

```sh
./build.sh                         # swiftc -O; also burns the slow first launch of a fresh binary (macOS verifies it)
bin/pred try                       # starts the daemon if needed (it exits after 30 idle minutes)
bin/pred ask "git sta"             # one prediction with timings
bin/pred stop
```

Needs macOS 27+ with Apple Intelligence enabled, the Xcode command line tools and `python3` (standard library only: keep it that way,
no venv). Run Python with `-I`.

## How the pipeline works (details in README)

1. **Session** (`sessionMode: reuse`): one `LanguageModelSession` holds instructions + examples. After every answer its transcript is
   restored (`session.transcript = base`), so the next request hits the prefix cache, including most of the previous keystroke's text.
   A new request cancels the running one and takes over the session (free). A keep-alive re-prewarms every 3 s while idle.
2. **Trim**: last `textBudget` (100) tokens of typed text, cut on a word boundary (char-based estimate).
3. **Model**: `respond(to: "App: <app>\nText: <tail>")`, plain text (no `GenerationSchema`: it cost ~200 ms), greedy,
   `maximumResponseTokens` 6. The finish reason is read by reflection (`hitTokenCap`) to drop a cut-off last word.
4. **Assemble**: the model returns the remaining letters of the unfinished word, then next words. Glue + `NSSpellChecker`, re-space when
   the model dropped the space after a finished word, stop at the end of the first sentence, cap at 5 words.
5. **Client** (`pred try`): request on every keystroke (`--debounce 0`), follow the ghost when the typed char matches it, remember answers
   by exact text, prefetch the continuation of a shown ghost.

## Facts about the model that drive the design (measured, M4 Pro)

- **One cached session at a time.** Apple's docs ("Optimizing key-value caching in language model sessions") leave cache management to
  the provider. On-device, only the session that prewarmed or generated last keeps its KV cache; any other session, in any process,
  evicts it. It expires after ~5-6 s idle. Never run two daemons; another app using the model (Apple Intelligence) can evict ours.
- **Cost model**: ~100 ms fixed per request, ~0.55 ms per cached input token (instructions and examples count), ~2 ms per uncached input
  token, ~16 ms per output token. Shorter prompt and answer = faster. Short instructions were also more accurate.
- **No early words**: `streamResponse` snapshots and the public `SystemLanguageModel.Executor` channel both deliver a short answer in
  one piece. No stop sequences, no smaller model, guardrails at most `permissiveContentTransformations` (skips the checks). The model
  already uses a draft model (speculative decoding).
- **Determinism and modes**: greedy outputs are deterministic within a mode, but the system switches between a fast and a slow mode
  (different outputs, ~70 ms apart) for unknown reasons. See RESULTS.md.
- `prewarm()` needs ~1 s of lead time; `tokenCount(for:)` costs ~25 ms; cancelling a plain generation is free.
- Non-public bits in use: reading `Transcript.Response.finishReason` via `Mirror`. If an OS update breaks it, cut-off words are kept.

## Benchmarking rules

- Before a run, make sure nothing else uses the model: `bin/pred stop`, quit any open `pred try` (it restarts its daemon), no other
  `predictd` (`pgrep -fl predictd`). Results taken with a concurrent user are invalid (cache misses, different outputs).
- Fixed benchmark: `cd bench && python3 -I run.py --spawn --label <name> [--config '{...}']` (private daemon with overrides).
  Typing: `SEED=1 python3 -I bench/human_pty.py` and `ACCEPT=1 ...` (Tab when the ghost is right). Both save to `bench/results/`.
- Compare with `python3 -I bench/compare.py a.json b.json` and only within one model mode (matching `mode_fingerprint`). If a result
  looks odd, re-run before bisecting: a mode switch once made a harmless change look like a 70 ms regression.
- Quality metrics are exact word matches against one real continuation: treat them as relative. Mid-word completion accuracy is the
  most objective number.
- To share a run, copy it to `bench/baselines/` and update `bench/RESULTS.md`. Put before/after numbers in the commit message.
- Changing `cases.json` or `corpus.md` breaks comparability with older runs: record a new baseline.

## Repo rules

- **No personal or machine-identifying data in tracked files**: no usernames, home paths, emails, hosts or private documents in cases,
  corpus, prompt or docs (the machine's hardware spec and benchmark results are fine to share). `pred try --log` files contain what the
  user typed: never commit them. Scan `git diff --cached` before committing.
- **Commit identity**: commits use the owner's personal identity through the repo-local git config. The global config on the owner's
  machine is a work identity that must not appear here. On a fresh clone `git config --local user.email` prints nothing: stop, remind
  the owner, and set it from `git log --format='%an <%ae>' | sort -u` after confirming.
- Don't commit `predictd` or `bench/results/` (ignored). Keep README and this file in sync with pipeline changes.

## Testing the integrations

Drive the real apps in tmux (they render to a terminal; nothing else shows the ghost). Clear a Claude Code draft with `C-e` then `C-u`
(`C-u` only kills before the cursor). Test Claude Code with a throwaway `CLAUDE_CONFIG_DIR` holding the keybindings, never by editing
`~/.claude/keybindings.json`: that binds Tab and → in every session, including ones without the mod. Agent sandboxes may block
`claude`/`pi` (they use `sandbox-exec` themselves); run them in a tmux session the agent owns.

## Pitfalls

- zsh: never name a loop variable `path` (it is tied to `PATH`).
- A freshly compiled binary is slow on its very first launch; `build.sh` runs it once.
- `python3` may be a wrapper on some machines; any Python 3.9+ works.

## Open questions and future work

- Product surface: pi and Claude Code integrations exist; a system-wide input method is undecided (Apple Intelligence is MDM-restricted
  on managed Macs: check policy first). Key bindings (Tab = one word, → = all) need user testing.
- Energy cost of a model request on almost every keystroke (needs `powermetrics`, i.e. sudo: ask the owner).
- Quality on the owner's real typing (keep that data local and out of git); the 80 cases are a small proxy.
- Known misses: an abbreviation the spell checker accepts ("fri") gets split from the model's next word when the model ignores it;
  one-letter prefixes are guesses ("won't j" → "job").
- Untested: CJK and other languages (trimming and word logic assume spaces), the Private Cloud Compute model, the trigger of the slow mode.
- Further latency means trading quality (fewer examples, shorter answers) or a different, smaller local model (not Apple's).
