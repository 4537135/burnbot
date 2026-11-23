"""Build research/market-map.html from the template, the data and Burnbot's pixel font.

    python3 research/build_page.py

Reads research/products.json, analysis.json, reddit-posts.json and spot-check.json,
inlines public/pixel.css (Burnbot's own pixel font) and writes research/market-map.html,
a single page with everything in it.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from common import method_text  # noqa: E402

here = pathlib.Path(__file__).resolve().parent
repo = here.parent

data = json.loads((here / "products.json").read_text())
analysis = json.loads((here / "analysis.json").read_text())
reddit = json.loads((here / "reddit-posts.json").read_text())
spot = json.loads((here / "spot-check.json").read_text())
decision = json.loads((here / "decision.json").read_text())
font =(repo / "public" / "pixel.css").read_text()
template = (here / "market-map.template.html").read_text()

# The page doesn't need the per-stage verification log, only its summary.
for p in data["products"]:
    p.get("verification", {}).pop("log", None)

# The catalogue only needs what its table shows.
data["catalogue"] = [
    {
        "id": c["id"],
        "name": c["name"],
        "aliases": [m for m in c.get("members", []) if m != c["name"]][:3],
        "primary_url": c.get("primary_url"),
        "one_liner": c.get("one_liner"),
        "category": c.get("category"),
        "tier": c.get("tier"),
        "profiled": bool(c.get("profiled")),
    }
    for c in sorted(data.get("catalogue", []), key=lambda c: (not c.get("profiled"), {"high": 0, "medium": 1, "low": 2}.get(c.get("notability"), 3), c["name"].lower()))
]

counts = data.get("counts", {})
finders = analysis.get("finders", [])
analysis = dict(analysis, finders=[{"lane": f["lane"], "returned": f["returned"]} for f in finders])
analysis.pop("synthesis_check", None)  # the checker's change log stays in analysis.json
analysis["method"] = method_text(counts, finders, len(spot["results"]))

community = dict(reddit)
for p in community["posts"]:
    p["highlight"] = p["id"] == "1xveugv"
built = [p for p in community["posts"] if p["kind"] == "built"]
talk = [p for p in community["posts"] if p["kind"] == "talk"]
community["notes"] = [
    f"Of the {len(built)} show-and-tell posts, the highest-scoring are physical: an ESP32 limit meter ({built[0]['score']:,}) and a desk lamp as a status light ({built[1]['score']:,}). "
    "Showing plan limits and showing 'it needs you' on something you can see from across the desk is what gets upvoted.",
    "The busiest discussions are about limits draining and waiting: what to do while Claude works, babysitting parallel sessions, and staying in flow.",
    "Removing /buddy from Claude Code drew two threads and a GitHub issue with over a thousand thumbs-up, so people do want a character in the loop.",
]

spot_rows = [{k: r[k] for k in ("id", "claim", "verdict", "note")} for r in spot["results"]]
payload = json.dumps({"data": data, "analysis": analysis, "community": community, "spot": spot_rows, "decision": decision}, ensure_ascii=False, separators=(",", ":"))
payload = payload.replace("</", "<\\/")  # keep "</script>" inside strings from closing the tag

# Burnbot's own robot drawing code guides the story; inline it as a plain module body.
robot = (repo / "public" / "robot.js").read_text()
robot = "\n".join(l[len("export "):] if l.startswith("export ") else l for l in robot.split("\n"))
assert "</script" not in robot.lower()
page = (template.replace("/*PIXEL_FONT*/", font)
        .replace("/*ROBOT_JS*/", robot)
        .replace("__PAYLOAD__", payload))
out = here / "market-map.html"
out.write_text(page)
print(f"{out.relative_to(repo)}: {len(page) / 1024:.0f} KB, {len(data['products'])} products, "
      f"{len(data.get('adjacent', []))} adjacent, {len(data['catalogue'])} in catalogue, {len(community['posts'])} Reddit posts")
