"""Editorial fixes on top of assemble.py's output. Safe to run more than once.

    python3 -I research/curate.py

Run after assemble.py and before build_page.py. It edits research/products.json
in place and copies the spot-check verdicts (research/spot-check.json) onto the
products they cover.

1. Anthropic's Hardware Buddy was profiled twice under two ids (same repo).
   The fuller record is kept and the other is folded into it.
2. Two different products are called "Clauddy". The id "clauddy" goes to the
   desktop pet from the r/ClaudeAI post (renatoaug/claude-usage-monitor); the
   Divoom speaker hack becomes "divoom-clauddy".
3. Corrections from the refute-first spot check.
"""
import json
from pathlib import Path

here = Path(__file__).resolve().parent
d = json.loads((here / "products.json").read_text())
spot = json.loads((here / "spot-check.json").read_text())
P = {p["id"]: p for p in d["products"]}
CAT = {c["id"]: c for c in d["catalogue"]}
log = []


def rename(old, new, name):
    if old not in P or new in P:
        return
    p = P.pop(old)
    p["id"], p["name"] = new, name
    P[new] = p
    if old in CAT:
        c = CAT.pop(old)
        c["id"], c["name"] = new, name
        CAT[new] = c
    log.append(f"renamed {old} -> {new}")


def fold(dup, keep, why):
    if dup not in P or keep not in P:
        return
    a, b = P[keep], P.pop(dup)
    seen = {s["url"] for s in a.get("sources", [])}
    a["sources"] = a.get("sources", []) + [s for s in b.get("sources", []) if s["url"] not in seen]
    va, vb = a.setdefault("verification", {}), b.get("verification", {})
    va["stages"] = sorted(set(va.get("stages", [])) | set(vb.get("stages", [])))
    va["changes"] = va.get("changes", 0) + vb.get("changes", 0)
    a["merged_from"] = a.get("merged_from", []) + [dup]
    if dup in CAT:
        c = CAT.pop(dup)
        k = CAT.get(keep)
        if k is not None:
            k["members"] = list(dict.fromkeys(k.get("members", []) + c.get("members", []) + [c["name"]]))
    log.append(f"folded {dup} into {keep}: {why}")


# 1 + 2 (order matters: free the "clauddy" id first)
fold("claude-desktop-buddy-protocol", "anthropic-desktop-buddy", "same repo, profiled twice")
fold("claude-face-gadget-30", "anthropic-desktop-buddy", "Yanko Design's '$30 gadget' headline for the same Anthropic repo")
rename("clauddy", "divoom-clauddy", "Clauddy for Divoom MiniToo (bugzmanov)")
rename("claude-usage-monitor-pet", "clauddy", "Clauddy (desktop pet, renatoaug)")

# 3: spot-check corrections that change a record
def note(pid, key, text):
    p = P.get(pid)
    if p and text not in (p["features"].get(key, {}).get("note") or ""):
        f = p["features"].setdefault(key, {"v": "unknown"})
        f["note"] = ((f.get("note") or "") + " " + text).strip()


if "codexbar" in P:
    p = P["codexbar"]
    if "Linux" not in p.get("os", []):
        p["os"] = p.get("os", []) + ["Linux"]
    note("codexbar", "plan_limits", "Covers 114 providers as of 2026-11-18 (up from about 80 in September); Linux desktop app and CLI exist too.")
if "pixel-agents" in P:
    p = P["pixel-agents"]
    if "web-app" not in p.get("form_factors", []):
        p["form_factors"] = p.get("form_factors", []) + ["web-app"]
    note("pixel-agents", "agent_status", "Also runs outside VS Code: `npx pixel-agents` serves the office in a browser; listed on Open VSX. Roadmap names Codex, Gemini and Cursor.")
note("clauddy", "plan_limits", "Catches fire when session usage passes a configurable threshold (90% by default). The npm 'clauddy' package is a launcher that downloads the native app.")

# spot-check verdicts onto the records they cover
COVERS = {"slashvibe": ["slashvibe"], "codex-micro": ["codex-micro"], "clawd-on-desk": ["clawd-on-desk"],
          "hardware-buddy": ["anthropic-desktop-buddy"], "pixel-agents": ["pixel-agents"], "codexbar": ["codexbar"],
          "small-campaigns": ["ctrlvibe", "agentdeck-hardware", "token-monitor-fractal"], "agent-cat": ["agent-cat"],
          "codeburn": ["codeburn"], "clauddy": ["clauddy"],
          "prices": ["usagebar", "vibe-buddy", "vibekeys", "vibe-island", "claudeassistant-freakstudio"]}
# The spot-checker could not reach Reddit; the Arctic Shift archive could (see reddit-posts.json).
for r in spot["results"]:
    if r["id"] == "clauddy" and "Arctic Shift" not in r["note"]:
        r["claim"] = r["claim"].replace("on 2026-11-18 as", "on 2026-11-13 as")
        r["note"] += (" Added after the check: the Arctic Shift Reddit archive shows the post went up on 2026-11-13 "
                      "(not 11-18), by u/SuccessfulCress7441, with 179 points and 27 comments as archived.")
        (here / "spot-check.json").write_text(json.dumps(spot, indent=1, ensure_ascii=False))
        log.append("spot-check: Clauddy Reddit date corrected from the archive")

for r in spot["results"]:
    for pid in COVERS.get(r["id"], []):
        if pid in P:
            P[pid]["spot_check"] = {"verdict": r["verdict"], "claim": r["claim"], "note": r["note"]}

d["products"] = list(P.values())
d["catalogue"] = list(CAT.values())
prof = [p for p in d["products"] if not p.get("is_reference") and p.get("in_scope") is not False]
d["counts"].update({
    "catalogue": len(d["catalogue"]),
    "profiled": sum(1 for p in d["products"] if not p.get("is_reference")),
    "profiled_t1": sum(1 for p in prof if p["tier"] == "T1"),
    "profiled_t2": sum(1 for p in prof if p["tier"] == "T2"),
    "out_of_scope_after_profile": sum(1 for p in d["products"] if p.get("in_scope") is False),
    "spot_checked": len(spot["results"]),
})
d["curation"] = sorted(set(d.get("curation", []) + log))
(here / "products.json").write_text(json.dumps(d, indent=1, ensure_ascii=False))
print("\n".join(log) or "nothing to do (already curated)")
print({k: d["counts"][k] for k in ("catalogue", "profiled", "profiled_t1", "profiled_t2", "out_of_scope_after_profile")})
missing = [pid for ids in COVERS.values() for pid in ids if pid not in P]
if missing:
    print("spot-check ids not found:", missing)
