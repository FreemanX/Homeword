"""Generate cases.json: hand-written cases (several apps) + cases cut from a frozen text corpus at several context sizes.

Each case: id, bucket (context size), app, text (what the user typed so far, may end mid-word), rest (what they typed next).
The truth for scoring is the words of (unfinished word + rest). Deterministic (fixed seed); re-run to regenerate.
Usage: python3 -I gen_cases.py [corpus file, default bench/corpus.md]
"""
import json, random, re, sys, pathlib

HAND = [
    ("mail", "Hi Sarah, thanks for the update. I will review the proposal and get back to you by fri", "day afternoon with my comments."),
    ("mail", "Please find attached the signed contract. Let me know if you need anything el", "se from our side before the kickoff."),
    ("mail", "Dear customers, we are writing to inform you that our service will be unavail", "able on Sunday between 2 and 4 AM for maintenance."),
    ("mail", "Could you please send me the slides from yesterday's pres", "entation so I can share them with the team?"),
    ("mail", "Hi team, a quick reminder that the quarterly planning meeting is tomorrow at ", "10 AM in the main conference room."),
    ("mail", "I wanted to follow up on my previous email regarding the invoice that is still out", "standing from last month."),
    ("chat", "lol that was hilarious, I can't believe he actu", "ally said that in front of everyone"),
    ("chat", "Are you free for lunch tomorrow? I was thinking we could try that new ", "ramen place near the office."),
    ("chat", "Thanks, I'll take a look at the PR this after", "noon and leave some comments."),
    ("chat", "hey, did you see the build failure on main? looks like someone broke the tes", "ts when they merged the refactor."),
    ("chat", "Running a bit late, will be there in ", "about ten minutes, sorry about that."),
    ("chat", "Can we move our one on one to thurs", "day? I have a conflict on Wednesday."),
    ("notes", "Meeting notes: we agreed to postpone the release until the security review is comp", "leted and all blocking bugs are fixed."),
    ("notes", "TODO: update the documentation, fix the flaky integration test, and ", "write a migration guide for the new API."),
    ("notes", "Ideas for the weekend: go hiking at the state park, finish the book I started, and cook some", "thing new for dinner on Sunday."),
    ("review", "This function is doing too much. I suggest splitting it into smaller helpers so that each one has a single respons", "ibility and can be tested separately."),
    ("review", "Nit: please add a comment explaining why we need to retry here, otherwise the next person will probab", "ly remove it thinking it is redundant."),
    ("review", "LGTM overall, but the error handling in the parser should be more explic", "it about which inputs are rejected and why."),
    ("terminal", "git commit -m \"fix: prevent crash when the user input is emp", "ty or contains only whitespace\""),
    ("terminal", "git log --oneline --graph --dec", "orate --all | head -20"),
    ("terminal", "docker run -it --rm -v $(pwd):/app -w /app py", "thon:3.12 bash"),
    ("code", "    # TODO: handle the case where the file does not exi", "st and return an empty list instead of raising"),
    ("code", "// Returns true if the given string is a valid identif", "ier according to the language specification."),
    ("editor", "The quick brown fox jumps over the lazy dog. The dog, however, was not impres", "sed and went back to sleep under the tree."),
    ("terminal", "git sta", "tus --short"),
    ("terminal", "docker compose up -d --bu", "ild"),
    ("terminal", "kubectl get pods -n kube-sys", "tem -o wide"),
    ("terminal", "npm run bui", "ld && npm test"),
    ("terminal", "brew upd", "ate && brew upgrade"),
    ("terminal", "ls -la ~/Down", "loads"),
    ("terminal", "python3 -m http.ser", "ver 8000 --bind 127.0.0.1"),
    ("terminal", "grep -rn \"TODO\" --inc", "lude=\"*.py\" ."),
    ("terminal", "curl -fsSL https://example.com/install.sh | ba", "sh"),
    ("terminal", "tmux new-session -s ma", "in -d"),
    ("terminal", "git commit -m \"fix: handle timeout in the retry l", "oop when the server is slow\""),
    ("terminal", "git push origin feature/login-pa", "ge --force-with-lease"),
    ("chat", "What time does the pharmacy clo", "se on Sundays?"),
    ("chat", "I just got back from the grocery store and forgot to buy the but", "ter for the cake."),
    ("mail", "Dear Mr. Thompson, thank you for your interest in the posi", "tion of marketing coordinator at our company."),
    ("notes", "Chapter three covers the causes of the French Revol", "ution and its effect on the rest of Europe."),
    ("chat", "The kids have a dentist appointment on Tues", "day at four so I will leave work early."),
    ("notes", "Packing list for the trip: passport, phone char", "ger, sunscreen, and a light rain jacket."),
    ("mail", "I am writing to request a refund for the blender I purch", "ased last week, which stopped working."),
    ("chat", "Congratulations on the new job! You deserve it, you have worked so ha", "rd for this opportunity."),
    # the last word is already complete and there is no trailing space: the suggestion must start with a space
    ("chat", "Thanks for letting me know about", " the schedule change."),
    ("chat", "See you at the restaurant at", " seven tonight, don't be late."),
    ("mail", "I look forward to hearing from", " you soon."),
    ("notes", "Remember to call the", " plumber about the leaking kitchen faucet."),
    ("terminal", "git commit", " -m \"update the readme\""),
    ("terminal", "docker run", " -it --rm ubuntu bash"),
    ("terminal", "ls", " -la ~/Documents"),
    ("terminal", "cd ~/projects", " && git status"),
]

SIZES = {"s": (270, 10), "m": (900, 10), "l": (3000, 6), "xl": (6000, 4)}   # approx chars of context, number of cases
WORD = re.compile(r"^[A-Za-z][A-Za-z']*(-[A-Za-z]+)?[,.]?$")

def corpus(path):
    return re.sub(r"[`*|]", "", pathlib.Path(path).read_text())


def main():
    text = corpus(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).with_name("corpus.md"))
    rng = random.Random(7)
    cases = []
    for app, t, rest in HAND:
        cases.append({"id": f"h{len(cases):02d}", "bucket": "xs", "app": app, "text": t, "rest": rest})
    # candidate cut points: next 8 words must be plain prose
    words = [(m.start(), m.group()) for m in re.finditer(r"\S+", text)]
    used = set()
    for bucket, (chars, n) in SIZES.items():
        tries = 0; got = 0
        while got < n and tries < 5000:
            tries += 1
            i = rng.randrange(len(words) // 3 if bucket == "xl" else 20, len(words) - 10)
            start = words[i][0]
            if start < chars or any(abs(start - u) < 60 for u in used):
                continue
            nxt = words[i:i + 8]
            if not all(WORD.match(w) for _, w in nxt):
                continue
            mid = got % 2 == 0                       # alternate: cut inside a word / at a word boundary
            w = nxt[0][1]
            if mid:
                if len(re.sub(r"\W", "", w)) < 5:
                    continue
                cut = start + rng.randint(2, 3)
            else:
                cut = start
            rest_end = words[i + 7][0] + len(words[i + 7][1])
            cases.append({"id": f"{bucket}{got:02d}", "bucket": bucket, "app": "notes",
                          "text": text[max(0, cut - chars):cut] if bucket != "xl" else text[max(0, cut - chars):cut],
                          "rest": text[cut:rest_end]})
            used.add(start); got += 1
    # the generated contexts may start mid-sentence, like a window over a longer document: that is the point
    out = pathlib.Path(__file__).with_name("cases.json")
    out.write_text(json.dumps(cases, indent=1, ensure_ascii=False))
    from collections import Counter
    print(len(cases), "cases", dict(Counter(c["bucket"] for c in cases)), "->", out)

main()
