#!/usr/bin/env python3
"""Writes the replay fixtures in tools/fixtures/ (read by app/Replay.swift).

Each case below is a short script of what happened in a working session:
what you typed, what Claude ran and what came back, what Claude Code's hooks
reported, and which app you had in front. This turns it into Claude Code
session logs, hook events and an attention file, in the formats the app reads.

    python3 tools/make-fixtures.py          # rewrite every fixture (keeps expected.txt)
    tools/check-moments.sh                  # replay them and compare

All times are UTC on 17 November 2026.
"""
import itertools
import json
import os
import shutil
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'fixtures')
DAY = datetime(2026, 11, 17, tzinfo=timezone.utc)

TERMINAL = 'com.apple.Terminal'
SAFARI = 'com.apple.Safari'
SLACK = 'com.tinyspeck.slackmacgap'


def at(hms):
    h, m, *s = (int(x) for x in hms.split(':'))
    return DAY.replace(hour=h, minute=m, second=s[0] if s else 0)


def iso(t):
    return t.strftime('%Y-%m-%dT%H:%M:%S.000Z')


class Case:
    def __init__(self, name, about, end=None, **settings):
        self.name, self.about, self.end = name, about, end
        self.settings = settings            # levels=True, goal=n, judge=True/False (see app/Replay.swift)
        self.logs = {}
        self.hooks = []
        self.attention = []
        self.ids = itertools.count(1)

    def session(self, sid, project, title, branch='main'):
        return Session(self, sid, project, title, branch)

    def front(self, hms, app, idle=0):
        self.attention.append((at(hms), app, idle))

    def busy(self, start, end, app=TERMINAL):
        """At the keyboard in `app`: input every 20 seconds."""
        t, stop = at(start), at(end)
        while t <= stop:
            self.attention.append((t, app, 0))
            t += timedelta(seconds=20)

    def hook(self, hms, event, session, **extra):
        self.hooks.append({'at': iso(at(hms)), 'hook_event_name': event, 'session_id': session.sid,
                           'cwd': session.cwd, 'transcript_path': session.path, **extra})

    def write(self):
        folder = os.path.join(OUT, self.name)
        expected = None
        if os.path.exists(os.path.join(folder, 'expected.txt')):
            expected = open(os.path.join(folder, 'expected.txt')).read()
        shutil.rmtree(folder, ignore_errors=True)
        os.makedirs(folder)
        with open(os.path.join(folder, 'README.txt'), 'w') as f:
            f.write(self.about.strip() + '\n')
        for path, lines in self.logs.items():
            full = os.path.join(folder, 'logs', path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, 'w') as f:
                for line in lines:
                    f.write(json.dumps(line, separators=(',', ':')) + '\n')
        with open(os.path.join(folder, 'hooks.jsonl'), 'w') as f:
            for hook in sorted(self.hooks, key=lambda h: h['at']):
                f.write(json.dumps(hook) + '\n')
        with open(os.path.join(folder, 'attention.txt'), 'w') as f:
            for t, app, idle in sorted(self.attention):
                f.write(f'{iso(t)} {app} {idle}\n')
        if self.end or self.settings:
            with open(os.path.join(folder, 'fixture.json'), 'w') as f:
                json.dump({**({'end': iso(at(self.end))} if self.end else {}), **self.settings}, f)
                f.write('\n')
        if expected is not None:
            with open(os.path.join(folder, 'expected.txt'), 'w') as f:
                f.write(expected)


class Session:
    def __init__(self, case, sid, project, title, branch):
        self.case, self.sid, self.branch = case, sid, branch
        self.cwd = '/Users/dev/' + project
        self.path = '-Users-dev-' + project + '/' + sid + '.jsonl'
        self.lines = case.logs.setdefault(self.path, [])
        self.lines.append({'type': 'ai-title', 'aiTitle': title, 'sessionId': sid})

    def _base(self, kind, hms):
        n = next(self.case.ids)
        return {'parentUuid': None, 'isSidechain': False, 'type': kind, 'timestamp': iso(at(hms)), 'sessionId': self.sid,
                'cwd': self.cwd, 'gitBranch': self.branch, 'version': '2.1.325', 'uuid': f'u-{n:04d}'}, n

    def prompt(self, hms, text):
        line, _ = self._base('user', hms)
        line['message'] = {'role': 'user', 'content': text}
        self.lines.append(line)

    def _assistant(self, hms, content):
        line, n = self._base('assistant', hms)
        line['requestId'] = f'req_{n:04d}'
        line['message'] = {'model': 'claude-opus-5-5', 'id': f'msg_{n:04d}', 'type': 'message', 'role': 'assistant',
                           'content': content, 'stop_reason': 'tool_use',
                           'usage': {'input_tokens': 4, 'cache_creation_input_tokens': 2500,
                                     'cache_read_input_tokens': 48000, 'output_tokens': 350}}
        self.lines.append(line)
        return n

    def think(self, hms, text='Looking at it.'):
        self._assistant(hms, [{'type': 'text', 'text': text}])

    def work(self, start, end, every=60):
        """Claude busy: a response every `every` seconds."""
        t, stop = at(start), at(end)
        while t <= stop:
            self.think(t.strftime('%H:%M:%S'))
            t += timedelta(seconds=every)

    def edit(self, hms, name):
        n = self._assistant(hms, [{'type': 'tool_use', 'id': f'toolu_e{next(self.case.ids):04d}', 'name': 'Edit',
                                   'input': {'file_path': self.cwd + '/' + name, 'old_string': 'a', 'new_string': 'b'}}])
        return n

    def bash(self, hms, command, done, exit=0, output='', denied=False, interrupted=False):
        tool = f'toolu_b{next(self.case.ids):04d}'
        self._assistant(hms, [{'type': 'tool_use', 'id': tool, 'name': 'Bash', 'input': {'command': command}}])
        line, _ = self._base('user', done)
        line['sourceToolAssistantUUID'] = 'x'
        if denied:
            text = ('Permission for this action was denied by the Claude Code auto mode classifier. '
                    'Reason: [Unauthorized Access].')
            line['message'] = {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool, 'content': text, 'is_error': True}]}
            line['toolUseResult'] = 'Error: ' + text
            line['toolDenialKind'] = 'classifier'
        elif exit != 0:
            text = f'Exit code {exit}\n{output}'
            line['message'] = {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool, 'content': text, 'is_error': True}]}
            line['toolUseResult'] = 'Error: ' + text
        else:
            line['message'] = {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool, 'content': output, 'is_error': False}]}
            line['toolUseResult'] = {'stdout': output, 'stderr': '', 'interrupted': interrupted, 'isImage': False, 'noOutputExpected': False}
        self.lines.append(line)


    def interrupt(self, hms):
        """You pressed Esc while Claude was working."""
        line, _ = self._base('user', hms)
        line['message'] = {'role': 'user', 'content': [{'type': 'text', 'text': '[Request interrupted by user]'}]}
        self.lines.append(line)

    def _tool_answer(self, tool, done, text, result, error=False):
        line, _ = self._base('user', done)
        line['sourceToolAssistantUUID'] = 'x'
        line['message'] = {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool, 'content': text, 'is_error': error}]}
        line['toolUseResult'] = result
        self.lines.append(line)

    def ask(self, hms, done, question, answer):
        """Claude asks you a question (AskUserQuestion); you answer at `done`."""
        tool = f'toolu_q{next(self.case.ids):04d}'
        self._assistant(hms, [{'type': 'tool_use', 'id': tool, 'name': 'AskUserQuestion',
                               'input': {'questions': [{'question': question, 'header': 'Q', 'multiSelect': False,
                                                        'options': [{'label': answer, 'description': ''}, {'label': 'Other', 'description': ''}]}]}}])
        self._tool_answer(tool, done, f'User has answered your questions: "{question}"="{answer}".',
                          {'questions': [{'question': question}], 'answers': {question: answer}})

    def plan(self, hms, done, approved=True):
        """Claude shows you a plan (ExitPlanMode); you approve or turn it down at `done`."""
        tool = f'toolu_p{next(self.case.ids):04d}'
        plan = '# Plan\n\n## Context\n\nDo the thing.'
        self._assistant(hms, [{'type': 'tool_use', 'id': tool, 'name': 'ExitPlanMode', 'input': {'plan': plan}}])
        if approved:
            self._tool_answer(tool, done, 'User has approved your plan. You can now start coding.',
                              {'plan': plan, 'isAgent': False, 'filePath': '/Users/dev/.claude/plans/plan.md'})
        else:
            self._tool_answer(tool, done, "The user doesn't want to proceed with this tool use. The tool use was rejected.",
                              'User rejected tool use', error=True)


FAIL_2 = 'FAIL src/checkout.test.ts\n  ✕ adds tax to the total (14 ms)\n  ✕ rounds to cents (3 ms)\nTests:       2 failed, 12 passed, 14 total'
FAIL_1 = 'FAIL src/checkout.test.ts\n  ✕ rounds to cents (3 ms)\nTests:       1 failed, 13 passed, 14 total'
PASS = 'PASS src/checkout.test.ts\nTests:       14 passed, 14 total\nTime:        2.81 s'

cases = []

# ---------------------------------------------------------------------------
c = Case('breakthrough-at-desk', """
You are at the terminal the whole time. The checkout tests fail twice, then pass.
Each failure gets a worried face for a few seconds, no words. The pass after two
failures is a breakthrough: a short bubble and a happy face. Claude stopping
while you watch says nothing.
""", end='10:09:00')
s = c.session('a1b2c3d4-0001-4000-8000-000000000001', 'shop', 'Fix checkout tax tests')
c.busy('09:59:40', '10:09:00')
s.prompt('10:00:00', 'The checkout tests fail on the tax line. Fix them.')
s.think('10:00:15')
s.edit('10:00:40', 'src/tax.ts')
s.bash('10:01:00', 'npm test', '10:01:40', exit=1, output=FAIL_2)
s.edit('10:02:30', 'src/tax.ts')
s.bash('10:03:00', 'npm test', '10:03:40', exit=1, output=FAIL_1)
s.edit('10:05:00', 'src/round.ts')
s.bash('10:05:30', 'npm test', '10:06:10', output=PASS)
s.think('10:06:30', 'Fixed: tax is added before rounding.')
c.hook('10:06:32', 'Stop', s)
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('breakthrough-while-away', """
The tests fail once while you watch (worried face), then you go to Slack. The
second failure, while you are away, changes nothing. The pass comes while you
are still away: the bubble shows and stays until you are back at the terminal,
then stays a few seconds more so you see it.
""", end='10:12:00')
s = c.session('a1b2c3d4-0002-4000-8000-000000000002', 'shop', 'Fix checkout tax tests')
c.busy('09:59:40', '10:02:00')
c.front('10:02:10', SLACK, 0)
c.busy('10:09:30', '10:12:00')
s.prompt('10:00:00', 'The checkout tests fail on the tax line. Fix them.')
s.edit('10:00:40', 'src/tax.ts')
s.bash('10:01:00', 'npm test', '10:01:40', exit=1, output=FAIL_2)
s.edit('10:02:30', 'src/tax.ts')
s.bash('10:03:00', 'npm test', '10:03:40', exit=1, output=FAIL_1)
s.edit('10:05:00', 'src/round.ts')
s.bash('10:05:30', 'npm test', '10:06:10', output=PASS)
s.think('10:06:30', 'Fixed.')
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('no-proof-no-party', """
Passing is only celebrated with proof. One quick failure then a pass: nothing.
After two real failures, a piped run that hides its own exit code, a run with
"|| true", a run that was denied, and commands that only mention tests are all
ignored. Only the plain run that passes, with a pass count, is a breakthrough.
""", end='10:12:00')
s = c.session('a1b2c3d4-0003-4000-8000-000000000003', 'shop', 'Cart rounding')
c.busy('09:59:40', '10:12:00')
s.prompt('10:00:00', 'Make the cart round to cents.')
s.bash('10:00:30', 'npm test', '10:00:50', exit=1, output=FAIL_1)
s.bash('10:01:30', 'npm test', '10:01:50', output=PASS)
s.prompt('10:03:00', 'Now the tax tests.')
s.bash('10:03:20', 'npm test -- tax', '10:03:40', exit=1, output=FAIL_2)
s.bash('10:04:20', 'npm test -- tax', '10:04:40', exit=1, output=FAIL_1)
s.bash('10:05:20', 'npm test -- tax 2>&1 | tail -3', '10:05:40', output='Done in 2.1s.')
s.bash('10:06:20', 'npm test -- tax || true', '10:06:40', output='')
s.bash('10:07:00', 'git log --oneline | grep "npm test"', '10:07:02', output='')
s.bash('10:07:20', 'npm test -- tax', '10:07:22', denied=True)
s.bash('10:08:30', 'npm test -- tax', '10:08:50', output=PASS)
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('permission-away', """
Claude needs a yes to run a command while you are in Safari. The bubble stays
until you are back at your terminal; the Now line says what is waiting. Coming
back is enough: you can see the question there, so the bubble goes.
""", end='10:06:00')
s = c.session('a1b2c3d4-0004-4000-8000-000000000004', 'shop', 'Clean rebuild')
c.busy('09:59:40', '10:00:20')
c.front('10:00:30', SAFARI, 0)
c.busy('10:04:00', '10:06:00')
s.prompt('10:00:00', 'Do a clean rebuild.')
s.think('10:00:20')
s.bash('10:01:00', 'rm -rf dist && npm run build', '10:04:30', output='built in 3.1s')
c.hook('10:01:01', 'PermissionRequest', s, tool_name='Bash', tool_input={'command': 'rm -rf dist && npm run build'})
s.think('10:04:45', 'Rebuilt.')
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('permission-at-desk', """
Claude needs a yes while you are at the terminal. You will see the prompt
there, so no bubble: the robot only looks at you until you touch something.
""", end='10:03:00')
s = c.session('a1b2c3d4-0005-4000-8000-000000000005', 'shop', 'Clean rebuild')
c.front('10:00:00', TERMINAL, 0)
c.front('10:01:00', TERMINAL, 0)
c.front('10:01:20', TERMINAL, 0)
s.prompt('10:00:00', 'Do a clean rebuild.')
s.bash('10:01:00', 'rm -rf dist && npm run build', '10:01:30', output='built in 3.1s')
c.hook('10:01:01', 'PermissionRequest', s, tool_name='Bash', tool_input={'command': 'rm -rf dist && npm run build'})
s.think('10:01:40', 'Rebuilt.')
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('your-move', """
Claude stops after a long turn while you are away: "your move", for a minute.
A short turn says nothing. A long turn that ends while you are at the terminal
says nothing. A bubble that is showing goes as soon as you are back.
""", end='10:26:00')
s = c.session('a1b2c3d4-0006-4000-8000-000000000006', 'shop', 'Refactor the cart')
c.busy('09:59:40', '10:00:20')
c.front('10:00:30', SAFARI, 0)
s.prompt('10:00:00', 'Refactor the cart into its own module.')
s.work('10:00:20', '10:05:00')
c.hook('10:05:02', 'Stop', s)
c.busy('10:09:40', '10:20:20')
s.prompt('10:10:00', 'Rename it to basket.')
s.think('10:10:30')
c.hook('10:10:40', 'Stop', s)
s.prompt('10:12:00', 'Update the imports too.')
s.work('10:12:20', '10:16:00')
c.hook('10:16:02', 'Stop', s)
s.prompt('10:20:00', 'Run the whole suite and fix what breaks.')
c.front('10:20:30', SLACK, 0)
s.work('10:20:20', '10:24:00')
c.hook('10:24:02', 'Stop', s)
c.busy('10:24:20', '10:26:00')
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('two-sessions', """
Two sessions in two projects. "shop" needs a yes while "api" finishes a long
turn, both while you are away. The question about shop wins the one bubble;
api's turn ending does not clear shop's question. Back at the terminal, it goes.
""", end='10:08:00')
a = c.session('a1b2c3d4-0007-4000-8000-00000000000a', 'shop', 'Migrate orders table')
b = c.session('a1b2c3d4-0007-4000-8000-00000000000b', 'api', 'Paginate the orders endpoint')
c.busy('09:59:40', '10:00:40')
c.front('10:01:00', SAFARI, 0)
c.busy('10:06:00', '10:08:00')
a.prompt('10:00:00', 'Write the migration and run it.')
b.prompt('10:00:30', 'Add cursor pagination to /orders.')
a.work('10:00:20', '10:02:30')
b.work('10:00:50', '10:04:00')
a.bash('10:03:00', 'npm run migrate', '10:06:30', output='Migrated 3 tables.')
c.hook('10:03:01', 'PermissionRequest', a, tool_name='Bash', tool_input={'command': 'npm run migrate'})
c.hook('10:04:02', 'Stop', b)
a.think('10:06:40', 'Done.')
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('session-recap', """
Half an hour on one session: a breakthrough, a commit, three files changed.
Then nothing for 30 minutes: the session is over, and the recap says what
happened in it.
""", end='10:32:00')
s = c.session('a1b2c3d4-0008-4000-8000-000000000008', 'shop', 'Fix checkout tax tests', branch='fix/tax')
c.busy('09:29:40', '10:32:00')
s.prompt('09:30:00', 'The checkout tests fail on the tax line. Fix them.')
s.work('09:30:20', '09:40:00')
s.edit('09:40:10', 'src/tax.ts')
s.bash('09:41:00', 'npx jest src/checkout.test.ts', '09:41:30', exit=1, output=FAIL_2)
s.prompt('09:43:00', 'Round after tax, not before.')
s.edit('09:44:10', 'src/round.ts')
s.bash('09:45:00', 'npx jest src/checkout.test.ts', '09:45:30', exit=1, output=FAIL_1)
s.edit('09:47:10', 'src/cart.ts')
s.bash('09:48:00', 'npx jest src/checkout.test.ts', '09:48:30', output=PASS)
s.work('09:49:00', '09:54:00')
s.bash('09:55:00', 'git add -A && git commit -m "Round after tax"', '09:55:02', output='[fix/tax 3e1f2a9] Round after tax\n 3 files changed')
s.prompt('09:57:00', 'Thanks. Anything else to clean up?')
s.work('09:57:20', '10:00:00')
cases.append(c)

# ---------------------------------------------------------------------------
c = Case('quiet-budget', """
Bubbles that are not urgent are rationed: one per ten minutes. A breakthrough
at 10:09 uses it; the session ends at 10:12, so its recap waits until 10:19.
""", end='10:24:00')
s = c.session('a1b2c3d4-0009-4000-8000-000000000009', 'shop', 'Fix checkout tax tests')
c.busy('09:44:40', '10:24:00')
s.prompt('09:45:00', 'The checkout tests fail on the tax line. Fix them.')
s.work('09:45:20', '10:05:00')
s.bash('10:05:30', 'pytest tests/test_checkout.py', '10:06:00', exit=1, output='FAILED tests/test_checkout.py::test_tax - AssertionError\n1 failed, 9 passed in 0.41s')
s.bash('10:07:30', 'pytest tests/test_checkout.py', '10:08:00', exit=1, output='FAILED tests/test_checkout.py::test_round\n1 failed, 9 passed in 0.40s')
s.bash('10:08:40', 'pytest tests/test_checkout.py', '10:09:10', output='10 passed in 0.39s')
s.work('10:09:30', '10:11:30')
c.hook('10:12:00', 'SessionEnd', s, reason='prompt_input_exit')
cases.append(c)

# ---------------------------------------------------------------------------
# The app plays this one for "Play Every Moment" (Robot menu, or --demo), with the
# quiet stretches cut short. build-app.sh copies it into the app.
c = Case('demo', """
Every moment in one session, for Play Every Moment. A plan you approve (a win).
The same ask three times with nothing changing (puzzled, going round), until
Claude edits. The tests fail twice while you watch (worried), then pass: all
green, and with it the daily goal of 2 (happy). Claude needs a yes while you
are in Safari (your call, until you are back). Claude stops after a long turn
while you read in Safari at the Mac (your move), you stay there (bored, then
still there?), come back (back to), and the session ends: the recap, once the
bubble budget allows.
""", end='10:42:00', goal=2)
s = c.session('d3m0d3m0-0000-4000-8000-000000000001', 'shop', 'Fix checkout tax tests', branch='fix/tax')
c.busy('09:49:40', '10:06:20')
s.prompt('09:50:00', 'Checkout totals are a cent off. Plan the fix first.')
s.work('09:50:20', '09:52:00')
s.plan('09:52:30', '09:54:00')
s.prompt('09:54:20', 'Make the checkout total match the receipt.')
s.work('09:54:40', '09:56:20')
s.interrupt('09:56:40')
s.prompt('09:56:50', 'Make the checkout total match the receipt exactly.')
s.work('09:57:10', '09:58:00')
s.prompt('09:58:20', 'The checkout total still does not match the receipt. Make it match.')
s.work('09:58:40', '09:59:20')
s.interrupt('09:59:40')
s.prompt('09:59:50', 'Stop. The tax line is wrong. Fix the checkout tests on the tax line.')
s.edit('10:00:40', 'src/tax.ts')
s.bash('10:01:00', 'npm test', '10:01:40', exit=1, output=FAIL_2)
s.edit('10:02:10', 'src/tax.ts')
s.bash('10:02:30', 'npm test', '10:03:10', exit=1, output=FAIL_1)
s.edit('10:03:40', 'src/round.ts')
s.bash('10:04:00', 'npm test', '10:04:40', output=PASS)
s.bash('10:05:10', 'git add -A && git commit -m "Round after tax"', '10:05:12', output='[fix/tax 3e1f2a9] Round after tax\n 3 files changed')
s.prompt('10:06:00', 'Now a clean rebuild.')
c.front('10:06:30', SAFARI, 0)
s.think('10:06:20')
s.bash('10:07:00', 'rm -rf dist && npm run build', '10:09:30', output='built in 3.1s')
c.hook('10:07:01', 'PermissionRequest', s, tool_name='Bash', tool_input={'command': 'rm -rf dist && npm run build'})
c.busy('10:09:00', '10:10:20')
s.think('10:09:40', 'Rebuilt.')
s.prompt('10:10:00', 'Run the whole suite and fix what breaks.')
c.busy('10:10:30', '10:28:00', SAFARI)
s.work('10:10:20', '10:17:00')
c.hook('10:17:02', 'Stop', s)
c.busy('10:28:20', '10:42:00')
s.prompt('10:28:40', 'Good. Push it.')
s.work('10:29:00', '10:30:00')
c.hook('10:30:10', 'SessionEnd', s, reason='prompt_input_exit')
cases.append(c)

# ---------------------------------------------------------------------------
# Burnbot 1.2: planning counts as work, loops, drift, the daily goal.

c = Case('planning', """
Planning with Claude at the terminal. Claude asks a question (3 min to answer),
then shows a plan you read for 9 min before approving. Nothing is typed while you
read, and Claude is silent, but you are working: the level must never drop to
idle (Chilling) while a question or plan is open and you are at the Mac.
""", end='10:30:00', levels=True)
s = c.session('a1b2c3d4-0011-4000-8000-000000000011', 'shop', 'Plan the refunds flow')
c.busy('09:59:40', '10:30:00')
s.prompt('10:00:00', 'Plan how refunds should work: partial refunds, store credit, and the emails.')
s.work('10:00:20', '10:06:00')
s.ask('10:06:30', '10:09:30', 'Should store credit expire?', 'No, never')
s.work('10:09:40', '10:12:00')
s.plan('10:12:30', '10:21:30')
s.work('10:21:40', '10:25:00')
s.edit('10:25:30', 'src/refunds.ts')
cases.append(c)

c = Case('loop-real', """
The same ask three times, but Claude changes files between them: that is
iteration, not going round. No puzzled face, no bubble.
""", end='10:20:00')
s = c.session('a1b2c3d4-0012-4000-8000-000000000012', 'shop', 'Restyle the checkout button')
c.busy('09:59:40', '10:20:00')
s.prompt('10:00:00', 'Make the checkout button bigger and use the brand colour.')
s.work('10:00:20', '10:02:00')
s.edit('10:02:30', 'src/Button.css')
s.prompt('10:04:00', 'Make the checkout button bigger still, and the brand colour darker.')
s.work('10:04:20', '10:05:00')
s.edit('10:05:30', 'src/Button.css')
s.prompt('10:07:00', 'Make the checkout button a bit bigger, brand colour is right now.')
s.work('10:07:20', '10:08:00')
s.edit('10:08:30', 'src/Button.css')
cases.append(c)


def stuck(name, about, **settings):
    c = Case(name, about, end='10:32:00', **settings)
    s = c.session('a1b2c3d4-0013-4000-8000-000000000013', 'shop', 'Fix the flaky login test')
    c.busy('09:59:40', '10:32:00')
    s.prompt('10:00:00', 'Fix the flaky login test, it times out on CI.')
    s.work('10:00:20', '10:03:00')
    s.interrupt('10:03:30')
    s.prompt('10:03:45', 'Fix the flaky login test, it still times out on CI.')
    s.work('10:04:00', '10:05:30')
    s.prompt('10:06:00', 'The login test is still flaky on CI, fix the timeout.')
    s.work('10:06:20', '10:08:30')
    s.interrupt('10:09:00')
    s.prompt('10:09:20', 'Just fix the flaky login test timeout.')
    s.work('10:09:40', '10:24:30')
    s.prompt('10:25:00', 'Fix the login test timeout. It is still flaky.')
    s.work('10:25:20', '10:27:30')
    s.edit('10:28:00', 'test/login.test.ts')
    return c


cases.append(stuck('loop-stuck', """
The same ask again and again: stopped, retyped, reworded, and Claude changes
nothing. On the third redo the robot looks puzzled and the line under it says
so. Fifteen minutes on, one more redo: with no AI, the rule decides and the
robot says it once. Claude finally editing a file ends it.
"""))
cases.append(stuck('loop-judged', """
The same session as loop-stuck, but AI is on and your claude reads it as real
iteration: the puzzled face and the line still show, the bubble does not.
""", judge=False))


def drift(name, about, at_mac):
    c = Case(name, about, end='10:22:00')
    s = c.session('a1b2c3d4-0014-4000-8000-000000000014', 'shop', 'Paginate the orders list')
    c.busy('09:59:40', '10:02:00')
    s.prompt('10:00:00', 'Paginate the orders list, 50 a page.')
    s.work('10:00:20', '10:06:00')
    c.hook('10:06:05', 'Stop', s)
    if at_mac:
        c.busy('10:02:20', '10:19:00', SAFARI)
        c.busy('10:19:20', '10:22:00')
        s.prompt('10:19:40', 'Looks good. Add a page size picker.')
        s.work('10:20:00', '10:21:30')
    else:
        c.front('10:02:20', SAFARI, 0)          # then nothing: you left the Mac
    return c


cases.append(drift('drift', """
Claude finishes a 6-minute turn while you are reading in Safari, at the Mac.
Your move gets its bubble. Past your usual break (5 min until learned) the
robot looks bored and the line says what is waiting; past twice that, one
bubble. Back in the terminal: "Back to" for a minute.
""", at_mac=True))
cases.append(drift('drift-away', """
The same, but you walked away from the Mac: that is 1.1's away path (your move,
kept), not drifting. No bored face, no drift bubble.
""", at_mac=False))

c = Case('goal', """
A daily goal of 2 wins. An approved plan is the first; tests going green after
two failures is the second: the goal is hit, a happy face and the line for two
minutes, no bubble.
""", end='10:16:00', goal=2)
s = c.session('a1b2c3d4-0015-4000-8000-000000000015', 'shop', 'Fix checkout tax tests')
c.busy('09:59:40', '10:16:00')
s.prompt('10:00:00', 'Plan the tax fix first.')
s.work('10:00:20', '10:02:00')
s.plan('10:02:30', '10:04:00')
s.edit('10:04:30', 'src/tax.ts')
s.bash('10:05:00', 'npm test', '10:05:40', exit=1, output=FAIL_2)
s.edit('10:06:10', 'src/tax.ts')
s.bash('10:06:30', 'npm test', '10:07:10', exit=1, output=FAIL_1)
s.edit('10:07:40', 'src/round.ts')
s.bash('10:08:00', 'npm test', '10:08:40', output=PASS)
cases.append(c)

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    for case in cases:
        case.write()
    print(f'{len(cases)} fixtures in {os.path.relpath(OUT)}')
