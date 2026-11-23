"""Rebuild the market-map data from the research workflow's journal.

    python3 -I research/assemble.py <journal.jsonl> <reference.json> research/

Every agent's return value sits in journal.jsonl under its label:
  find:<lane>:r<n>, find:gap<n>   raw candidates from each search lane
  dedup:c<n>, dedup:extra         clean product lists per batch (+ drops)
  dedup:merge                     cross-batch duplicate groups
  profile:<id>                    full profile of one of the top 40
  verify:<id>, recheck:<id>       the fact-checked record and what changed
  adjacent:<id>+<id>...           short profiles of adjacent gadgets / platform features
  demand:<lane>                   what users say they want
  critic, synth                   completeness check and the write-up

A product's final record is the last one returned for it (profile -> verify -> recheck),
the same rule the workflow script used. The catalogue is every deduplicated product,
with the search lanes that found it.

Writes products.json (reference + profiled records, adjacent, catalogue) and analysis.json.
"""
import json
import re
import sys
from collections import defaultdict

journal, ref_path, out_dir = sys.argv[1], sys.argv[2], sys.argv[3].rstrip("/")
AS_OF = "2026-11-18"


def norm(s):
    s = re.sub(r"\(.*?\)", "", (s or "").lower())
    return re.sub(r"[^a-z0-9一-鿿぀-ヿ가-힯]", "", s)


def repo_key(u):
    s = re.sub(r"^https?://(www\.)?", "", str(u or "").lower())
    s = re.sub(r"[?#].*$", "", s)
    for pat, tag in [(r"^github\.com/([^/]+/[^/]+)", "gh"), (r"^kickstarter\.com/projects/([^/]+/[^/]+)", "ks"),
                     (r"^pypi\.org/project/([^/]+)", "pypi"), (r"^npmjs\.com/package/((@[^/]+/)?[^/]+)", "npm")]:
        m = re.match(pat, s)
        if m:
            return f"{tag}:{m.group(1)}"
    return ""


# ---------- read the journal ----------
label_of, results = {}, []
for line in open(journal):
    e = json.loads(line)
    if e.get("type") == "started":
        label_of[e["agentId"]] = e.get("label") or ""
    elif e.get("type") == "result" and e.get("result") is not None:
        results.append((label_of.get(e["agentId"], ""), e["result"]))

by_label = defaultdict(list)
for label, res in results:
    by_label[label].append(res)


def last(label):
    return by_label[label][-1] if by_label.get(label) else None


# ---------- candidate pool: which lanes found which name ----------
lanes_for = defaultdict(set)
for s in json.load(open(ref_path)).get("seeds", []):
    lanes_for[norm(s["name"])].add("scouting")
finder_log = []
for label, res in results:
    if not label.startswith("find:"):
        continue
    lane = label.split(":")[1]
    cands = res.get("candidates") or []
    finder_log.append({"lane": label[5:], "returned": len(cands), "searched": len(res.get("searched") or [])})
    for c in cands:
        lanes_for[norm(c.get("name"))].add(lane)

# ---------- catalogue: chunk outputs in order, code merge, agent merge ----------
chunk_labels = sorted((l for l in by_label if re.fullmatch(r"dedup:c\d+", l)), key=lambda l: int(l[7:]))
products, dropped, seen = [], [], set()


def add_products(lst, origin):
    for p in lst:
        base = p.get("id") or norm(p.get("name")) or "product"
        pid, n = base, 2
        while pid in seen:
            pid, n = f"{base}-{n}", n + 1
        p["id"] = pid
        p["origin"] = origin
        seen.add(pid)
        products.append(p)


for l in chunk_labels:
    r = last(l)
    add_products(r.get("products") or [], "search")
    dropped += r.get("dropped") or []

by_pid = {p["id"]: p for p in products}
NOTE = {"high": 3, "medium": 2, "low": 1}


def absorb(keep, x):
    if not keep or not x or keep is x:
        return
    keep["aliases"] = sorted(set((keep.get("aliases") or []) + [x["name"]] + (x.get("aliases") or [])))
    keep["urls"] = list(dict.fromkeys([u for u in (keep.get("urls") or []) + [x.get("primary_url")] + (x.get("urls") or []) if u]))
    keep["members"] = list(dict.fromkeys((keep.get("members") or []) + (x.get("members") or [])))
    if NOTE.get(x.get("notability"), 0) > NOTE.get(keep.get("notability"), 0):
        keep["notability"] = x["notability"]
    keep["commercial"] = bool(keep.get("commercial") or x.get("commercial"))
    by_pid.pop(x["id"], None)


PLATFORM = re.compile(r"(^|\.)(github\.com|github\.io|gitee\.com|kickstarter\.com|indiegogo\.com|pledgebox\.com|crowdsupply\.com|youtube\.com|reddit\.com|x\.com|twitter\.com|hackster\.io|hackaday\.(com|io)|medium\.com|dev\.to|producthunt\.com|tindie\.com|makerworld\.com|npmjs\.com|pypi\.org|apps\.apple\.com|vercel\.app|pages\.dev|netlify\.app)$")


def page_key(u):
    s = re.sub(r"^https?://(www\.)?", "", str(u or "").lower())
    return re.sub(r"[?#].*$", "", s).rstrip("/")


owner = {}
for p in list(by_pid.values()):
    if p["id"] not in by_pid:
        continue
    keys = list(dict.fromkeys(k for k in map(repo_key, [p.get("primary_url")] + (p.get("urls") or [])) if k))
    pk = page_key(p.get("primary_url"))
    if pk and "/" not in pk and not PLATFORM.search(pk):
        keys.append(f"page:{pk}")
    hit = next((owner[k] for k in keys if k in owner and owner[k]["id"] in by_pid and owner[k] is not p), None)
    if hit:
        absorb(hit, p)
    for k in keys:
        owner.setdefault(k, hit or p)

merge = last("dedup:merge") or {}
for g in merge.get("groups") or []:
    for d in g.get("duplicates") or []:
        absorb(by_pid.get(g.get("keep")), by_pid.get(d))

extra = last("dedup:extra")
if extra:
    add_products(extra.get("products") or [], "gap search")
    for p in extra.get("products") or []:
        by_pid[p["id"]] = p
    dropped += extra.get("dropped") or []

catalogue = list(by_pid.values())
for p in catalogue:
    lanes = set()
    for m in [p.get("name")] + (p.get("members") or []) + (p.get("aliases") or []):
        lanes |= lanes_for.get(norm(m), set())
    p["lanes"] = sorted(lanes)

# ---------- profiled records: profile -> verify -> recheck ----------
final, verification = {}, defaultdict(list)
for label, res in results:
    kind, _, pid = label.partition(":")
    if kind == "profile":
        rec = res.get("record", res)
        final[pid] = rec
        verification[pid].append({"stage": "profile"})
    elif kind in ("verify", "recheck") and res.get("record"):
        final[pid] = res["record"]
        verification[pid].append({"stage": kind, "changes": res.get("changes") or [], "unverified": res.get("unverified_fields") or []})

profiled = []
for pid, rec in final.items():
    rec = dict(rec)
    rec["id"] = pid
    v = verification[pid]
    rec["verification"] = {
        "stages": [x["stage"] for x in v],
        "verified": any(x["stage"] != "profile" for x in v),
        "changes": sum(len(x.get("changes", [])) for x in v),
        "unverified_fields": sorted({f for x in v for f in x.get("unverified", [])}),
        "log": [c for x in v for c in x.get("changes", [])],
    }
    profiled.append(rec)

adjacent = []
for label, res in results:
    if label.startswith("adjacent:"):
        for p in res.get("products") or []:
            p["tier"] = "T3"
            adjacent.append(p)

profiled_ids = set(final) | {a.get("id") for a in adjacent}
for p in catalogue:
    p["profiled"] = p["id"] in profiled_ids

ref = json.load(open(ref_path)).get("reference")
ref = dict(ref, id="burnbot", name="Burnbot", is_reference=True, maker="us", in_scope=True,
           primary_url="https://github.com/megamind-rgb/burnbot",
           verification={"stages": ["own README"], "verified": True, "changes": 0, "unverified_fields": [], "log": []},
           sources=[{"url": "https://github.com/megamind-rgb/burnbot", "what": "README"}], confidence="high")

in_scope = [r for r in profiled if r.get("in_scope") is not False]
data = {
    "as_of": AS_OF,
    "counts": {
        "candidates": sum(len(lanes) > 0 for lanes in lanes_for.values()),
        "catalogue": len(catalogue),
        "dropped_by_dedup": len(dropped),
        "profiled": len(profiled),
        "profiled_t1": sum(r.get("tier") == "T1" for r in in_scope),
        "profiled_t2": sum(r.get("tier") == "T2" for r in in_scope),
        "out_of_scope_after_profile": len(profiled) - len(in_scope),
        "adjacent": len(adjacent),
        "verify_changes": sum(r["verification"]["changes"] for r in profiled),
        "catalogue_by_tier": {t: sum(p.get("tier") == t for p in catalogue) for t in ("T1", "T2", "T3")},
    },
    "products": [ref] + profiled,
    "adjacent": adjacent,
    "catalogue": catalogue,
    "dropped": dropped,
}
demand = []
for label, res in results:
    if label.startswith("demand:"):
        demand.append(dict(res, lane=label.split(":", 1)[1]))
analysis = {"as_of": AS_OF, "synthesis": last("synth"), "critic": last("critic"), "demand": demand, "finders": finder_log}

json.dump(data, open(f"{out_dir}/products.json", "w"), indent=1, ensure_ascii=False)
json.dump(analysis, open(f"{out_dir}/analysis.json", "w"), indent=1, ensure_ascii=False)
print(json.dumps(data["counts"], indent=1))
print("demand lanes:", [d["lane"] for d in demand], "| synth:", bool(analysis["synthesis"]), "| critic:", bool(analysis["critic"]))
