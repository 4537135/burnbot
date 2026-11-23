"""Stage A, step 5: run the candidates on every checkpoint in the frozen sample.

    python3 -I tools/progress-eval/candidates.py rules         --data DIR
    python3 -I tools/progress-eval/candidates.py haiku         --data DIR [--cap 6.00] [--workers 3]
    python3 -I tools/progress-eval/candidates.py ondevice-prep --data DIR

rules:  always 0.5, stage median (cross-fitted by objective, so no prediction comes from a
        median its own objective helped fit), the plan-file rule, and the checklist rule
        Stage B ships. Writes DIR/candidates/rules.json.
haiku:  one `claude -p --model haiku` call per checkpoint, with app/Summaries.swift's flags,
        from the neutral DIR/cwd. Raw answers go to DIR/candidates/haiku/<id>.json as they
        arrive; finished ones are skipped on a rerun. Stops before the total passes --cap.
ondevice-prep: writes DIR/candidates/ondevice/{instructions.txt,prompts.jsonl} for
        ondevice-run.swift, which asks Apple's on-device model the same question with the
        same schema and writes DIR/candidates/ondevice/answers.jsonl.

Both models get the same instructions, the same digest and the same output schema; score.py
applies the same no-bar and confidence handling to both.
"""
import json
import os
import random
import statistics
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import data_dir, load, save  # noqa: E402
from label import app_env, args_for, ask, claude_path  # noqa: E402

INSTRUCTIONS = """You estimate how far Claude Code has got with what the user asked for, at one moment during the work. You see only what existed at that moment; nobody knows yet how it ends.

kind: "bounded" if the request has a finish line you could recognise (a fix, a feature, a change, a document or plan to write). "open_ended" if it has none (exploring, brainstorming, open research, conversation, "look around and tell me", iterating with no completion criteria).

tenths: for bounded work, how much of the whole job is done, 0 to 10, judged by milestones reached: understood the problem, each part built, checks run, failures fixed, verified, handed back. Never judge by time spent or by the number of actions. A failing check means the work is not done. For open_ended work answer 0.

plan_sections and plan_done: if an approved plan is listed, how many work sections it has (leave out headings such as Context, Approach, Files, Verification, Risks) and how many of those are fully done. Both 0 when there is no plan.

complete: true only if the work is finished and checked.

confidence: 0 to 1, how sure you are that tenths is right to within one tenth.

label: up to 24 characters saying where the work is, e.g. "Step 3 of 5", "Fixing a failing test", "Running checks".
"""

SCHEMA = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": ["bounded", "open_ended"]},
        "tenths": {"type": "integer", "minimum": 0, "maximum": 10},
        "plan_sections": {"type": "integer", "minimum": 0, "maximum": 20},
        "plan_done": {"type": "integer", "minimum": 0, "maximum": 20},
        "complete": {"type": "boolean"},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "label": {"type": "string", "maxLength": 24},
    },
    "required": ["kind", "tenths", "plan_sections", "plan_done", "complete", "confidence", "label"],
    "additionalProperties": False,
}

HAIKU_BUDGET = "0.10"  # app/Summaries.swift's per-call --max-budget-usd
FOLD_SEED = 20261118


def text_for(cp):
    return INSTRUCTIONS + "\n--- THE MOMENT ---\n" + cp["digest"]


def frozen(data):
    labels = load(os.path.join(data, "labels.json"))
    sample = load(os.path.join(data, "sample.json"))
    cps = {c["id"]: c for c in sample["checkpoints"]}
    return labels, sample, [cps[i] for i in labels["sample"]]


def folds(labels):
    """Two folds by objective, each group (bounded / open) split evenly."""
    objs = sorted({c["objective"] for c in labels["checkpoints"] if c.get("in_sample")})
    rng = random.Random(FOLD_SEED)
    rng.shuffle(objs)
    return {o: n % 2 for n, o in enumerate(objs)}


def stage_medians(rows):
    by = {}
    for stage, label in rows:
        by.setdefault(stage, []).append(label)
    overall = statistics.median([l for _, l in rows]) if rows else 0.5
    return {s: statistics.median(v) for s, v in by.items() if len(v) >= 3}, overall


def rules(data):
    labels, sample, cps = frozen(data)
    lab = {c["id"]: c for c in labels["checkpoints"]}
    fold = folds(labels)
    fits = {}
    for k in (0, 1):
        rows = [(c["facts"]["stage"], lab[c["id"]]["label"]) for c in cps
                if fold[c["objective"]] != k and lab[c["id"]]["status"] == "ok"]
        fits[k] = stage_medians(rows)
    out = {"folds": fold, "medians": {str(k): {"by_stage": v[0], "overall": v[1]} for k, v in fits.items()},
           "candidates": {"const": {}, "stage": {}, "planfile": {}, "checklist": {}}}
    for c in cps:
        f = c["facts"]
        by_stage, overall = fits[fold[c["objective"]]]
        median = by_stage.get(f["stage"], overall)
        out["candidates"]["const"][c["id"]] = {"shown": True, "fill": 0.5}
        out["candidates"]["stage"][c["id"]] = {"shown": True, "fill": median}
        if f["plan"] and f["plan_files"] >= 2:
            fill = 1.0 if f["stage"] == "handback_checked" else 0.1 + 0.8 * f["plan_files_edited"] / f["plan_files"]
            out["candidates"]["planfile"][c["id"]] = {"shown": True, "fill": round(fill, 3), "basis": "plan"}
        else:
            out["candidates"]["planfile"][c["id"]] = {"shown": True, "fill": median, "basis": "stage"}
        if f["checklist_total"] >= 3:
            out["candidates"]["checklist"][c["id"]] = {"shown": True, "fill": f["checklist_done"] / f["checklist_total"]}
        else:
            out["candidates"]["checklist"][c["id"]] = {"shown": False}
    save(os.path.join(data, "candidates", "rules.json"), out)
    print(json.dumps({"checkpoints": len(cps), "fold_sizes": [sum(1 for v in fold.values() if v == k) for k in (0, 1)],
                      "plan_rule_used": sum(1 for v in out["candidates"]["planfile"].values() if v.get("basis") == "plan"),
                      "checklist_shown": sum(1 for v in out["candidates"]["checklist"].values() if v["shown"])}))


def haiku(data):
    argv = sys.argv
    cap = float(argv[argv.index("--cap") + 1]) if "--cap" in argv else 6.0
    workers = int(argv[argv.index("--workers") + 1]) if "--workers" in argv else 3
    _, _, cps = frozen(data)
    folder = os.path.join(data, "candidates", "haiku")
    os.makedirs(folder, exist_ok=True)
    cwd = os.path.join(data, "cwd")
    os.makedirs(cwd, exist_ok=True)
    claude = claude_path()
    args = args_for(claude, "haiku", HAIKU_BUDGET, SCHEMA)
    env = app_env(claude)
    spent = [0.0]
    for name in os.listdir(folder):
        if name.endswith(".json"):
            spent[0] += load(os.path.join(folder, name)).get("total_cost_usd") or 0
    lock = threading.Lock()
    stop = threading.Event()
    todo = [c for c in cps if not os.path.exists(os.path.join(folder, c["id"] + ".json"))]
    print("to do %d, spent so far $%.2f, cap $%.2f" % (len(todo), spent[0], cap), flush=True)

    def one(c):
        with lock:
            # leave room for the calls still in flight (about $0.05 each)
            if stop.is_set() or spent[0] + 0.06 * workers > cap:
                stop.set()
                return
        out = ask(args, text_for(c), cwd, timeout=120, env=env)
        save(os.path.join(folder, c["id"] + ".json"), out)
        with lock:
            spent[0] += out.get("total_cost_usd") or 0
            ok = isinstance(out.get("structured_output"), dict)
            print("%s %s $%.4f %.1fs total $%.2f" % (c["id"], "ok" if ok else "ERROR", out.get("total_cost_usd") or 0,
                                                    out["_seconds"], spent[0]), flush=True)

    with ThreadPoolExecutor(workers) as pool:
        list(pool.map(one, todo))
    if stop.is_set():
        print("STOPPED at the cap: $%.2f spent" % spent[0])
    print("haiku spent $%.2f" % spent[0])


def ondevice_prep(data):
    _, _, cps = frozen(data)
    folder = os.path.join(data, "candidates", "ondevice")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "instructions.txt"), "w") as f:
        f.write(INSTRUCTIONS)
    with open(os.path.join(folder, "prompts.jsonl"), "w") as f:
        for c in cps:
            f.write(json.dumps({"id": c["id"], "prompt": "--- THE MOMENT ---\n" + c["digest"]}) + "\n")
    print(json.dumps({"prompts": len(cps), "folder": folder}))


if __name__ == "__main__":
    data = data_dir()
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    {"rules": rules, "haiku": haiku, "ondevice-prep": ondevice_prep}.get(command, lambda _: sys.exit(__doc__))(data)
