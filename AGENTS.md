# AGENTS.md: working on input-predictor

Context for an AI agent (or a human) who develops, benchmarks or extends this project. Read before changing anything:
[README.md](README.md) (overview), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (mechanism/policy split, protocol, pipeline),
[docs/CONFIG.md](docs/CONFIG.md) (every knob), [docs/DEVELOPING.md](docs/DEVELOPING.md) (applications, policies, predictd changes),
[docs/PERFORMANCE.md](docs/PERFORMANCE.md) and [bench/RESULTS.md](bench/RESULTS.md) (numbers).

## What this is

A research prototype of a typing predictor on Apple's on-device language model (FoundationModels framework, macOS 27): given the app
and the text typed so far, show a gray "ghost" with the rest of the unfinished word plus up to 5 more words, within one sentence. The
owner works experiment-first: measure, then decide. It runs in `pred try`, in two coding agents (pi, Claude Code) and in a
prototype menu bar Mac app (any text field, plus proofreading of the selection).

**Design principle: separate mechanism from policy.** The owner asked for this explicitly; keep it when changing anything.

- **Mechanism** `predictd.swift` → `./predictd` (config `predictd.json`): a model host that assumes nothing about its use. Named
  profiles (instructions, example turns, schema, guardrails, defaults), pinning (which profile the keep-alive keeps warm), stateless
  or conversation sessions, `generate` (plain or structured, `maxTokens`, sampling), newest-wins `stream`s, `tokens`, `spell`,
  `stats`. Newline-delimited JSON on `/tmp/predictd-<uid>.sock`, the same over HTTP on `127.0.0.1:47320`, plus an
  OpenAI-compatible chat API there (`/v1/models`, `/v1/chat/completions`: streaming, tool calls returned to the caller, JSON schema;
  docs/OPENAI.md). The context window is 8192 tokens.
- **Policy** `ghost/` (Python, standard library only): the typing predictor and the proofreader. `policy.py` (profile from
  `prompt.json`, trim, generate, assemble), `proofread.py` (fix or rewrite a text, word diff), `config.json` (their knobs),
  `predictd.py` (generic predictd client), `server.py` (HTTP `127.0.0.1:47321`, `POST /predict` and `POST /proofread`, for
  non-Python apps).
- `bin/pred`: CLI on the policy. `pred try` (interactive line editor, Enter = new round with stats), `pred ask`, `pred serve`,
  `pred start|stop|status` (predictd + ghost server).
- `bench/`: `run.py` (fixed 80-case benchmark), `human_pty.py` (drives `pred try` like a typist), `compare.py`, `gen_cases.py` +
  `corpus.md` → `cases.json`, `machine.py`, `try_pty_test.py` (smoke test), `integration_latency.py` (keystroke → ghost in a real
  terminal app via tmux), `openai_compare.py` (native protocol vs OpenAI API on the typing workload), `app_metrics.py` (summary of
  the Mac app's usage metrics), `baselines/` (shared results), `RESULTS.md`.
- `integrations/pi/ghost-editor.ts`: pi extension (a `CustomEditor` subclass drawing the ghost in the fake cursor and padding).
- `integrations/claude-code/`: Claude Code mod (`prompt.edit` hook + `$.prompt.fill` decorations; Tab/→ through two commands bound in
  `keybindings.json`, since keys that do nothing at the end of the draft never reach the hook). Validate with `claude plugin validate`.
- `app/`: menu bar Mac app (Swift, AppKit + SwiftUI, `app/build.sh`). Accessibility reads the focused field and caret, a session
  event tap sees keys (consumes Tab/Esc while a suggestion shows, ⌃⌥P/⌃⌥R proofread), a non-activating panel shows the suggestion.
  Metrics in `~/Library/Application Support/InputPredictor/metrics.jsonl`: counts and timings only, never text. Keep it that way.

## Build and run

```sh
./build.sh                         # swiftc -O; also burns the slow first launch of a fresh binary (macOS verifies it)
bin/pred try                       # starts predictd if needed (it exits after 30 idle minutes)
bin/pred ask "git sta"             # one prediction with timings
bin/pred start                     # predictd + the ghost HTTP server, for the integrations
bin/pred status; bin/pred stop
```

Needs macOS 27+ with Apple Intelligence enabled, the Xcode command line tools and `python3` (standard library only: keep it that way,
no venv). Run Python with `-I`.

## How it works (details in docs/ARCHITECTURE.md)

Mechanism (predictd):
1. **Profile → session**: a profile's instructions + examples become a `LanguageModelSession` transcript, the cached prefix. The
   default session is stateless: after every answer `session.transcript = base`, so the next request hits the prefix cache,
   including most of the previous keystroke's text. A newer request on the same `stream` cancels the running one and takes over
   (free). While idle the keep-alive keeps the session that generated last warm for `followRecentSec` (30 s, e.g. an agent loop),
   then the pinned profile (at once after another session took the cache, else every 3 s).
2. **Generate**: `respond(to: prompt)` with the caller's `maxTokens` and sampling, plain or with a schema. The finish reason is read by
   reflection (`hitTokenCap`) and reported as `finish: length|stop`.

Policy (ghost, typing):
1. **Profile**: instructions + 6 examples from `ghost/prompt.json`, named by a content hash, registered and pinned.
2. **Trim**: last `textBudget` (100) tokens of typed text, cut on a word boundary (char-based estimate).
3. **Ask**: `generate` with `App: <app>\nText: <tail>`, plain text (a schema cost ~200 ms), greedy, `maxTokens` 6.
4. **Assemble**: the model returns the remaining letters of the unfinished word, then next words. Glue + spell check (predictd's
   `spell` op), re-space when the model dropped the space after a finished word, drop a word cut by the token cap, stop at the end of
   the first sentence, cap at 5 words.
5. **Applications** (`pred try`, pi, Claude Code): request on every keystroke, follow the ghost when the typed char matches it;
   `pred try` also remembers answers by exact text and prefetches the continuation of a shown ghost.

## Facts about the model that drive the design (measured on Apple M4 Pro, macOS 27.2)

- **One cached session at a time.** Apple's docs ("Optimizing key-value caching in language model sessions") leave cache management to
  the provider. On-device, only the session that prewarmed or generated last keeps its KV cache; any other session, in any process,
  evicts it. It expires after ~5-6 s idle. Never run two daemons; another app using the model (Apple Intelligence) can evict ours.
- **Cost model** (short typing prompts, ~300 tokens): ~100 ms fixed per request, ~0.55 ms per cached input token (instructions and
  examples count), ~2 ms per uncached input token, ~16 ms per output token. Shorter prompt and answer = faster. Short instructions were
  also more accurate. Long prompts (~4k tokens, agents) cost ~0.75 ms per token even when cached and ~20 ms per output token.
- **Context window**: 8192 tokens.
- **No early words**: `streamResponse` snapshots and the public `SystemLanguageModel.Executor` channel both deliver a short answer in
  one piece. No stop sequences, no smaller model, guardrails at most `permissiveContentTransformations` (skips the checks). The model
  already uses a draft model (speculative decoding).
- **Determinism and modes**: greedy outputs are deterministic within a mode, but the system switches between a fast and a slow mode
  (different outputs, ~70 ms apart) for unknown reasons. See RESULTS.md.
- `prewarm()` needs ~1 s of lead time; `tokenCount(for:)` costs ~25 ms; cancelling a plain generation is free.
- Non-public bits in use: reading `Transcript.Response.finishReason` via `Mirror`. macOS 27.0.1 does not have it (cut-off words are
  kept there; see bench/RESULTS.md).

## Benchmarking rules

- Before a run, make sure nothing else uses the model: `bin/pred stop` (also stops the ghost server), quit any open `pred try` and
  pi/Claude Code sessions with the integrations (they restart the services), no other
  `predictd` (`pgrep -fl predictd`). Results taken with a concurrent user are invalid (cache misses, different outputs).
- Fixed benchmark: `cd bench && python3 -I run.py --spawn --label <name> [--config '{...}'] [--daemon-config '{...}']` (private
  predictd; `--config` overrides the policy, `--daemon-config` predictd).
  Typing: `SEED=1 python3 -I bench/human_pty.py` and `ACCEPT=1 ...` (Tab when the ghost is right). Both save to `bench/results/`.
- Compare with `python3 -I bench/compare.py a.json b.json` and only within one model mode (matching `mode_fingerprint`). If a result
  looks odd, re-run before bisecting: a mode switch once made a harmless change look like a 70 ms regression.
- Quality metrics are exact word matches against one real continuation: treat them as relative. Mid-word completion accuracy is the
  most objective number.
- To share a run, copy it to `bench/baselines/` (name: `<date>-<scenario>-<chip>.json`) and add a row to the tables in
  `bench/RESULTS.md`. Present results plainly: the machine by its specs (chip, GPU, memory, macOS version) in the Machines table and
  a Machine column, the numbers in the tables, the JSON file only as a link. No personal context ("this laptop", "my machine",
  "here"), no narrative. Put before/after numbers in the commit message.
- Changing `cases.json` or `corpus.md` breaks comparability with older runs: record a new baseline.

## Repo rules

- **No personal or machine-identifying data in tracked files**: no usernames, home paths, emails, hosts or private documents in cases,
  corpus, prompt or docs (the machine's hardware spec and benchmark results are fine to share). `pred try --log` files contain what the
  user typed: never commit them. Scan `git diff --cached` before committing.
- **Commit identity**: commits use the owner's personal identity through the repo-local git config. The global config on the owner's
  machine is a work identity that must not appear here. On a fresh clone `git config --local user.email` prints nothing: stop, remind
  the owner, and set it from `git log --format='%an <%ae>' | sort -u` after confirming.
- Don't commit `predictd` or `bench/results/` (ignored). Keep README, docs/ and this file in sync with pipeline changes.
- **Mechanism vs policy**: predictd must not learn what its text is for (no words, keystrokes, apps, typing rules in Swift). If
  every policy would need it (caching, cancelling, limits, OS services), it goes in predictd as a generic op or field; otherwise in
  the policy. The integrations are UI only: no prediction logic in TypeScript.
- A new tunable is a knob, not a constant: daemon-wide → `Config` + predictd.json; per request → a `generate`/profile field; policy →
  ghost/config.json. Plus a row in docs/CONFIG.md (steps in docs/DEVELOPING.md). Results must not record machine paths (`run.py`
  drops the daemon's `socketPath`). Mermaid diagrams in docs must render on GitHub: quoted labels, `<br/>` for line breaks.

## Testing the integrations

Drive the real apps in tmux (they render to a terminal; nothing else shows the ghost). The Mac app needs the Accessibility
permission, which only the owner can grant (it survives rebuilds: `build.sh` signs with a bundle-ID requirement);
`status.json` in the app's support folder shows the permission state. Clear a
Claude Code draft with `C-e` then `C-u` (`C-u` only kills before the cursor). Test Claude Code with a throwaway `CLAUDE_CONFIG_DIR` holding the keybindings, never by editing
`~/.claude/keybindings.json`: that binds Tab and → in every session, including ones without the mod. Agent sandboxes may block
`claude`/`pi` (they use `sandbox-exec` themselves); run them in a tmux session the agent owns.

## Pitfalls

- zsh: never name a loop variable `path` (it is tied to `PATH`).
- A freshly compiled binary is slow on its very first launch; `build.sh` runs it once.
- `python3` may be a wrapper on some machines; any Python 3.9+ works.

## Open questions and future work

- Product surface: pi, Claude Code and a menu bar Mac app (pop-up, not inline) exist; inline ghost text system-wide would need an input
  method (InputMethodKit). Apple Intelligence is MDM-restricted on managed Macs: check policy first. Key bindings (Tab = one word,
  → = all) need user testing; the Mac app's metrics are the place to measure acceptance.
- Energy cost of a model request on almost every keystroke (needs `powermetrics`, i.e. sudo: ask the owner).
- Quality on the owner's real typing (keep that data local and out of git); the 80 cases are a small proxy.
- Known misses: an abbreviation the spell checker accepts ("fri") gets split from the model's next word when the model ignores it;
  one-letter prefixes are guesses ("won't j" → "job").
- Untested: CJK and other languages (trimming and word logic assume spaces), the Private Cloud Compute model, the trigger of the slow mode.
- Further latency means trading quality (fewer examples, shorter answers) or a different, smaller local model (not Apple's).
