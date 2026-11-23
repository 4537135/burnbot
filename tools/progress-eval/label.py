"""Stage A, step 3: hindsight labels, the mechanical cross-check, and the freeze.

    python3 -I tools/progress-eval/label.py run    --data DIR [--only O01,O02] [--workers 3]
                                                   [--definition confirm] [--app-env] [--cap USD]
    python3 -I tools/progress-eval/label.py freeze --data DIR

run: one `claude -p --model opus` per objective, with the flags app/Summaries.swift uses
     (--no-session-persistence, --output-format json, --json-schema, no tools, no setting
     sources, a budget cap), run from DIR so no project's CLAUDE.md comes along. With
     --no-session-persistence nothing is written to ~/.claude/projects, which Burnbot tracks.
     The labeller sees the whole window with hindsight and never sees a candidate's output.
     Raw answers land in DIR/labels/raw/<objective>.json; a rerun skips the ones already there.
freeze: adds the mechanical cross-check (share of the objective's edits and checks done by
     each checkpoint), lists disagreements over 0.3, picks the final sample and writes
     DIR/labels.json read-only, with its sha256 beside it. Candidates must not run before this.
"""

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import data_dir, load, save
from sample import verifying

MODEL = "opus"
BUDGET = "1.50"
TIMEOUT = 600

SCHEMA = {
    "type": "object",
    "properties": {
        "objective": {"type": "string", "maxLength": 200},
        "new_objective": {"type": "boolean"},
        "kind": {"type": "string", "enum": ["bounded", "open_ended"]},
        "end_turn": {"type": "integer", "minimum": 0, "maximum": 99},
        "finished": {"type": "boolean"},
        "unfinished_reason": {"type": "string", "enum": ["none", "log_ends", "window_cut", "abandoned"]},
        "milestones": {"type": "array", "items": {"type": "string", "maxLength": 120}, "maxItems": 10},
        "checkpoints": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "in_objective": {"type": "boolean"},
                    "milestones_reached": {"type": "integer", "minimum": 0, "maximum": 10},
                    "progress_tenths": {"type": "integer", "minimum": -1, "maximum": 10},
                    "why": {"type": "string", "maxLength": 200},
                },
                "required": ["id", "in_objective", "milestones_reached", "progress_tenths", "why"],
                "additionalProperties": False,
            },
        },
        "ambiguous": {"type": "boolean"},
        "notes": {"type": "string", "maxLength": 400},
    },
    "required": ["objective", "new_objective", "kind", "end_turn", "finished", "unfinished_reason", "milestones",
                 "checkpoints", "ambiguous", "notes"],
    "additionalProperties": False,
}

INSTRUCTIONS = """You are setting ground-truth labels for an evaluation of a progress bar. Below is a window from a real Claude Code session: the person's prompts (YOU [T1], YOU [T2], ...), Claude's narration, compact tool actions, and checkpoint markers (>>> CHECKPOINT CPn <<<). You see the whole window with hindsight. Read all of it before answering.

1. objective: in a few words, what the person asked for at T1.
   new_objective: true if T1 starts a new objective; false if T1 only continues or fixes up work that began before the window (use the earlier prompts listed for context).

2. kind:
   - bounded: a deliverable whose completion can be recognised (fix this, build that, write this, ship that). A bounded task with some investigation in it is still bounded.
   - open_ended: no finish line knowable in advance (exploration, brainstorming, open research, "look around and tell me", conversation, iteration with no completion criteria). For these the right progress bar is "no bar".

3. Where the objective really ends. It ends where the objective was achieved, not where a turn ended: Claude hands back, and the person's next message moves on (a new task, asking to commit or push, thanks) instead of asking for fixes or changes to the same thing. If the person asks for fixes or changes to the same deliverable, the objective runs on through that work.
   - end_turn: the turn number (the n in Tn) in which the objective was achieved. If it never was within the window, the last turn that worked on it.
   - finished: true only if the objective was achieved within the window.
   - unfinished_reason: "none" if finished; "log_ends" if the session log ends with it unfinished; "window_cut" if the log continues past the window and the work is still going on at the window's end; "abandoned" if the person dropped it.

4. milestones: the objective's milestones as it was eventually done, in order, 2 to 8 of them, for example: understood the problem, each part built, checked, failures fixed, verified.

5. For every checkpoint marker, in order:
   - in_objective: false if the checkpoint falls after the objective ended (or before it began).
   - milestones_reached: how many of your milestones were reached at that moment.
   - progress_tenths: how much of the objective's work, as it was eventually done, had been done at that moment, in tenths (0 to 10). Judge by milestones reached, never by elapsed time or by how many tool calls happened. 10 only if the objective was complete and verified at that moment. Work that was later redone or thrown away does not count as progress. Use -1 for open-ended objectives and for checkpoints outside the objective.
   - why: one short reason.

6. ambiguous: true if the objective or its end is genuinely unclear. notes: anything an adjudicator should know, briefly.

Answer only through the structured output.

--- SESSION WINDOW ---
"""


KIND_STAGE_A = """2. kind:
   - bounded: a deliverable whose completion can be recognised (fix this, build that, write this, ship that). A bounded task with some investigation in it is still bounded.
   - open_ended: no finish line knowable in advance (exploration, brainstorming, open research, \"look around and tell me\", conversation, iteration with no completion criteria). For these the right progress bar is \"no bar\".
"""
# The confirmation round (Phase 2b) fixes open-ended to this definition, word for word from the brief.
KIND_CONFIRM = """2. kind:
   - open_ended: no deliverable the user could tick off at the end: questions, advice, comparing options, brainstorming, review or explanation without a requested change. For these the right progress bar is \"no bar\". Judge by what the person asked for at T1; if a later prompt in the window asks for a change, the open-ended objective ends at the turn before that prompt.
   - bounded: everything else: the person asked for a change or a deliverable they could tick off (fix this, build that, write this, ship that). A bounded task with some investigation in it is still bounded.
"""


def instructions(definition):
    if definition == "confirm":
        return INSTRUCTIONS.replace(KIND_STAGE_A, KIND_CONFIRM)
    return INSTRUCTIONS


def app_env(claude):
    """The environment a Mac app hands `claude`: nothing inherited from the shell or editor this
    runs in (no API proxy, effort override, or parent session). DISABLE_NON_ESSENTIAL_MODEL_CALLS
    drops the CLI's own Sonnet side call, which otherwise costs about twice the Haiku answer."""
    return {"PATH": os.path.dirname(claude) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": os.path.expanduser("~"), "USER": os.environ.get("USER", ""),
            "LOGNAME": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "LANG": "en_US.UTF-8", "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1"}


def claude_path():
    path = shutil.which("claude")
    if not path:
        sys.exit("no claude command found")
    return path


def flags(path):
    out = subprocess.run([path, "--help"], capture_output=True, text=True, timeout=60).stdout
    return out


def args_for(path, model, budget, schema):
    """The same flags app/Summaries.swift passes, for the model given."""
    help_text = flags(path)
    if "--json-schema" not in help_text or "--no-session-persistence" not in help_text:
        sys.exit("this claude has no --json-schema / --no-session-persistence")
    args = [path, "-p", "--no-session-persistence", "--model", model, "--output-format", "json", "--json-schema", json.dumps(schema)]
    if "--bare" in help_text:
        args.append("--bare")
    elif "--setting-sources" in help_text:
        args += ["--setting-sources", ""]
    if "--tools" in help_text:
        args += ["--tools", ""]
    if "--max-budget-usd" in help_text:
        args += ["--max-budget-usd", budget]
    return args


def ask(args, text, cwd, timeout=TIMEOUT, env=None):
    # env=None inherits this shell's environment; that is how the frozen labels were made.
    started = time.time()
    p = subprocess.run(args, input=text, capture_output=True, text=True, cwd=cwd, timeout=timeout, env=env)
    took = time.time() - started
    try:
        out = json.loads(p.stdout)
    except ValueError:
        out = {"is_error": True, "raw": p.stdout[-2000:], "stderr": p.stderr[-2000:]}
    out["_seconds"] = round(took, 1)
    out["_exit"] = p.returncode
    return out


def run(data):
    sample = load(os.path.join(data, "sample.json"))
    raw_dir = os.path.join(data, "labels", "raw")
    os.makedirs(raw_dir, exist_ok=True)
    work = os.path.join(data, "cwd")          # a neutral, empty working folder
    os.makedirs(work, exist_ok=True)
    claude = claude_path()
    args = args_for(claude, MODEL, BUDGET, SCHEMA)
    argv = sys.argv
    only = set(argv[argv.index("--only") + 1].split(",")) if "--only" in argv else None
    workers = int(argv[argv.index("--workers") + 1]) if "--workers" in argv else 3
    definition = argv[argv.index("--definition") + 1] if "--definition" in argv else "stage-a"
    prompt = instructions(definition)
    prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
    env = app_env(claude) if "--app-env" in argv else None   # env=None: how the Stage A labels were made
    cap = float(argv[argv.index("--cap") + 1]) if "--cap" in argv else None
    todo = [o for o in sample["objectives"] if (only is None or o["id"] in only)
            and not os.path.exists(os.path.join(raw_dir, o["id"] + ".json"))]
    spent, stop, lock = [0.0], threading.Event(), threading.Lock()

    def one(o):
        if stop.is_set():
            return o["id"], None, None, None, None, "skipped: cap"
        with lock:
            if cap is not None and spent[0] + 0.15 * workers > cap:
                stop.set()
                return o["id"], None, None, None, None, "skipped: cap"
        with open(os.path.join(data, "views", o["id"] + ".txt")) as f:
            view = f.read()
        ids = ", ".join(c.split("-")[1] for c in o["checkpoints"])
        text = prompt + view + "\n--- END ---\nCheckpoints to label, in order: " + ids + "\n"
        for attempt in range(2):
            out = ask(args, text, work, env=env)
            with lock:
                spent[0] += out.get("total_cost_usd") or 0
            if not out.get("is_error") and isinstance(out.get("structured_output"), dict):
                break
        out["_definition"], out["_prompt_sha256"], out["_app_env"] = definition, prompt_sha, env is not None
        save(os.path.join(raw_dir, o["id"] + ".json"), out)
        s = out.get("structured_output") or {}
        return o["id"], out.get("total_cost_usd"), out.get("_seconds"), s.get("kind"), s.get("finished"), out.get("is_error")

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for r in pool.map(one, todo):
            print(*r, flush=True)
    total = 0.0
    for o in sample["objectives"]:
        p = os.path.join(raw_dir, o["id"] + ".json")
        if os.path.exists(p):
            total += load(p).get("total_cost_usd") or 0
    print("labelled cost so far: $%.2f" % total)


def mechanical(session, obj, end_turn):
    """Share of the objective's edits and checks done by each checkpoint (None when it has none)."""
    events, turns = session["events"], session["turns"]
    last_turn = min(obj["ti"] + max(end_turn, 1) - 1, len(turns) - 1)
    i0, i1 = obj["i0"], turns[last_turn]["j"]
    units = [i for i in range(i0, i1 + 1) if events[i]["k"] == "edit" or verifying(events[i])]
    return i1, units


def freeze(data):
    sample = load(os.path.join(data, "sample.json"))
    raw_dir = os.path.join(data, "labels", "raw")
    out_path = os.path.join(data, "labels.json")
    if os.path.exists(out_path):
        sys.exit("labels.json is already frozen; delete it by hand only if no candidate has run")
    cps = {c["id"]: c for c in sample["checkpoints"]}
    sessions = {}
    objectives, labels, cost, seconds, missing = {}, [], 0.0, [], []
    models, prompts = {}, set()
    for o in sample["objectives"]:
        p = os.path.join(raw_dir, o["id"] + ".json")
        if not os.path.exists(p):
            missing.append(o["id"])
            continue
        raw = load(p)
        cost += raw.get("total_cost_usd") or 0
        seconds.append(raw.get("_seconds") or 0)
        for m, u in (raw.get("modelUsage") or {}).items():
            models[m] = models.get(m, 0) + (u.get("costUSD") or 0)
        s = raw.get("structured_output")
        if not isinstance(s, dict):
            missing.append(o["id"])
            continue
        prompts.add((raw.get("_definition", "stage-a"), raw.get("_prompt_sha256"), raw.get("_app_env", False)))
        if o["session"] not in sessions:
            sessions[o["session"]] = load(os.path.join(data, "sessions", o["session"] + ".json"))
        session = sessions[o["session"]]
        end_turn = s["end_turn"]
        i_end, units = mechanical(session, o, end_turn)
        by_id = {x["id"].strip().upper(): x for x in s["checkpoints"]}
        dropped_reason = None
        if not s["new_objective"]:
            dropped_reason = "not_new"
        elif s["ambiguous"] and s["kind"] != "open_ended":
            dropped_reason = "ambiguous"       # an open-ended turn's answer is "no bar" whatever its end
        objectives[o["id"]] = {"kind": s["kind"], "new_objective": s["new_objective"], "finished": s["finished"],
                               "unfinished_reason": s["unfinished_reason"], "end_turn": end_turn, "ambiguous": s["ambiguous"],
                               "milestones": s["milestones"], "dropped": dropped_reason, "group": o["group"],
                               "strata": o["strata"], "project": o["project"], "session": o["session"]}
        for cid in o["checkpoints"]:
            c = cps[cid]
            x = by_id.get(c["cp"])
            if x is None:
                labels.append({"id": cid, "objective": o["id"], "status": "no_label"})
                continue
            inside = x["in_objective"] and c["index"] <= i_end
            mech = None
            if units and inside:
                mech = round(sum(1 for i in units if i <= c["index"]) / len(units), 3)
            label = x["progress_tenths"] / 10 if x["progress_tenths"] >= 0 else None
            status = "ok"
            if dropped_reason:
                status = dropped_reason
            elif not inside:
                status = "outside"
            elif s["kind"] == "open_ended":
                status = "open"
            elif not s["finished"]:
                status = "unfinished"
            elif label is None:
                status = "no_label"
            labels.append({"id": cid, "objective": o["id"], "moment": c["moment"], "status": status, "kind": s["kind"],
                           "label": label, "milestones_reached": x["milestones_reached"], "mechanical": mech,
                           "gap": round(abs(label - mech), 3) if (label is not None and mech is not None) else None,
                           "why": x["why"]})
    # the final sample: every usable checkpoint. Open-ended turns turned out rare, so all their in-objective
    # checkpoints count (the report gives the open-ended numbers per objective too, since they are correlated).
    final = []
    for oid in sorted(objectives):
        for l in labels:
            if l["objective"] == oid and l["status"] in ("ok", "open"):
                l["in_sample"] = True
                final.append(l["id"])
    disagree = [l for l in labels if l.get("in_sample") and l.get("gap") is not None and l["gap"] > 0.3]
    for l in disagree:
        l["adjudicate"] = True
    frozen = {"frozen_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "labeller": MODEL, "labeller_models": models,
              "cost_usd": round(cost, 2), "seconds_median": sorted(seconds)[len(seconds) // 2] if seconds else None,
              "missing": missing, "objectives": objectives, "checkpoints": labels, "sample": final,
              "adjudicate": [l["id"] for l in disagree]}
    if any(p[1] for p in prompts):     # older raw answers carry no prompt record
        if len(prompts) != 1:
            sys.exit("raw labels were made with different labeller prompts: %s" % sorted(prompts, key=str))
        (frozen["labeller_definition"], frozen["labeller_prompt_sha256"], frozen["labeller_app_env"]), = prompts
    save(out_path, frozen)
    digest = hashlib.sha256(open(out_path, "rb").read()).hexdigest()
    with open(out_path + ".sha256", "w") as f:
        f.write(digest + "  labels.json\n")
    os.chmod(out_path, stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    from collections import Counter
    print(json.dumps({"sample": len(final), "statuses": Counter(l["status"] for l in labels),
                      "objectives": Counter((v["kind"], v["finished"], v["dropped"]) for v in objectives.values()).most_common(),
                      "adjudicate": len(disagree), "cost_usd": round(cost, 2), "missing": missing, "sha256": digest}, default=str))


if __name__ == "__main__":
    d = data_dir()
    if len(sys.argv) > 1 and sys.argv[1] == "run":
        run(d)
    elif len(sys.argv) > 1 and sys.argv[1] == "freeze":
        freeze(d)
    else:
        sys.exit(__doc__)
