// Homeword ghost text for Claude Code's prompt box.
//
// While you type, asks Homeword's engine (ghostd, http://127.0.0.1:47321, on top of the predictd model host) how the
// prompt continues and paints the answer as dim virtual text after the cursor: drawn, never part of the draft.
//
//   Tab         accept one word of the ghost     (keybinding "tab": "command:ghost-word" in the Chat context)
//   →           accept the whole ghost; with no ghost it moves the cursor right as usual   ("right": "command:ghost-all")
//   typing      a character that matches the ghost keeps the rest of it; anything else asks again
//
// Keys that do nothing at the end of the draft never reach a prompt.edit hook, so accepting goes through two slash commands
// bound in ~/.claude/keybindings.json (see integrations/claude-code/README.md); the autocomplete menu keeps its own Tab.
//
// Shown only with the cursor at the end of the draft, and not for /commands or !shell lines. Start the engine with `bin/pred start`.
import type { Register } from 'claude-code'

const URL = 'http://127.0.0.1:47321/predict'
const APP = 'coding agent prompt'

let ghost = '' // the continuation shown after the cursor
let ghostFor = '' // the draft it continues; a ghost for any other draft is never shown
let pendingAccept = '' // the draft our last accept-all wrote, so prompt.change can ask for the next words
let seq = 0 // bumped on every change, so a late answer for an older draft is dropped

const wanted = (text: string) => {
  const t = text.trimStart()
  return t.trim().length >= 2 && !t.startsWith('/') && !t.startsWith('!')
}

// the ghost's first word with its leading space: "ing" of "includ|ing", " the" after a finished word
const firstWord = (g: string) => g.match(/^\s*\S+/)?.[0] ?? g

const paint = (text: string, g: string) => [{ start: text.length, end: text.length, virtualText: g, dimColor: true }]

const clear = () => {
  ghost = ''
  ghostFor = ''
  seq++
}

export const register: Register = on => {
  on('prompt.edit', async ($, e, next) => {
    // Ask the daemon from a timer, so the keystroke is not held up; a late answer for an older draft is dropped.
    const ask = (text: string) => {
      if (!wanted(text)) return
      const my = seq
      $.clock.after(1, async () => {
        let suggestion = ''
        try {
          const res = await $.http.fetch(URL, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ app: APP, text: text.slice(-2000), stream: 'claude-code' }),
          })
          const body = JSON.parse(res.text)
          suggestion = body.ok ? (body.suggestion ?? '') : ''
        } catch {
          return // ghostd not running or request refused: no ghost
        }
        if (my !== seq || !suggestion.trim()) return
        const box = await $.prompt.read()
        if (my !== seq || box.text !== text || box.cursor !== text.length) return
        ghost = suggestion
        ghostFor = text
        // write the same draft back with the painted run at its end (decorations ride on a fill); checked unchanged just above
        await $.prompt.fill({ text, mode: 'replace', cursor: text.length, decorations: paint(text, suggestion) })
      })
    }

    const atEnd = e.cursor === e.text.length
    const showing = ghost !== '' && ghostFor === e.text && atEnd
    const k = e.key
    if (showing && k && !k.ctrl && !k.meta) {
      const all = k.key === 'right' || k.key === 'end'
      if (all || k.key === 'tab') {
        const piece = all ? ghost : firstWord(ghost)
        const text = e.text + piece
        const rest = ghost.slice(piece.length)
        if (rest.trim()) {
          ghost = rest
          ghostFor = text
          return { text, cursor: text.length, decorations: paint(text, rest) }
        }
        clear()
        ask(text) // the ghost is used up: ask what comes next
        return { text, cursor: text.length }
      }
    }

    const r = await next(e)
    if (r.text === e.text) {
      // a cursor move: keep the ghost while the cursor stays at the end
      return showing && r.cursor === r.text.length ? { ...r, decorations: paint(r.text, ghost) } : r
    }
    // typed the ghost's next character: keep following it instead of asking again
    if (showing && r.text === e.text + ghost[0] && r.cursor === r.text.length && ghost.slice(1).trim()) {
      ghost = ghost.slice(1)
      ghostFor = r.text
      return { ...r, decorations: paint(r.text, ghost) }
    }
    clear()
    if (r.cursor === r.text.length) ask(r.text)
    return r
  })

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await $.command.register({ name: 'ghost-word', description: 'Homeword: accept one word of the ghost text', immediate: true })
    await $.command.register({ name: 'ghost-all', description: 'Homeword: accept the ghost text (or move the cursor right)', immediate: true })
    return r
  })

  on('command.run', { command: 'ghost-word' }, async ($, e, next) => {
    const box = await $.prompt.read()
    if (ghost === '' || ghostFor !== box.text || box.cursor !== box.text.length) return {}
    const piece = firstWord(ghost)
    const text = box.text + piece
    const rest = ghost.slice(piece.length)
    if (rest.trim()) {
      ghost = rest
      ghostFor = text
      await $.prompt.fill({ text, mode: 'replace', cursor: text.length, decorations: paint(text, rest) })
    } else {
      clear()
      pendingAccept = text
      await $.prompt.fill({ text, mode: 'replace', cursor: text.length })
    }
    return {}
  })

  on('command.run', { command: 'ghost-all' }, async ($, e, next) => {
    const box = await $.prompt.read()
    if (ghost === '' || ghostFor !== box.text || box.cursor !== box.text.length) {
      // no ghost: do what → does
      if (box.cursor < box.text.length) await $.prompt.fill({ text: box.text, mode: 'replace', cursor: box.cursor + 1 })
      return {}
    }
    const text = box.text + ghost
    clear()
    pendingAccept = text
    await $.prompt.fill({ text, mode: 'replace', cursor: text.length })
    return {}
  })

  // the draft changed some other way (history, a submit, a fill): the ghost no longer fits
  on('prompt.change', async ($, e, next) => {
    if (e.text === ghostFor) return next(e) // our own accept of one word: the rest of the ghost still fits
    const accepted = e.text === pendingAccept // our own accept of the whole ghost: ask what comes next
    pendingAccept = ''
    clear()
    if (accepted && wanted(e.text)) {
      const text = e.text
      const my = seq
      $.clock.after(1, async () => {
        try {
          const res = await $.http.fetch(URL, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ app: APP, text: text.slice(-2000), stream: 'claude-code' }),
          })
          const body = JSON.parse(res.text)
          const suggestion: string = body.ok ? (body.suggestion ?? '') : ''
          if (my !== seq || !suggestion.trim()) return
          const box = await $.prompt.read()
          if (my !== seq || box.text !== text || box.cursor !== text.length) return
          ghost = suggestion
          ghostFor = text
          await $.prompt.fill({ text, mode: 'replace', cursor: text.length, decorations: paint(text, suggestion) })
        } catch {
          // ghostd not running or request refused: no ghost
        }
      })
    }
    return next(e)
  })
}
