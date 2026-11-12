# Architecture

The project is split by one rule: **separate mechanism from policy.**

- **Mechanism: `predictd`** (Swift, `predictd.swift`) hosts Apple's on-device model and nothing else. It keeps named system
  prompts ("profiles"), keeps one of them warm, and generates plain or structured output with the limits the caller asks for. It
  assumes nothing about what the text is for. It also serves an OpenAI-compatible chat API for agent harnesses.
- **Policies: `ghostd`** (Swift, `ghost/`): the typing predictor decides what to ask while someone types and how to turn the
  answer into ghost text; the proofreader fixes or rewrites a selected text. Both run in one process, `ghostd`, which serves them
  over HTTP and talks to predictd over its unix socket. A summariser, a commit-message writer or a triage bot would be other
  clients of predictd, side by side.
- **Applications** reach the policies over HTTP and draw the results: the Homeword Mac app, `pred try`, the pi extension and the
  Claude Code mod. They hold no prediction logic.

Together, ghostd and predictd are "the engine". Both are plain binaries next to their data files: in the repo after `./build.sh`,
or inside `Homeword.app` in a release.

```mermaid
flowchart TB
    subgraph apps["Applications"]
        direction LR
        mac["Homeword Mac app<br/>menu bar, any text field"]
        try["pred try<br/>terminal"]
        pi["pi extension"]
        cc["Claude Code mod"]
        next["shell completer<br/>future"]:::future
    end
    subgraph policy["Policies"]
        direction LR
        subgraph gd["ghostd: HTTP 127.0.0.1:47321"]
            direction LR
            typing["typing prediction<br/>prompts per writing style,<br/>trim, assemble"]
            proof["proofreading<br/>fix, rewrite, word diff"]
            prompts["user prompts,<br/>benchmarks"]
        end
        other["other policies<br/>future"]:::future
    end
    subgraph mech["Mechanism"]
        predictd["predictd<br/>profiles, sessions, generate, keep-alive<br/>unix socket, HTTP 127.0.0.1:47320"]
    end
    harness["agent harnesses<br/>OpenAI-compatible clients"]
    fm["FoundationModels<br/>on-device model"]
    mac -->|"HTTP"| gd
    try -->|"HTTP"| gd
    pi -->|"HTTP"| gd
    cc -->|"HTTP"| gd
    next -.-> gd
    gd -->|"socket: profile.set, generate, spell"| predictd
    other -.-> predictd
    harness -->|"/v1/chat/completions"| predictd
    predictd --> fm
    classDef future stroke-dasharray: 5 5
```

| predictd provides (mechanism) | ghostd decides (policy) |
|---|---|
| host the model, keep a profile's prefix warm (`pin`) | pin its own profile |
| profiles: instructions, example turns, optional schema, guardrails, default options | the instructions, the examples, the `App: … Text: …` template |
| `generate` with `maxTokens`, sampling, plain or structured output | 6 tokens, greedy, plain |
| newest request wins per `stream`, one generation at a time per session, `cancel` | one stream per input field |
| stateless sessions, or conversations that keep their turns | stateless |
| finish reason (`length` or `stop`) | drop a word cut by the token cap |
| OS text services: `tokens`, `spell` | what counts as a word, when to show nothing |
| an OpenAI-compatible chat API (`/v1`), a pure translation onto sessions | nothing: harnesses bring their own prompts and tools |

## Processes: who starts what

Nothing is installed as a service. Each layer starts the one below it when it finds it missing, and each exits after 30 idle
minutes, so the engine runs only while something uses it.

```mermaid
flowchart TD
    client["Homeword, pi or pred"] --> ask{"GET /health on 47321<br/>answers service ghostd?"}
    ask -- yes --> reuse["use it"]
    ask -- no --> spawn["start ghostd in the background"]
    spawn --> port{"port 47321 free?"}
    port -- "no: a ghostd answers there" --> quit["exit at once, status 0<br/>already running"]
    port -- yes --> sock{"predictd answers<br/>on its socket?"}
    sock -- yes --> pin["register and pin<br/>the general prompt"]
    sock -- no --> startd["start predictd, detached<br/>wait for its socket"]
    startd --> pin
    pin --> serve["serve HTTP<br/>exit after 30 idle minutes"]
```

- **Is the engine running?** `GET 127.0.0.1:47321/health` answers `{"ok": true, "service": "ghostd", "version", "build", "pid",
  "started", "port", "model", "availability"}`. `service` tells ghostd from any other program on the port; `model` says whether
  predictd answers; `availability` whether Apple's model can be used (`available`, `apple_intelligence_off`, `model_not_ready`,
  `device_not_eligible`); `build` is the binary's modification time, to spot a ghostd started before a rebuild. Details:
  [DEVELOPING.md](DEVELOPING.md#the-contract).
- **One ghostd per port, one predictd per socket.** ghostd claims its port before anything else, so a second start (two apps racing)
  exits without touching predictd; a predictd that finds a live one on its socket exits too.
- **Who starts ghostd**: Homeword (on launch and when a request finds it down, unless the user pressed Stop), the pi extension, and
  `pred` (`pred start`, `pred try`, `pred ask`). The Claude Code mod only asks. Benchmarks run a private ghostd (`--port 0
  --no-user`) on a private predictd. Detached starts survive the app that started them.
- **Stop**: `POST /shutdown` (with `{"predictd": true}` also stops predictd): Homeword's Stop button and `pred stop`.

| | Development | Release |
|---|---|---|
| Binaries | `./ghostd`, `./predictd` in the repo (`./build.sh`) | `Homeword.app/Contents/Resources/engine/` (`app/release.sh`) |
| Data next to them | `predictd.json`, `VERSION`, `ghost/*.json` (prompts, styles, knobs), `bench/cases.json` and `bench/styles.json` (the benchmark suite) | the same files in the same layout |
| Started by | Homeword (a build of the repo knows its path), pi, `pred` | Homeword |
| User data | `~/.config/homeword/`: knob overrides, prompts, history, benchmark cases | the same |
| Logs | `/tmp/ghostd-UID.log`, `/tmp/predictd-UID.log` | the same |

## predictd: the mechanism

### Inside the process

```mermaid
flowchart LR
    subgraph threads["Threads"]
        s1["socket accept loop<br/>one reader per connection"]
        h1["HTTP accept loop<br/>127.0.0.1:47320"]
        guard["orphan guard<br/>exit when the socket file is gone"]
    end
    subgraph actor["Engine actor (owns all state)"]
        handle["handle(op)"]
        profiles["profiles<br/>by name"]
        slots["sessions<br/>profile/name, each with a queue"]
        streams["streams<br/>newest request wins"]
        ka["keep-alive, 500 ms tick<br/>prewarm the recent or pinned session, idle exit"]
    end
    spell["NSSpellChecker<br/>main actor"]
    s1 --> handle
    h1 --> handle
    handle --> profiles
    handle --> slots
    handle --> streams
    handle --> spell
    ka --> slots
```

All state lives in one Swift actor, so requests, the keep-alive and profile changes never race. Listener threads only parse and
hand requests to `Engine.handle`; answers go back on the connection (a JSON line on the socket, one response per HTTP request).

### Profiles, sessions and the cache

Measured facts that shape the design (Apple M4 Pro, macOS 27.2):

- The on-device model keeps **one prefix KV cache for the whole system**: only the session that prewarmed or generated last keeps
  it. Any other session, in any process, evicts it, and it expires after ~5-6 s idle.
- Cost of a short request (~300 tokens): ~100 ms fixed, ~0.55 ms per cached input token, ~2 ms per uncached input token, ~16 ms per
  output token. Long prompts (~4k tokens) cost ~0.75 ms per token even when cached. The context window is 8192 tokens.
- No token streaming for short answers, no stop sequences; cancelling a running generation is free.

So a **profile** (instructions + example turns) becomes a session whose transcript is the cached prefix, and every request on the
default session puts the transcript back afterwards:

```mermaid
flowchart LR
    subgraph cached["Profile = cached prefix"]
        ins["instructions"] --> ex["example turns<br/>prompt, response"]
    end
    ex --> msg["request prompt"]
    msg --> out["answer<br/>up to maxTokens"]
    out -.->|"default session: transcript restored"| ex
```

- **Default session** (`session` omitted): stateless. After each answer `session.transcript = base`, so the next request matches the
  cache: the whole prefix and often the start of the previous prompt.
- **Named sessions** (`session: "conv1"`, `keep: true`): the turns stay, for a conversation. `session.drop` forgets one.
- **Pinning**: while idle, the keep-alive keeps the session that generated last warm for `followRecentSec` (30 s: an agent loop
  keeps its cache between turns), then the pinned profile: at once when another session took the cache, otherwise every
  `keepAliveSec`. Without a pin it keeps the most recently used session warm. Using several profiles is fine; each switch costs one
  uncached prefix (~2 ms per token).
- **Order**: generations on one session run one after another; a newer request with the same `stream` cancels the older one (it
  answers `{"ok":false,"error":"cancelled"}`) and takes its place.
- Each answer reports the cache `state` it met: `warm`, `expired` (idle too long), `evicted` (another session had the cache) or
  `cold` (a new session).

### Protocol

Newline-delimited JSON on the unix socket `/tmp/predictd-UID.sock` (mode 0600), or the same objects as the body of an HTTP `POST` to
`127.0.0.1:47320` (`op` defaults to `generate`; `GET /health` answers `{"ok", "service": "predictd", "version", "pid"}`). Every
request may carry an `id`, echoed in its answer.

| Op | Request | Answer |
|---|---|---|
| `profile.set` | `name`, `instructions`, `examples: [{prompt, response}]`, `schema`, `guardrails` (`default`/`permissive`), `defaults: {maxTokens, ...}`, `pin` | `changed` (false when the definition is identical: its warm sessions are kept), `prefix_tokens` |
| `profile.pin` | `name` (or null to unpin) | `pinned` |
| `profile.drop` | `name` | |
| `generate` | `profile`, `prompt`, `session`, `keep`, `stream`, `maxTokens`, `sampling` (`greedy`/`topK`/`topP`), `topK`, `topP`, `temperature`, `seed`, `schema` (`true` = the profile's, or a JSON schema), `schemaInPrompt` | `text` or `content` (structured), `finish` (`length`/`stop`), `tokens: {in, cached, out}`, `timing: {wait_ms, model_ms, total_ms}`, `state` |
| `cancel` | `stream` | |
| `session.drop` | `profile`, `session` | |
| `prewarm` | `profile` | `prewarmed`: warm the profile's default session now and keep it warm as the most recently used one (skipped while a generation runs) |
| `tokens` | `text` | `count` |
| `spell` | `words`, `language` | `valid: [bool]` (`NSSpellChecker`) |
| `stats` | | counters, `profiles`, `pinned`, `warm`, `config` |
| `reload` | `config: {...}` | re-reads predictd.json and the user's overrides, applies `config` on top |
| `ping`, `shutdown` | | |

Errors: `{"ok":false,"error":...}` with `cancelled`, `unknown_profile` (register it, then retry: a restarted daemon has none),
`guardrail`, `context_length_exceeded`, or a message (`keep needs a named session`, `profile X has no schema`, `unknown op X`, ...).
Schemas are a JSON Schema subset: `object` (`properties`, `required`, `propertyOrder`), `array` (`items`, `minItems`, `maxItems`),
`string` (with `enum`), `integer`, `number`, `boolean`, `anyOf`/`oneOf` and nullable types (`["string", "null"]`); anything else
(refs, formats) is generated as a string. Example responses of a structured profile are JSON objects.

```sh
# a structured profile and a request, over HTTP
curl -s 127.0.0.1:47320/ -d '{"op":"profile.set","name":"triage","instructions":"Triage the issue report.",
  "schema":{"type":"object","propertyOrder":["category","urgent"],"properties":{
    "category":{"type":"string","enum":["bug","feature","question"]},"urgent":{"type":"boolean"}}}}'
curl -s 127.0.0.1:47320/ -d '{"profile":"triage","prompt":"Could you add a dark mode?","schema":true}'
# {"ok":true,"content":{"category":"feature","urgent":false},"finish":"stop","state":"cold",...}
```

### OpenAI-compatible API

The HTTP port also serves `GET /v1/models` and `POST /v1/chat/completions`. Each request's messages become a session transcript
(system → instructions with the tools as tool definitions, earlier turns → prompt, response, tool-call and tool-output entries), the
last user message is the prompt. Tools are never run: a stand-in tool records the model's call and stops the generation, and the
call goes back as OpenAI `tool_calls`. One session per model and tool set, so a conversation's turns hit the prefix cache. Details,
parameters and harness setup: [OPENAI.md](OPENAI.md).

### Lifecycle

- **Start**: ghostd starts `predictd` (next to its own binary) when nothing answers on the socket: detached, in its own session.
  It listens within a second; loading the model takes a few more. No profiles exist until clients register them.
- **One per user**: a new daemon that finds a live one on the socket exits; a daemon whose socket file is removed or replaced exits.
- **Idle**: keep-alive for `keepAliveMaxIdleSec` (5 min) after the last request, exit after `idleExitSec` (30 min).
- **Config**: `predictd.json` next to the binary (`--config`), then the user's overrides in `~/.config/homeword/predictd.json`
  if present (`$XDG_CONFIG_HOME` respected; `--user-config ""` ignores them, as the benchmarks do).
- **Logs**: stderr, `/tmp/predictd-UID.log` when started by ghostd.
- **Non-public bits**: the finish reason is read from the transcript through `Mirror` (`Transcript.Response.finishReason`). macOS
  27.0.1 does not have it: there every answer reports `stop`. Settable `session.transcript` is macOS 27 API.

## ghostd: the policy server

`ghostd` (`ghost/*.swift`) runs the typing and proofreading policies and serves them, with the user's prompts and the benchmarks,
on `127.0.0.1:47321`. It is a client of predictd like any other: it registers profiles and calls `generate` and `spell` over the
unix socket.

```mermaid
flowchart LR
    subgraph threads["Threads"]
        acc["HTTP accept loop<br/>127.0.0.1:47321"]
        task["one task per request<br/>HTTP/1.1, connection close"]
        watch["idle watchdog<br/>exit after serverIdleExitSec"]
    end
    subgraph pols["Policies"]
        typing["typing<br/>Policy.swift"]
        proof["proofreading<br/>Proofread.swift"]
        user["user prompts, history,<br/>cases, results<br/>Prompts.swift"]
        jobs["benchmark jobs<br/>one at a time<br/>Evaluate.swift"]
    end
    pool["connection pool<br/>Predictd.swift"]
    d["predictd<br/>unix socket"]
    acc --> task
    task --> typing
    task --> proof
    task --> user
    task --> jobs
    jobs --> typing
    jobs --> proof
    typing --> pool
    proof --> pool
    pool --> d
```

- **Startup**: claim the port (exit if a ghostd answers there), connect to predictd (start it if needed), register and pin the
  general prompt, then accept requests. A request that finds predictd gone (it exits when idle) restarts it and registers the
  profiles again.
- **Profiles** are named by a hash of their content (`ghost-` + 8 hex digits of a SHA-1), so an unchanged prompt keeps its name
  and predictd's warm session across restarts, and any change (a user's prompt, `words`) is a new profile.
- **Routes**: `/predict`, `/warm` (typing), `/proofread`, the prompt routes (`/prompts`, `/history`, `/tokens`, `/bench`, `/suite`,
  `/cases`, `/settings`, below), `/health`, `/config` (the knobs in effect), `/request` (the profile and `generate` request a
  prediction would use, without running it), `/shutdown`. The full list is at the top of `ghost/main.swift`.
- **Flags**: `--port N` (0 = a free port, named in the ready line on stdout), `--socket` (predictd's), `--config JSON` (knob
  overrides), `--no-user` (ignore the user's overrides and prompts: benchmarks), `--quiet`; `--selftest` runs the pure functions on
  JSON lines without a model (`Selftest.swift`, for checks such as `bench/check_cases.py`).
- **Text semantics**: the policy was first written in Python, and ghostd keeps Python's string rules (`PyCompat.swift`: code
  points, character classes, split and strip, JSON encoding, rounding), so it gives the same answers, profile names and benchmark
  results as before (checked on every suite case before the Python version was removed).

## The typing policy

**Writing styles.** One prompt per style: `general` (`ghost/prompt.json`, the prompt the benchmarks have always used) and `chat`,
`email`, `work`, `academic`, `code` (`ghost/styles.json`). A request names its style (`context`) and gets that style's prompt and
its label in the `App:` line. Every style has 6 examples: email, work and academic with their own short instructions and examples;
chat with general's instructions plus a line about chat and 6 chat examples; code with general's instructions, 4 of its mixed
examples and 2 code examples (6 code-only examples lost 4 of 25 cases). Each was chosen on tuning cases (`bench/styles-dev.json`)
and checked on the suite; only work beats general's prompt on its category in both model modes, the others are within a few cases
([bench/RESULTS.md](../bench/RESULTS.md)). Each style is its own profile: the first request after switching costs ~70 ms more, which
`POST /warm` (pin + predictd's `prewarm`) moves to when the user switches apps.

At startup ghostd registers the general profile from `ghost/prompt.json` (instructions + the first `shots` examples) and pins it;
a request in another style registers and pins that style's profile. Then, per keystroke (`ghost/Policy.swift`):

| Step | What happens | Knobs (ghost/config.json) |
|---|---|---|
| 1 trim | Keep the tail of the text that fits `textBudget` tokens, cut on a word boundary (char estimate: 4.8 chars/token prose, 2.9 code/shell, 1.6 CJK). | `textBudget` |
| 2 ask | `generate` on its profile with prompt `App: <app>\nText: <tail>`, `maxTokens`, sampling; plain text, or a one-field schema with `output: structured`. | `maxTokens`, `sampling`, `output` |
| 3 assemble | Turn the answer into the ghost (below); words are checked with predictd's `spell` op, batched once per answer. | `words`, `oneSentence`, `invalidPolicy`, `lenientApps`, `spellCheck`, `spellLanguage`, `format`, `repeatNgram`, `repeatWindow` |

The model is asked for the **rest** of the unfinished word, then the next words ("suffix" format): for `...is fail` it answers
`ing despite correct preparation`.

```mermaid
flowchart TD
    raw["model answer"] --> cut["drop a cut-off last word<br/>when finish = length"]
    cut --> sent["stop at the first sentence end<br/>oneSentence, not in lenientApps"]
    sent --> cap["keep the unfinished word + up to words more"]
    cap --> mid{"text ends mid-word?"}
    mid -- no --> nw{"first new word lowercase<br/>and not a word?"}
    nw -- yes --> none
    nw -- no --> rep
    mid -- yes --> word{"typed part + first piece<br/>is a word?"}
    word -- yes --> rep
    word -- no --> sep{"is the piece a new word?<br/>flag, path, quote, capital,<br/>or a word after a finished word"}
    sep -- yes --> space["insert the missing space"] --> rep
    sep -- no --> drop{"invalidPolicy drop and<br/>app not lenient?"}
    drop -- yes --> none["no ghost<br/>suppressed: invalid_word"]
    drop -- no --> rep
    rep["cut before a word that repeats<br/>a 3-word run of the recent text"] --> show["suggestion"]
```

The repetition cut keeps the completion of an unfinished word; when nothing is left the answer is `suppressed: repetition`.
Without it the model echoes recent phrases ("timeline changes timeline adjustments"), and accepting the echo with Tab feeds it
back, in a loop. Replaying the 240 recorded answers of the steady baselines changed one suggestion (a real echo of the input).

Days and months also count as words in their capitalised form. Sentence ends ignore abbreviations ("e.g.", "Dr."), initials and
numbers, and the rule is off for `lenientApps` (terminal, code), where `.` and `!` are syntax.

### One keystroke through all layers

```mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant A as pi
    participant G as ghostd
    participant D as predictd
    participant M as model
    U->>A: types "...is fail"
    A->>G: POST /predict app, text, stream=pi
    G->>D: generate profile=ghost-..., prompt, maxTokens 6, stream=pi
    D->>M: respond on the warm session
    U->>A: types "i" 40 ms later
    A->>G: POST /predict text=...faili
    G->>D: generate, same stream
    D-->>M: cancel the first generation (free)
    D-->>G: first: ok=false cancelled
    D->>M: same session takes over, prefix still cached
    M-->>D: "ng despite correct preparation"
    D-->>G: text, finish, tokens, state=warm
    G->>D: spell failing, despite, ...
    D-->>G: valid
    G-->>A: suggestion "ng despite correct preparation"
    A-->>U: dim ghost after the cursor
    Note over D,M: transcript restored, keep-alive keeps the session warm
```

### The ghost answer

`POST 127.0.0.1:47321/predict` with `{"app": "chat", "text": "See you tomor", "stream": "pi", "opts": {...}}` (`opts` overrides
ghost/config.json for one request):

| Field | Meaning |
|---|---|
| `suggestion` | text to show after the cursor, exactly as it should be inserted (may start with a space); `""` = no ghost |
| `partial`, `first_word` | the unfinished word at the end of `text` (`tomor`); the first whole word of the suggestion (`tomorrow`) |
| `valid`, `suppressed` | spell check of the completed word; why nothing is shown (`invalid_word`, `guardrail`) |
| `raw_suggestion`, `model_completion` | before suppression; the model's raw text |
| `truncated`, `dropped_partial`, `sentence_end`, `glued`, `respaced`, `words`, `misspelled` | what assembly did |
| `timing` | `trim_ms`, `wait_ms`, `model_ms`, `assemble_ms`, `daemon_ms`, `total_ms`, `session` (the cache state) |
| `tokens` | `in`, `cached`, `out` from predictd, plus the trim details |
| `ok:false` | `error: "cancelled"` when a newer request on the stream replaced this one: ignore it |

## The proofreading policy

`ghost/Proofread.swift` fixes (`mode: "fix"`: spelling, typos, grammar, punctuation, as few changes as possible) or rewrites
(`mode: "rewrite"`: clearer, same meaning, intent, tone and about the same length) a text. It is an occasional policy, so it does
not pin: one profile per mode (instructions + 2-3 examples from `ghost/proofread.json`, about 200-250 tokens), registered on first
use. The first request after typing pays an uncached prefix, and the typing profile pays one on the next keystroke. A text is
proofread **one paragraph per request** (paragraphs are separated by blank lines): asked for a whole text with a repeated passage,
the model returned the first copy only, and a long text could hit the token cap. Paragraph requests share the cached prefix, so
the total time stays the same.

| Step | What happens |
|---|---|
| 1 check | empty text answers unchanged; a paragraph over `proofreadMaxInputTokens` (estimated) is refused |
| 2 ask | per paragraph: `generate` on the mode's profile with the paragraph as the prompt, greedy, `maxTokens` ≈ 1.6 × its tokens + 40 |
| 3 clean | drop a preamble ("Here is the corrected text:") and quotes the model added; keep the original whitespace around each paragraph |
| 4 check | warn when a paragraph comes back much shorter (under 80% for fix, 40% for rewrite) or was cut by the token cap |
| 5 diff | a word-level edit script for display |

`POST 127.0.0.1:47321/proofread` with `{"text": "...", "mode": "fix"}` answers `text`, `changed`, `changes` (`[{"op": "equal" |
"replace" | "insert" | "delete", "a": old, "b": new}]`), `truncated` (the answer hit the token cap), `timing` (`model_ms`,
`total_ms`), `tokens`, `paragraphs` and `warnings` (show them before replacing). A refusal answers `ok: false` with `error: "the
model declined this text"`. A paragraph takes about 0.5-1 s (a 4-paragraph, 180-word email: 3.6 s).

### User prompts, history and benchmarks

Every prompt (instructions and examples) can be replaced per user (`ghost/Prompts.swift`), in files outside the repo
(`~/.config/homeword/`): `predict-<style>` for each writing style, `proofread-fix`, `proofread-rewrite`.

| Endpoint | What |
|---|---|
| `GET /prompts` | every prompt: the one in use, the shipped one, whether it is the user's, its hash, the benchmark results of both, a note |
| `POST /prompts` | `{"name", "prompt": {"instructions", "examples"}}` saves the user's version and a history entry (last 20 per prompt); `{"name", "reset": true}` restores the shipped one |
| `GET /history?name=` | the saved versions, newest first, each with its benchmark result |
| `POST /tokens` | `{"name", "prompt"?}`: tokens of the instructions and of the whole prompt as sent (a probe profile), and the estimated cost per request (~0.55 ms per cached token) |
| `POST /bench` | `{"name", "prompt"?, "scope": "all" \| "user"}`: starts a job that runs the prompt (default: the one in use) on the benchmark suite and the user's cases (`all`), or on the user's cases only (`user`), with an unpinned profile, then gives the cache back to the pinned prompt; answers `{"job"}` |
| `GET /bench?job=` | `state` (`running`, `done`, `error`), `done`/`total` cases, then `result`: per category, overall, the user's section, and `suite` (a fingerprint of the cases); stored by the prompt's content hash. `/prompts` and `/history` leave out results from another version of the suite |
| `GET /suite?name=` | the built-in benchmark cases the prompt runs on, per category (`{"name", "title", "cases": [{"text", "rest", "skipped"}]}`), for viewing; `skipped`: left out because it shares text with an example of the prompt in use |
| `GET`/`POST /cases` | the user's own benchmark cases for a prompt: `[{"text", "rest"}]` (`rest` = what comes next, or the expected output for proofreading) |
| `GET`/`POST /settings` | `{"words"}` (1-10): how many words to suggest; sets `words` and `maxTokens` (words + 1 per 5 words) and saves both to the user's config overrides; `{words}` in the prompts changes with it, so the profiles change too |

A changed prompt is a new profile (named by its content hash), so it applies to the next request; the typing policy re-pins whenever
its profile changes.

**The benchmark suite** (`ghost/Evaluate.swift`, also run by `bench/run.py --styles` through `POST /bench`): every case of
`bench/cases.json` (the fixed 80-case benchmark) and `bench/styles.json` (per style, and terminal), 200 in all, each tagged with a
category (chat 26, email 25, work 25, academic 25, code 25, general 49, terminal 25) and keeping its own app label. A prompt runs
on all of them, so one run shows how it does on every kind of text; results are reported per category. A case that shares text
with one of the prompt's examples is skipped and counted (`skipped`): it would test recall of the example. No shipped example is
in the suite or in the tuning cases (`bench/styles-dev.json`, 30 per style, used only to choose the style prompts): `python3 -I
bench/check_cases.py`. The user's cases run with the prompt's own label and are reported as a separate section. Metrics: latency
p50/p90, next word right (`acc1`), words right (`lead`), word completions right (`mid_word_ok`), shown; proofreading: fully
corrected, word match; rewriting: latency and length ratio. Benchmarks from the command line (`run.py`, `human_pty.py`,
`openai_compare.py`) ignore the user's prompts and config overrides (a private `ghostd --no-user`, `PRED_NO_USER=1`), so their
numbers stay comparable; a benchmark run in Homeword uses the engine, so the user's settings (e.g. words to suggest) apply.
