"""Homeword's interface texts and their translations. The code names every text in English, L("English text", args...)
(app/Sources/Localization.swift); each language has <language>.lproj/Localizable.strings for them, and Localizable.stringsdict for
the phrases with a count (plural forms; en.lproj has the English ones and decides which phrases those are). Developer tool,
standard library only:

    python3 -I app/Localization/strings.py              check every language against the code (exit status 1 on problems)
    python3 -I app/Localization/strings.py --export     the texts as JSON ({"key", "files", "plural"}), for translating

A translation keeps every format specifier of its key in its order (%d, %@; %% for a percent sign in a text with values), or
numbers them all (%2$d ... %1$@) where the language needs another order.
"""
import json, os, plistlib, re, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
SOURCES = os.path.join(os.path.dirname(HERE), "Sources")
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|@|f|%)")


def literal(src, i):
    """The Swift string literal starting at src[i] == '"': (its text, the index after it)."""
    out, i = [], i + 1
    while src[i] != '"':
        if src[i] == "\\":
            nxt = src[i + 1]
            if nxt == "(":
                raise ValueError("interpolation in an L() text: use a format and arguments")
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(nxt, nxt))
            i += 2
        else:
            out.append(src[i])
            i += 1
    return "".join(out), i + 1


def keys():
    """Every L() text in the app's code: {key: [files]}."""
    found = {}
    for name in sorted(os.listdir(SOURCES)):
        if not name.endswith(".swift"):
            continue
        src = open(os.path.join(SOURCES, name), encoding="utf-8").read()
        for m in re.finditer(r'(?<![\w.])L\(\s*"', src):
            if "//" in src[src.rfind("\n", 0, m.start()) + 1:m.start()]:     # in a comment
                continue
            i, parts = m.end() - 1, []
            while True:                                     # "a" + "b" + ... (a long text split over lines)
                text, i = literal(src, i)
                parts.append(text)
                j = i
                while src[j] in " \t\n":
                    j += 1
                if src[j] != "+":
                    break
                j += 1
                while src[j] in " \t\n":
                    j += 1
                if src[j] != '"':
                    raise ValueError(f"{name}: an L() text joined with something other than a literal")
                i = j
            found.setdefault("".join(parts), []).append(name)
    return found


def read_strings(path):
    if not os.path.exists(path):
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if out.returncode:
        raise ValueError(f"{path}: {out.stderr.strip()}")
    return json.loads(out.stdout)


def read_dict(path):
    return plistlib.load(open(path, "rb")) if os.path.exists(path) else {}


def specs(s):
    """The values a format takes, in argument order: its specifiers, put in order by their positions ("%2$d %1$@" -> %@, %d).
    None when it mixes numbered and plain ones."""
    found = [x for x in SPEC.findall(s) if x != "%%"]
    numbered = [x for x in found if re.match(r"%\d+\$", x)]
    if numbered and len(numbered) != len(found):
        return None
    if numbered:
        found = sorted(found, key=lambda x: int(re.match(r"%(\d+)\$", x).group(1)))
    return [re.sub(r"\d+\$", "", x).replace("ld", "d").replace("lld", "d") for x in found]


def stray(s):
    """A % that is not a specifier (it would garble or crash the formatting)."""
    return "%" in SPEC.sub("", re.sub(r"%#@\w+@", "", s))


def plural_specs(entry):
    """The values a stringsdict entry takes: its format's, the plural variable's in its place."""
    fmt = entry.get("NSStringLocalizedFormatKey", "")
    for var in re.findall(r"%#@(\w+)@", fmt):
        fmt = fmt.replace(f"%#@{var}@", "%" + entry.get(var, {}).get("NSStringFormatValueTypeKey", "?"), 1)
    return specs(fmt)


def check():
    code = keys()
    plural = read_dict(os.path.join(HERE, "en.lproj", "Localizable.stringsdict"))
    problems = 0

    def say(msg):
        nonlocal problems
        problems += 1
        print(msg)

    for k in plural:
        if k not in code:
            say(f"en: plural entry not in the code: {k!r}")
    langs = sorted(d[:-6] for d in os.listdir(HERE) if d.endswith(".lproj") and d != "en.lproj")
    for lang in langs:
        strings = read_strings(os.path.join(HERE, f"{lang}.lproj", "Localizable.strings"))
        dicts = read_dict(os.path.join(HERE, f"{lang}.lproj", "Localizable.stringsdict"))
        for k in code:
            if k in plural:
                e = dicts.get(k)
                if e is None:
                    say(f"{lang}: missing plural entry {k!r}")
                elif plural_specs(e) != specs(k) or stray(e.get("NSStringLocalizedFormatKey", "")):
                    say(f"{lang}: format specifiers differ in plural entry {k!r}")
                else:
                    for var in re.findall(r"%#@(\w+)@", e.get("NSStringLocalizedFormatKey", "")):
                        forms = {f: v for f, v in e.get(var, {}).items() if not f.startswith("NSString")}
                        if "other" not in forms:
                            say(f"{lang}: plural entry {k!r} has no 'other' form")
                        for f, v in forms.items():
                            if stray(v) or any(x not in ("%d", "%ld", "%lld") for x in SPEC.findall(v) if x != "%%"):
                                say(f"{lang}: plural form {f!r} of {k!r} takes other values than the count: {v!r}")
            elif k not in strings:
                say(f"{lang}: missing {k!r}")
            elif specs(strings[k]) != specs(k) or (specs(k) and stray(strings[k])):
                say(f"{lang}: format specifiers differ: {k!r} -> {strings[k]!r}")
        for k in list(strings) + list(dicts):
            if k not in code:
                say(f"{lang}: no longer in the code: {k!r}")
    print(f"{len(code)} texts ({len(plural)} with plural forms), {len(langs)} languages besides English: {problems} problems")
    return problems


if __name__ == "__main__":
    if "--export" in sys.argv:
        plural = read_dict(os.path.join(HERE, "en.lproj", "Localizable.stringsdict"))
        json.dump([{"key": k, "files": f, "plural": k in plural} for k, f in keys().items()], sys.stdout, ensure_ascii=False, indent=1)
        print()
    else:
        sys.exit(1 if check() else 0)
