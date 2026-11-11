# Mac app, version 2: design

Status: implemented (Homeword). Changes from the plan below, after measuring or later requests:

- Benchmark: every prompt runs on the whole suite (`bench/cases.json` + `bench/styles.json`, 200 cases, at least 25 per category)
  and is reported per category, plus the user's own test cases as a separate section; the built-in cases can be viewed read-only.
  Not "12-15 cases per style". A case that shares text with the prompt's examples is skipped.
- Style prompts: chosen on separate tuning cases (`bench/styles-dev.json`) and checked on the suite; each has 6 examples (email,
  work, academic their own instructions; chat and code general's instructions; code keeps 4 of general's mixed examples). See
  bench/RESULTS.md.
- Switching between prompts costs ~70 ms on the first request, not the ~0.4 s assumed below.
- Added: words to suggest (1-10) in General, info tips (ⓘ) on the Prompts and Statistics tabs. Window 880 × 660.

Scope of this round: user-facing names, a writing style per app (detected automatically, adjustable), a prompt per style with a
built-in benchmark and a history of versions, custom shortcuts, an app picker instead of bundle IDs, and an Engine tab that
shows and controls the local service. The layering stays: the app is UI only; prompts, styles, benchmarks and history live in the
Python policy and its HTTP server; predictd stays a model host that knows nothing about apps or styles.

## 1. Words the user sees

No design jargon in the UI. Internal names stay in code and developer docs.

| Internal | User-facing |
|---|---|
| policy server (`pred serve`) + predictd | **Engine** ("runs Apple's on-device model on this Mac; nothing leaves it") |
| predictd's OpenAI-compatible API | **OpenAI-compatible API** (for other apps) |
| profile, pin, prefix cache | not shown; a prompt's size is shown as tokens and an estimated time per request |
| context label (`app`) | **Writing style**: General, Chat, Email, Work documents, Academic, Code |
| excluded apps | **Off** as an app's style |
| suppressed, invalid_word | not shown |

## 2. Writing styles (context detection)

The app picks a style for the field being typed in:

1. The user's choice for that app (Settings → Apps), if any.
2. Browsers: the page's host name, read through Accessibility (`AXURL` of the focused web area), mapped by a built-in table:
   mail.google.com, outlook.* → Email; app.slack.com, teams.microsoft.com, discord.com, web.whatsapp.com, messenger.com → Chat;
   docs.google.com, notion.so, *.atlassian.net, quip.com → Work documents; overleaf.com → Academic. The host is used in memory
   only, never logged.
3. The app's bundle ID, by a built-in table: Messages, Slack, Teams, WhatsApp, Telegram, Discord, Signal, Messenger, Zoom → Chat;
   Mail, Outlook, Spark, Superhuman, Mimestream → Email; Pages, Word, Keynote, PowerPoint, Notion, Quip → Work documents;
   TeXShop, TeXstudio, Texifier → Academic; Xcode, VS Code, Cursor, JetBrains IDEs, Zed, Sublime Text, Nova → Code.
4. Otherwise General.

Terminals and password managers default to Off.

Each style has its own prompt (instructions + 6 examples in that register). The app sends `context` with each request. The policy
keeps one profile per style and pins the one in use.

**The cache.** The model keeps one prompt prefix cached system-wide, so the first keystroke after switching to an app with another
style would be uncached (~+0.4 s). Fix: on app switch the app calls `POST /warm {"context"}`; the policy pins that style's profile
and asks predictd to prewarm it now. That needs a new generic predictd op, `prewarm {profile}`: prewarm the profile's default
session now and treat it as the most recently used one (today pinning a known profile only takes effect after `followRecentSec`).
Prewarm needs ~1 s of lead time, usually there between switching apps and typing.

**General stays the current prompt** (prompt.json, unchanged), so the existing benchmark and baselines stay comparable. The new
styles live in `ghost/styles.json`. The pi and Claude Code integrations send no style and keep using General.

## 3. Prompts tab

```
┌ Styles ───────────┐ ┌──────────────────────────────────────────────────────────────────┐
│ PREDICTION        │ │ Chat                                         custom · saved 14:02 │
│   General         │ │ Instructions                                                     │
│ ▸ Chat •          │ │ ┌──────────────────────────────────────────────────────────────┐ │
│   Email           │ │ │ Continue the user's chat message ...                         │ │
│   Work documents  │ │ └──────────────────────────────────────────────────────────────┘ │
│   Academic        │ │ Examples                                              [+] [−]    │
│   Code            │ │   typed text                    │ continuation                   │
│ PROOFREADING      │ │   omw, be there in              │  10 min                        │
│   Proofread       │ │   ...                                                            │
│   Rewrite         │ │ 214 characters · 41 tokens · whole prompt 262 tokens (≈145 ms)   │
│                   │ │ [Reset to Default]                         [Revert]  [Save ⌘S]   │
│                   │ │ Benchmark: 14 chat cases                   [Run on this version] │
│                   │ │  version          latency  next word  words right  completions   │
│                   │ │  default            301 ms     43%        0.71         58%       │
│                   │ │  this draft         288 ms     50%        0.86         64%       │
│                   │ │ History (last 20 saved)                                          │
│                   │ │  Nov 10 14:02  262 tok  288 ms  50%   [Load]                     │
└───────────────────┘ └──────────────────────────────────────────────────────────────────┘
```

- Instructions and examples are editable. Prediction examples are (typed text → continuation); proofreading ones are (input →
  output).
- Token counts come from predictd's `tokens` op, debounced while typing. "Whole prompt" is the profile prefix (instructions +
  examples as sent). The time estimate is ~0.55 ms per cached token, the measured cost.
- **Benchmark**: `POST /bench {"name", "prompt"?}` runs the draft (or the saved prompt) on that style's cases with a temporary,
  unpinned profile. It returns latency p50, next word right (acc1), mean words right (lead), word completions right
  (mid_word_ok) and shown. Results are stored by the prompt's content hash, so a saved version keeps its numbers. Running the
  default once gives the comparison row. ~12-15 cases, ~6-10 s. Predictions pause meanwhile, because the model has one cache.
  The model's two speed modes can shift latency by ~70 ms between runs, so the table says to compare runs made together.
- Proofread benchmark: 12 sentences with known errors. It reports latency and corrected exactly / edits matched. Rewrite has no
  ground truth, so it reports latency and length ratio only.
- **History**: every Save appends a version (last 20 per prompt) with time, tokens and any benchmark result. Load puts it in the
  editor. Kept by the policy in `~/.config/input-predictor/prompt-history.json`, next to `prompts.json`.

**Benchmark cases per style**: new hand-written cases in `bench/styles.json`, about 12-15 per style: chat (informal messaging),
email (professional), work documents (formal), academic, code (comments, reviews, commit messages), and general (notes,
informal). Synthetic text, no personal data. `bench/run.py --styles` runs them for all styles from the command line too, so the
same numbers are reproducible outside the app.

## 4. Apps tab (replaces the bundle ID list)

A table of apps with icon, name and style:

- Rows: every app with a user setting, plus the built-in defaults that are installed (terminals → Off, ...). A style picker per
  row: Automatic (shows what was detected), General, Chat, Email, Work documents, Academic, Code, Off.
- **+** offers running apps (icons) or "Choose…" (an open panel on /Applications); **−** removes the user's setting. Bundle IDs
  appear only as a tooltip.
- Stored as `{bundleID: style}` in the app's preferences. Existing excluded-app entries migrate to Off.

## 5. Shortcuts

Settings → General → Shortcuts: a recorder per action (Proofread selection, Rewrite selection). Click, press a key combination,
done. Esc cancels; Delete clears, which turns the shortcut off. At least one of ⌘ ⌃ ⌥ is required. A warning shows when the
combination is the other action's, or a common app shortcut (⌘ + a letter without other modifiers). Stored as key code +
modifier flags; the key tap matches exactly. The tap ignores keys while a recorder is active. Menu items show the current
shortcut.

## 6. Engine tab

```
Engine                                   ● Running        [Stop] [Restart]
  Runs Apple's on-device model on this Mac. Nothing leaves it.
  Port  [47321]                          (used by this app, pred, pi, Claude Code)
OpenAI-compatible API                    ● Available
  Base URL  http://127.0.0.1:47320/v1    [Copy]
  Model     apple-on-device  · API key: any text
  Port  [47320]
Permissions                              ● Accessibility allowed   [Open Settings]
```

- Dots: green = running, yellow = starting / stopping / restarting, red = stopped (with the reason: "stopped by you:
  predictions are paused", or "starts when you type" after it shut down when idle, or an error).
- Start, Stop and Restart run `bin/pred start|stop`. After Stop the app does not restart the engine on its own until Start.
- Ports: saved to user config files outside the repo, then the engine restarts: `~/.config/input-predictor/config.json` (policy
  overrides, `serverPort`) and `~/.config/input-predictor/predictd.json` (predictd overrides, `httpPort`). This needs generic
  layering: predictd loads its `predictd.json`, then the user file if present; the policy loads `ghost/config.json`, then the user
  file. The pi and Claude Code integrations keep their own port settings; the tab says so.
- Status: the app polls `GET /health` (engine) and predictd's HTTP `ping` (API) every 2 s while the tab is open, and on use.

## 7. Statistics

Adds the style to `suggestion` metrics and a "By style" section: shown, accepted, latency per style. Still no text.

## 8. Window

One Settings window, 860 × 640: General (prediction, proofreading, shortcuts), Apps, Prompts, Statistics, Engine.

## 9. Name: Homeword

Homeword: your words never leave home. Bundle ID `dev.homeword.app`. The new bundle ID means Accessibility has to be
granted once more, and the app migrates the old preferences and metrics on first launch.

## Build order

1. Mechanism: predictd `prewarm` op, user config overlay. Policy: styles (styles.json, `context`, `/warm`), user overlay for
   config.json, prompts with examples, `/tokens`, `/bench`, history. Verify with curl and the benchmark.
2. Benchmark cases per style (`bench/styles.json`, `run.py --styles`), first numbers for all styles.
3. App: names and Engine tab, Apps tab and detection, shortcuts, Prompts tab with benchmark and history, statistics by style,
   rename.
4. Docs, privacy scan, commits per step.
