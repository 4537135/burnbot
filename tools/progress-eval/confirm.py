"""Phase 2b: a pre-registered confirmation round for the "haiku-working" variant.

    python3 -I tools/progress-eval/confirm.py draft   --data DIR                # decision rule, before any tuning
    python3 -I tools/progress-eval/confirm.py tune    --data DIR [--cap 1.50]   # revised prompt on Stage A mid-work
    python3 -I tools/progress-eval/confirm.py prereg  --data DIR                # freezes DIR/confirm/prereg.json
    python3 -I tools/progress-eval/extract.py --data DIR/confirm --exclude SESSION --active-minutes 60
    python3 -I tools/progress-eval/confirm.py sample  --data DIR [--screen-cap 0.60]
    python3 -I tools/progress-eval/confirm.py extend  --data DIR [--want 14] [--screen-cap 0.15]   # more open-ended, before freezing
    python3 -I tools/progress-eval/label.py   run     --data DIR/confirm --definition confirm --app-env --cap USD
    python3 -I tools/progress-eval/label.py   freeze  --data DIR/confirm
    (adjudicate disagreements by hand into DIR/confirm/adjudicated.json, then)
    python3 -I tools/progress-eval/confirm.py seal    --data DIR                # hashes adjudicated.json
    python3 -I tools/progress-eval/confirm.py run     --data DIR [--cap USD]    # haiku-working + the rules
    python3 -I tools/progress-eval/confirm.py score   --data DIR
    python3 -I tools/progress-eval/confirm.py grading --data DIR [--out OUT_DIR --export SCRIPT]   # subset; export only if asked
    python3 -I tools/progress-eval/confirm.py spend   --data DIR

DIR is the Stage A data folder (outside the repo); this round lives in DIR/confirm and only reads
Stage A. Every step that needs an earlier one checks that step's frozen file and its sha256 first,
so the order (rule, tuning, pre-registration, new data, labels, adjudication, candidates) is
enforced, not just intended. Model calls use label.py's flags and app_env from the neutral DIR/cwd.
"""

import hashlib
import json
import os
import random
import re
import stat
import statistics
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import candidates as cand  # noqa: E402
import grade  # noqa: E402
from common import clip, data_dir, load, save, tidy  # noqa: E402
from label import KIND_CONFIRM, app_env, args_for, ask, claude_path, instructions  # noqa: E402
from more_open import SCHEMA as SCREEN_SCHEMA  # noqa: E402
from sample import build_objective, candidates as span_pool, features, moments, span_of  # noqa: E402

MID = ("plan_approved", "checklist", "first_edit", "check_after_edits", "new_prompt")
WRONG = 0.3
GATE = {"error": 0.15, "wrong": 0.10, "coverage": 0.30, "open_shown": 0.10, "open_n": 15, "gpt_error": 0.15}
TOTAL_CAP = 7.00
SEED = 2026111802
N_BOUNDED, N_OPEN = 24, 20      # sized for the $7 round cap (labels ~$0.065, Haiku ~$0.022 a call)
FULL_RULES = ("const", "stage", "planfile")      # "beats the best rule" compares against these (as in Stage A)

KIND_OLD = ('kind: "bounded" if the request has a finish line you could recognise (a fix, a feature, a change, a '
            'document or plan to write). "open_ended" if it has none (exploring, brainstorming, open research, '
            'conversation, "look around and tell me", iterating with no completion criteria).')
KIND_NEW = ('kind: "open_ended" if there is no deliverable the user could tick off at the end: questions, advice, '
            'comparing options, brainstorming, review or explanation without a requested change (also exploring, '
            'open research, conversation, "look around and tell me"). "bounded" if the user asked for a change or a '
            'deliverable they could tick off (a fix, a feature, a change to files, a document or plan to write). '
            'Judge by what the user asked for, not by what Claude has done so far: reading code to answer a question '
            'is still open_ended, and a requested change is bounded even before the first edit.')
assert KIND_OLD in cand.INSTRUCTIONS
PROMPTS = {"original": cand.INSTRUCTIONS, "revised": cand.INSTRUCTIONS.replace(KIND_OLD, KIND_NEW)}

DECISION = ("Adopt the revised prompt only if, on Stage A's mid-work checkpoints, it (1) shows a bar on no more of "
            "the open-ended ones than the original did, (2) keeps coverage of the bounded ones at 70% or more, "
            "(3) has an error against the frozen labels no more than 0.02 above the original's, and (4) has a "
            "confidently-wrong share no more than 3 points above the original's. Otherwise keep the original. "
            "Either way the chosen text is frozen into prereg.json by its sha256.")

SCREEN = """You are screening turns from real Claude Code sessions for an evaluation of a progress bar. For each numbered item you get the person's request, any short follow-ups in the same stretch, and a few counts of what Claude did.

Classify each item by what the person asked for:
- open_ended: no deliverable the user could tick off at the end: questions, advice, comparing options, brainstorming, review or explanation without a requested change.
- bounded: everything else: the person asked for a change or a deliverable they could tick off (fix this, build that, write this, ship that).
sure: how sure you are, 0 to 1. Answer for every item, through the structured output only.

"""
QUESTION = re.compile(r"\?|\b(what do you think|should (we|i)|just asking|don'?t (write|change|code|implement|edit|touch)|"
                      r"no code|why|how (does|do|can|would|should|is)|what if|which (is|one|would)|compare|explain|"
                      r"review|thoughts|opinion|is it possible|pros and cons|recommend|advice|ideas?|brainstorm)\b", re.I)


# ---- small helpers ----

def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def sha_file(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def freeze_file(path):
    digest = sha_file(path)
    with open(path + ".sha256", "w") as f:
        f.write(digest + "  " + os.path.basename(path) + "\n")
    os.chmod(path, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    return digest


def frozen_ok(path):
    if not (os.path.exists(path) and os.path.exists(path + ".sha256")):
        sys.exit("%s is not frozen yet" % os.path.basename(path))
    want = open(path + ".sha256").read().split()[0]
    if sha_file(path) != want:
        sys.exit("%s changed since it was frozen" % os.path.basename(path))
    return want


def arg(name, default=None, kind=str):
    argv = sys.argv
    return kind(argv[argv.index(name) + 1]) if name in argv else default


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else None


def text_for(prompt, cp):
    return prompt + "\n--- THE MOMENT ---\n" + cp["digest"]     # exactly candidates.text_for's join


def working(answer):
    """haiku-working: tenths / 10 capped at 0.9, hidden when it calls the request open-ended; no threshold."""
    s = (answer or {}).get("structured_output")
    if not isinstance(s, dict):
        return {"shown": False, "missing": True}
    if s["kind"] == "open_ended":
        return {"shown": False}
    return {"shown": True, "fill": min(s["tenths"] / 10, 0.9)}


def metrics(pred, bounded, opens, truth):
    shown = [i for i in bounded if pred[i]["shown"]]
    errs = [abs(pred[i]["fill"] - truth[i]) for i in shown]
    return {"n": len(bounded), "shown": len(shown), "coverage": len(shown) / len(bounded) if bounded else None,
            "error": mean(errs), "wrong": (sum(1 for e in errs if e > WRONG + 1e-9) / len(errs)) if errs else None,
            "open_n": len(opens), "open_shown_n": sum(1 for i in opens if pred[i]["shown"]),
            "open_shown": (sum(1 for i in opens if pred[i]["shown"]) / len(opens)) if opens else None}


def spent(data):
    """Everything this round has spent, from the answers on disk."""
    cdir = os.path.join(data, "confirm")
    out = {}

    def folder(name, path):
        total = 0.0
        if os.path.isdir(path):
            for f in os.listdir(path):
                if f.endswith(".json"):
                    total += load(os.path.join(path, f)).get("total_cost_usd") or 0
        out[name] = round(total, 4)

    folder("tuning (haiku, Stage A)", os.path.join(cdir, "tune", "revised"))
    sp = os.path.join(cdir, "labels", "screen.json")
    out["screening (opus)"] = round(load(sp)["cost_usd"], 4) if os.path.exists(sp) else 0.0
    folder("labels (opus)", os.path.join(cdir, "labels", "raw"))
    folder("haiku-working (new sample)", os.path.join(cdir, "candidates", "haiku"))
    out["total"] = round(sum(out.values()), 4)
    return out


def haiku_batch(jobs, folder, cap, cwd, workers=3):
    """jobs: [(id, text, prompt_sha)]. Same flags and env as Stage A's run; a rerun skips answered ids."""
    os.makedirs(folder, exist_ok=True)
    claude = claude_path()
    args = args_for(claude, "haiku", cand.HAIKU_BUDGET, cand.SCHEMA)
    env = app_env(claude)
    total, lock, stop = [0.0], threading.Lock(), threading.Event()
    todo = [j for j in jobs if not os.path.exists(os.path.join(folder, j[0] + ".json"))]
    print("to do %d, cap for this step $%.2f" % (len(todo), cap), flush=True)

    def one(job):
        cid, text, prompt_sha = job
        with lock:
            if stop.is_set() or total[0] + 0.06 * workers > cap:
                stop.set()
                return
        for attempt in range(2):
            out = ask(args, text, cwd, timeout=120, env=env)
            with lock:
                total[0] += out.get("total_cost_usd") or 0
            if isinstance(out.get("structured_output"), dict):
                break
        out["_prompt_sha256"] = prompt_sha
        save(os.path.join(folder, cid + ".json"), out)
        with lock:
            print("%s %s $%.4f %.1fs step $%.2f" % (cid, "ok" if isinstance(out.get("structured_output"), dict)
                                                     else "ERROR", out.get("total_cost_usd") or 0, out["_seconds"],
                                                     total[0]), flush=True)

    with ThreadPoolExecutor(workers) as pool:
        list(pool.map(one, todo))
    if stop.is_set():
        print("STOPPED at the cap")
    return total[0]


def budget_for(data, asked):
    left = TOTAL_CAP - spent(data)["total"]
    if left <= 0.05:
        sys.exit("the round's $%.2f cap is used up" % TOTAL_CAP)
    return min(asked, left)


# ---- Stage A, read only ----

def stage_a(data):
    frozen_ok(os.path.join(data, "labels.json"))
    frozen_ok(os.path.join(data, "adjudicated.json"))
    L = load(os.path.join(data, "labels.json"))
    S = load(os.path.join(data, "sample.json"))
    A = load(os.path.join(data, "adjudicated.json"))["items"]
    G = load(os.path.join(data, "gpt-grades.json"))
    cps = {c["id"]: c for c in S["checkpoints"]}
    lab = {c["id"]: c for c in L["checkpoints"]}
    mid = [i for i in L["sample"] if cps[i]["moment"] in MID]
    nobar = {v["checkpoint"] for v in G["answers"].values() if v["answer"] == "no_bar"}
    opens = [i for i in mid if lab[i]["status"] == "open" or i in nobar]
    bounded = [i for i in mid if lab[i]["status"] == "ok" and i not in opens]
    opus = {i: lab[i]["label"] for i in bounded}
    adj = {i: (A[i]["value"] if i in A else lab[i]["label"]) for i in bounded}
    return S, L, cps, lab, mid, bounded, opens, opus, adj


def draft(data):
    cdir = os.path.join(data, "confirm")
    os.makedirs(cdir, exist_ok=True)
    path = os.path.join(cdir, "prereg-draft.json")
    if os.path.exists(path):
        sys.exit("prereg-draft.json already written")
    if os.path.isdir(os.path.join(cdir, "tune")):
        sys.exit("tuning has already started; the decision rule must come first")
    save(path, {"written_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "decision_rule": DECISION,
                "prompts": {k: {"sha256": sha(v)} for k, v in PROMPTS.items()},
                "revision": {"replaces": KIND_OLD, "with": KIND_NEW},
                "why": "Stage A: Haiku called chat-like turns bounded (both open-ended mid-work checkpoints shown). "
                       "The revision gives Haiku the confirmation round's fixed open-ended definition."})
    print(json.dumps({"draft": path, "sha256": freeze_file(path)}))


def tune(data):
    cdir = os.path.join(data, "confirm")
    frozen_ok(os.path.join(cdir, "prereg-draft.json"))
    if os.path.exists(os.path.join(cdir, "prereg.json")):
        sys.exit("prereg.json is frozen; no more tuning")
    S, L, cps, lab, mid, bounded, opens, opus, adj = stage_a(data)
    cap = budget_for(data, arg("--cap", 1.50, float))
    p = PROMPTS["revised"]
    jobs = [(i, text_for(p, cps[i]), sha(p)) for i in mid]
    haiku_batch(jobs, os.path.join(cdir, "tune", "revised"), cap, os.path.join(data, "cwd"))
    summary = tune_summary(data)
    save(os.path.join(cdir, "tune", "summary.json"), summary)
    print(json.dumps(summary, indent=1))


def tune_summary(data):
    cdir = os.path.join(data, "confirm")
    S, L, cps, lab, mid, bounded, opens, opus, adj = stage_a(data)
    out = {"n_mid": len(mid), "n_bounded": len(bounded), "n_open": len(opens)}
    preds = {}
    for name, folder in (("original", os.path.join(data, "candidates", "haiku")),
                         ("revised", os.path.join(cdir, "tune", "revised"))):
        pred = {}
        for i in mid:
            p = os.path.join(folder, i + ".json")
            pred[i] = working(load(p) if os.path.exists(p) else None)
        preds[name] = pred
        m = metrics(pred, bounded, opens, opus)
        m["error_adjudicated"] = metrics(pred, bounded, opens, adj)["error"]
        m["missing"] = sum(1 for i in mid if pred[i].get("missing"))
        out[name] = m
    o, r = out["original"], out["revised"]
    out["newly_hidden_bounded"] = sum(1 for i in bounded if preds["original"][i]["shown"] and not preds["revised"][i]["shown"])
    out["newly_shown_bounded"] = sum(1 for i in bounded if not preds["original"][i]["shown"] and preds["revised"][i]["shown"])
    checks = {"open_not_worse": r["open_shown_n"] <= o["open_shown_n"],
              "coverage_at_least_70": (r["coverage"] or 0) >= 0.70,
              "error_within_0.02": r["error"] is not None and r["error"] <= o["error"] + 0.02,
              "wrong_within_3_points": r["wrong"] is not None and r["wrong"] <= o["wrong"] + 0.03,
              "no_missing_answers": r["missing"] == 0}
    out["decision_checks"] = checks
    out["choice"] = "revised" if all(checks.values()) else "original"
    return out


def prereg(data):
    cdir = os.path.join(data, "confirm")
    draft_sha = frozen_ok(os.path.join(cdir, "prereg-draft.json"))
    path = os.path.join(cdir, "prereg.json")
    if os.path.exists(path):
        sys.exit("prereg.json is already frozen")
    for later in ("sessions.json", "sample.json", "labels.json"):
        if os.path.exists(os.path.join(cdir, later)):
            sys.exit("%s exists: new data was read before the pre-registration" % later)
    summary = tune_summary(data)
    choice = summary["choice"]
    text = PROMPTS[choice]
    labeller = instructions("confirm")
    doc = {
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "round": "Phase 2b confirmation of haiku-working (Stage A untouched)",
        "draft_sha256": draft_sha,
        "variant": {
            "name": "haiku-working",
            "shown_at": list(MID),
            "never_at": ["handback"],
            "opening_request": "counts as new_prompt (the app estimates when any prompt arrives)",
            "fill": "min(tenths / 10, 0.9)",
            "hidden_when": "kind == open_ended, or no structured answer",
            "confidence_threshold": None,
            "hard_rules": "all off: no 0.4 pre-edit cap, no fail-never-raises rule, no plan split",
        },
        "model_call": {
            "cli": ["claude", "-p", "--no-session-persistence", "--model", "haiku", "--output-format", "json",
                    "--json-schema", "<candidates.SCHEMA>", "--setting-sources", "", "--tools", "",
                    "--max-budget-usd", cand.HAIKU_BUDGET],
            "schema_sha256": sha(json.dumps(cand.SCHEMA, sort_keys=True)),
            "env": "label.app_env: nothing inherited; DISABLE_NON_ESSENTIAL_MODEL_CALLS=1",
            "cwd": "DIR/cwd (empty, neutral)",
            "input": "prompt + '\\n--- THE MOMENT ---\\n' + digest (only what existed at that moment)",
        },
        "prompt": {"choice": choice, "sha256": sha(text), "text": text, "decision_rule": DECISION,
                   "tuning_on_stage_a_mid_work": summary},
        "sample": {
            "sessions": "interactive only (claude-vscode, claude-desktop, cli); no session that holds any Stage A "
                        "objective; nothing active in the last 60 minutes",
            "bounded": "about %d objectives with 2+ mid-work moments, stratified like Stage A, up to 3 mid-work "
                       "checkpoints each; target 40-60 bounded mid-work checkpoints after labelling" % N_BOUNDED,
            "open_ended": "turns screened by Opus with the fixed definition (the labeller decides); about %d objectives, "
                          "each with its opening request plus up to 2 mid-work moments; target 15+ open-ended "
                          "mid-work checkpoints after labelling" % N_OPEN,
            "seed": SEED,
        },
        "labeller": {"model": "opus", "definition": KIND_CONFIRM, "prompt_sha256": sha(labeller),
                     "env": "label.app_env", "same_as_stage_a_otherwise": True,
                     "adjudication": "every in-sample checkpoint where label and mechanical cross-check differ by "
                                     "more than 0.3, decided by hand before any candidate runs"},
        "gate": {
            "scope": "new sample, mid-work checkpoints only; bounded metrics leave out opening checkpoints "
                     "(trivially near 0, and Stage A had none); open-ended metrics include them",
            "error": "mean |fill - frozen label| over shown bounded checkpoints <= 0.15 (adjudicated reported too)",
            "confidently_wrong": "share of shown bounded checkpoints off by more than 0.3 <= 10%",
            "coverage": "shown / bounded checkpoints >= 30%",
            "open_ended": "shown on <= 10% of the open-ended checkpoints (objectives the labeller called "
                          "open-ended), with n >= 15; if n < 15 this criterion FAILS",
            "gpt": "blind 24-item GPT subset (mid-work, stratified, 5+ open-ended, no bounded openings): error vs "
                   "GPT's numeric answers <= 0.15 over items it shows, and lower than the best of const, stage and "
                   "plan-file (each over the items it shows)",
            "passes": "all five",
        },
        "baselines": {
            "const": "0.5 everywhere",
            "stage": "median frozen Stage A label per stage, fit on Stage A's mid-work checkpoints only "
                     "(3+ per stage, else their overall median)",
            "planfile": "with an approved plan naming 2+ files: 0.1 + 0.8 x share of those files edited; "
                        "otherwise the stage median",
            "checklist": "done / total for a checklist of 3+ items, else hidden",
        },
    }
    save(path, doc)
    print(json.dumps({"prereg": path, "sha256": freeze_file(path), "prompt": choice, "prompt_sha256": doc["prompt"]["sha256"]}))


# ---- the new sample ----

def mid_moments(s, c):
    turns = s["turns"]
    return [m for m in moments(s["events"], turns[c["ti"]]["i"], turns[c["tj"]]["j"]) if m[1] in MID]


def free(c, chosen, per_session=3):
    same = [x for x in chosen if x["session"] == c["session"]]
    return len(same) < per_session and all(c["tj"] < x["ti"] or c["ti"] > x["tj"] for x in same)


def pick_bounded(pool, rng, n):
    targets = [("checklist", 4), ("long_debug", 5), ("plan", 8), ("failed_checks", 6), ("changed_req", 6),
               ("quick_fix", 4), ("no_plan", 8)]
    rng.shuffle(pool)
    chosen = []
    cap = max(3, int(0.45 * n))

    def ok(c):
        return free(c, chosen) and sum(1 for x in chosen if x["project"] == c["project"]) < cap

    for p in sorted({c["project"] for c in pool}):           # one per project first
        for c in pool:
            if c["project"] == p and ok(c):
                chosen.append(dict(c, group="bounded"))
                break
    for stratum, want in sorted(targets, key=lambda kv: sum(1 for c in pool if kv[0] in c["strata"])):
        have = sum(1 for x in chosen if stratum in x["strata"])
        for c in pool:
            if have >= want or len(chosen) >= n:
                break
            if stratum in c["strata"] and ok(c) and (c["session"], c["ti"]) not in {(x["session"], x["ti"]) for x in chosen}:
                chosen.append(dict(c, group="bounded"))
                have += 1
    for c in pool:
        if len(chosen) >= n:
            break
        if ok(c) and (c["session"], c["ti"]) not in {(x["session"], x["ti"]) for x in chosen}:
            chosen.append(dict(c, group="bounded"))
    return chosen


def open_pool(sessions, chosen, short=False, tiny=False):
    """Turns that might be open-ended. short=True also takes quick ones (under 2 minutes or 6 events, but 3+
    events): questions are often answered fast, and the app would still estimate when the prompt arrives.
    tiny=True (the extend step) also takes requests of 8+ typed characters and turns Claude answered in a
    reply alone: the moment the request arrives, the estimator sees the same thing however long the answer."""
    out = []
    for s in sessions.values():
        turns, events = s["turns"], s["events"]
        for ti, t in enumerate(turns):
            a = events[t["i"]]
            if a["typed"] < (8 if tiny else 25) and a["pasted"] < 300:
                continue
            tj = span_of(s, ti)
            c = {"session": s["id"], "project": s["project"], "ti": ti, "tj": tj}
            if not free(c, [x for x in chosen if x["session"] == s["id"]], per_session=99):
                continue
            f, strata = features(s, ti, tj)
            if tiny:
                if not any(e["k"] == "say" for e in events[t["i"]:turns[tj]["j"] + 1]):
                    continue
            elif f["events"] < 3 or (not short and (f["minutes"] < 2 or f["events"] < 6)):
                continue
            if not (f["edits"] == 0 or QUESTION.search(a["text"][:600])):
                continue
            ev = events[t["i"]:turns[tj]["j"] + 1]
            counts = Counter(e["k"] for e in ev)
            follow = [tidy(events[turns[k]["i"]]["text"], 120) for k in range(ti + 1, tj + 1)][:3]
            out.append(dict(c, f=f, strata=[x for x in strata if x != "open_candidate"] + ["open_candidate"],
                            request=clip(tidy(a["text"], 400), 400), follow=follow,
                            counts="%.0f min, %d turn(s), %d edits, %d reads/searches, %d shell runs, %d narration lines"
                                   % (f["minutes"], f["turns"], f["edits"], counts["read"] + counts["search"],
                                      counts["bash"] + counts["check"], counts["say"])))
    return out


def screen(cdir, pool, rng, cap, want):
    """Batched Opus screen with the fixed definition, cheapest-first (few edits), until enough open-ended turns."""
    path = os.path.join(cdir, "labels", "screen.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    done = load(path) if os.path.exists(path) else {"answers": {}, "cost_usd": 0.0, "batches": 0}
    rng.shuffle(pool)
    pool.sort(key=lambda c: c["f"]["edits"] > 3)
    key = lambda c: "%s:%d" % (c["session"], c["ti"])
    claude = claude_path()
    args = args_for(claude, "opus", "1.00", SCREEN_SCHEMA)
    env = app_env(claude)
    work = os.path.join(os.path.dirname(cdir), "cwd")

    def found():
        return sum(1 for c in pool if done["answers"].get(key(c), {}).get("kind") == "open_ended"
                   and done["answers"][key(c)]["sure"] >= 0.6)

    todo = [c for c in pool if key(c) not in done["answers"]]
    while todo and found() < want and done["cost_usd"] + 0.12 <= cap:
        batch, todo = todo[:40], todo[40:]
        text = SCREEN + "\n\n".join("[%d] REQUEST: %s%s\nWHAT CLAUDE DID: %s" % (
            n + 1, c["request"], "".join("\nFOLLOW-UP: " + x for x in c["follow"]), c["counts"])
            for n, c in enumerate(batch))
        out = ask(args, text, work, env=env)
        done["cost_usd"] += out.get("total_cost_usd") or 0
        done["batches"] += 1
        for it in (out.get("structured_output") or {}).get("items", []):
            if 1 <= it["n"] <= len(batch):
                done["answers"][key(batch[it["n"] - 1])] = {"kind": it["kind"], "sure": it["sure"]}
        save(path, done)
        print("screened %d, open-ended %d, screen cost $%.2f" % (len(done["answers"]), found(), done["cost_usd"]), flush=True)
    return [c for c in pool if done["answers"].get(key(c), {}).get("kind") == "open_ended"
            and done["answers"][key(c)]["sure"] >= 0.6], done


def build_sample(data):
    cdir = os.path.join(data, "confirm")
    frozen_ok(os.path.join(cdir, "prereg.json"))
    if os.path.exists(os.path.join(cdir, "labels.json")):
        sys.exit("labels are frozen; the sample cannot change now")
    stage_a_sessions = {o["session"] for o in load(os.path.join(data, "sample.json"))["objectives"]}
    index = load(os.path.join(cdir, "sessions.json"))
    sessions = {}
    for x in index:
        if x["id"] not in stage_a_sessions:
            sessions[x["id"]] = load(os.path.join(cdir, "sessions", x["id"] + ".json"))
    rng = random.Random(SEED)
    pool = [c for c in span_pool(sessions.values()) if "open_candidate" not in c["strata"]]
    pool = [c for c in pool if len(mid_moments(sessions[c["session"]], c)) >= 2]
    chosen = pick_bounded(pool, rng, N_BOUNDED)
    short = "--open-short" in sys.argv
    opens, scr = screen(cdir, open_pool(sessions, chosen, short), rng, arg("--screen-cap", 0.60, float), 2 * N_OPEN)
    rng.shuffle(opens)
    by_project = defaultdict(list)
    for c in opens:
        by_project[c["project"]].append(c)
    picked = 0
    while picked < N_OPEN and any(by_project.values()):
        for p in sorted(by_project):
            while by_project[p]:
                c = by_project[p].pop()
                if sum(1 for x in chosen if x["session"] == c["session"] and x["group"] == "open") < 3 and free(c, chosen):
                    chosen.append(dict({k: v for k, v in c.items() if k not in ("request", "follow", "counts")}, group="open"))
                    picked += 1
                    break
            if picked >= N_OPEN:
                break
    objectives, checkpoints = [], []
    for n, c in enumerate(sorted(chosen, key=lambda c: (c["group"], c["project"], c["session"], c["ti"]))):
        s = sessions[c["session"]]
        built = build_objective(cdir, s, c, "C%02d" % (n + 1), rng, n=3, allowed=MID, opening=c["group"] == "open")
        if built:
            objectives.append(built[0])
            checkpoints += built[1]
    save(os.path.join(cdir, "sample.json"), {
        "seed": SEED, "objectives": objectives, "checkpoints": checkpoints,
        "excluded_stage_a_sessions": len(stage_a_sessions & {x["id"] for x in index}),
        "screen": {"pool": len(open_pool(sessions, chosen, short)), "short_turns_allowed": short,
                   "screened": len(scr["answers"]),
                   "open_found": len(opens), "cost_usd": round(scr["cost_usd"], 4)}})
    print(json.dumps({"sessions_available": len(sessions), "bounded_pool": len(pool),
                      "objectives": Counter(o["group"] for o in objectives),
                      "checkpoints": len(checkpoints), "moments": Counter(c["moment"] for c in checkpoints),
                      "openings": sum(1 for c in checkpoints if c["index"] == next(o for o in objectives if o["id"] == c["objective"])["i0"]),
                      "projects": len({o["project"] for o in objectives}), "sessions": len({o["session"] for o in objectives}),
                      "screen_cost_usd": round(scr["cost_usd"], 2)}, default=str))


def extend(data):
    """Add open-ended objectives to an unfrozen sample when the first build found too few: screen the wider
    pool (open_pool tiny=True), then append what the screen calls open-ended, with new ids, leaving every
    existing objective, checkpoint and raw label exactly as it is."""
    cdir = os.path.join(data, "confirm")
    frozen_ok(os.path.join(cdir, "prereg.json"))
    if os.path.exists(os.path.join(cdir, "labels.json")):
        sys.exit("labels are frozen; the sample cannot change now")
    S = load(os.path.join(cdir, "sample.json"))
    stage_a_sessions = {o["session"] for o in load(os.path.join(data, "sample.json"))["objectives"]}
    sessions = {x["id"]: load(os.path.join(cdir, "sessions", x["id"] + ".json"))
                for x in load(os.path.join(cdir, "sessions.json")) if x["id"] not in stage_a_sessions}
    chosen = [{"session": o["session"], "ti": o["ti"], "tj": o["tj"], "group": o["group"]} for o in S["objectives"]]
    rng = random.Random(SEED + 1)
    pool = open_pool(sessions, chosen, tiny=True)
    prev = load(os.path.join(cdir, "labels", "screen.json"))["cost_usd"]
    want = arg("--want", 14, int)
    opens, scr = screen(cdir, pool, rng, prev + arg("--screen-cap", 0.15, float), 99)
    rng.shuffle(opens)
    by_project = defaultdict(list)
    for c in opens:
        by_project[c["project"]].append(c)
    added = []
    while len(added) < want and any(by_project.values()):
        for p in sorted(by_project):
            while by_project[p]:
                c = by_project[p].pop()
                if sum(1 for x in chosen if x["session"] == c["session"] and x["group"] == "open") < 3 \
                        and free(c, chosen, per_session=99):
                    chosen.append(dict({k: v for k, v in c.items() if k not in ("request", "follow", "counts")}, group="open"))
                    added.append(chosen[-1])
                    break
            if len(added) >= want:
                break
    first = max(int(o["id"][1:]) for o in S["objectives"]) + 1
    new_objs, new_cps = [], []
    for n, c in enumerate(sorted(added, key=lambda c: (c["project"], c["session"], c["ti"]))):
        built = build_objective(cdir, sessions[c["session"]], c, "C%02d" % (first + n), rng, n=3, allowed=MID, opening=True)
        if built:
            new_objs.append(built[0])
            new_cps += built[1]
    S["objectives"] += new_objs
    S["checkpoints"] += new_cps
    S.setdefault("extended", []).append({"pool": len(pool), "screened_total": len(scr["answers"]),
                                         "screen_cost_usd": round(scr["cost_usd"] - prev, 4),
                                         "added": [o["id"] for o in new_objs], "checkpoints": len(new_cps)})
    save(os.path.join(cdir, "sample.json"), S)
    print(json.dumps({"pool": len(pool), "open_found_unused": len(opens), "added": len(new_objs),
                      "checkpoints": len(new_cps), "reply_only": sum(1 for o in new_objs if o["f"]["events"] < 3),
                      "projects": Counter(o["project"] for o in new_objs),
                      "screen_cost_usd": round(scr["cost_usd"] - prev, 4)}, default=str))


# ---- after the labels ----

def frozen_round(data):
    cdir = os.path.join(data, "confirm")
    pre = load(os.path.join(cdir, "prereg.json"))
    out = {"prereg_sha256": frozen_ok(os.path.join(cdir, "prereg.json")),
           "labels_sha256": frozen_ok(os.path.join(cdir, "labels.json")),
           "adjudicated_sha256": frozen_ok(os.path.join(cdir, "adjudicated.json"))}
    L = load(os.path.join(cdir, "labels.json"))
    A = load(os.path.join(cdir, "adjudicated.json"))
    if A["labels_sha256"] != out["labels_sha256"]:
        sys.exit("adjudicated.json was made against other labels")
    if L.get("labeller_prompt_sha256") != pre["labeller"]["prompt_sha256"]:
        sys.exit("the labels were not made with the pre-registered labeller prompt")
    S = load(os.path.join(cdir, "sample.json"))
    return cdir, pre, L, A, S, out


def seal(data):
    cdir = os.path.join(data, "confirm")
    labels_sha = frozen_ok(os.path.join(cdir, "labels.json"))
    path = os.path.join(cdir, "adjudicated.json")
    if os.path.exists(path + ".sha256"):
        sys.exit("adjudicated.json is already sealed")
    if os.path.isdir(os.path.join(cdir, "candidates")):
        sys.exit("candidates have already run")
    A = load(path)
    L = load(os.path.join(cdir, "labels.json"))
    if A["labels_sha256"] != labels_sha:
        sys.exit("adjudicated.json names other labels")
    missing = [i for i in L["adjudicate"] if i not in A["items"]]
    if missing:
        sys.exit("not adjudicated yet: %s" % ", ".join(missing))
    print(json.dumps({"adjudicated": len(A["items"]), "sha256": freeze_file(path)}))


def stage_a_medians(data):
    S, L, cps, lab, mid, bounded, opens, opus, adj = stage_a(data)
    rows = [(cps[i]["facts"]["stage"], lab[i]["label"]) for i in bounded]
    return cand.stage_medians(rows)


def rule_preds(cps, ids, medians):
    by_stage, overall = medians
    out = {"const": {}, "stage": {}, "planfile": {}, "checklist": {}}
    for i in ids:
        f = cps[i]["facts"]
        median = by_stage.get(f["stage"], overall)
        out["const"][i] = {"shown": True, "fill": 0.5}
        out["stage"][i] = {"shown": True, "fill": median}
        if f["plan"] and f["plan_files"] >= 2:
            out["planfile"][i] = {"shown": True, "fill": 0.1 + 0.8 * f["plan_files_edited"] / f["plan_files"]}
        else:
            out["planfile"][i] = {"shown": True, "fill": median}
        out["checklist"][i] = ({"shown": True, "fill": f["checklist_done"] / f["checklist_total"]}
                               if f["checklist_total"] >= 3 else {"shown": False})
    return out


def run(data):
    cdir, pre, L, A, S, hashes = frozen_round(data)
    text = pre["prompt"]["text"]
    if sha(text) != pre["prompt"]["sha256"]:
        sys.exit("the pre-registered prompt text does not match its hash")
    cps = {c["id"]: c for c in S["checkpoints"]}
    ids = list(L["sample"])
    medians = stage_a_medians(data)
    os.makedirs(os.path.join(cdir, "candidates", "haiku"), exist_ok=True)
    save(os.path.join(cdir, "candidates", "rules.json"),
         {"stage_medians": {"by_stage": medians[0], "overall": medians[1]}, "candidates": rule_preds(cps, ids, medians)})
    cap = budget_for(data, arg("--cap", 3.00, float))
    jobs = [(i, text_for(text, cps[i]), pre["prompt"]["sha256"]) for i in ids]
    haiku_batch(jobs, os.path.join(cdir, "candidates", "haiku"), cap, os.path.join(data, "cwd"))
    print(json.dumps(spent(data)))


def scores(data):
    cdir, pre, L, A, S, hashes = frozen_round(data)
    cps = {c["id"]: c for c in S["checkpoints"]}
    objs = {o["id"]: o for o in S["objectives"]}
    lab = {c["id"]: c for c in L["checkpoints"]}
    ids = list(L["sample"])
    opening = {i for i in ids if cps[i]["index"] == objs[cps[i]["objective"]]["i0"]}
    bounded_all = [i for i in ids if lab[i]["status"] == "ok"]
    bounded = [i for i in bounded_all if i not in opening]
    opens = [i for i in ids if lab[i]["status"] == "open"]
    opus = {i: lab[i]["label"] for i in bounded_all}
    adj = {i: (A["items"][i]["value"] if i in A["items"] else lab[i]["label"]) for i in bounded_all}
    rules = load(os.path.join(cdir, "candidates", "rules.json"))["candidates"]
    folder = os.path.join(cdir, "candidates", "haiku")
    answers = {}
    for i in ids:
        p = os.path.join(folder, i + ".json")
        if os.path.exists(p):
            a = load(p)
            if a.get("_prompt_sha256") != pre["prompt"]["sha256"]:
                sys.exit("%s was answered with another prompt" % i)
            answers[i] = a
    preds = {"haiku-working": {i: working(answers.get(i)) for i in ids}}
    for k in ("const", "stage", "planfile", "checklist"):
        preds["rule: " + k] = rules[k]
    table = {}
    for name, p in preds.items():
        m = metrics(p, bounded, opens, opus)
        m["error_adjudicated"] = metrics(p, bounded, opens, adj)["error"]
        m["wrong_adjudicated"] = metrics(p, bounded, opens, adj)["wrong"]
        m["with_openings"] = metrics(p, bounded_all, opens, opus)
        m["open_without_openings"] = metrics(p, bounded, [i for i in opens if i not in opening], opus)
        m["by_moment"] = {mo: metrics(p, [i for i in bounded if cps[i]["moment"] == mo], [], opus)
                          for mo in MID if any(cps[i]["moment"] == mo for i in bounded)}
        table[name] = m
    # GPT's blind subset, once its grades are in
    gpt = None
    gp, kp = os.path.join(cdir, "gpt-grades.json"), os.path.join(cdir, "grading", "key.json")
    if os.path.exists(gp) and os.path.exists(kp):
        g = {v["checkpoint"]: v["answer"] for v in load(gp)["answers"].values()}
        numeric = {i: float(a) for i, a in g.items() if a != "no_bar"}
        gpt = {"graded": len(g), "no_bar": sum(1 for a in g.values() if a == "no_bar"), "by": {}}
        for name, p in preds.items():
            items = [i for i in numeric if p[i]["shown"]]
            gpt["by"][name] = {"n": len(items), "error": mean(abs(p[i]["fill"] - numeric[i]) for i in items)}
        best = min((gpt["by"]["rule: " + r]["error"], r) for r in FULL_RULES if gpt["by"]["rule: " + r]["error"] is not None)
        gpt["best_rule"] = {"rule": best[1], "error": best[0]}
        gpt["gap_to_opus"] = mean(abs(numeric[i] - opus[i]) for i in numeric if i in opus)
        gpt["gap_to_adjudicated"] = mean(abs(numeric[i] - adj[i]) for i in numeric if i in adj)
        gpt["no_bar_on_opus_open"] = sum(1 for i, a in g.items() if a == "no_bar" and i in opens)
        gpt["opus_open_graded"] = sum(1 for i in g if i in opens)
    h = table["haiku-working"]
    gate = {"error": h["error"] is not None and h["error"] <= GATE["error"],
            "wrong": h["wrong"] is not None and h["wrong"] <= GATE["wrong"],
            "coverage": (h["coverage"] or 0) >= GATE["coverage"],
            "open_ended": len(opens) >= GATE["open_n"] and h["open_shown"] is not None and h["open_shown"] <= GATE["open_shown"],
            "gpt": None if gpt is None else (gpt["by"]["haiku-working"]["error"] is not None
                                             and gpt["by"]["haiku-working"]["error"] <= GATE["gpt_error"]
                                             and gpt["by"]["haiku-working"]["error"] < gpt["best_rule"]["error"])}
    gate["passes"] = False if False in gate.values() else (None if None in gate.values() else True)
    lat = [a["_seconds"] for a in answers.values() if a.get("_seconds")]
    cost = [a.get("total_cost_usd") or 0 for a in answers.values()]
    result = {"hashes": hashes, "prompt": pre["prompt"]["choice"],
              "counts": {"checkpoints": len(ids), "bounded_mid": len(bounded), "bounded_openings": len(bounded_all) - len(bounded),
                         "open_mid": len(opens), "open_openings": sum(1 for i in opens if i in opening),
                         "bounded_objectives": len({cps[i]["objective"] for i in bounded}),
                         "open_objectives": len({cps[i]["objective"] for i in opens}),
                         "sessions": len({objs[cps[i]["objective"]]["session"] for i in ids}),
                         "projects": len({objs[cps[i]["objective"]]["project"] for i in ids}),
                         "answered": len(answers), "missing": sum(1 for i in ids if preds["haiku-working"][i].get("missing"))},
              "table": table, "gpt": gpt, "gate": gate,
              "haiku_cost": {"calls": len(answers), "total": round(sum(cost), 4), "per_call": round(mean(cost) or 0, 4),
                             "median_s": statistics.median(lat) if lat else None},
              "spend": spent(data)}
    save(os.path.join(cdir, "scores.json"), result)
    print(markdown(result))


def markdown(r):
    f2 = lambda x: "–" if x is None else "%.3f" % x
    pc = lambda x: "–" if x is None else "%.0f%%" % (100 * x)
    yn = {True: "yes", False: "NO", None: "pending"}
    c = r["counts"]
    L = ["Checkpoints %d: bounded mid-work %d (from %d objectives; %d bounded openings kept apart), open-ended "
         "mid-work %d (from %d objectives; %d of them openings); %d sessions, %d projects. Haiku answered %d, missing %d."
         % (c["checkpoints"], c["bounded_mid"], c["bounded_objectives"], c["bounded_openings"], c["open_mid"],
            c["open_objectives"], c["open_openings"], c["sessions"], c["projects"], c["answered"], c["missing"]), "",
         "| candidate | error | error (adjudicated) | coverage | confidently wrong | open-ended shown |",
         "|---|---|---|---|---|---|"]
    for name, m in r["table"].items():
        L.append("| %s | %s | %s | %s (%d/%d) | %s | %s (%d/%d) |" % (
            name, f2(m["error"]), f2(m["error_adjudicated"]), pc(m["coverage"]), m["shown"], m["n"], pc(m["wrong"]),
            pc(m["open_shown"]), m["open_shown_n"], m["open_n"]))
    g = r["gate"]
    L += ["", "| gate | error <= 0.15 | wrong <= 10% | coverage >= 30% | open-ended shown <= 10%, n >= 15 | GPT subset | passes |",
          "|---|---|---|---|---|---|---|",
          "| haiku-working | %s | %s | %s | %s | %s | %s |" % tuple(yn[g[k]] for k in ("error", "wrong", "coverage", "open_ended", "gpt", "passes"))]
    h = r["table"]["haiku-working"]
    L += ["", "Secondary: with bounded openings error %s, coverage %s; open-ended shown without openings %s (%d/%d)."
          % (f2(h["with_openings"]["error"]), pc(h["with_openings"]["coverage"]), pc(h["open_without_openings"]["open_shown"]),
             h["open_without_openings"]["open_shown_n"], h["open_without_openings"]["open_n"]),
          "By moment (haiku-working): " + "; ".join("%s n=%d err %s cov %s" % (k, v["n"], f2(v["error"]), pc(v["coverage"]))
                                                   for k, v in h["by_moment"].items()),
          "Haiku: %d calls, $%.4f per call, $%.2f total, median %ss." % (r["haiku_cost"]["calls"], r["haiku_cost"]["per_call"],
                                                                       r["haiku_cost"]["total"], r["haiku_cost"]["median_s"]),
          "Spend this round: " + json.dumps(r["spend"])]
    if r["gpt"]:
        x = r["gpt"]
        L.append("GPT: %d graded, %d no_bar (%d of %d on labeller-open items); gap to Opus %s, to adjudicated %s; "
                 "haiku-working vs GPT %s on %d; best rule %s %s." % (
                     x["graded"], x["no_bar"], x["no_bar_on_opus_open"], x["opus_open_graded"], f2(x["gap_to_opus"]),
                     f2(x["gap_to_adjudicated"]), f2(x["by"]["haiku-working"]["error"]), x["by"]["haiku-working"]["n"],
                     x["best_rule"]["rule"], f2(x["best_rule"]["error"])))
    return "\n".join(L)


def grading(data):
    """24 blind items for GPT: mid-work, stratified, 5+ open-ended, no bounded openings."""
    cdir, pre, L, A, S, hashes = frozen_round(data)
    out_dir, export = arg("--out"), arg("--export")     # both or neither: without them only the subset is built
    if bool(out_dir) != bool(export):
        sys.exit("give both --out OUT_DIR and --export path/to/export_gpt.py, or neither")
    cps = {c["id"]: c for c in S["checkpoints"]}
    objs = {o["id"]: o for o in S["objectives"]}
    lab = {c["id"]: c for c in L["checkpoints"]}
    ids = list(L["sample"])
    is_opening = lambda i: cps[i]["index"] == objs[cps[i]["objective"]]["i0"]
    rng = random.Random(SEED + 24)
    opens = [i for i in ids if lab[i]["status"] == "open"]
    bounded = [i for i in ids if lab[i]["status"] == "ok" and not is_opening(i)]
    rng.shuffle(opens)
    rng.shuffle(bounded)
    picked, used, projects, moms = [], set(), Counter(), Counter()

    def take(i):
        picked.append(i)
        used.add(cps[i]["objective"])
        projects[objs[cps[i]["objective"]]["project"]] += 1
        moms[cps[i]["moment"]] += 1

    n_open = min(6, len({cps[i]["objective"] for i in opens}))
    for i in opens:                                                     # one per objective, project cap 3
        if len(picked) >= n_open:
            break
        if cps[i]["objective"] not in used and projects[objs[cps[i]["objective"]]["project"]] < 3:
            take(i)
    for i in opens:                                                     # project cap relaxed if short
        if len(picked) >= max(5, n_open):
            break
        if cps[i]["objective"] not in used:
            take(i)
    cap = max(3, int(0.45 * (24 - len(picked))))
    for stratum, quota in grade.QUOTAS:
        got = 0
        pool = sorted([i for i in bounded if stratum in objs[cps[i]["objective"]]["strata"]], key=lambda i: moms[cps[i]["moment"]])
        for i in pool:
            if got >= quota or len(picked) >= 24:
                break
            if cps[i]["objective"] not in used and projects[objs[cps[i]["objective"]]["project"]] < cap:
                take(i)
                got += 1
    for relax in (False, True):
        for i in sorted(bounded, key=lambda i: moms[cps[i]["moment"]]):
            if len(picked) >= 24:
                break
            if i not in picked and (cps[i]["objective"] not in used or relax) and (relax or projects[objs[cps[i]["objective"]]["project"]] < cap):
                take(i)
    rng.shuffle(picked)
    grade.MOMENT["opening"] = "you had just sent the request; Claude was starting"
    sessions, items, key = {}, [], {}
    for k, cid in enumerate(picked, 1):
        cp = dict(cps[cid])
        if is_opening(cid):
            cp["moment"] = "opening"
        obj = objs[cp["objective"]]
        if obj["session"] not in sessions:
            sessions[obj["session"]] = load(os.path.join(cdir, "sessions", obj["session"] + ".json"))
        item = grade.item_for(sessions[obj["session"]], obj, cp, k)
        items.append(item)
        key[item["item"]] = cid
    os.makedirs(os.path.join(cdir, "grading"), exist_ok=True)
    save(os.path.join(cdir, "grading", "items.json"), items)
    save(os.path.join(cdir, "grading", "key.json"), key)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        subprocess.run([sys.executable, "-I", export, cdir, out_dir], check=True)
    print(json.dumps({"items": len(items), "open_ended": sum(1 for i in picked if lab[i]["status"] == "open"),
                      "open_openings": sum(1 for i in picked if lab[i]["status"] == "open" and is_opening(i)),
                      "moments": Counter(cps[i]["moment"] for i in picked),
                      "objectives": len({cps[i]["objective"] for i in picked}),
                      "projects": len({objs[cps[i]["objective"]]["project"] for i in picked}), "out": out_dir}, default=str))


if __name__ == "__main__":
    d = data_dir()
    steps = {"draft": draft, "tune": tune, "prereg": prereg, "sample": build_sample, "extend": extend, "seal": seal, "run": run,
             "score": scores, "grading": grading, "spend": lambda d: print(json.dumps(spent(d), indent=1))}
    if len(sys.argv) > 1 and sys.argv[1] in steps:
        steps[sys.argv[1]](d)
    else:
        sys.exit(__doc__)
