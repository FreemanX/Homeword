/**
 * Homeword ghost text for the pi coding agent.
 *
 * Replaces pi's prompt editor with a subclass that asks Homeword's engine (ghostd, the policies over HTTP, on top of predictd)
 * for a continuation of what you are typing and draws it as dim "ghost" text after the cursor.
 *
 *   Tab         accept one word of the ghost (pi's own Tab completion runs when no ghost is shown)
 *   → / Ctrl+F  accept the whole ghost (at the end of the text, where these keys do nothing in pi)
 *   typing      a character that matches the ghost keeps the rest of it; anything else asks again
 *
 * Install: see integrations/pi/README.md. Talks to http://127.0.0.1:$GHOST_PORT (default 47321) and starts the repo's `ghostd`
 * (it starts predictd) if nothing answers. Ghost text is shown only when the cursor is at the end of the text, and not for /commands or
 * !shell lines.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CustomEditor, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { CURSOR_MARKER, matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const PORT = Number(process.env.GHOST_PORT ?? 47321);
const APP = process.env.GHOST_APP ?? "coding agent prompt";
const FAKE_CURSOR_START = "\x1b_pi:fc\x07"; // pi-tui wraps the cursor cell in these markers (renderFakeCursor)
const FAKE_CURSOR_END = "\x1b_pi:/fc\x07";
const GHOSTD = process.env.GHOSTD ?? fileURLToPath(new URL("../../ghostd", import.meta.url));

let daemonStart: Promise<void> | undefined;
let lastStart = 0;

/** Start ghostd in the background (it starts predictd) and wait until it answers. One start at a time, and at most one every
 * 10 s: the services exit after 30 idle minutes, so a long pi session may need to start them again. */
function startDaemon(): Promise<void> {
	if (!daemonStart && Date.now() - lastStart > 10_000) {
		lastStart = Date.now();
		daemonStart = (async () => {
			if (!existsSync(GHOSTD)) return;
			const p = spawn(GHOSTD, ["--port", String(PORT)], { stdio: "ignore", detached: true });
			p.on("error", () => {});
			p.unref();
			for (let i = 0; i < 150; i++) {
				try {
					if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) return;
				} catch {}
				await new Promise((r) => setTimeout(r, 200));
			}
		})().finally(() => {
			daemonStart = undefined;
		});
	}
	return daemonStart ?? Promise.resolve();
}

async function predict(text: string, signal: AbortSignal): Promise<string> {
	const call = () =>
		fetch(`http://127.0.0.1:${PORT}/predict`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ app: APP, text: text.slice(-2000), stream: "pi" }),
			signal,
		});
	let res: Response;
	try {
		res = await call();
	} catch (err) {
		if (signal.aborted) throw err;
		await startDaemon(); // not running yet: start it and try once more
		res = await call();
	}
	const body = (await res.json()) as { ok?: boolean; suggestion?: string };
	return body.ok ? (body.suggestion ?? "") : "";
}

/** The ghost's first word, with its leading space ("ing" of "includ|ing", " the" after a finished word). */
function firstWord(g: string): string {
	const m = g.match(/^\s*\S+/);
	return m ? m[0] : g;
}

class GhostEditor extends CustomEditor {
	private ghost = "";
	private ghostFor = ""; // the text the ghost continues; a ghost for any other text is never drawn
	private inflight?: AbortController;
	private readonly dim: (s: string) => string;

	constructor(tui: any, theme: any, keybindings: any) {
		super(tui, theme, keybindings);
		this.dim = (s) => (typeof theme?.fg === "function" ? theme.fg("dim", s) : `\x1b[90m${s}\x1b[39m`);
	}

	private atEnd(): boolean {
		const lines = this.getLines();
		const { line, col } = this.getCursor();
		return line === lines.length - 1 && col === (lines[line] ?? "").length;
	}

	private wanted(text: string): boolean {
		const t = text.trimStart();
		return t.trim().length >= 2 && !t.startsWith("/") && !t.startsWith("!");
	}

	private clearGhost(): void {
		this.ghost = "";
		this.ghostFor = "";
	}

	private request(): void {
		this.inflight?.abort();
		const text = this.getExpandedText();
		if (!this.atEnd() || !this.wanted(text)) return;
		const ac = new AbortController();
		this.inflight = ac;
		predict(text, ac.signal)
			.then((suggestion) => {
				if (ac.signal.aborted || this.getExpandedText() !== text || !suggestion.trim()) return;
				this.ghost = suggestion;
				this.ghostFor = text;
				this.tui.requestRender();
			})
			.catch(() => {}); // daemon unavailable or request superseded: no ghost
	}

	private accept(all: boolean): void {
		const piece = all ? this.ghost : firstWord(this.ghost);
		const rest = this.ghost.slice(piece.length);
		this.insertTextAtCursor(piece);
		if (rest.trim()) {
			this.ghost = rest;
			this.ghostFor = this.getExpandedText();
		} else {
			this.clearGhost();
			this.request(); // the ghost is used up: ask what comes next
		}
		this.tui.requestRender();
	}

	handleInput(data: string): void {
		const showing = this.ghost !== "" && this.ghostFor === this.getExpandedText() && this.atEnd();
		if (showing && matchesKey(data, "tab")) return this.accept(false);
		if (showing && (matchesKey(data, "right") || matchesKey(data, "ctrl+f"))) return this.accept(true);

		const before = this.getExpandedText();
		super.handleInput(data);
		const after = this.getExpandedText();
		if (after === before) return;

		// typed the ghost's next character: keep following it instead of asking again
		if (showing && after === before + this.ghost[0] && this.ghost.slice(1).trim()) {
			this.ghost = this.ghost.slice(1);
			this.ghostFor = after;
			this.tui.requestRender();
			return;
		}
		this.clearGhost();
		this.request();
	}

	render(width: number): string[] {
		const lines = super.render(width);
		if (!this.ghost || this.ghostFor !== this.getExpandedText() || !this.atEnd()) return lines;
		const i = lines.findIndex((l) => l.includes(CURSOR_MARKER));
		if (i < 0) return lines; // editor not focused
		const line = lines[i]!;
		const start = line.indexOf(FAKE_CURSOR_START, line.indexOf(CURSOR_MARKER));
		const end = start < 0 ? -1 : line.indexOf(FAKE_CURSOR_END, start);
		if (end < 0) return lines;
		const tail = line.slice(end + FAKE_CURSOR_END.length);
		const room = (tail.match(/^ */)?.[0].length ?? 0) + 1; // the cursor cell plus the padding after it
		if (room < 2) return lines;
		const shown = truncateToWidth(this.ghost, room, "");
		const first = [...shown][0] ?? " ";
		const restShown = shown.slice(first.length);
		const used = visibleWidth(restShown);
		// fish-style: the cursor sits on the ghost's first character, the rest follows dimmed over the padding
		lines[i] =
			line.slice(0, start) +
			FAKE_CURSOR_START +
			this.dim(first) +
			FAKE_CURSOR_END +
			this.dim(restShown) +
			tail.slice(Math.min(used, tail.length));
		return lines;
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		ctx.ui.setEditorComponent((tui, theme, keybindings) => new GhostEditor(tui, theme, keybindings));
	});
}
