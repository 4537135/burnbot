"""Stage A, step 2: pick objectives and checkpoints, and build what each reader gets.

    python3 -I tools/progress-eval/sample.py --data DIR [--seed 7] [--stats]

Reads DIR/sessions/*.json (from extract.py). Writes DIR/sample.json:
  objectives: where each one starts, the window the hindsight labeller sees, its strata
  checkpoints: for each, the digest a candidate estimator would get (only what existed at
               that moment, about 1.5k tokens) and the facts the rule candidates use
and DIR/views/<objective>.txt, the hindsight view for the labeller (the whole window,
checkpoints marked). --stats prints the candidate pool by stratum and stops.
"""

import json
import os
import random
import re
import sys
from collections import Counter

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import base, clip, data_dir, load, plan_files, plan_headings, save, tidy

SUBSTANTIAL_TYPED = 80
SUBSTANTIAL_PASTED = 300
GAP_MS = 3 * 3600_000                 # a pause this long ends the heuristic span
FOLLOW_SUBSTANTIAL = 2                # the labeller sees this many substantial prompts past the span
VIEW_BUDGET = 56_000                  # characters in a hindsight view (~14k tokens)
DEBUG_WORDS = re.compile(r"\b(bug|broken|break|fix|error|crash|fail|failing|doesn'?t work|not working|wrong|issue|stuck|regress)", re.I)
OPEN_WORDS = re.compile(r"\b(explore|brainstorm|ideas|research|investigate|look into|what do you think|audit|analy[sz]e|"
                        r"compare|options|suggest|opinions?|think about|play with|experiment)\b", re.I)
CHANGE_WORDS = re.compile(r"\b(actually|instead|rather|change|also|but|wait|don'?t|not|no longer|make it|switch)\b", re.I)
VERIFY = re.compile(r"\b(test|tests|check|checks|verify|lint|build|smoke|regress\w*|playwright|screenshot|snapshot|validate|compile)\b", re.I)
TRIGGERS = ("plan_approved", "checklist", "first_edit", "check_after_edits", "handback", "new_prompt")


def substantial(e, first=False):
    return e["typed"] >= SUBSTANTIAL_TYPED or e["pasted"] >= SUBSTANTIAL_PASTED or (first and e["typed"] >= 20)


def is_check(e):
    return e["k"] == "check"


def verifying(e):
    """A check in the wide sense: a classified test/build/typecheck run, a shell run that says it verifies
    something, or a screenshot looked at. Used by the mechanical cross-check and the digests."""
    if e["k"] == "check" or e["k"] == "look":
        return True
    return e["k"] == "bash" and not e.get("denied") and bool(VERIFY.search(e.get("desc", "") + " " + e.get("cmd", "")[:120]))


def moments(events, i0, i1):
    """Stage C trigger events between i0 and i1 (inclusive): (index, kind)."""
    out, edits, edits_since_check, first_seen = [], 0, 0, False
    for i in range(i0, i1 + 1):
        e = events[i]
        k = e["k"]
        if k == "plan" and e["status"] == "approved":
            out.append((i, "plan_approved"))
        elif k == "checklist":
            out.append((i, "checklist"))
        elif k == "edit":
            edits += 1
            edits_since_check += 1
            if not first_seen:
                first_seen = True
                out.append((i, "first_edit"))
        elif k == "check" and edits_since_check > 0:
            out.append((i, "check_after_edits"))
            edits_since_check = 0
        elif k == "prompt" and i > i0:
            out.append((i, "new_prompt"))
        # handback: the last event before the next prompt
        nxt = events[i + 1] if i + 1 < len(events) else None
        if k != "prompt" and (nxt is None or nxt["k"] == "prompt") and i > i0:
            out.append((i, "handback"))
    return out


def span_of(session, ti):
    """The heuristic span: the anchor turn and its short follow-ups, up to the next substantial prompt."""
    turns, events = session["turns"], session["events"]
    tj = ti
    while tj + 1 < len(turns):
        nxt = turns[tj + 1]
        if substantial(events[nxt["i"]]) or nxt["t0"] - turns[tj]["t1"] > GAP_MS:
            break
        tj += 1
    return tj


def features(session, ti, tj):
    turns, events = session["turns"], session["events"]
    i0, i1 = turns[ti]["i"], turns[tj]["j"]
    ev = events[i0:i1 + 1]
    anchor = events[i0]
    edits = [e for e in ev if e["k"] == "edit"]
    checks = [e for e in ev if is_check(e)]
    fails = [e for e in checks if e["verdict"] == "fail"]
    plan = any(e["k"] == "plan" and e["status"] == "approved" for e in ev)
    rejected_note = any(e["k"] == "plan" and e["status"] == "rejected" and e.get("note") for e in ev)
    checklist = max((len(e["items"]) for e in ev if e["k"] == "checklist"), default=0)
    minutes = sum(turns[t]["minutes"] for t in range(ti, tj + 1))
    follow = [events[turns[t]["i"]] for t in range(ti + 1, tj + 1)]
    long_follow = [e for e in follow if e["typed"] >= 40 and CHANGE_WORDS.search(e["text"])]
    qa_typed = any(e["k"] == "qa" for e in ev)
    interrupted = any(e["k"] == "interrupt" for e in ev[:-1])
    text = anchor["text"]
    f = {
        "minutes": round(minutes, 1),
        "turns": tj - ti + 1,
        "edits": len(edits),
        "files": len({x["file"] for x in edits}),
        "checks": len(checks),
        "fails": len(fails),
        "plan": plan,
        "checklist": checklist >= 3,
        "looks": sum(1 for e in ev if e["k"] == "look"),
        "events": len(ev),
    }
    strata = []
    strata.append("plan" if plan else "no_plan")
    if f["checklist"]:
        strata.append("checklist")
    if f["edits"] and f["edits"] <= 4 and f["files"] <= 2 and minutes <= 15:
        strata.append("quick_fix")
    if minutes >= 20 and (len(fails) >= 2 or DEBUG_WORDS.search(text)) and f["edits"] >= 3:
        strata.append("long_debug")
    if fails:
        strata.append("failed_checks")
    if rejected_note or long_follow or qa_typed or interrupted:
        strata.append("changed_req")
    if f["edits"] == 0 or (OPEN_WORDS.search(text[:400]) and f["edits"] <= 3):
        strata.append("open_candidate")
    return f, strata


def candidates(sessions):
    pool = []
    for s in sessions:
        turns, events = s["turns"], s["events"]
        for ti, turn in enumerate(turns):
            anchor = events[turn["i"]]
            if not substantial(anchor, first=(ti == 0)):
                continue
            tj = span_of(s, ti)
            f, strata = features(s, ti, tj)
            if f["minutes"] < 3 or f["events"] < 8:
                continue
            if "open_candidate" not in strata and f["edits"] == 0:
                continue
            pool.append({"session": s["id"], "project": s["project"], "ti": ti, "tj": tj, "f": f, "strata": strata})
    return pool


def select(pool, rng):
    """Stratified: rare strata first, projects spread, then fill. Open-ended candidates kept apart."""
    targets_bounded = {"checklist": 5, "plan": 11, "quick_fix": 6, "long_debug": 7, "failed_checks": 9, "changed_req": 8, "no_plan": 13}
    n_bounded, n_open = 40, 26
    project_cap = {"bounded": 0.45, "open": 0.5}
    rng.shuffle(pool)
    chosen, used = [], set()

    def ok(c, group, limit):
        if (c["session"], c["ti"]) in used:
            return False
        # spans must not overlap in a session
        for x in chosen:
            if x["session"] == c["session"] and not (c["tj"] < x["ti"] or c["ti"] > x["tj"]):
                return False
        same = [x for x in chosen if x["group"] == group]
        if same and sum(1 for x in same if x["project"] == c["project"]) >= max(3, project_cap[group] * limit):
            return False
        # no more than 3 objectives from one session
        return sum(1 for x in chosen if x["session"] == c["session"]) < 3

    def take(c, group):
        c = dict(c, group=group)
        chosen.append(c)
        used.add((c["session"], c["ti"]))

    bounded = [c for c in pool if "open_candidate" not in c["strata"]]
    open_ = [c for c in pool if "open_candidate" in c["strata"]]
    # projects first: one of each where it exists
    for group, src in (("bounded", bounded), ("open", open_)):
        for p in sorted({c["project"] for c in src}):
            for c in src:
                if c["project"] == p and ok(c, group, n_bounded if group == "bounded" else n_open):
                    take(c, group)
                    break
    for stratum, want in sorted(targets_bounded.items(), key=lambda kv: sum(1 for c in bounded if kv[0] in c["strata"])):
        have = sum(1 for x in chosen if x["group"] == "bounded" and stratum in x["strata"])
        for c in bounded:
            if have >= want:
                break
            if stratum in c["strata"] and ok(c, "bounded", n_bounded):
                take(c, "bounded")
                have += 1
    for group, src, n in (("bounded", bounded, n_bounded), ("open", open_, n_open)):
        for c in src:
            if sum(1 for x in chosen if x["group"] == group) >= n:
                break
            if ok(c, group, n):
                take(c, group)
    return chosen


# ---- rendering ----

def checklist_line(items):
    mark = {"completed": "x", "in_progress": ">", "pending": " "}
    return " ".join("[%s] %s" % (mark.get(st, " "), clip(c, 60)) for c, st in items)


def render(events, i0, i1, markers, say_clip=260, quiet=None, anchor_clip=3000, prompt_clip=1500, turn_names=None):
    """Hindsight view lines for events[i0..i1]. markers: {index: label} drawn right after that event."""
    lines, pend = [], Counter()
    pend_files, pend_runs = [], []

    def flush():
        if not pend:
            return
        parts = []
        if pend["read"]:
            parts.append("%d read%s (%s)" % (pend["read"], "s" if pend["read"] > 1 else "", ", ".join(dict.fromkeys(pend_files))[:120]))
        if pend["search"]:
            parts.append("%d search%s" % (pend["search"], "es" if pend["search"] > 1 else ""))
        if pend["bash"]:
            runs = list(dict.fromkeys(pend_runs))
            parts.append("%d shell command%s%s%s" % (pend["bash"], "s" if pend["bash"] > 1 else "",
                                                     " (%d failed)" % pend["bashfail"] if pend["bashfail"] else "",
                                                     ": " + "; ".join(runs[:3]) + ("…" if len(runs) > 3 else "") if runs else ""))
        if pend["tool"]:
            parts.append("%d other tool call%s" % (pend["tool"], "s" if pend["tool"] > 1 else ""))
        lines.append("  · looked around: " + ", ".join(parts))
        pend.clear()
        pend_files.clear()
        pend_runs.clear()

    last_edit_files = None
    for i in range(i0, i1 + 1):
        e = events[i]
        k = e["k"]
        if k in ("read", "search", "bash", "tool"):
            pend[k] += 1
            if k == "read":
                pend_files.append(base(e["file"]))
            if k == "bash" and e.get("err"):
                pend["bashfail"] += 1
            if k == "bash" and (e.get("desc") or verifying(e)):
                pend_runs.append(clip(e.get("desc") or e["cmd"], 50) + (" ✗" if e.get("err") else ""))
            if i in markers:
                flush()
                lines.append(markers[i])
            continue
        if k == "edit" and last_edit_files is not None and lines and lines[-1].startswith("  ✎ edit"):
            last_edit_files[base(e["file"])] = last_edit_files.get(base(e["file"]), 0) + 1
            lines[-1] = "  ✎ edit " + ", ".join(f + (" ×%d" % n if n > 1 else "") for f, n in last_edit_files.items())
            if i in markers:
                lines.append(markers[i])
            continue
        flush()
        last_edit_files = None
        if k == "prompt":
            name = turn_names.get(i, "") if turn_names else ""
            lines.append("")
            lines.append("YOU%s: %s" % (" [" + name + "]" if name else "", clip(tidy(e["text"], 600), anchor_clip if i == i0 else prompt_clip)))
        elif k == "say":
            if quiet and i in quiet:
                continue
            lines.append("  Claude: " + clip(e["text"], say_clip))
        elif k == "edit":
            last_edit_files = {base(e["file"]): 1}
            lines.append("  ✎ edit " + base(e["file"]))
        elif k == "check":
            tail = (" — " + clip(e["tail"], 140)) if e["verdict"] == "fail" and e.get("tail") else ""
            lines.append("  ✓ check (%s) `%s` → %s%s" % (e["family"], clip(e["core"], 70), e["verdict"].upper(), tail))
        elif k == "look":
            lines.append("  👁 looked at " + base(e["file"]))
        elif k == "git":
            lines.append("  ⎇ " + ("git commit" if e["what"] == "commit" else "opened a pull request"))
        elif k == "agent":
            lines.append("  ⇢ subagent: " + e["desc"])
        elif k == "plan":
            if e["status"] == "approved":
                heads = plan_headings(e["plan"], limit=30)
                lines.append("  ▣ PLAN APPROVED by you. Headings:")
                lines += ["      " + h for h in heads] or ["      (no headings)"]
            else:
                lines.append("  ▣ plan turned down" + (": you said: " + clip(e.get("note", ""), 600) if e.get("note") else ""))
        elif k == "qa":
            for q, a in e["pairs"]:
                lines.append("  ? Claude asked: %s" % clip(q, 200))
                lines.append("    you answered: %s" % clip(a, 200))
        elif k == "checklist":
            lines.append("  ☑ checklist: " + checklist_line(e["items"]))
        elif k == "compact":
            lines.append("  (context compacted)")
        elif k == "interrupt":
            lines.append("  (you interrupted Claude)")
        elif k == "wrapup":
            lines.append("  Claude wrap-up: " + clip(e["recap"], 300) + (" | asks: " + clip(e["ask"], 150) if e["ask"] else ""))
        if i in markers:
            lines.append(markers[i])
    flush()
    return lines


def view_for(session, obj, cps):
    """The hindsight view: context before, the window with checkpoints marked, and whether the log goes on."""
    events, turns = session["events"], session["turns"]
    i0, i1 = obj["i0"], obj["view_i1"]
    markers = {cp["index"]: "  >>>>>>>>>> CHECKPOINT %s (%s) <<<<<<<<<<" % (cp["cp"], cp["moment"].replace("_", " ")) for cp in cps}
    turn_names = {turns[t]["i"]: "T%d" % (t - obj["ti"] + 1) for t in range(obj["ti"], obj["view_tj"] + 1)}
    before = [events[turns[t]["i"]] for t in range(max(0, obj["ti"] - 3), obj["ti"])]
    head = ["Project: %s" % session["project"], ""]
    if before:
        head.append("Earlier prompts in this session (context only, oldest first):")
        head += ["  - " + clip(tidy(e["text"], 80), 240) for e in before]
    else:
        head.append("(This is the first prompt of the session.)")
    head += ["", "=== WINDOW STARTS (turn T1 is where this objective is assumed to start) ==="]
    tail = ["", "=== WINDOW ENDS: " + ("the session log ends here ===" if obj["log_ends"] else
                                         "the session log continues after this (not shown) ===")]
    narr = [i for i in range(i0, i1 + 1) if events[i]["k"] == "say"]
    for say_clip in (260, 200, 150):
        body = render(events, i0, i1, markers, say_clip=say_clip, turn_names=turn_names)
        text = "\n".join(head + body + tail)
        if len(text) <= VIEW_BUDGET:
            return text
    # still too long: keep narration near prompts, checkpoints and handbacks, thin the rest evenly
    keep_near = set(markers) | {turns[t]["i"] for t in range(obj["ti"], obj["view_tj"] + 1)} | {turns[t]["j"] for t in range(obj["ti"], obj["view_tj"] + 1)}
    for step in (2, 3, 4, 6, 8, 12, 16):
        quiet = set()
        for n, i in enumerate(narr):
            near = any(abs(i - m) <= 3 for m in keep_near)
            if not near and n % step:
                quiet.add(i)
        body = render(events, i0, i1, markers, say_clip=150, quiet=quiet, turn_names=turn_names)
        text = "\n".join(head + body + tail)
        if len(text) <= VIEW_BUDGET:
            return text
    return text[: VIEW_BUDGET - 200] + "\n…(cut)\n" + "\n".join(tail)


# ---- the digest: what a candidate sees at a checkpoint ----

MOMENT_TEXT = {
    "plan_approved": "You just approved Claude's plan.",
    "checklist": "Claude just updated its checklist.",
    "first_edit": "Claude just made its first edit.",
    "check_after_edits": "A check just finished after edits.",
    "handback": "Claude just stopped and handed back to you.",
    "new_prompt": "You just sent a follow-up.",
}


def digest(session, obj, idx, moment):
    events = session["events"]
    i0 = obj["i0"]
    ev = events[i0:idx + 1]
    anchor = ev[0]
    parts = ["Request: " + clip(tidy(anchor["text"]), 1800)]
    clar = []
    for e in ev[1:]:
        if e["k"] == "prompt":
            clar.append("you said: " + clip(tidy(e["text"], 120), 300))
        elif e["k"] == "qa":
            clar += ["Claude asked: %s / you answered: %s" % (clip(q, 120), clip(a, 120)) for q, a in e["pairs"]]
        elif e["k"] == "plan" and e["status"] == "rejected" and e.get("note"):
            clar.append("you turned a plan down: " + clip(e["note"], 260))
        elif e["k"] == "interrupt":
            clar.append("you interrupted Claude")
    if clar:
        clar = clar[-8:]
        parts.append("Since then:\n" + "\n".join("- " + c for c in clar))
    plan = next((e for e in reversed(ev) if e["k"] == "plan" and e["status"] == "approved"), None)
    if plan:
        parts.append("Approved plan, headings:\n" + "\n".join(plan_headings(plan["plan"], limit=14)))
    cl = next((e for e in reversed(ev) if e["k"] == "checklist"), None)
    if cl:
        done = sum(1 for _, st in cl["items"] if st == "completed")
        parts.append("Checklist (%d of %d done): %s" % (done, len(cl["items"]), checklist_line(cl["items"][:10])))
    # recent actions: edits, checks, looks, commits, compactly
    acts = []
    for e in ev[1:]:
        k = e["k"]
        if k == "edit":
            name = base(e["file"])
            if acts and acts[-1][0] == "edit":
                acts[-1][1].append(name)
            else:
                acts.append(["edit", [name]])
        elif k == "check":
            acts.append(["check", "%s `%s` %s" % (e["family"], clip(e["core"], 50), e["verdict"])])
        elif k == "look":
            acts.append(["look", "looked at " + base(e["file"])])
        elif k == "bash" and verifying(e):
            acts.append(["run", "ran %s%s" % (clip(e.get("desc") or e["cmd"], 60), " (failed)" if e.get("err") else "")])
        elif k == "git":
            acts.append(["git", "git commit" if e["what"] == "commit" else "opened a pull request"])
        elif k == "plan" and e["status"] == "approved":
            acts.append(["plan", "plan approved"])
        elif k == "agent":
            acts.append(["agent", "subagent: " + clip(e["desc"], 50)])
    shown = []
    for a in acts[-15:]:
        if a[0] == "edit":
            names = list(dict.fromkeys(a[1]))
            shown.append("edited " + ", ".join(names[:5]) + (" +%d more" % (len(names) - 5) if len(names) > 5 else "")
                         + (" (%d edits)" % len(a[1]) if len(a[1]) > 1 else ""))
        else:
            shown.append(a[1])
    edits = [e for e in ev if e["k"] == "edit"]
    runs = [e for e in ev if e["k"] in ("check", "bash") and verifying(e)]
    ok = sum(1 for e in runs if (e["k"] == "check" and e["verdict"] == "pass") or (e["k"] == "bash" and not e.get("err")))
    bad = sum(1 for e in runs if (e["k"] == "check" and e["verdict"] == "fail") or (e["k"] == "bash" and e.get("err")))
    summary = "So far: %d edits to %d files; %d check runs (%d passed, %d failed); %d screenshots looked at." % (
        len(edits), len({e["file"] for e in edits}), len(runs), ok, bad, sum(1 for e in ev if e["k"] == "look"))
    parts.append(summary + ("\nRecent actions, oldest first:\n" + "\n".join("- " + s for s in shown) if shown else "\nNo edits or checks yet."))
    says = [e["text"] for e in ev if e["k"] == "say"][-4:]
    if says:
        parts.append("Claude's last words, oldest first:\n" + "\n".join("- " + clip(s, 300) for s in says))
    parts.append("Now: " + ("You just sent this request; Claude is starting on it." if idx == i0 else MOMENT_TEXT[moment]))
    return "\n\n".join(parts)


def wide_verdict(e):
    if e["k"] == "check":
        return e["verdict"]
    return "fail" if e.get("err") else "pass"


def facts(session, obj, idx, moment):
    """As-of-checkpoint facts for the rule candidates."""
    events = session["events"]
    ev = events[obj["i0"]:idx + 1]
    edits = [e for e in ev if e["k"] == "edit"]
    last_edit = max((n for n, e in enumerate(ev) if e["k"] == "edit"), default=-1)
    after = ev[last_edit + 1:] if last_edit >= 0 else []
    checks_after = [e for e in after if e["k"] == "check" or (e["k"] == "bash" and verifying(e))]
    plan = next((e for e in reversed(ev) if e["k"] == "plan" and e["status"] == "approved"), None)
    pf = plan_files(plan["plan"]) if plan else []
    edited = {base(e["file"]) for e in edits}
    cl = next((e for e in reversed(ev) if e["k"] == "checklist"), None)
    if not edits:
        stage = "before_edit"
    elif moment == "handback" and checks_after and wide_verdict(checks_after[-1]) == "pass":
        stage = "handback_checked"
    elif moment == "handback":
        stage = "handback"
    elif checks_after:
        stage = "checked_" + wide_verdict(checks_after[-1])
    else:
        stage = "editing"
    return {
        "stage": stage,
        "edits": len(edits),
        "files": len(edited),
        "checks": sum(1 for e in ev if e["k"] == "check"),
        "fails": sum(1 for e in ev if e["k"] == "check" and e["verdict"] == "fail"),
        "last_check_after_edit": wide_verdict(checks_after[-1]) if checks_after else None,
        "verify_runs": sum(1 for e in ev if verifying(e)),
        "looked_after_edit": any(e["k"] == "look" for e in after),
        "plan": bool(plan),
        "plan_files": len(pf),
        "plan_files_edited": len(set(pf) & edited),
        "checklist_total": len(cl["items"]) if cl else 0,
        "checklist_done": sum(1 for _, st in cl["items"] if st == "completed") if cl else 0,
        "turns_so_far": sum(1 for e in ev if e["k"] == "prompt"),
        "handed_back": moment == "handback",
    }


def place_checkpoints(session, obj, rng, n, allowed=None, opening=False):
    """n checkpoints at trigger moments, one per equal slice of the span's events (by position, not time).
    allowed: only these moment kinds. opening: the request itself counts as a new_prompt moment too
    (the app makes an estimate when a prompt arrives; Stage A never placed one there)."""
    events = session["events"]
    i0, i1 = obj["i0"], obj["span_i1"]
    if opening:     # always the opening, then up to n-1 more
        rest = place_checkpoints(session, obj, rng, n - 1, allowed) if n > 1 else []
        return [(i0, "new_prompt")] + [m for m in rest if m[0] != i0]
    ms_ = moments(events, i0, i1)
    if allowed is not None:
        ms_ = [m for m in ms_ if m[1] in allowed]
    if not ms_:
        return []
    picks = []
    width = (i1 - i0 + 1) / n
    for s in range(n):
        lo, hi = i0 + s * width, i0 + (s + 1) * width
        inside = [m for m in ms_ if lo <= m[0] < hi and m not in picks]
        if inside:
            picks.append(rng.choice(inside))
    # unfilled slices: take any unused moment
    spare = [m for m in ms_ if m not in picks]
    rng.shuffle(spare)
    while len(picks) < n and spare:
        picks.append(spare.pop())
    picks.sort()
    return picks


def build_objective(data, s, c, oid, rng, n=None, allowed=None, opening=False):
    """One sampled span -> (objective, checkpoints), with its hindsight view written to DIR/views."""
    turns, events = s["turns"], s["events"]
    # window: the span plus FOLLOW_SUBSTANTIAL substantial prompts past it (or the log's end)
    vt, seen = c["tj"], 0
    while vt + 1 < len(turns) and seen < FOLLOW_SUBSTANTIAL:
        vt += 1
        if substantial(events[turns[vt]["i"]]):
            seen += 1
    obj = {"id": oid, "session": c["session"], "project": c["project"], "group": c["group"], "strata": c["strata"],
           "f": c["f"], "ti": c["ti"], "tj": c["tj"], "view_tj": vt,
           "i0": turns[c["ti"]]["i"], "span_i1": turns[c["tj"]]["j"], "view_i1": turns[vt]["j"],
           "log_ends": vt == len(turns) - 1}
    picks = place_checkpoints(s, obj, rng, n or (3 if c["group"] == "bounded" else 2), allowed, opening)
    cps = []
    for k, (idx, moment) in enumerate(picks):
        cp = {"cp": "CP%d" % (k + 1), "id": "%s-CP%d" % (oid, k + 1), "objective": oid, "index": idx, "moment": moment}
        cp["digest"] = digest(s, obj, idx, moment)
        cp["facts"] = facts(s, obj, idx, moment)
        cps.append(cp)
    if not cps:
        return None
    view = view_for(s, obj, cps)
    os.makedirs(os.path.join(data, "views"), exist_ok=True)
    with open(os.path.join(data, "views", oid + ".txt"), "w") as f:
        f.write(view)
    obj["view_chars"] = len(view)
    obj["checkpoints"] = [cp["id"] for cp in cps]
    return obj, cps


def main():
    data = data_dir()
    args = sys.argv[1:]
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 7
    rng = random.Random(seed)
    index = load(os.path.join(data, "sessions.json"))
    sessions = {x["id"]: load(os.path.join(data, "sessions", x["id"] + ".json")) for x in index}
    pool = candidates(sessions.values())
    if "--stats" in args:
        c = Counter(s for p in pool for s in p["strata"])
        print("pool", len(pool), dict(c))
        print("projects", Counter(p["project"] for p in pool))
        return
    chosen = select(pool, rng)
    objectives, checkpoints = [], []
    os.makedirs(os.path.join(data, "views"), exist_ok=True)
    for n, c in enumerate(sorted(chosen, key=lambda c: (c["group"], c["project"], c["session"], c["ti"]))):
        built = build_objective(data, sessions[c["session"]], c, "O%02d" % (n + 1), rng)
        if built:
            objectives.append(built[0])
            checkpoints += built[1]
    save(os.path.join(data, "sample.json"), {"seed": seed, "objectives": objectives, "checkpoints": checkpoints})
    g = Counter(o["group"] for o in objectives)
    print(json.dumps({"objectives": dict(g), "checkpoints": len(checkpoints),
                      "strata": dict(Counter(s for o in objectives for s in o["strata"])),
                      "projects": dict(Counter(o["project"] for o in objectives)),
                      "view_chars_max": max(o["view_chars"] for o in objectives),
                      "view_chars_total": sum(o["view_chars"] for o in objectives),
                      "digest_chars_max": max(len(c["digest"]) for c in checkpoints),
                      "digest_chars_mean": round(sum(len(c["digest"]) for c in checkpoints) / len(checkpoints))}))


if __name__ == "__main__":
    main()
