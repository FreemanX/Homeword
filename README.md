# Homeword

<img src="app/Icon/icon.svg" width="96" align="right" alt="Homeword icon">

Homeword brings Apple's on-device language model (FoundationModels, macOS 27) to your typing and your tools: next-word suggestions
and proofreading in any app, ghost text in coding agents' prompt boxes, and a local OpenAI-compatible API. Everything runs on your
Mac. Your words never leave home.

## What it provides

- **The Homeword Mac app**: a menu bar app. While you type in any app, a pop-up shows the next words (about a quarter of a second,
  in a writing style that follows the app: chat, email, work documents, ...); Tab inserts a word. Select text and press ⌃⌥P to
  proofread it or ⌃⌥R to rewrite it. Suggestions follow the language you type in (the 16 languages of Apple's model: list the
  ones you write in), and the app itself speaks them too. Every prompt is editable, with a built-in benchmark.
  [More](#the-homeword-mac-app)
  <br/><img src="docs/gifs/mail.gif" width="600" alt="Next-word suggestions while typing an email in Mail: a pop-up under the cursor, Tab inserts the word">
- **The engine**: runs the model on your Mac and turns its answers into suggestions (the rest of the unfinished word plus up to five
  words, one sentence) and proofreading. The `pred` command line tool starts it and lets you try it in a terminal (`pred try`); apps
  reach it over local HTTP. [Quick start](#quick-start)
  <!-- demo GIF: pred try in a terminal -->
- **An OpenAI-compatible API**: point any agent harness, SDK or tool at `http://127.0.0.1:47320/v1` to use the on-device model:
  chat completions with streaming, tool calls and JSON output. [More](#use-the-on-device-model-from-any-agent-harness)
  <!-- demo GIF: an agent harness running on the on-device model -->
- **Ghost text in pi**: suggestions while you type a prompt in the pi coding agent; Tab takes a word, → all.
  [More](#pi-ghost-text-in-pis-prompt-editor)
  <br/><img src="docs/gifs/pi.gif" width="600" alt="Dim ghost text after the cursor in pi's prompt editor">
- **Ghost text in Claude Code**: the same in Claude Code's prompt box, as a Claude Code mod.
  [More](#claude-code-ghost-text-in-the-prompt-box)
  <br/><img src="docs/gifs/claude-code.gif" width="600" alt="Dim ghost text after the cursor in Claude Code's prompt box">

## How it is built

Three layers, keeping **mechanism and policy apart**:

- **predictd**: a model host, mechanism only. It keeps named system prompts ("profiles") with their prefix cache warm and
  generates plain or structured output with the limits each caller asks for. It knows nothing about typing. It also speaks the
  **OpenAI chat API**, so agent harnesses can use the on-device model directly.
- **ghostd**: the policies (Swift, `ghost/`), served over local HTTP. Typing prediction owns the prompts and examples (one per
  writing style), the context trimming and the rules that turn the model's answer into a ghost (word glue, spelling, one sentence,
  up to five words by default). Proofreading fixes or rewrites a selected text. ghostd starts predictd when it needs it; together
  they are the engine, inside the app in a release.
- **Applications**: the Homeword Mac app, `pred try`, and the pi and Claude Code integrations. They only draw: they ask ghostd and
  start it when no ghostd answers. Other policies (summarise, commit messages, triage) can share the same predictd.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 480}}}%%
flowchart TB
    subgraph apps["Applications"]
        direction LR
        try["pred try"]
        pi["pi extension"]
        cc["Claude Code mod"]
        mac["Homeword<br/>Mac app"]
        next["shell completer<br/>future"]:::future
    end
    subgraph policy["Policy"]
        direction LR
        ghost["ghostd<br/>typing prediction, proofreading<br/>HTTP :47321"]
        other["other policies<br/>future"]:::future
    end
    subgraph mech["Mechanism"]
        predictd["predictd<br/>profiles, warm sessions, generate<br/>socket, HTTP :47320, OpenAI /v1"]
    end
    harness["agent harnesses<br/>OpenAI-compatible clients"]
    fm["Apple on-device model"]
    try --> ghost
    pi --> ghost
    cc --> ghost
    mac --> ghost
    next -.-> ghost
    ghost -->|"unix socket"| predictd
    other -.-> predictd
    harness --> predictd
    predictd --> fm
    classDef future stroke-dasharray: 5 5
```

## Install the Mac app

Requirements: a Mac with Apple silicon, macOS 27 or later, Apple Intelligence turned on.

1. Download `Homeword-<version>.dmg` from [Releases](../../releases), open it and drag Homeword to Applications.
2. Open Homeword from Applications. It is not notarized by Apple (no paid developer account), so the first time macOS says it
   cannot check it for malicious software: click Done, then open System Settings → Privacy & Security, click **Open Anyway** next
   to Homeword and confirm. Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Homeword.app`.
3. Allow Accessibility when Homeword asks (System Settings → Privacy & Security → Accessibility): it reads the text field you type
   in and the keys you press, on your Mac only.

The app contains the whole engine; nothing else to install. To check the download: `shasum -a 256 -c Homeword-<version>.dmg.sha256`
in the folder holding both files. To build it yourself: [app](app/README.md).

## Quick start (from source)

Requirements: macOS 27+ with Apple Intelligence enabled, the Xcode command line tools (`swiftc`). The command line tool `pred` and
the benchmarks also need `python3` (standard library only, no virtualenv); the engine and the app don't.

```sh
./build.sh                    # swiftc -> ./predictd (the model host) and ./ghostd (the policies and their HTTP server)
bin/pred try                  # type and watch the ghost; Enter = new round with stats, Ctrl-C quits
bin/pred ask "git sta"        # one prediction with timings
bin/pred start                # the engine (ghostd + predictd) in the background (for pi, Claude Code)
bin/pred status               # daemon, profiles, policy knobs;  bin/pred stop

curl -s 127.0.0.1:47321/predict -d '{"app":"chat","text":"See you tomor"}'          # the typing policy
curl -s 127.0.0.1:47321/proofread -d '{"text":"i dont no","mode":"fix"}'           # the proofreading policy
curl -s 127.0.0.1:47320/ -d '{"op":"profile.set","name":"haiku","instructions":"Answer with a haiku."}'
curl -s 127.0.0.1:47320/ -d '{"profile":"haiku","prompt":"Autumn in the city","maxTokens":40}'   # the raw mechanism
curl -s 127.0.0.1:47320/v1/chat/completions -d '{"model":"apple-on-device","messages":[{"role":"user","content":"Hi!"}]}'
```

ghostd starts predictd when it needs it; ghostd starts with `pred start`, `pred serve` or any other `pred` command, and the pi
extension and Homeword start it themselves. Both exit after 30 idle minutes.

## Applications

### The Homeword Mac app

A menu bar Mac app (prototype); your words never leave home. While you type in any app, a pop-up below the text cursor shows the
next words in a writing style that follows the app (Chat in Slack, Email in Mail or Gmail, Work documents in Pages or Google Docs,
...); Tab inserts the next word, Esc dismisses. Select text and press ⌃⌥P to fix typos and grammar, or ⌃⌥R to rewrite it, keeping
its meaning; Return replaces the selection. Settings has a writing style per app, every prompt editable with a built-in benchmark
and version history, configurable shortcuts, engine controls and the OpenAI-compatible API's address. It logs latency and acceptance
statistics (no text). Needs the Accessibility permission.

[Install it](#install-the-mac-app) from the releases, or build it from source (it then runs the engine from the repo):

```sh
./build.sh && app/build.sh && open app/build/Homeword.app
```

Suggestions in Notes:

<img src="docs/gifs/notes.gif" width="600" alt="Next-word suggestions while typing in Notes">

Proofread (⌃⌥P): the changes marked, then the clean result, then Replace:

<img src="docs/gifs/proofread.gif" width="600" alt="Proofreading a short email in Notes: removed words struck through in red, fixes in green, then Replace">

Rewrite (⌃⌥R): a rambling paragraph made clearer, with the same meaning:

<img src="docs/gifs/rewrite.gif" width="600" alt="Rewriting a long-winded paragraph in Notes into two clear sentences">

Details, permissions and metrics: [app](app/README.md).

### `pred try`: try it in a terminal

An append-only line editor that asks for a ghost on every keystroke. **Tab** accepts one word, **→** all of it, **Esc** dismisses,
and typing the ghost's next character follows it instead of re-asking. Answers are remembered by text and the continuation of a shown
ghost is prefetched. **Enter** ends a round and prints its stats (keystrokes saved, suggestions shown and accepted, key → ghost
latency, cache share). `--app mail|chat|terminal|...` picks the context, `--log file` keeps rounds as JSON (your typed text: keep it
private).

### pi: ghost text in pi's prompt editor

A pi extension that replaces the prompt editor and draws the ghost after the cursor. Tab and → accept, as above.

```sh
pi -e integrations/pi/ghost-editor.ts
```

Details and permanent install: [integrations/pi](integrations/pi/README.md).

### Claude Code: ghost text in the prompt box

A Claude Code mod (a plugin with a hooks module) that paints the ghost as dim virtual text after the cursor. Accepting with Tab and
→ needs two entries in `keybindings.json`, which apply to every session: read
[integrations/claude-code](integrations/claude-code/README.md) before installing it.

Last keystroke → ghost on screen, human-like typing in tmux (Apple M4 Pro, macOS 27.2): pi 117 ms p50, Claude Code 157 ms p50.

## Use the on-device model from any agent harness

predictd serves an OpenAI-compatible API: base URL `http://127.0.0.1:47320/v1`, any API key, model `apple-on-device`. Chat
completions with streaming, tool calls (returned to the harness, OpenAI-style), JSON-schema output and the usual sampling
parameters. Tested with pi as the harness, including tool calls. The model's context window is 8,192 tokens on most Macs and
4,096 on some (`bin/pred status` and the app's Engine tab show this Mac's), so keep system prompts small. Setup for the `openai` SDK, pi and others: [docs/OPENAI.md](docs/OPENAI.md).

## Documentation

| Document | For |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | the mechanism/policy split, which process starts which, how predictd works (profiles, sessions, cache, protocol), ghostd and the typing and proofreading pipelines |
| [docs/OPENAI.md](docs/OPENAI.md) | the OpenAI-compatible API: connecting a harness, tool calls, parameters, limits |
| [docs/CONFIG.md](docs/CONFIG.md) | every knob: predictd.json, profile and generate fields, ghost/config.json, prompt.json, recipes |
| [docs/DEVELOPING.md](docs/DEVELOPING.md) | a new application, a new policy, changing predictd, testing |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | benchmarks, latency history, measuring pitfalls |
| [bench/RESULTS.md](bench/RESULTS.md) | current benchmark numbers |
| [AGENTS.md](AGENTS.md) | context and rules for AI agents and contributors |

## Status

A research prototype. Benchmark results (the best run per machine):

| Machine | Model | Steady p50 | Typing key → ghost p50 |
|---|---|---|---|
| Apple M4 Pro, 16-core GPU, 48 GB, macOS 27.2 | AFM 3 Core Advanced | 329 ms | 259 ms |
| Apple M4 Max, 32-core GPU, 36 GB, macOS 27.0.1 | AFM 3 Core Advanced | 295 ms | 258 ms |
| Apple M1 Pro, 14-core GPU, 16 GB, macOS 27.2.1 | AFM 3 Core | 500 ms | 352 ms |
| Apple M2, 8-core GPU, 16 GB, macOS 27.2.1 | AFM 3 Core | 286 ms | 256 ms |

macOS runs a different version of the on-device model on M4 Macs ("Core Advanced") than on M1 and M2 Macs ("Core"): their
suggestions differ, and the lighter Core model is why the M2 is as fast as the M4s.

Details and raw data: [bench/RESULTS.md](bench/RESULTS.md).

## Known limits

- **Other languages are well below English** in quality (the prompts and examples are English; 10 test cases per language), and
  Japanese and Chinese have no spell check.
- **One warm prompt cache for the whole system**: switching between prompts (another writing style, proofreading, an agent on the
  OpenAI API) makes the next request ~70 ms slower once, and another app using Apple Intelligence can evict the cache.
- **Slower Macs show fewer suggestions while typing fast**: on an Apple M1 Pro a model call (~355 ms) is longer than the gap
  between keys, so most requests are replaced by the next keystroke before they answer ([results](bench/RESULTS.md#typing-simulation)).
- **One-letter prefixes** are mostly guesses ("won't j" → "job").
- **macOS 27.0.1**: predictd reads one non-public field (`finishReason`, via reflection) that this version does not have, so a word
  cut by the token cap is kept instead of dropped.
- **Managed Macs**: Apple Intelligence can be restricted by the organization (MDM); check before relying on it.
- The Mac app's own limits (caret position in some apps, pop-up instead of inline text, ...): [app/README.md](app/README.md#known-limits).

## License

[MIT](LICENSE).
