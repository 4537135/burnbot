"""Stage A, step 6: score every candidate against the frozen labels and the gate.

    python3 -I tools/progress-eval/score.py --data DIR [--md OUT.md]

Reads labels.json (checked against its .sha256 first), adjudicated.json, sample.json,
candidates/rules.json, candidates/haiku/*.json, candidates/ondevice/answers.jsonl and any
grades (grades.json from the user's page, gpt-grades.json from the independent grader).
Writes DIR/scores.json and prints aggregate tables in Markdown (or writes them to --md).
The tables hold counts and averages only: no prompt text, session ids or project names.

How a model answer becomes a bar, as Stage C would ship it:
  - a checklist of 3 or more items always wins (Stage B): done / total
  - "open_ended" -> no bar
  - an approved plan the model split into 2+ sections -> (done + 1/2) / sections
  - otherwise tenths / 10, shown only at or above the confidence threshold
  - hard rules: full only with evidence (every checklist item done, or handed back with a passing
    check after the last edit and the model saying complete), otherwise at most 0.9; before any
    edit at most 0.4; a failing last check never raises the fill above the previous one
The threshold is cross-fitted: each fold uses the threshold chosen on the other fold.
"""
import glob
import hashlib
import json
import os
import statistics
import sys

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import data_dir, load, save  # noqa: E402

THRESHOLDS = [0.0, 0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0]
WRONG = 0.3        # "confidently wrong": shown and off by more than this (1e-9 slack: tenths are floats)
GATE = {"error": 0.15, "wrong": 0.10, "open_shown": 0.10, "coverage": 0.30}
BINS = [(0.0, 0.5), (0.5, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.01)]


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def f2(x):
    return "–" if x is None else "%.3f" % x


def pct(x):
    return "–" if x is None else "%d%%" % round(100 * x)


# ---------------------------------------------------------------- inputs

def inputs(data):
    path = os.path.join(data, "labels.json")
    want = open(path + ".sha256").read().split()[0]
    have = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if want != have:
        sys.exit("labels.json does not match its frozen sha256; refusing to score")
    labels = load(path)
    adjud = load(os.path.join(data, "adjudicated.json"))
    if adjud.get("labels_sha256") != have:
        sys.exit("adjudicated.json was made against different labels")
    sample = load(os.path.join(data, "sample.json"))
    cps = {c["id"]: c for c in sample["checkpoints"]}
    lab = {c["id"]: c for c in labels["checkpoints"]}
    ids = list(labels["sample"])
    adj = {i: v["value"] for i, v in adjud["items"].items()}
    return labels, lab, cps, ids, adj, have


def model_answers(data):
    out = {}
    hfolder = os.path.join(data, "candidates", "haiku")
    haiku = {}
    for p in glob.glob(os.path.join(hfolder, "*.json")):
        o = load(p)
        i = os.path.basename(p)[:-5]
        so = o.get("structured_output")
        use = o.get("modelUsage") or {}
        haiku[i] = {"answer": so if isinstance(so, dict) else None, "seconds": o.get("_seconds"),
                    "cost": o.get("total_cost_usd") or 0,
                    "tokens_in": sum((v.get("inputTokens") or 0) + (v.get("cacheReadInputTokens") or 0)
                                     + (v.get("cacheCreationInputTokens") or 0) for v in use.values()),
                    "tokens_out": sum(v.get("outputTokens") or 0 for v in use.values()),
                    "haiku_cost": sum(v.get("costUSD") or 0 for k, v in use.items() if "haiku" in k)}
    if haiku:
        out["haiku"] = haiku
    ap = os.path.join(data, "candidates", "ondevice", "answers.jsonl")
    if os.path.exists(ap):
        ond = {}
        for line in open(ap):
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            so = o.get("structured_output")
            prev = ond.get(o["id"])
            if prev and prev["answer"] is not None and so is None:
                continue  # keep a good answer over a later error
            ond[o["id"]] = {"answer": so if isinstance(so, dict) and "error" not in o else None,
                            "seconds": o.get("_seconds"), "cost": 0.0, "tokens_in": None, "tokens_out": None}
        out["ondevice"] = ond
    return out


def grades(data, name):
    p = os.path.join(data, name)
    if not os.path.exists(p):
        return {}
    g = load(p)
    return {v["checkpoint"]: v["answer"] for v in g.get("answers", {}).values()}


# ---------------------------------------------------------------- turning answers into bars

ALL_RULES = frozenset(("full_needs_evidence", "before_edit_cap", "fail_never_raises"))


def hard_rules(fill, f, complete, prev, on=ALL_RULES):
    fill = max(0.0, min(1.0, fill))
    total, done = f["checklist_total"], f["checklist_done"]
    evidence = (total >= 3 and done == total) or (
        f["handed_back"] and f["last_check_after_edit"] == "pass" and complete)
    if "full_needs_evidence" in on and not evidence:
        fill = min(fill, 0.9)
    if "before_edit_cap" in on and f["edits"] == 0:
        fill = min(fill, 0.4)
    if "fail_never_raises" in on and f["last_check_after_edit"] == "fail" and prev is not None:
        fill = min(fill, prev)
    return fill


def hybrid(order, cps, answers, threshold_of, raw=False, rules_on=ALL_RULES, plan_split=True):
    """order: checkpoint ids in objective order. Returns {id: {"shown", "fill", "basis", "conf"}}.
    rules_on / plan_split exist only for the ablation table; Stage C as planned uses the defaults."""
    out = {}
    prev_by_obj = {}
    for i in order:
        c = cps[i]
        f = c["facts"]
        a = (answers.get(i) or {}).get("answer")
        prev = prev_by_obj.get(c["objective"])
        if raw:
            if a is None or a["kind"] == "open_ended":
                out[i] = {"shown": False, "basis": "none" if a is None else "open"}
            else:
                out[i] = {"shown": True, "fill": a["tenths"] / 10, "basis": "read", "conf": a["confidence"]}
            continue
        if f["checklist_total"] >= 3:
            fill = f["checklist_done"] / f["checklist_total"]
            r = {"shown": True, "fill": hard_rules(fill, f, a and a["complete"], prev, rules_on), "basis": "checklist"}
        elif a is None:
            r = {"shown": False, "basis": "none"}
        elif a["kind"] == "open_ended":
            r = {"shown": False, "basis": "open"}
        elif plan_split and f["plan"] and a["plan_sections"] >= 2:
            fill = (min(a["plan_done"], a["plan_sections"]) + 0.5) / a["plan_sections"]
            if a["complete"] or a["plan_done"] >= a["plan_sections"]:
                fill = 1.0
            r = {"shown": True, "fill": hard_rules(fill, f, a["complete"], prev, rules_on), "basis": "plan"}
        elif a["confidence"] >= threshold_of(c["objective"]):
            r = {"shown": True, "fill": hard_rules(a["tenths"] / 10, f, a["complete"], prev, rules_on), "basis": "read",
                 "conf": a["confidence"]}
        else:
            r = {"shown": False, "basis": "low_confidence", "conf": a["confidence"]}
        if r["shown"]:
            prev_by_obj[c["objective"]] = r["fill"]
        out[i] = r
    return out


# ---------------------------------------------------------------- metrics

def metrics(pred, ids, truth, bounded, opens):
    """truth: {id: value}; bounded: ids with a value; opens: ids where the right answer is no bar."""
    shown = [i for i in bounded if i in ids and pred[i]["shown"]]
    nb = sum(1 for i in bounded if i in ids)
    errs = [abs(pred[i]["fill"] - truth[i]) for i in shown]
    on = [i for i in opens if i in ids]
    return {"n": nb, "shown": len(shown), "coverage": len(shown) / nb if nb else None,
            "error": mean(errs), "wrong": (sum(1 for e in errs if e > WRONG + 1e-9) / len(errs)) if errs else None,
            "wrong_of_all": (sum(1 for e in errs if e > WRONG + 1e-9) / nb) if nb else None,
            "open_n": len(on), "open_shown": (sum(1 for i in on if pred[i]["shown"]) / len(on)) if on else None}


def jitter(pred, order, cps, truth):
    """Neighbouring checkpoints in one objective, both shown: how often the bar moves backwards while
    the truth does not, and the mean |change in bar - change in truth|."""
    pairs = []
    last = {}
    for i in order:
        o = cps[i]["objective"]
        if i in truth and pred[i]["shown"]:
            if o in last:
                j = last[o]
                pairs.append((pred[i]["fill"] - pred[j]["fill"], truth[i] - truth[j]))
            last[o] = i
    if not pairs:
        return {"pairs": 0, "backwards": None, "delta_error": None}
    return {"pairs": len(pairs), "backwards": sum(1 for d, t in pairs if d < -0.05 and t >= 0) / len(pairs),
            "delta_error": mean([abs(d - t) for d, t in pairs])}


def choose_threshold(order, cps, answers, truth, bounded, fit_objs):
    """The lowest threshold whose read-basis bars meet the gate on the fitting fold; failing that,
    the one with the least error that still keeps 30% coverage; failing that, 0.9."""
    ids = {i for i in order if cps[i]["objective"] in fit_objs}
    rows = []
    for t in THRESHOLDS:
        p = hybrid(order, cps, answers, lambda _o, t=t: t)
        m = metrics(p, ids, truth, bounded, [])
        rows.append((t, m))
    ok = [t for t, m in rows if m["error"] is not None and m["error"] <= GATE["error"]
          and m["wrong"] <= GATE["wrong"] and m["coverage"] >= GATE["coverage"]]
    if ok:
        return ok[0]
    cov = [(m["error"], t) for t, m in rows if m["error"] is not None and m["coverage"] >= GATE["coverage"]]
    return min(cov)[1] if cov else 0.9


def calibration(order, cps, answers, truth, bounded):
    """Read-basis answers only (no checklist, no plan split): error by the model's own confidence."""
    out = []
    for lo, hi in BINS:
        errs = []
        for i in bounded:
            c = cps[i]
            a = (answers.get(i) or {}).get("answer")
            if a is None or a["kind"] == "open_ended" or c["facts"]["checklist_total"] >= 3:
                continue
            if c["facts"]["plan"] and a["plan_sections"] >= 2:
                continue
            if lo <= a["confidence"] < hi:
                errs.append(abs(a["tenths"] / 10 - truth[i]))
        out.append({"bin": "%.1f–%.1f" % (lo, min(hi, 1.0)), "n": len(errs), "error": mean(errs),
                     "wrong": (sum(1 for e in errs if e > WRONG + 1e-9) / len(errs)) if errs else None})
    return out


# ---------------------------------------------------------------- main

def main():
    data = data_dir()
    argv = sys.argv
    md_path = argv[argv.index("--md") + 1] if "--md" in argv else None
    labels, lab, cps, ids, adj, sha = inputs(data)
    rules = load(os.path.join(data, "candidates", "rules.json"))
    fold = rules["folds"]
    order = sorted(ids, key=lambda i: (cps[i]["objective"], cps[i]["index"], i))

    opus = {i: lab[i]["label"] for i in ids if lab[i]["status"] == "ok"}
    adjv = dict(opus)
    adjv.update({i: v for i, v in adj.items() if i in adjv})
    bounded = [i for i in order if i in opus]
    open_frozen = [i for i in order if lab[i]["status"] == "open"]
    handback = {i for i in ids if cps[i]["moment"] == "handback"}

    # GPT is the independent grader. The user's own page answers are reported on their own, and only
    # once there are more than 2 of them; they never feed the open-ended pool or the gate.
    graders = {}
    for name, file, least in (("GPT", "gpt-grades.json", 1), ("user", "grades.json", 3)):
        g = {k: v for k, v in grades(data, file).items() if k in cps}
        if len(g) >= least:
            graders[name] = g

    preds = {}
    for name in ("const", "stage", "planfile", "checklist"):
        preds["rule: " + name] = rules["candidates"][name]
    answers = model_answers(data)
    thresholds = {}
    ablate = {}
    for model, ans in answers.items():
        preds[model + " raw"] = hybrid(order, cps, ans, None, raw=True)
        per_fold = {}
        for k in (0, 1):
            fit = {o for o, v in fold.items() if v != k}
            per_fold[k] = choose_threshold(order, cps, ans, opus, bounded, fit)
        thresholds[model] = per_fold
        preds[model + " hybrid"] = hybrid(order, cps, ans, lambda o, pf=per_fold: pf[fold[o]])
        th = (lambda o, pf=per_fold: pf[fold[o]])
        ablate[model] = {
            "as planned": preds[model + " hybrid"],
            "no plan split": hybrid(order, cps, ans, th, plan_split=False),
            "no hard rules": hybrid(order, cps, ans, th, rules_on=frozenset()),
            "without 0.9 cap": hybrid(order, cps, ans, th, rules_on=ALL_RULES - {"full_needs_evidence"}),
            "without 0.4 cap": hybrid(order, cps, ans, th, rules_on=ALL_RULES - {"before_edit_cap"}),
            "without fail rule": hybrid(order, cps, ans, th, rules_on=ALL_RULES - {"fail_never_raises"}),
            "no threshold": hybrid(order, cps, ans, lambda o: 0.0),
        }

    # open-ended evidence: the 5 frozen, plus whatever a grader called "no bar"
    open_graded = {name: [i for i, a in g.items() if a == "no_bar"] for name, g in graders.items()}
    all_open = sorted(set(open_frozen) | set(open_graded.get("GPT", [])))

    table = {}
    for cand, p in preds.items():
        row = {}
        for ref_name, truth in (("opus", opus), ("adjudicated", adjv)):
            b = [i for i in bounded if i not in all_open]
            row[ref_name] = {
                "all": metrics(p, set(ids), truth, b, all_open),
                "mid": metrics(p, set(ids) - handback, truth, b, all_open),
                "handback": metrics(p, handback, truth, b, all_open),
            }
        row["open_frozen"] = metrics(p, set(ids), opus, [], open_frozen)
        row["jitter"] = jitter(p, order, cps, opus)
        for gname, g in graders.items():
            gtruth = {i: float(a) for i, a in g.items() if a != "no_bar"}
            gb = [i for i in order if i in gtruth and i in p]
            row["grader_" + gname] = metrics(p, set(gtruth), gtruth, gb, [i for i in open_graded[gname] if i in p])
            # the same graded items, scored only where this candidate shows a bar (for the rule comparison)
            row["grader_" + gname]["shown_ids"] = [i for i in gb if p[i]["shown"]]
        table[cand] = row

    # the grader's own gap to the hindsight labels (the noise floor), and the rule comparison
    noise = {}
    for gname, g in graders.items():
        gv = {i: float(a) for i, a in g.items() if a != "no_bar"}
        both = [i for i in gv if i in opus]
        noise[gname] = {"graded": len(g), "no_bar": len(open_graded[gname]),
                        "no_bar_where_opus_bounded": sum(1 for i in open_graded[gname] if i in opus),
                        "n": len(both), "gap_opus": mean([abs(gv[i] - opus[i]) for i in both]),
                        "gap_adjudicated": mean([abs(gv[i] - adjv[i]) for i in both]),
                        "opus_open_marked_no_bar": sum(1 for i in open_frozen if g.get(i) == "no_bar"),
                        "opus_open_graded": sum(1 for i in open_frozen if i in g)}

    def grader_compare(cand, gname):
        g = graders[gname]
        gv = {i: float(a) for i, a in g.items() if a != "no_bar"}
        shown = table[cand]["grader_" + gname]["shown_ids"]
        if not shown:
            return None
        mine = mean([abs(preds[cand][i]["fill"] - gv[i]) for i in shown])
        best = min((mean([abs(preds[r][i]["fill"] - gv[i]) for i in shown]), r)
                   for r in preds if r.startswith("rule: ") and r != "rule: checklist")
        return {"n": len(shown), "error": mine, "best_rule": best[1], "best_rule_error": best[0]}

    gate = {}
    for cand in preds:
        if not cand.endswith("hybrid"):
            continue
        a = table[cand]["opus"]["all"]
        g = {"error": a["error"] is not None and a["error"] <= GATE["error"],
             "wrong": a["wrong"] is not None and a["wrong"] <= GATE["wrong"],
             "coverage": a["coverage"] is not None and a["coverage"] >= GATE["coverage"],
             "open_shown": a["open_shown"] is not None and a["open_shown"] <= GATE["open_shown"]}
        if "GPT" in graders:
            cmp_ = grader_compare(cand, "GPT")
            g["beats_best_rule_on_grader"] = bool(cmp_) and cmp_["error"] < cmp_["best_rule_error"]
            g["grader_compare"] = cmp_
        else:
            g["beats_best_rule_on_grader"] = None
        g["passes"] = all(v for k, v in g.items() if k not in ("grader_compare",) and v is not None) and \
            g["beats_best_rule_on_grader"] is not None
        gate[cand] = g

    cost = {}
    for model, ans in answers.items():
        rows = list(ans.values())
        ok = [r for r in rows if r["answer"] is not None]
        secs = sorted(r["seconds"] for r in rows if r["seconds"] is not None)
        cost[model] = {"calls": len(rows), "answered": len(ok), "of": len(ids),
                       "total_usd": sum(r["cost"] for r in rows),
                       "per_call_usd": mean([r["cost"] for r in rows]),
                       "haiku_share_usd": mean([r.get("haiku_cost") or 0 for r in rows]) if model == "haiku" else None,
                       "seconds_median": statistics.median(secs) if secs else None,
                       "seconds_p90": secs[int(0.9 * (len(secs) - 1))] if secs else None,
                       "tokens_in_mean": mean([r["tokens_in"] for r in rows if r["tokens_in"] is not None]),
                       "tokens_out_mean": mean([r["tokens_out"] for r in rows if r["tokens_out"] is not None]),
                       "kinds": {k: sum(1 for r in ok if r["answer"]["kind"] == k) for k in ("bounded", "open_ended")},
                       "bases": {b: sum(1 for v in preds[model + " hybrid"].values() if v["basis"] == b)
                                 for b in ("checklist", "plan", "read", "low_confidence", "open", "none")}}
    calib = {m: calibration(order, cps, a, opus, bounded) for m, a in answers.items()}
    b_only = [i for i in bounded if i not in all_open]
    ablation = {m: {k: metrics(p, set(ids), opus, b_only, all_open) for k, p in v.items()} for m, v in ablate.items()}
    by_basis = {}
    for m in answers:
        p = preds[m + " hybrid"]
        by_basis[m] = {}
        for basis in ("checklist", "plan", "read"):
            errs = [abs(p[i]["fill"] - opus[i]) for i in b_only if p[i]["shown"] and p[i]["basis"] == basis]
            by_basis[m][basis] = {"n": len(errs), "error": mean(errs),
                                  "wrong": (sum(1 for e in errs if e > WRONG + 1e-9) / len(errs)) if errs else None}

    result = {"labels_sha256": sha, "n_sample": len(ids), "n_bounded": len(bounded),
              "n_handback": sum(1 for i in bounded if i in handback), "open_frozen": len(open_frozen),
              "open_all": len(all_open), "adjudicated": len(adj),
              "adjudicated_changed_03": sorted(i for i, v in adj.items() if i in opus and abs(v - opus[i]) >= 0.3 - 1e-9),
              "thresholds": thresholds, "table": table, "gate": gate, "noise": noise, "cost": cost,
              "calibration": calib, "ablation": ablation, "by_basis": by_basis, "graders": {k: len(v) for k, v in graders.items()},
              "pending": [x for x, missing in (("on-device", "ondevice" not in answers),
                                               ("independent grader (GPT)", "GPT" not in graders)) if missing]}
    save(os.path.join(data, "scores.json"), result)
    md = markdown(result, preds)
    if md_path:
        with open(md_path, "w") as f:
            f.write(md)
    print(md)


def markdown(r, preds):
    L = []
    cands = list(preds)
    L.append("Sample: %d checkpoints; %d bounded with a label (%d at handback, %d mid-work); "
             "%d open-ended frozen, %d open-ended counting grader \"no bar\" answers." %
             (r["n_sample"], r["n_bounded"], r["n_handback"], r["n_bounded"] - r["n_handback"],
              r["open_frozen"], r["open_all"]))
    L.append("")
    for ref in ("opus", "adjudicated"):
        L.append("#### Against the %s labels" % ("hindsight (Opus)" if ref == "opus" else "adjudicated"))
        L.append("")
        L.append("| candidate | error, all | error, mid-work | error, handback | coverage | coverage, mid-work | confidently wrong | wrongly shown, open-ended |")
        L.append("|---|---|---|---|---|---|---|---|")
        for c in cands:
            t = r["table"][c][ref]
            L.append("| %s | %s | %s | %s | %s | %s | %s | %s (n=%d) |" % (
                c, f2(t["all"]["error"]), f2(t["mid"]["error"]), f2(t["handback"]["error"]),
                pct(t["all"]["coverage"]), pct(t["mid"]["coverage"]), pct(t["all"]["wrong"]),
                pct(t["all"]["open_shown"]), t["all"]["open_n"]))
        L.append("")
    L.append("Open-ended is weakly measured: n=%d (%d frozen by the labeller, %d more that the independent "
             "grader marked \"no bar\"). On the %d frozen ones alone: %s." % (
                 r["open_all"], r["open_frozen"], r["open_all"] - r["open_frozen"], r["open_frozen"],
                 "; ".join("%s shown on %s" % (c, pct(r["table"][c]["open_frozen"]["open_shown"])) for c in cands)))
    L.append("")
    L.append("#### Jitter between neighbouring checkpoints (same objective, both shown)")
    L.append("")
    L.append("| candidate | pairs | bar moves back while truth doesn't | mean error of the change |")
    L.append("|---|---|---|---|")
    for c in cands:
        j = r["table"][c]["jitter"]
        L.append("| %s | %d | %s | %s |" % (c, j["pairs"], pct(j["backwards"]), f2(j["delta_error"])))
    L.append("")
    for g, n in r["noise"].items():
        L.append("#### %s" % ("Independent grader (GPT)" if g == "GPT" else
                               "The user's own grades (reported apart; not used by the gate)"))
        L.append("")
        L.append("%d graded; %d marked \"no bar\" (%d of them where the hindsight label is bounded); of the %d "
                 "frozen open-ended items in the graded set, %d marked \"no bar\"." %
                 (n["graded"], n["no_bar"], n["no_bar_where_opus_bounded"], n["opus_open_graded"],
                  n["opus_open_marked_no_bar"]))
        L.append("Mean gap to the hindsight labels: %s (n=%d); to the adjudicated labels: %s. "
                 "This is the label noise floor: above 0.15 the gate's error test cannot separate a good "
                 "estimator from a bad one." % (f2(n["gap_opus"]), n["n"], f2(n["gap_adjudicated"])))
        L.append("")
        L.append("| candidate | n shown | error vs grader | coverage | wrongly shown on grader's no-bar items |")
        L.append("|---|---|---|---|---|")
        for c in cands:
            t = r["table"][c].get("grader_" + g)
            if t:
                L.append("| %s | %d | %s | %s | %s (n=%d) |" % (c, t["shown"], f2(t["error"]), pct(t["coverage"]),
                                                             pct(t["open_shown"]), t["open_n"]))
        L.append("")
    if r["calibration"]:
        L.append("#### Calibration (model answers read directly: no checklist, no plan split)")
        L.append("")
        L.append("| model | confidence | n | error | off by more than 0.3 |")
        L.append("|---|---|---|---|---|")
        for m, rows in r["calibration"].items():
            for b in rows:
                L.append("| %s | %s | %d | %s | %s |" % (m, b["bin"], b["n"], f2(b["error"]), pct(b["wrong"])))
        L.append("")
        L.append("Confidence threshold (cross-fitted; fold 0 / fold 1): " + "; ".join(
            "%s %s / %s" % (m, t["0"] if "0" in t else t[0], t["1"] if "1" in t else t[1])
            for m, t in r["thresholds"].items()))
        L.append("")
    if r["ablation"]:
        L.append("#### What each part of the hybrid does (against the hindsight labels)")
        L.append("")
        L.append("| model | variant | error | coverage | confidently wrong | open-ended shown |")
        L.append("|---|---|---|---|---|---|")
        for m, rows in r["ablation"].items():
            for k, t in rows.items():
                L.append("| %s | %s | %s | %s | %s | %s |" % (m, k, f2(t["error"]), pct(t["coverage"]), pct(t["wrong"]),
                                                          pct(t["open_shown"])))
        L.append("")
        L.append("| model | bar basis | n | error | confidently wrong |")
        L.append("|---|---|---|---|---|")
        for m, rows in r["by_basis"].items():
            for k, t in rows.items():
                L.append("| %s | %s | %d | %s | %s |" % (m, k, t["n"], f2(t["error"]), pct(t["wrong"])))
        L.append("")
    if r["cost"]:
        L.append("#### Latency and cost")
        L.append("")
        L.append("| model | answered | median s | p90 s | per call | total | mean tokens in / out |")
        L.append("|---|---|---|---|---|---|---|")
        for m, c in r["cost"].items():
            L.append("| %s | %d of %d | %s | %s | $%.4f | $%.2f | %s / %s |" % (
                m, c["answered"], c["of"], c["seconds_median"], c["seconds_p90"], c["per_call_usd"] or 0,
                c["total_usd"], "–" if c["tokens_in_mean"] is None else round(c["tokens_in_mean"]),
                "–" if c["tokens_out_mean"] is None else round(c["tokens_out_mean"])))
        L.append("")
        for m, c in r["cost"].items():
            L.append("%s: kinds %s; bars by basis %s." % (m, c["kinds"], c["bases"]))
        L.append("")
    L.append("#### Gate (model hybrids, against the hindsight labels)")
    L.append("")
    L.append("| candidate | error ≤ 0.15 | confidently wrong ≤ 10% | open-ended shown ≤ 10% | coverage ≥ 30% | beats best rule on GPT's 24 grades | passes |")
    L.append("|---|---|---|---|---|---|---|")
    yn = {True: "yes", False: "no", None: "pending"}
    for c, g in r["gate"].items():
        cmp_ = g.get("grader_compare")
        beat = yn[g["beats_best_rule_on_grader"]]
        if cmp_:
            beat += " (%s vs %s %s, n=%d)" % (f2(cmp_["error"]), cmp_["best_rule"].replace("rule: ", ""),
                                              f2(cmp_["best_rule_error"]), cmp_["n"])
        L.append("| %s | %s | %s | %s | %s | %s | %s |" % (c, yn[g["error"]], yn[g["wrong"]], yn[g["open_shown"]],
                                                          yn[g["coverage"]], beat,
                                                          "no" if False in (g["error"], g["wrong"], g["open_shown"],
                                                                            g["coverage"], g["beats_best_rule_on_grader"])
                                                          else "pending" if g["beats_best_rule_on_grader"] is None
                                                          else yn[g["passes"]]))
    L.append("")
    return "\n".join(L)


if __name__ == "__main__":
    main()
