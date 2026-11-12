"""Overlaps between the shipped prompts' examples and the benchmark and tuning cases: there should be none (a case that shares
text with an example measures recall of the example, not prediction; the benchmark skips such cases). Run after editing a
prompt (ghost/prompt.json, styles.json, proofread.json) or the cases (bench/cases.json, styles.json, styles-dev.json,
languages.json):

    python3 -I bench/check_cases.py          (exit status 1 when it finds overlaps)

The prompts, the suite and the overlap rule come from the engine itself (`ghostd --selftest`, no model needed).
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
GHOSTD = os.path.join(os.path.dirname(HERE), "ghostd")
CATEGORIES = ["chat", "email", "work", "academic", "code", "general", "terminal"]
LANGUAGES = ["da-DK", "de-DE", "es-ES", "fr-FR", "it-IT", "ja-JP", "ko-KR", "nb-NO", "nl-NL", "pt-BR", "sv-SE", "tr-TR", "vi-VN",
             "zh-Hans-CN", "zh-Hant-TW"]                 # every language with cases in languages.json


def main():
    if not os.access(GHOSTD, os.X_OK):
        sys.exit("no ghostd: run ./build.sh")
    proc = subprocess.Popen([GHOSTD, "--selftest"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def ask(fn, **args):
        proc.stdin.write(json.dumps({"fn": fn, "args": args}) + "\n")
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())["out"]

    suite = ask("suite", languages=LANGUAGES)["cases"]
    styles = json.load(open(os.path.join(HERE, "styles.json")))
    dev = json.load(open(os.path.join(HERE, "styles-dev.json")))
    pools = [("suite", suite), ("proofread", [{"text": c["text"]} for c in styles["proofread"]]),
             ("tuning", [c for k, v in dev.items() if not k.startswith("_") for c in v])]
    found = 0
    for name, prompt in ask("default_prompts").items():
        for pool, cases in pools:
            for c in cases:
                if not ask("overlaps", text=c["text"], examples=prompt["examples"]):
                    continue
                for e in prompt["examples"]:
                    if ask("overlaps", text=c["text"], examples=[e]):
                        found += 1
                        print(f"{name}: example {e['text']!r} ~ {pool} case {c['text']!r}")
    proc.stdin.close()
    counts = {}
    for c in suite:
        counts[c["category"]] = counts.get(c["category"], 0) + 1
    print("suite cases per category:", ", ".join(f"{k} {counts.get(k, 0)}" for k in CATEGORIES))
    print("language cases:", ", ".join(f"{k.removeprefix('lang-')} {n}" for k, n in counts.items() if k.startswith("lang-")))
    print(f"{found} overlaps")
    return found


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
