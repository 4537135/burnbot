#!/usr/bin/env python3
"""Checks Burnbot's token counts against an independent recount.

It reads Claude Code's session logs again in the plainest way possible (no
shared code with the app: one JSON line at a time, one entry per API response
id) and compares the totals, day by day, with the history Burnbot has saved.

    python3 tools/audit.py

Burnbot may be higher on some days: it keeps what it counted from logs that
Claude Code (or another app) has since deleted. Those are listed separately.
"""
import collections, datetime, glob, json, os, sys

ROOT = os.path.expanduser('~/.claude/projects')
STORE = os.path.expanduser('~/Library/Application Support/Burnbot/store.json')

def day_of(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).strftime('%Y-%m-%d')

# ---- the recount ----
recount = collections.Counter()
per_file = {}
for path in glob.glob(ROOT + '/**/*.jsonl', recursive=True):
    best = {}
    with open(path, 'rb') as log:
        for raw in log:
            if b'"type":"assistant"' not in raw:
                continue
            try:
                line = json.loads(raw)
            except ValueError:
                continue
            message = line.get('message') or {}
            usage = message.get('usage')
            if line.get('type') != 'assistant' or not usage or message.get('model') == '<synthetic>' or not line.get('timestamp'):
                continue
            key = message.get('id') or line.get('requestId') or line.get('uuid')
            counts = [usage.get(k) or 0 for k in ('input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')]
            old = best.get(key)
            if old is None:
                best[key] = (line['timestamp'], counts)
            elif counts[1] > old[1][1] or sum(counts) > sum(old[1]):
                best[key] = (old[0], counts)          # first-seen time, final counts
    total = 0
    for stamp, counts in best.values():
        when = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00')).astimezone()
        recount[when.strftime('%Y-%m-%d')] += sum(counts)
        total += sum(counts)
    per_file[path] = total

# ---- what Burnbot saved ----
if not os.path.exists(STORE):
    sys.exit('Burnbot has not saved any history yet. Open Burnbot, wait a few minutes (or quit it), and run this again.')
store = json.load(open(STORE))
burnbot = collections.Counter()
deleted = collections.Counter()
behind = 0
for entry in store['files']:
    gone = not os.path.exists(entry['p'])
    for row in entry['m']:
        tokens = sum(row[1:5])
        burnbot[day_of(row[0] * 60000)] += tokens
        if gone:
            deleted[day_of(row[0] * 60000)] += tokens
    if not gone and os.path.getsize(entry['p']) > entry['o']:
        behind += 1

print(f"Burnbot's history was saved {datetime.datetime.fromtimestamp(store['savedAt'] / 1000):%Y-%m-%d %H:%M}.")
if behind:
    print(f'{behind} log(s) have grown since then, so today can differ until Burnbot saves again (every 5 minutes, and when it quits).')
print(f"\n{'day':12}{'Burnbot':>18}{'recount':>18}{'from deleted logs':>20}{'unexplained':>14}")
worst = 0
for day in sorted(set(recount) | set(burnbot)):
    gap = burnbot[day] - deleted[day] - recount[day]
    share = abs(gap) / recount[day] * 100 if recount[day] else 0
    worst = max(worst, share) if day != day_of(store['savedAt']) else worst
    if gap or deleted[day]:
        print(f'{day:12}{burnbot[day]:>18,.0f}{recount[day]:>18,.0f}{deleted[day]:>20,.0f}{gap:>+14,.0f}')
days = len(set(recount) | set(burnbot))
print(f"\n{days} days checked. Days not listed above match exactly.")
print(f"Totals: Burnbot {sum(burnbot.values()):,.0f}, recount {sum(recount.values()):,.0f}, of which {sum(deleted.values()):,.0f} are from logs since deleted.")
print('Largest unexplained difference on a finished day: %.4f%%' % worst)
