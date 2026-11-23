"""Write research/market-landscape.md and research/catalogue.csv from the research data.

    python3 -I research/build_report.py

Reads the same files as build_page.py (products.json, analysis.json, reddit-posts.json,
spot-check.json), so the report and the page always say the same thing.
"""
import csv
import json
import re
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
from common import CATEGORY, FEATURES, STAGE, method_text  # noqa: E402

data = json.loads((here / "products.json").read_text())
analysis = json.loads((here / "analysis.json").read_text())
reddit = json.loads((here / "reddit-posts.json").read_text())
spot = json.loads((here / "spot-check.json").read_text())
decision = json.loads((here / "decision.json").read_text())
S = analysis.get("synthesis") or {}
counts = data.get("counts", {})
AS_OF = data.get("as_of", "")

MARK = {"yes": "●", "partial": "◐", "no": "·", "unknown": "?"}
products = [p for p in data["products"] if p.get("in_scope") is not False]
ref = next(p for p in data["products"] if p.get("is_reference"))
by_id = {p["id"]: p for p in data["products"] + data.get("adjacent", [])}


def cell(s):
    return str(s if s is not None else "").replace("|", "/").replace("\n", " ").strip()


def split_points(text):
    """Sub-points arrive as "\n- a\n- b" or inline as "Head: - a. - b."; return [head, a, b]."""
    text = str(text)
    parts = re.split(r"\n\s*[-•]\s+", text)
    if len(parts) > 1:
        return parts
    m = re.search(r":\s+-\s+", text)
    if not m:
        return [text]
    return [text[: m.start() + 1]] + re.split(r"\s+-\s+(?=\S)", text[m.end():])


def bullet(text):
    head, *subs = split_points(text)
    return "\n".join([f"- {head.strip()}"] + [f"  - {x.strip()}" for x in subs])


def name(pid):
    return by_id.get(pid, {}).get("name", pid)


def names(ids):
    return ", ".join(name(i) for i in (ids or []))


def fv(p, k):
    f = (p.get("features") or {}).get(k) or {}
    return f.get("v", "unknown") if isinstance(f, dict) else str(f)


def price(p):
    usd = p.get("price_usd")
    if isinstance(usd, (int, float)) and usd >= 0:
        return "Free" if usd == 0 else f"${usd:,.0f}"
    t = (p.get("price_text") or "?").replace("unverified:", "").strip()
    return t[:40] + ("…" if len(t) > 40 else "")


def traction(p):
    t = p.get("traction") or {}
    bits = []
    if t.get("github_stars"):
        bits.append(f"{t['github_stars']:,} stars")
    if t.get("backers"):
        bits.append(f"{t['backers']:,} backers")
    if t.get("raised_usd"):
        bits.append(f"${t['raised_usd']:,.0f} raised")
    return ", ".join(bits)


def tier_rows(tier):
    ps = [p for p in products if p.get("tier") == tier]
    first = [p for p in ps if p.get("is_reference")]
    return first + sorted((p for p in ps if not p.get("is_reference")), key=lambda p: p["name"].lower())


out = []
w = out.append

# ---------- title and bottom line ----------
D0 = decision
w("# What already exists around Burnbot: market landscape")
w("")
w(f"Research as of {AS_OF}. The interactive version, with filters, every product's sources and the full catalogue, "
  "is `market-map.html` in this folder (published privately at https://claude.ai/artifact/58UU5hcDAYTTA7yfLhdqWJ; share it from the page's Share menu). The data behind both is in `products.json`.")
w("")
w("## Bottom line")
w("")
if D0.get("lede"):
    w(f"**{D0['lede']}**")
    w("")
    w("What the research says:")
    w("")
if S.get("headline"):
    w(S["headline"])
    w("")
for b in S.get("summary_bullets", []):
    w(bullet(b))
w("")

# ---------- going forward (from decision.json) ----------
D = decision
FW = D.get("forward")
if FW:
    w(f"## {FW['title']}")
    w("")
    w(FW["intro"])
    w("")
    for t in FW["tracks"]:
        w(f"**{t['name']}**")
        w("")
        for it in t["items"]:
            a, b = it["weeks"]
            when = f"Week {a}" if a == b else f"Weeks {a} to {b}"
            w(f"- _{when}:_ {it['text']}")
        w("")
    if FW.get("after"):
        w(f"**{FW['after']['title']}**")
        w("")
        for x in FW["after"]["points"]:
            w(f"- {x}")
        w("")
    w(f"_{FW['not_now']}_")
    w("")
    w(f"**{FW.get('gauges_title', 'How we would know')}**")
    w("")
    for g in FW["gauges"]:
        refs = ", ".join(m["label"] for m in g.get("marks", []) if m.get("ref"))
        w(f"- {g['label']}: {g['note']}" + (f" (for comparison: {refs})" if refs else ""))
    for x in FW["also_watch"]:
        w(f"- {x}")
    w("")

# ---------- should we enter (our reflections, from decision.json) ----------
w("## Should we enter?")
w("")
w(f"_{D['note']}_")
w("")
w(D["framing"])
w("")
w("### For")
w("")
for x in D["pros"]:
    w(f"- **{x['point']}.** {x['evidence']}")
w("")
w("### Against")
w("")
for x in D["cons"]:
    w(f"- **{x['point']}.** {x['evidence']}")
w("")
DC = D.get("device_case")
if DC:
    w(f"### {DC['title']}")
    w("")
    w(DC["intro"])
    w("")
    w("**For a device**")
    w("")
    for x in DC["pros"]:
        w(f"- **{x['point']}.** {x['evidence']}")
    w("")
    w("**Against selling one**")
    w("")
    for x in DC["cons"]:
        w(f"- **{x['point']}.** {x['evidence']}")
    w("")
w("### The options")
w("")
w("| Option | Call | Why |")
w("|---|---|---|")
for o in D["options"]:
    w(f"| {cell(o['option'])} | {cell(o['verdict'])} | {cell(o['why'])} |")
w("")
w("### Keep going if")
w("")
for s in D["signals"]["go"]:
    w(f"- {s}")
w("")
w("### Stop or shrink if")
w("")
for s in D["signals"]["stop"]:
    w(f"- {s}")
w("")
w("### Best bets, cheapest first")
w("")
for b in D["bets"]:
    w(f"- **{b['bet']}** ({b['effort']}). {b['why']}")
w("")

# ---------- numbers ----------
t1, t2 = tier_rows("T1"), tier_rows("T2")
w("## In numbers")
w("")
w("| | |")
w("|---|--:|")
w(f"| Products found (after merging duplicates) | {counts.get('catalogue', 0):,} |")
w(f"| Direct products profiled in full (T1) | {len([p for p in t1 if not p.get('is_reference')])} |")
w(f"| Same-job tools profiled in full (T2) | {len(t2)} |")
w(f"| Adjacent gadgets and platform features, short profile (T3) | {len(data.get('adjacent', []))} |")
w(f"| Corrections made by the fact-checkers | {counts.get('verify_changes', 0)} |")
w(f"| Reddit posts with scores | {len(reddit['posts'])} |")
w("")
w("T1 means made for AI coding agents and living outside the terminal: desk hardware, status lights, desktop pets and overlays. "
  "T2 does the same job in another form: menu-bar monitors, statuslines, phone and approval apps, dashboards. "
  "T3 is general desk gadgets and the AI companies' own features.")
w("")

# ---------- where Burnbot stands ----------
w("## Where Burnbot stands")
w("")
w("### What only Burnbot does, or nearly")
w("")
for u in S.get("reference_unique", []):
    w(f"- **{u.get('point', '')}** {u.get('evidence', '')}")
w("")
w("### Where Burnbot is behind")
w("")
for b in S.get("reference_behind", []):
    who = names(b.get("who_does_it"))
    w(f"- **{b.get('point', '')}** {b.get('evidence', '')}" + (f" *Who does it: {who}.*" if who else ""))
w("")
w("### Threats")
w("")
SEV = {"high": 0, "medium": 1, "low": 2}
for t in sorted(S.get("threats", []), key=lambda t: SEV.get(t.get("severity"), 3)):
    who = names(t.get("who"))
    w(f"- **{(t.get('severity') or '?').upper()}: {t.get('threat', '')}** {t.get('why', '')}" + (f" *Who: {who}.*" if who else ""))
w("")
w("### Openings")
w("")
EFF = {"small": 0, "medium": 1, "large": 2}
for o in sorted(S.get("opportunities", []), key=lambda o: EFF.get(o.get("effort"), 3)):
    w(f"- **{(o.get('effort') or '?').capitalize()} effort: {o.get('opportunity', '')}** {o.get('evidence', '')}")
w("")

# ---------- categories ----------
w("## The market, by category")
w("")
for c in S.get("categories", []):
    w(f"### {c.get('name', '')}")
    w("")
    if c.get("description"):
        w(c["description"])
        w("")
    if c.get("leaders"):
        w(f"Leaders: {names(c['leaders'])}.")
        w("")
    for o in c.get("observations", []):
        w(bullet(o))
    if c.get("observations"):
        w("")

w("### What is common and what is rare")
w("")
for f in S.get("feature_landscape", []):
    w(bullet(f))
w("")

# ---------- feature matrix ----------
w("## Feature matrix")
w("")
w("Every product profiled in full, checked against the same 20 points. ● yes · ◐ partly · · no · ? not shown on any page we read "
  "(which is not the same as no). Burnbot is the first row.")
w("")
HALVES = [("Seeing and acting on sessions", ["agent_status", "multi_session", "permission_alert", "approve_from_device", "jump_to_session",
                                             "token_usage_cost", "plan_limits", "second_screen_mode", "physical_controls", "voice_input", "sound_voice_out"]),
          ("Insight and character", ["personal_baseline_levels", "test_build_red_green", "loop_stuck_detection", "drift_away_detection",
                                     "ai_session_recap", "history_dashboard", "streaks_goals_achievements", "leaderboard", "character_personality"])]
LABEL = dict(FEATURES)
for tier, title in (("T1", "Direct products (T1)"), ("T2", "Same-job tools (T2)")):
    ps = tier_rows(tier)
    if tier == "T2":
        ps = [ref] + ps
    w(f"### {title}")
    w("")
    w("| Product | Maker | Form | Platforms | Agents | Price | Stage | Traction |")
    w("|---|---|---|---|---|---|---|---|")
    for p in ps:
        nm = f"**{p['name']}** (us)" if p.get("is_reference") else f"[{cell(p['name'])}]({p.get('primary_url', '')})"
        ag = p.get("agents_supported") or []
        ags = ", ".join(ag[:3]) + (f" +{len(ag) - 3}" if len(ag) > 3 else "")
        w(f"| {nm} | {cell(p.get('maker', '?'))} | {cell(', '.join(p.get('form_factors') or []))} | {cell(', '.join(p.get('os') or []))} | "
          f"{cell(ags)} | {cell(price(p))} | {STAGE.get(p.get('stage'), p.get('stage', '?'))} | {cell(traction(p))} |")
    w("")
    for half, keys in HALVES:
        w(f"**{half}**")
        w("")
        w("| Product | " + " | ".join(LABEL[k] for k in keys) + " |")
        w("|---|" + "|".join(":-:" for _ in keys) + "|")
        for p in ps:
            nm = f"**{p['name']}**" if p.get("is_reference") else cell(p["name"])
            w(f"| {nm} | " + " | ".join(MARK.get(fv(p, k), "?") for k in keys) + " |")
        w("")

t1_others = [p for p in t1 if not p.get("is_reference")]
w(f"### How common each feature is among the {len(t1_others)} direct products")
w("")
w("| Feature | Yes | Partly | Share with it | Burnbot |")
w("|---|--:|--:|--:|:-:|")
rows = []
for k, lab in FEATURES:
    y = sum(fv(p, k) == "yes" for p in t1_others)
    pa = sum(fv(p, k) == "partial" for p in t1_others)
    rows.append((y + pa, y, pa, lab, k))
for tot, y, pa, lab, k in sorted(rows, key=lambda r: (-r[0], -r[1])):
    w(f"| {lab} | {y} | {pa} | {round(100 * tot / max(1, len(t1_others)))}% | {MARK.get(fv(ref, k), '?')} |")
w("")

# ---------- demand ----------
w("## What people ask for")
w("")
for d in S.get("demand_takeaways", []):
    w(bullet(d))
w("")
LANE = {"reddit": "Reddit", "crowdfunding": "Crowdfunding comments", "hn": "Hacker News", "skeptics": "Skeptics"}
RANK = {"strong": 0, "moderate": 1, "weak": 2}
themes = [dict(t, lane=d["lane"]) for d in analysis.get("demand", []) for t in d.get("themes", [])]
themes = [t for t in themes if t.get("strength") == "strong"]
if themes:
    w("### The strongest themes, with what people said")
    w("")
    for t in sorted(themes, key=lambda t: RANK.get(t.get("strength"), 3)):
        w(f"**{t['theme']}** ({LANE.get(t['lane'], t['lane'])})")
        w("")
        w(t.get("summary", ""))
        w("")
        for q in (t.get("quotes") or [])[:2]:
            where = ", ".join(x for x in (q.get("where"), q.get("date")) if x)
            w(f"> \"{cell(q.get('text'))}\" ([{where or 'source'}]({q.get('url', '')}))")
            w("")

# ---------- reddit ----------
w("## Seen on Reddit")
w("")
w(f"{len(reddit['posts'])} posts the research cited, with score and comment count from the {reddit.get('source', 'Reddit archive')}. "
  "\"Built\" means someone showing what they made; \"Talk\" is a discussion.")
w("")
built = [p for p in reddit["posts"] if p["kind"] == "built"]
w(f"Of the {len(built)} show-and-tell posts, the top two are physical: an ESP32 limit meter ({built[0]['score']:,}) and a desk lamp "
  f"used as a status light ({built[1]['score']:,}).")
w("")
w("| Score | Comments | Kind | Post | Posted |")
w("|--:|--:|---|---|---|")
for p in reddit["posts"]:
    title = cell(p["title"])
    title = title[:110] + ("…" if len(title) > 110 else "")
    mark = " ← the post that started this" if p["id"] == "1xveugv" else ""
    w(f"| {p['score']:,} | {p['comments']:,} | {p['kind'].capitalize()} | [{title}]({p['url']}) r/{p['subreddit']}{mark} | {p['date']} |")
w("")

# ---------- pricing ----------
w("## Pricing benchmarks")
w("")
w("| Segment | Range | Examples |")
w("|---|---|---|")
for b in S.get("pricing_benchmarks", []):
    ex = b.get("examples") or []
    w(f"| {cell(b.get('segment'))} | {cell(b.get('range'))} | {cell('; '.join(ex) if isinstance(ex, list) else ex)} |")
w("")

# ---------- questions ----------
w("## Questions to settle")
w("")
for q in S.get("open_questions", []):
    w(bullet(q))
w("")

# ---------- method ----------
w("## How this was made")
w("")
w(method_text(counts, analysis.get("finders", []), len(spot["results"])))
w("")
w("Prices, backer counts and star counts move. Each is as of the date in its source note in `products.json`.")
w("")
w("### The headline claims, checked a second time")
w("")
w("| Result | Claim | Note |")
w("|---|---|---|")
VERD = {"confirmed": "Confirmed", "partly": "Mostly", "refuted": "Wrong", "unverifiable": "Unclear"}
for r in spot["results"]:
    w(f"| {VERD.get(r['verdict'], r['verdict'])} | {cell(r['claim'])} | {'' if r['verdict'] == 'confirmed' else cell(r['note'])} |")
w("")
gaps = [g for g in (analysis.get("critic") or {}).get("gaps", []) if g.get("kind") != "weak-claim"]
if gaps:
    w("### What this research does not cover well")
    w("")
    for g in gaps:
        w(f"- {g['description']}")
    w("")

# ---------- appendix ----------
w("## Appendix: adjacent gadgets and platform features (T3)")
w("")
w("| Name | Maker | What | Price |")
w("|---|---|---|---|")
for a in sorted(data.get("adjacent", []), key=lambda a: a["name"].lower()):
    if a.get("in_scope") is False:
        continue
    w(f"| [{cell(a['name'])}]({a.get('primary_url', '')}) | {cell(a.get('maker'))} | {cell(a.get('one_liner'))} | {cell(price(a))} |")
w("")
w("## Files")
w("")
w("- `market-map.html`: the interactive page, built by `build_page.py` from the template.")
w(f"- `catalogue.csv`: all {counts.get('catalogue', 0):,} products found, one row each, for a spreadsheet.")
w("- `products.json`: full records, sources and verification for every profiled product, plus the catalogue.")
w("- `analysis.json`: the write-up, demand research and completeness review. `reddit-posts.json`, `spot-check.json`: as named.")
w("- `assemble.py` → `curate.py` → `build_page.py` / `build_report.py`: rebuild everything from the research run.")
w("")

(here / "market-landscape.md").write_text("\n".join(out))

# ---------- catalogue.csv ----------
profiled = {p["id"] for p in data["products"]} | {a["id"] for a in data.get("adjacent", [])}
with open(here / "catalogue.csv", "w", newline="") as f:
    cw = csv.writer(f)
    cw.writerow(["name", "tier", "category", "profiled", "notability", "what it is", "link", "also known as"])
    for c in sorted(data.get("catalogue", []), key=lambda c: (c.get("tier", "T9"), c.get("category", ""), c["name"].lower())):
        cw.writerow([c["name"], c.get("tier", ""), CATEGORY.get(c.get("category"), c.get("category", "")),
                     "yes" if c["id"] in profiled or c.get("profiled") else "", c.get("notability", ""),
                     c.get("one_liner", ""), c.get("primary_url", ""),
                     "; ".join(m for m in c.get("members", []) if m != c["name"])[:200]])

print(f"research/market-landscape.md: {len(out)} lines; research/catalogue.csv: {len(data.get('catalogue', []))} rows")
