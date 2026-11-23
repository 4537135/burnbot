"""Stage A, step 2b: find more open-ended turns, so "no bar" has a real test set.

    python3 -I tools/progress-eval/more_open.py --data DIR [--want 24] [--seed 11] [--any-edits]

The first sample's open-ended guesses were mostly bounded work once the labeller saw them,
so this looks again among the turns that are not in the sample yet: turns with no edits,
or exploratory wording and few edits (--any-edits: every turn, since open-ended
iteration can edit a lot). One batched Opus call per 40 candidates screens them
from the request and a few counts only (same flags as label.py: no tools, no session
persistence, run from the neutral folder). The ones it calls open-ended are appended to
DIR/sample.json as new objectives (group "open"), with views and digests built exactly as
sample.py builds them. label.py run then labels them in full, and its verdict decides.
The screen's raw answers go to DIR/labels/screen.json.
"""

import json
import os
import random
import sys
from collections import Counter, defaultdict

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import clip, data_dir, load, save, tidy
from sample import OPEN_WORDS, build_objective, features, span_of
from label import args_for, ask, claude_path

BATCH = 40
SCHEMA = {
    "type": "object",
    "properties": {"items": {"type": "array", "items": {
        "type": "object",
        "properties": {"n": {"type": "integer"},
                       "kind": {"type": "string", "enum": ["bounded", "open_ended"]},
                       "sure": {"type": "number", "minimum": 0, "maximum": 1}},
        "required": ["n", "kind", "sure"], "additionalProperties": False}}},
    "required": ["items"], "additionalProperties": False,
}
PROMPT = """You are screening turns from real Claude Code sessions for an evaluation of a progress bar. For each numbered item you get the person's request, any short follow-ups in the same stretch, and a few counts of what Claude did.

Classify each item:
- bounded: a deliverable whose completion can be recognised (fix this, build that, write this, ship that, answer this specific question, commit and push). A bounded task with some investigation in it is still bounded.
- open_ended: no finish line knowable in advance (exploration, brainstorming, open research, "look around and tell me", conversation, iteration with no completion criteria). For these the right progress bar is "no bar".
sure: how sure you are, 0 to 1. Answer for every item, through the structured output only.

"""


def pool(data, sample, any_edits=False):
    taken = defaultdict(list)
    for o in sample["objectives"]:
        taken[o["session"]].append((o["ti"], o["view_tj"]))
    out = []
    for x in load(os.path.join(data, "sessions.json")):
        s = load(os.path.join(data, "sessions", x["id"] + ".json"))
        turns, events = s["turns"], s["events"]
        for ti, t in enumerate(turns):
            a = events[t["i"]]
            if a["typed"] < 25 and a["pasted"] < 300:
                continue
            tj = span_of(s, ti)
            if any(not (tj < lo or ti > hi) for lo, hi in taken[s["id"]]):
                continue
            f, strata = features(s, ti, tj)
            if f["minutes"] < 2 or f["events"] < 6:
                continue
            if not any_edits and not (f["edits"] == 0 or (OPEN_WORDS.search(a["text"][:400]) and f["edits"] <= 3)):
                continue
            ev = events[t["i"]:turns[tj]["j"] + 1]
            follow = [tidy(events[turns[k]["i"]]["text"], 120) for k in range(ti + 1, tj + 1)][:3]
            counts = Counter(e["k"] for e in ev)
            out.append({"session": s["id"], "project": s["project"], "ti": ti, "tj": tj, "f": f,
                        "strata": [x for x in strata if x != "open_candidate"] + ["open_candidate"],
                        "request": clip(tidy(a["text"], 400), 400), "follow": follow,
                        "counts": "%.0f min, %d turn(s), %d edits, %d reads/searches, %d shell runs, %d narration lines"
                                  % (f["minutes"], f["turns"], f["edits"], counts["read"] + counts["search"],
                                     counts["bash"] + counts["check"], counts["say"])})
    return out


def main():
    data = data_dir()
    argv = sys.argv
    want = int(argv[argv.index("--want") + 1]) if "--want" in argv else 24
    seed = int(argv[argv.index("--seed") + 1]) if "--seed" in argv else 11
    sample_path = os.path.join(data, "sample.json")
    if os.path.exists(os.path.join(data, "labels.json")):
        sys.exit("labels.json is frozen; the sample cannot grow now")
    sample = load(sample_path)
    cands = pool(data, sample, "--any-edits" in argv)
    screen_path = os.path.join(data, "labels", "screen.json")
    screen = load(screen_path) if os.path.exists(screen_path) else {"answers": {}, "cost_usd": 0.0}
    todo = [c for c in cands if "%s:%d" % (c["session"], c["ti"]) not in screen["answers"]]
    if todo:
        args = args_for(claude_path(), "opus", "1.00", SCHEMA)
        work = os.path.join(data, "cwd")
        os.makedirs(work, exist_ok=True)
        for b in range(0, len(todo), BATCH):
            batch = todo[b:b + BATCH]
            text = PROMPT + "\n\n".join(
                "[%d] REQUEST: %s%s\nWHAT CLAUDE DID: %s" % (n + 1, c["request"],
                    "".join("\nFOLLOW-UP: " + x for x in c["follow"]), c["counts"])
                for n, c in enumerate(batch))
            out = ask(args, text, work)
            screen["cost_usd"] += out.get("total_cost_usd") or 0
            for it in (out.get("structured_output") or {}).get("items", []):
                if 1 <= it["n"] <= len(batch):
                    c = batch[it["n"] - 1]
                    screen["answers"]["%s:%d" % (c["session"], c["ti"])] = {"kind": it["kind"], "sure": it["sure"]}
            save(screen_path, screen)
            print("screened %d, cost so far $%.2f" % (min(b + BATCH, len(todo)), screen["cost_usd"]), flush=True)
    opens = [c for c in cands if screen["answers"].get("%s:%d" % (c["session"], c["ti"]), {}).get("kind") == "open_ended"
             and screen["answers"]["%s:%d" % (c["session"], c["ti"])]["sure"] >= 0.6]
    rng = random.Random(seed)
    rng.shuffle(opens)
    # spread: projects round-robin, at most 2 per session, no overlapping spans
    chosen, by_project = [], defaultdict(list)
    for c in opens:
        by_project[c["project"]].append(c)
    while len(chosen) < want and any(by_project.values()):
        for p in sorted(by_project):
            while by_project[p]:
                c = by_project[p].pop()
                same = [x for x in chosen if x["session"] == c["session"]]
                if len(same) < 2 and all(c["tj"] < x["ti"] or c["ti"] > x["tj"] for x in same):
                    chosen.append(c)
                    break
            if len(chosen) >= want:
                break
    n = len(sample["objectives"])
    added = []
    for c in sorted(chosen, key=lambda c: (c["project"], c["session"], c["ti"])):
        s = load(os.path.join(data, "sessions", c["session"] + ".json"))
        c = dict(c, group="open")
        for k in ("request", "follow", "counts"):
            c.pop(k)
        built = build_objective(data, s, c, "O%02d" % (n + 1), rng)
        if built:
            n += 1
            sample["objectives"].append(built[0])
            sample["checkpoints"] += built[1]
            added.append(built[0])
    prev = sample.get("more_open", {})
    sample["more_open"] = {"screened": len(screen["answers"]), "screened_open": prev.get("screened_open", 0) + len(opens),
                           "added": prev.get("added", []) + [o["id"] for o in added]}
    save(sample_path, sample)
    print(json.dumps({"pool": len(cands), "screened_open": len(opens), "added": len(added),
                      "projects": dict(Counter(o["project"] for o in added)),
                      "screen_cost_usd": round(screen["cost_usd"], 2)}))


if __name__ == "__main__":
    main()
