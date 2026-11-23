"""Stage A, step 1: read interactive Claude Code sessions into compact event timelines.

    python3 -I tools/progress-eval/extract.py --data DIR [--exclude SESSION_ID ...] [--active-minutes 60]

Reads ~/.claude/projects/*/<session>.jsonl (main logs only, read-only). Keeps only
interactive sessions (entrypoint claude-vscode, claude-desktop or cli) and skips any log
written to in the last --active-minutes (a session still running). Writes
DIR/sessions/<id>.json and DIR/sessions.json (an index). Nothing is written anywhere else.
"""

import glob
import json
import os
import sys
import time

sys.dont_write_bytecode = True  # keep the repo free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (INTERACTIVE, EXIT_CODE, classify, clip, data_dir, git_action, is_interrupt, measure, ms,
                    prompt_text, save, typed_only, verdict)

ROOT = os.path.expanduser("~/.claude/projects")
WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic")
SEARCH_TOOLS = {"Grep", "Glob", "WebSearch", "WebFetch", "ToolSearch", "LS"}
QUIET_TOOLS = {"TaskStop", "TaskOutput", "ListAgents", "Monitor", "ScheduleWakeup", "BashOutput", "KillShell", "Skill"}


def result_text(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return ""


def checklist_apply(state, inp, result):
    """The checklist after one update. state: list of [content, status]."""
    items = inp.get("items") or inp.get("todos")
    if isinstance(items, list) and items:
        return [[clip(i.get("content") or i.get("activeForm") or "", 100), i.get("status", "pending")] for i in items if isinstance(i, dict)]
    state = [list(x) for x in state]
    if inp.get("advance") and state:
        cur = next((i for i, x in enumerate(state) if x[1] == "in_progress"), None)
        if cur is not None:
            state[cur][1] = "completed"
            nxt = next((i for i in range(cur + 1, len(state)) if state[i][1] == "pending"), None)
            if nxt is not None:
                state[nxt][1] = "in_progress"
    if isinstance(inp.get("done"), list) and state:
        for n in inp["done"]:
            if isinstance(n, int) and 1 <= n <= len(state):
                state[n - 1][1] = "completed"
        start = inp.get("start")
        if isinstance(start, int) and 1 <= start <= len(state):
            for i, x in enumerate(state):
                if x[1] == "in_progress":
                    x[1] = "completed" if i < start - 1 else "pending"
            state[start - 1][1] = "in_progress"
    # "Plan updated: step 3 of 7 is in progress." is the app's own count: trust it.
    import re
    m = re.search(r"step (\d+) of (\d+) is in progress", result or "")
    if m and state and int(m.group(2)) == len(state):
        k = int(m.group(1))
        for i, x in enumerate(state):
            x[1] = "completed" if i < k - 1 else ("in_progress" if i == k - 1 else "pending")
    return state


def parse(path):
    objs = []
    with open(path, "rb") as f:
        for line in f:
            try:
                objs.append(json.loads(line))
            except ValueError:
                pass
    entry = next((o.get("entrypoint") for o in objs[:80] if "entrypoint" in o), None)
    if entry not in INTERACTIVE:
        return None
    cwd = next((o.get("cwd") for o in objs if o.get("cwd")), "") or ""
    if "/.claude/worktrees/" in cwd:
        cwd = cwd.split("/.claude/worktrees/")[0]
    project = os.path.basename(cwd.rstrip("/")) or cwd

    events, pending, checklist = [], {}, []
    for o in objs:
        if o.get("isSidechain"):
            continue
        t = ms(o.get("timestamp"))
        typ = o.get("type")
        if typ == "system" and o.get("subtype") == "compact_boundary" and t:
            events.append({"k": "compact", "t": t})
            continue
        msg = o.get("message")
        if t is None or not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if typ == "assistant" and isinstance(content, list):
            if msg.get("model") == "<synthetic>":
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and (b.get("text") or "").strip():
                    events.append({"k": "say", "t": t, "text": b["text"].strip()[:4000]})
                if b.get("type") != "tool_use":
                    continue
                name, inp, tid = b.get("name") or "", b.get("input") or {}, b.get("id")
                if name in WRITE_TOOLS:
                    target = inp.get("file_path") or inp.get("notebook_path") or ""
                    events.append({"k": "edit", "t": t, "file": target, "tool": name})
                elif name == "Bash":
                    cmd = inp.get("command") or ""
                    kind = classify(cmd)
                    git = git_action(cmd)
                    pending[tid] = {"name": name, "cmd": cmd, "kind": kind, "git": git, "t0": t,
                                    "bg": inp.get("run_in_background") is True, "desc": inp.get("description") or ""}
                elif name == "Read":
                    f = inp.get("file_path") or ""
                    events.append({"k": "look" if f.lower().endswith(IMAGE_EXT) else "read", "t": t, "file": f})
                elif "screenshot" in name.lower() or name.endswith("__computer") and inp.get("action") == "screenshot":
                    events.append({"k": "look", "t": t, "file": name.split("__")[-1]})
                elif name in SEARCH_TOOLS:
                    what = inp.get("pattern") or inp.get("query") or inp.get("url") or ""
                    events.append({"k": "search", "t": t, "tool": name, "what": clip(str(what), 80)})
                elif name == "Agent" or name == "Task":
                    events.append({"k": "agent", "t": t, "desc": clip(inp.get("description") or "", 80),
                                   "type": inp.get("subagent_type") or ""})
                elif name == "ExitPlanMode":
                    pending[tid] = {"name": name, "plan": inp.get("plan") or "", "t0": t}
                elif name == "AskUserQuestion":
                    pending[tid] = {"name": name, "t0": t,
                                    "questions": [clip(q.get("question") or "", 300) for q in inp.get("questions") or [] if isinstance(q, dict)]}
                elif name in ("TodoWrite", "mcp__ccd_turn__update_plan"):
                    pending[tid] = {"name": name, "inp": inp, "t0": t}
                elif name == "mcp__ccd_turn__wrap_up":
                    events.append({"k": "wrapup", "t": t, "recap": clip(inp.get("recap") or "", 400), "ask": clip(inp.get("ask") or "", 200),
                                   "blocked": bool(inp.get("blocked"))})
                elif name in QUIET_TOOLS:
                    continue
                else:
                    events.append({"k": "tool", "t": t, "name": name})
            continue
        if typ != "user":
            continue
        if isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            tur = o.get("toolUseResult")
            for b in content:
                if not isinstance(b, dict) or b.get("type") != "tool_result":
                    continue
                p = pending.pop(b.get("tool_use_id"), None)
                if not p:
                    continue
                text = result_text(b)
                if p["name"] == "Bash":
                    out = text
                    interrupted = False
                    if isinstance(tur, dict):
                        out = "\n".join(x for x in (tur.get("stdout") or "", tur.get("stderr") or "") if x)
                        interrupted = bool(tur.get("interrupted"))
                    head = text[:40]
                    m = EXIT_CODE.match(head)
                    code = int(m.group(1)) if m else None
                    denied = o.get("toolDenialKind") is not None or head.startswith("Permission ") or head.startswith("The user doesn't want")
                    err = bool(b.get("is_error"))
                    if p["git"] and not err and not denied:
                        events.append({"k": "git", "t": t, "what": p["git"]})
                    if p["kind"] and not p["bg"]:
                        v = verdict(p["cmd"], err, code, denied, interrupted, out[-2048:])
                        events.append({"k": "check", "t": t, "t0": p["t0"], "family": p["kind"][0], "core": clip(p["kind"][1], 120),
                                       "verdict": v, "tail": clip(out[-300:], 300) if v == "fail" else ""})
                    else:
                        events.append({"k": "bash", "t": p["t0"], "cmd": clip(p["cmd"], 160), "desc": clip(p["desc"], 80),
                                       "err": err or (code or 0) != 0, "denied": denied})
                elif p["name"] == "ExitPlanMode":
                    plan = p["plan"] or (tur.get("plan") if isinstance(tur, dict) else "") or ""
                    if text.startswith("User has approved your plan") or (isinstance(tur, dict) and tur.get("plan")):
                        events.append({"k": "plan", "t": t, "status": "approved", "plan": plan})
                    elif text.startswith("The user doesn't want to proceed") or text.startswith("User rejected"):
                        note = text.split("the user said:", 1)[1].strip() if "the user said:" in text else ""
                        events.append({"k": "plan", "t": t, "status": "rejected", "plan": plan, "note": clip(note, 1500)})
                elif p["name"] == "AskUserQuestion":
                    answers = tur.get("answers") if isinstance(tur, dict) else None
                    if isinstance(answers, dict):
                        events.append({"k": "qa", "t": t, "pairs": [[clip(q, 300), clip(str(a), 300)] for q, a in answers.items()]})
                    else:
                        events.append({"k": "qa", "t": t, "pairs": [[q, "(no answer: " + clip(text, 120) + ")"] for q in p["questions"]]})
                else:
                    checklist = checklist_apply(checklist, p["inp"], text)
                    events.append({"k": "checklist", "t": t, "items": [list(x) for x in checklist],
                                   "src": "todo" if p["name"] == "TodoWrite" else "plan"})
            continue
        text = prompt_text(o)
        if text is None:
            continue
        if is_interrupt(text):
            events.append({"k": "interrupt", "t": t})
            continue
        typed, pasted = measure(text)
        if typed == 0 and pasted == 0:
            continue
        events.append({"k": "prompt", "t": t, "text": typed_only(text, keep_pasted=600)[:8000], "typed": typed, "pasted": pasted})

    events.sort(key=lambda e: e["t"])
    # Turns: from a prompt to the last thing before the next prompt.
    turns, starts = [], [i for i, e in enumerate(events) if e["k"] == "prompt"]
    for n, s in enumerate(starts):
        end = (starts[n + 1] - 1) if n + 1 < len(starts) else len(events) - 1
        last = events[end]["t"]
        turns.append({"i": s, "j": end, "t0": events[s]["t"], "t1": last, "minutes": round((last - events[s]["t"]) / 60000, 1)})
    return {"id": os.path.basename(path)[:-6], "project": project, "entry": entry, "events": events, "turns": turns}


def main():
    data = data_dir()
    exclude = set()
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--exclude":
            exclude.add(args[i + 1])
    active = float(args[args.index("--active-minutes") + 1]) if "--active-minutes" in args else 60
    out = os.path.join(data, "sessions")
    os.makedirs(out, exist_ok=True)
    index, skipped = [], {"excluded": 0, "active": 0, "headless": 0}
    now = time.time()
    for path in sorted(glob.glob(os.path.join(ROOT, "*", "*.jsonl"))):
        sid = os.path.basename(path)[:-6]
        if sid in exclude:
            skipped["excluded"] += 1
            continue
        if now - os.path.getmtime(path) < active * 60:
            skipped["active"] += 1
            continue
        s = parse(path)
        if s is None:
            skipped["headless"] += 1
            continue
        save(os.path.join(out, sid + ".json"), s)
        long_turns = [t for t in s["turns"] if t["minutes"] >= 5]
        index.append({"id": sid, "project": s["project"], "entry": s["entry"], "turns": len(s["turns"]),
                      "long": len(long_turns), "events": len(s["events"])})
    save(os.path.join(data, "sessions.json"), index)
    print(json.dumps({"interactive": len(index), "skipped": skipped,
                      "turns": sum(x["turns"] for x in index), "long_turns": sum(x["long"] for x in index)}))


if __name__ == "__main__":
    main()
