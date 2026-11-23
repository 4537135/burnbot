"""Stage A, step 4: the blind grading page.

    python3 -I tools/progress-eval/grade.py prepare --data DIR [--n 24] [--open 5]
    python3 -I tools/progress-eval/grade.py serve   --data DIR [--port 8777]

prepare: picks N checkpoints from the frozen sample (DIR/labels.json), stratified across the
    sampler's strata, one per objective, some of them open-ended, and writes a compact,
    skimmable view of each to DIR/grading/items.json (the key to checkpoint ids stays in
    DIR/grading/key.json). It shows the request, the plan headings, a turn-by-turn timeline
    with the checkpoint marked, and how it ended. It never includes a label or a candidate's output.
serve: serves the page on 127.0.0.1 only. Each answer is written to DIR/grades.json the moment
    it is given. Keys: 0-9 = 0.0-0.9, F = 1.0, N = no bar, arrows or J/K to move.

This script holds no session data; everything it shows comes from DIR.
"""

import json
import os
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import base, clip, data_dir, load, plan_headings, save, tidy
from sample import VERIFY

QUOTAS = [("checklist", 2), ("long_debug", 3), ("failed_checks", 3), ("changed_req", 3), ("quick_fix", 3), ("plan", 3), ("no_plan", 2)]
MOMENT = {
    "plan_approved": "you had just approved the plan",
    "checklist": "Claude had just updated its checklist",
    "first_edit": "Claude had just made its first edit",
    "check_after_edits": "a check had just finished after edits",
    "handback": "Claude had just stopped and handed back to you",
    "new_prompt": "you had just sent a follow-up",
}
MAX_CHIPS = 18


# ---- choosing the items ----

def choose(data, n, n_open):
    labels = load(os.path.join(data, "labels.json"))
    sample = load(os.path.join(data, "sample.json"))
    seed = sample["seed"]
    rng = random.Random(seed * 31 + 24)
    objs = {o["id"]: o for o in sample["objectives"]}
    cps = {c["id"]: c for c in sample["checkpoints"]}
    in_sample = [l for l in labels["checkpoints"] if l.get("in_sample")]
    opens = [l for l in in_sample if l["status"] == "open"]
    bounded = [l for l in in_sample if l["status"] == "ok"]
    rng.shuffle(opens)
    rng.shuffle(bounded)
    picked, used_obj, projects, moments = [], set(), {}, {}

    def fits(l, cap):
        o = objs[l["objective"]]
        return l["objective"] not in used_obj and projects.get(o["project"], 0) < cap

    def take(l):
        picked.append(l["id"])
        used_obj.add(l["objective"])
        p = objs[l["objective"]]["project"]
        projects[p] = projects.get(p, 0) + 1
        m = cps[l["id"]]["moment"]
        moments[m] = moments.get(m, 0) + 1

    for l in opens:
        if sum(1 for x in picked if x in {o["id"] for o in opens}) >= n_open:
            break
        if fits(l, max(2, n_open // 2)):
            take(l)
    n_bounded = n - len(picked)
    cap = max(3, int(n_bounded * 0.45))
    for stratum, quota in QUOTAS:
        got = 0
        pool = [l for l in bounded if stratum in objs[l["objective"]]["strata"]]
        # prefer moments seen least so far, so the timeline positions vary
        pool.sort(key=lambda l: moments.get(cps[l["id"]]["moment"], 0))
        for l in pool:
            if got >= quota or len(picked) >= n:
                break
            if fits(l, cap):
                take(l)
                got += 1
    for l in sorted(bounded, key=lambda l: moments.get(cps[l["id"]]["moment"], 0)):
        if len(picked) >= n:
            break
        if fits(l, cap) or (l["objective"] not in used_obj and len(picked) < n):
            take(l)
    rng.shuffle(picked)
    return picked, sample, objs, cps


# ---- the compact view ----

def chips_for(events, a, b):
    chips = []

    def last():
        return chips[-1] if chips else None

    for i in range(a, b + 1):
        e = events[i]
        k = e["k"]
        if k == "edit":
            if last() and last()["k"] == "edit":
                last()["n"] += 1
                if base(e["file"]) not in last()["files"]:
                    last()["files"].append(base(e["file"]))
            else:
                chips.append({"k": "edit", "n": 1, "files": [base(e["file"])]})
        elif k == "check" or (k == "bash" and not e.get("denied") and VERIFY.search(e.get("cmd", "") + " " + (e.get("desc") or ""))):
            ok = e["verdict"] if k == "check" else ("fail" if e.get("err") else "pass")
            what = e["family"] if k == "check" else clip(e.get("desc") or e["cmd"], 40)
            if last() and last()["k"] == "check" and last()["what"] == what:
                last()["seq"].append(ok)
            else:
                chips.append({"k": "check", "what": what, "seq": [ok]})
        elif k in ("read", "search", "bash", "tool"):
            if last() and last()["k"] == "look_around":
                last()["n"] += 1
            else:
                chips.append({"k": "look_around", "n": 1})
        elif k == "look":
            if last() and last()["k"] == "look":
                last()["n"] += 1
            else:
                chips.append({"k": "look", "n": 1})
        elif k == "plan":
            chips.append({"k": "plan", "ok": e["status"] == "approved", "note": clip(e.get("note") or "", 200)})
        elif k == "checklist":
            items = e["items"]
            done = sum(1 for x in items if x[1] == "completed")
            if last() and last()["k"] == "checklist":
                chips.pop()
            chips.append({"k": "checklist", "done": done, "total": len(items)})
        elif k == "git":
            chips.append({"k": "git", "what": e["what"]})
        elif k == "agent":
            if last() and last()["k"] == "agent":
                last()["n"] += 1
            else:
                chips.append({"k": "agent", "n": 1})
        elif k == "qa":
            for q, ans in e["pairs"][:2]:
                chips.append({"k": "qa", "q": clip(q, 140), "a": clip(ans, 140)})
        elif k == "interrupt":
            chips.append({"k": "interrupt"})
        elif k == "compact":
            chips.append({"k": "compact"})
    # drop the "looked around" noise between two meaningful chips when the row is long
    if len(chips) > MAX_CHIPS:
        chips = [c for c in chips if c["k"] != "look_around"]
    if len(chips) > MAX_CHIPS:
        head, tail = chips[: MAX_CHIPS // 2], chips[-(MAX_CHIPS // 2 - 1):]
        mid = chips[MAX_CHIPS // 2: -(MAX_CHIPS // 2 - 1)]
        edits = sum(c["n"] for c in mid if c["k"] == "edit")
        runs = [v for c in mid if c["k"] == "check" for v in c["seq"]]
        chips = head + [{"k": "more", "edits": edits, "checks": len(runs), "failed": runs.count("fail")}] + tail
    return chips


def said(events, a, b, clip_to=260):
    for i in range(b, a - 1, -1):
        if events[i]["k"] == "say":
            return clip(events[i]["text"], clip_to)
    return ""


def first_said(events, a, b, clip_to=200):
    for i in range(a, b + 1):
        if events[i]["k"] == "say":
            return clip(events[i]["text"], clip_to)
    return ""


def item_for(session, obj, cp, n):
    events, turns = session["events"], session["turns"]
    idx = cp["index"]
    out = {"item": "G%02d" % n, "project": session["project"], "earlier": [], "plan": None, "turns": [],
           "ending": "The session log ends here." if obj["log_ends"] else "The session goes on after this (not shown)."}
    for t in range(max(0, obj["ti"] - 2), obj["ti"]):
        out["earlier"].append(clip(tidy(events[turns[t]["i"]]["text"], 80), 160))
    for i in range(obj["i0"], obj["view_i1"] + 1):
        e = events[i]
        if e["k"] == "plan" and e["status"] == "approved":
            out["plan"] = {"headings": plan_headings(e["plan"], limit=14), "before": i <= idx}
    for t in range(obj["ti"], obj["view_tj"] + 1):
        tr = turns[t]
        a, b = tr["i"], min(tr["j"], obj["view_i1"])
        if a > obj["view_i1"]:
            break
        name = "T%d" % (t - obj["ti"] + 1)
        prompt = events[a]
        turn = {"name": name, "prompt": clip(tidy(prompt["text"], 600), 900 if t == obj["ti"] else 320), "rows": [],
                "minutes": round(tr.get("minutes") or 0)}
        cuts = [(a + 1, b)]
        if a <= idx <= b:
            cuts = [(a + 1, idx), None, (idx + 1, b)]
        for c in cuts:
            if c is None:
                turn["rows"].append({"checkpoint": MOMENT.get(cp["moment"], cp["moment"])})
                continue
            x, y = c
            if x > y:
                continue
            chips = chips_for(events, x, y)
            row = {"chips": chips, "said": said(events, x, y)}
            opening = first_said(events, x, y)
            if opening and opening != row["said"] and len(chips) > 3:
                row["opening"] = opening
            if chips or row["said"]:
                turn["rows"].append(row)
        out["turns"].append(turn)
    return out


def prepare(data):
    argv = sys.argv
    n = int(argv[argv.index("--n") + 1]) if "--n" in argv else 24
    n_open = int(argv[argv.index("--open") + 1]) if "--open" in argv else 5
    if not os.path.exists(os.path.join(data, "labels.json")):
        sys.exit("freeze the labels first (label.py freeze)")
    picked, sample, objs, cps = choose(data, n, n_open)
    sessions, items, key = {}, [], {}
    for k, cid in enumerate(picked, 1):
        cp = cps[cid]
        obj = objs[cp["objective"]]
        if obj["session"] not in sessions:
            sessions[obj["session"]] = load(os.path.join(data, "sessions", obj["session"] + ".json"))
        item = item_for(sessions[obj["session"]], obj, cp, k)
        items.append(item)
        key[item["item"]] = cid
    os.makedirs(os.path.join(data, "grading"), exist_ok=True)
    save(os.path.join(data, "grading", "items.json"), items)
    save(os.path.join(data, "grading", "key.json"), key)
    from collections import Counter
    strata = Counter(s for cid in picked for s in objs[cps[cid]["objective"]]["strata"])
    status = {l["id"]: l["status"] for l in load(os.path.join(data, "labels.json"))["checkpoints"]}
    print(json.dumps({"items": len(items), "open_ended": sum(1 for cid in picked if status[cid] == "open"),
                      "strata": strata, "moments": Counter(cps[c]["moment"] for c in picked),
                      "projects": len({objs[cps[c]["objective"]]["project"] for c in picked}),
                      "chars_mean": sum(len(json.dumps(i)) for i in items) // max(1, len(items))}))


# ---- the page ----

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Progress grading</title>
<style>
:root{--bg:#f6f5f2;--card:#fff;--ink:#1d1d1f;--mute:#6b6b70;--line:#e3e1dc;--accent:#7a5cff;--accent-soft:#efeaff;--ok:#1f8a4c;--bad:#c2372f;--warn:#a46a00;--chip:#f0efeb}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#17171a;--card:#202024;--ink:#ececf0;--mute:#9a9aa3;--line:#33333a;--accent:#a996ff;--accent-soft:#2c2645;--ok:#5cc98a;--bad:#ff7b72;--warn:#e0a84a;--chip:#2a2a30}}
:root[data-theme="dark"]{--bg:#17171a;--card:#202024;--ink:#ececf0;--mute:#9a9aa3;--line:#33333a;--accent:#a996ff;--accent-soft:#2c2645;--ok:#5cc98a;--bad:#ff7b72;--warn:#e0a84a;--chip:#2a2a30}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:16px 16px 150px}
header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin:4px 0 12px}
h1{font-size:17px;margin:0}
.count{color:var(--mute);font-variant-numeric:tabular-nums}
.help{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px;margin-bottom:14px;color:var(--mute);font-size:13.5px}
.help b{color:var(--ink)}
.help summary{cursor:pointer;color:var(--ink);font-weight:600}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-bottom:12px}
.label{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin-bottom:4px}
.request{white-space:pre-wrap;word-wrap:break-word}
.earlier{color:var(--mute);font-size:13px;margin-top:8px}
ol.plan{margin:4px 0 0;padding-left:22px}
ol.plan li{margin:1px 0}
.turn{border-left:3px solid var(--line);padding:2px 0 2px 12px;margin:12px 0}
.turn .who{font-weight:600}
.turn .min{color:var(--mute);font-size:12.5px;margin-left:6px}
.prompt{white-space:pre-wrap;word-wrap:break-word;margin:2px 0 6px}
.row{margin:6px 0 8px}
.chips{display:flex;flex-wrap:wrap;gap:5px}
.chip{background:var(--chip);border-radius:6px;padding:1px 7px;font-size:13px;white-space:nowrap;max-width:100%;overflow:hidden;text-overflow:ellipsis}
.chip.pass{color:var(--ok)} .chip.fail{color:var(--bad)} .chip.plan{color:var(--accent);font-weight:600} .chip.warn{color:var(--warn)}
.said{color:var(--mute);font-size:13.5px;margin-top:4px;font-style:italic}
.said::before{content:"Claude: ";font-style:normal;font-weight:600}
.qa{font-size:13.5px;margin:3px 0}
.cp{background:var(--accent-soft);border:2px solid var(--accent);border-radius:8px;padding:6px 10px;margin:10px 0;font-weight:600;color:var(--accent)}
.after{opacity:.92}
.ending{color:var(--mute);font-style:italic;margin-top:10px}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:10px 16px 12px}
.bar .in{max-width:860px;margin:0 auto}
.q{font-size:13.5px;margin-bottom:8px}
.btns{display:flex;flex-wrap:wrap;gap:6px}
.btns button{font:inherit;font-variant-numeric:tabular-nums;min-width:46px;padding:7px 8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--ink);cursor:pointer}
.btns button.on{background:var(--accent);border-color:var(--accent);color:#fff}
.btns button.nobar{min-width:120px}
.btns kbd{font-size:10.5px;color:var(--mute);margin-left:3px}
.btns button.on kbd{color:#fff}
.nav{display:flex;justify-content:space-between;align-items:center;margin-top:8px;font-size:13px;color:var(--mute)}
.nav button{font:inherit;background:none;border:none;color:var(--accent);cursor:pointer;padding:4px}
.saved{color:var(--ok)}
.done{text-align:center;padding:40px 0}
</style>
</head>
<body>
<main>
  <header><h1>How far along was it?</h1><span class="count" id="count"></span></header>
  <details class="help" id="help" open>
    <summary>How to grade (about 30 seconds each)</summary>
    <p>Each item is a real stretch of your own Claude Code work, shortened. One moment is marked <b>CHECKPOINT</b>. Looking at the whole thing with hindsight, answer: <b>how much of the objective's work, as it was eventually done, had been done at the checkpoint?</b></p>
    <p>Judge by milestones reached (understood, each part built, checked, fixed, verified), <b>not</b> by time spent or how many steps happened. The objective carries on through follow-ups that fix or change the same thing, and ends when you moved on. Work later thrown away doesn't count. Give <b>1.0</b> only if it was finished and verified at that moment. If the request had no finish line (exploring, brainstorming, open research, conversation), answer <b>No bar</b>.</p>
    <p>Keys: <b>0</b>–<b>9</b> = 0.0–0.9 &nbsp; <b>F</b> = 1.0 &nbsp; <b>N</b> = no bar &nbsp; <b>←/→</b> or <b>J/K</b> = previous/next. Each answer is saved as soon as you give it.</p>
  </details>
  <div id="item"></div>
</main>
<div class="bar"><div class="in">
  <div class="q">At the checkpoint, how far along was the objective?</div>
  <div class="btns" id="btns"></div>
  <div class="nav"><button id="prev">← previous</button><span id="status"></span><button id="next">next →</button></div>
</div></div>
<script>
const $ = (s) => document.querySelector(s);
let items = [], answers = {}, at = 0;
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const choices = [...Array(11).keys()].map((n) => ({v: n / 10, text: (n / 10).toFixed(1), key: n === 10 ? "F" : String(n)}));
choices.push({v: "no_bar", text: "No bar (open-ended)", key: "N"});

function chip(c) {
  switch (c.k) {
    case "edit": return `<span class="chip">✎ ${c.n} edit${c.n > 1 ? "s" : ""}: ${esc(c.files.slice(0, 3).join(", "))}${c.files.length > 3 ? " +" + (c.files.length - 3) : ""}</span>`;
    case "check": {
      const marks = c.seq.map((v) => v === "pass" ? "✓" : v === "fail" ? "✗" : "?").join("");
      const last = c.seq[c.seq.length - 1];
      return `<span class="chip ${last === "pass" ? "pass" : last === "fail" ? "fail" : ""}">${marks} ${esc(c.what)}</span>`;
    }
    case "look_around": return `<span class="chip">· looked around ×${c.n}</span>`;
    case "look": return `<span class="chip">👁 screenshot${c.n > 1 ? " ×" + c.n : ""}</span>`;
    case "plan": return c.ok ? `<span class="chip plan">▣ plan approved</span>` : `<span class="chip warn">▣ plan turned down${c.note ? ": " + esc(c.note) : ""}</span>`;
    case "checklist": return `<span class="chip plan">☑ checklist ${c.done}/${c.total}</span>`;
    case "git": return `<span class="chip">⎇ ${c.what === "commit" ? "commit" : "pull request"}</span>`;
    case "agent": return `<span class="chip">⇢ subagent${c.n > 1 ? " ×" + c.n : ""}</span>`;
    case "interrupt": return `<span class="chip warn">you interrupted</span>`;
    case "compact": return `<span class="chip">context compacted</span>`;
    case "more": return `<span class="chip">… ${c.edits} more edits, ${c.checks} checks${c.failed ? " (" + c.failed + " failed)" : ""} …</span>`;
    default: return "";
  }
}

function render() {
  const it = items[at];
  if (!it) return;
  const done = Object.keys(answers).length;
  $("#count").textContent = `${at + 1} of ${items.length} · ${done} answered`;
  let h = `<div class="card"><div class="label">Request · ${esc(it.project)}</div><div class="request">${esc(it.turns[0]?.prompt)}</div>`;
  if (it.earlier.length) h += `<div class="earlier">Just before this: ${it.earlier.map(esc).join(" · ")}</div>`;
  h += `</div>`;
  if (it.plan) h += `<div class="card"><div class="label">Approved plan headings (approved ${it.plan.before ? "before" : "after"} the checkpoint)</div>${it.plan.headings.length ? `<ol class="plan">${it.plan.headings.map((x) => `<li>${esc(x)}</li>`).join("")}</ol>` : "<div>(no headings)</div>"}</div>`;
  h += `<div class="card"><div class="label">What happened</div>`;
  let after = false;
  it.turns.forEach((t, n) => {
    h += `<div class="turn ${after ? "after" : ""}"><div><span class="who">${n === 0 ? "You asked" : "You: "}</span>${n === 0 ? "" : `<span class="prompt">${esc(t.prompt)}</span>`}<span class="min">${esc(t.name)}${t.minutes ? " · " + t.minutes + " min" : ""}</span></div>`;
    for (const r of t.rows) {
      if (r.checkpoint) { h += `<div class="cp" id="cp">▶ CHECKPOINT: ${esc(r.checkpoint)}</div>`; after = true; continue; }
      h += `<div class="row">`;
      if (r.opening) h += `<div class="said">${esc(r.opening)}</div>`;
      const qa = r.chips.filter((c) => c.k === "qa");
      if (r.chips.length - qa.length) h += `<div class="chips">${r.chips.filter((c) => c.k !== "qa").map(chip).join("")}</div>`;
      for (const c of qa) h += `<div class="qa">? <b>Claude asked:</b> ${esc(c.q)}<br>&nbsp;&nbsp;<b>you:</b> ${esc(c.a)}</div>`;
      if (r.said) h += `<div class="said">${esc(r.said)}</div>`;
      h += `</div>`;
    }
    h += `</div>`;
  });
  h += `<div class="ending">${esc(it.ending)}</div></div>`;
  $("#item").innerHTML = h;
  const mine = answers[it.item];
  $("#btns").innerHTML = choices.map((c) => `<button class="${c.v === "no_bar" ? "nobar" : ""} ${mine && mine.answer === c.v ? "on" : ""}" data-v="${c.v}">${c.text}<kbd>${c.key}</kbd></button>`).join("");
  $("#status").innerHTML = mine ? `<span class="saved">saved</span>` : "";
  const cp = document.getElementById("cp");
  if (cp) cp.scrollIntoView({block: "center"});
}

async function answer(v) {
  const it = items[at];
  answers[it.item] = {answer: v};
  render();
  $("#status").textContent = "saving…";
  try {
    const r = await fetch("/grade", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({item: it.item, answer: v})});
    if (!r.ok) throw new Error(r.status);
    $("#status").innerHTML = `<span class="saved">saved</span>`;
    setTimeout(() => { if (items[at] === it) go(1, true); }, 300);
  } catch (e) { $("#status").textContent = "not saved, try again (" + e.message + ")"; delete answers[it.item]; }
}

function go(d, skipDone) {
  if (skipDone && Object.keys(answers).length === items.length) {
    $("#item").innerHTML = `<div class="card done"><b>All ${items.length} answered.</b><br>Thank you. You can still go back and change any answer.</div>`;
    $("#count").textContent = `${items.length} of ${items.length} answered`;
    return;
  }
  at = Math.max(0, Math.min(items.length - 1, at + d));
  render();
}

document.addEventListener("click", (e) => {
  const b = e.target.closest("button[data-v]");
  if (b) answer(b.dataset.v === "no_bar" ? "no_bar" : Number(b.dataset.v));
});
$("#prev").onclick = () => go(-1); $("#next").onclick = () => go(1);
document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key.toLowerCase();
  if (/^[0-9]$/.test(k)) answer(Number(k) / 10);
  else if (k === "f") answer(1);
  else if (k === "n") answer("no_bar");
  else if (k === "arrowright" || k === "k") go(1);
  else if (k === "arrowleft" || k === "j") go(-1);
  else return;
  e.preventDefault();
});

(async () => {
  items = await (await fetch("/items")).json();
  answers = await (await fetch("/answers")).json();
  const first = items.findIndex((i) => !answers[i.item]);
  at = first < 0 ? 0 : first;
  if (Object.keys(answers).length) document.getElementById("help").open = false;
  render();
})();
</script>
</body>
</html>
"""


def serve(data):
    argv = sys.argv
    port = int(argv[argv.index("--port") + 1]) if "--port" in argv else 8777
    items_path = os.path.join(data, "grading", "items.json")
    key = load(os.path.join(data, "grading", "key.json"))
    grades_path = os.path.join(data, "grades.json")
    lock = threading.Lock()
    items_bytes = open(items_path, "rb").read()

    def grades():
        return load(grades_path) if os.path.exists(grades_path) else {"answers": {}}

    class Handler(BaseHTTPRequestHandler):
        def send(self, code, body, kind="application/json"):
            body = body.encode() if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", kind + "; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def local(self):
            # only this machine's own page: no DNS rebinding (Host) and no cross-site posts (JSON only)
            return self.headers.get("Host", "") in ("127.0.0.1:%d" % port, "localhost:%d" % port)

        def do_GET(self):
            if not self.local():
                return self.send(403, "{}")
            if self.path in ("/", "/index.html"):
                self.send(200, PAGE, "text/html")
            elif self.path == "/items":
                self.send(200, items_bytes)
            elif self.path == "/answers":
                with lock:
                    g = grades()
                self.send(200, json.dumps({k: {"answer": v["answer"]} for k, v in g["answers"].items()}))
            else:
                self.send(404, "{}")

        def do_POST(self):
            if not self.local() or not self.headers.get("Content-Type", "").startswith("application/json"):
                return self.send(403, "{}")
            if self.path != "/grade":
                return self.send(404, "{}")
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                item, answer = body["item"], body["answer"]
                if item not in key:
                    raise ValueError("unknown item")
                if answer != "no_bar":
                    answer = round(float(answer), 1)
                    if not 0 <= answer <= 1:
                        raise ValueError("out of range")
            except (ValueError, KeyError, TypeError) as e:
                return self.send(400, json.dumps({"error": str(e)}))
            with lock:
                g = grades()
                g["answers"][item] = {"checkpoint": key[item], "answer": answer, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
                g["complete"] = len(g["answers"]) == len(key)
                save(grades_path, g)
            self.send(200, json.dumps({"saved": len(g["answers"]), "of": len(key)}))

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("grading page: http://127.0.0.1:%d/  (answers go to %s; Ctrl-C to stop)" % (port, grades_path), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    d = data_dir()
    if len(sys.argv) > 1 and sys.argv[1] == "prepare":
        prepare(d)
    elif len(sys.argv) > 1 and sys.argv[1] == "serve":
        serve(d)
    else:
        sys.exit(__doc__)
