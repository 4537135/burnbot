"""Shared helpers for the progress evaluation (Stage A).

Nothing in this folder holds session data. Every script reads Claude Code's logs
(read-only) or the data folder you pass with --data, and writes only there.

The prompt, check and verdict rules are ports of app/Tracker.swift (promptText,
typedOnly) and app/Runs.swift (classify, verdict), so the evaluation sees the
session the way Burnbot does.
"""

import json
import os
import re
import sys
from datetime import datetime

INTERACTIVE = {"claude-vscode", "claude-desktop", "cli"}


def data_dir(argv=None):
    """The data folder: --data DIR, or $PROGRESS_EVAL_DATA. Never inside the repo."""
    argv = sys.argv if argv is None else argv
    path = None
    if "--data" in argv:
        path = argv[argv.index("--data") + 1]
    path = path or os.environ.get("PROGRESS_EVAL_DATA")
    if not path:
        sys.exit("give the data folder with --data DIR (or PROGRESS_EVAL_DATA); keep it outside the repo")
    path = os.path.abspath(path)
    repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    if path == repo or path.startswith(repo + os.sep):
        sys.exit("the data folder must be outside the repo: it holds session excerpts")
    os.makedirs(path, exist_ok=True)
    return path


def ms(stamp):
    if not stamp:
        return None
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1000
    except ValueError:
        return None


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


# ---- prompts (Tracker.swift) ----

INJECTED = re.compile(
    r"<(system-reminder|artifact-view-context|artifact-content-authored-by-others|local-command-stdout|local-command-stderr|"
    r"local-command-caveat|bash-stdout|bash-stderr|task-notification|fork-boilerplate|command-message|command-args|"
    r"user-prompt-submit-hook)\b[^>]*>[\s\S]*?</\1>")
PASTED = re.compile(r"<pasted_content\b[^>]*>([\s\S]*?)</pasted_content[^>]*>")
KEPT_TAGS = re.compile(r"</?(bash-input|command-name)>")


def prompt_text(o):
    for flag in ("isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"):
        if o.get(flag) is True:
            return None
    if o.get("toolUseResult") is not None:
        return None
    kind = (o.get("origin") or {}).get("kind") or o.get("turnOrigin") or ""
    if kind and kind != "human":
        return None
    content = (o.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    text = ""
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_result":
            return None
        if block.get("type") == "text":
            text += (block.get("text") or "") + "\n"
    return text


def typed_only(text, keep_pasted=0):
    """What you typed. Pasted blocks become [pasted] (or their first keep_pasted chars)."""
    def paste(m):
        if keep_pasted:
            body = m.group(1).strip()
            return " [pasted: " + body[:keep_pasted] + ("…" if len(body) > keep_pasted else "") + "] "
        return " [pasted] "
    rest = PASTED.sub(paste, text)
    rest = INJECTED.sub("", rest)
    rest = KEPT_TAGS.sub("", rest)
    return rest.strip()


def measure(text):
    pasted = sum(len(m.group(1)) for m in PASTED.finditer(text))
    rest = KEPT_TAGS.sub("", INJECTED.sub("", PASTED.sub("", text)))
    return len(rest.strip()), pasted


def is_interrupt(text):
    return text.strip().startswith("[Request interrupted by user")


# ---- checks (Runs.swift) ----

HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?[\s\S]*?\n\s*\1\b")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")
SEPARATORS = re.compile(r"&&|\|\||;|\||\n")
ENV_PREFIX = re.compile(r"^(?:\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+")
LOOKERS = {"git", "gh", "echo", "printf", "cat", "grep", "rg", "sed", "awk", "ls", "find", "head", "tail",
           "wc", "open", "which", "command", "type", "man", "cd", "export", "source", "less", "more", "diff"}
TEST = re.compile(
    r"(?:^|[\s/(])(?:pytest|py\.test|jest|vitest|mocha|rspec|phpunit|ctest|tox|nox)(?:\s|$)"
    r"|(?:^|\s)(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test(?::\S+)?(?:\s|$)"
    r"|\b(?:cargo\s+(?:test|nextest)|go\s+test|swift\s+test|deno\s+test|mix\s+test|dotnet\s+test|playwright\s+test"
    r"|python3?\s+-m\s+(?:pytest|unittest)|make\s+(?:test|check)|bundle\s+exec\s+rspec|rails\s+test)\b"
    r"|\bxcodebuild\b.*\btest\b|(?:^|\s)(?:\./)?(?:gradlew?|mvnw?)\b.*\b(?:test|check|verify)\b")
TYPECHECK = re.compile(
    r"(?:^|[\s/])(?:tsc|vue-tsc|mypy|pyright|basedpyright)(?:\s|$)"
    r"|(?:^|\s)(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:typecheck|type-check|check-types|types|tsc)(?:\s|$)|\bcargo\s+check\b")
BUILD = re.compile(
    r"(?:^|\s)(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?build(?::\S+)?(?:\s|$)"
    r"|\b(?:cargo|go|swift|dotnet|bazel)\s+build\b|(?:^|[\s/])(?:swiftc|xcodebuild|ninja|webpack)(?:\s|$)"
    r"|\bcmake\s+--build\b|\b(?:next|vite|astro|nuxt)\s+build\b|^make(?:\s+[\w.=-]+)*$"
    r"|(?:^|\s)(?:\./)?gradlew?\b.*\b(?:build|assemble)\b|(?:^|\s)mvnw?\b.*\b(?:package|compile|install)\b"
    r"|(?:^|[\s/])build[\w-]*\.sh(?:\s|$)")
NOISE = re.compile(r"\s(?:2>&1|>\s*/dev/null|-q|--quiet|-v+|--verbose|-s|--silent|--no-color|--color(?:=\S+)?)(?=\s|$)")
FILTER_PIPE = re.compile(r"\|\s*(?:tail|head|grep|rg|less|more|cat|tee|sed|awk|cut|sort|uniq|wc|xcpretty|xcbeautify|jq)\b")
SWALLOWED = re.compile(r"\|\|\s*(?:true|:|echo\b|printf\b|exit\s+0)|;\s*(?:true|:)\s*$")
FAIL_MARK = re.compile(
    r"\b[1-9]\d*\s+(?:failed|failing|failures?|errors?)\b|\bFAIL(?:ED|URES?)?\b|[✗✖❌]|(?:^|\s)error(?:\[E\d+\])?:"
    r"|\berror TS\d+|\bTests? failed\b|\bpanicked at\b|Traceback \(most recent call last\)|\bcommand not found\b")
PASS_MARK = re.compile(
    r"\b[1-9]\d*\s+(?:passed|passing)\b|\btests? passed\b|\ball tests passed\b|\btest result: ok\b|(?:^|\n)ok\s+\S+\s+[\d.]+s"
    r"|(?:^|\n)OK(?:\s*\(|\s*$)|Executed \d+ tests?, with 0 failures|Test Suite '.*' passed|\bBUILD SUCCEEDED\b|\bBUILD SUCCESSFUL\b"
    r"|Build complete!|Compiled successfully|\bFinished\b.*\bin [\d.]+s|\bbuilt in [\d.]+\s*m?s\b|Found 0 errors|Success: no issues found",
    re.I | re.M)
EXIT_CODE = re.compile(r"^(?:Error: )?Exit code (-?[0-9]+)")


def segments(command):
    bare = QUOTED.sub("''", HEREDOC.sub("", command))
    parts = SEPARATORS.sub("\x01", bare).split("\x01")
    return [ENV_PREFIX.sub("", p).strip() for p in parts if ENV_PREFIX.sub("", p).strip()]


def classify(command):
    parts = [p for p in segments(command) if (p.split(" ")[0] if p else "") not in LOOKERS]
    for family, pattern in (("test", TEST), ("typecheck", TYPECHECK), ("build", BUILD)):
        for part in parts:
            if pattern.search(part):
                core = " ".join(NOISE.sub("", " " + part + " ").split())
                return family, core
    return None


def git_action(command):
    for part in segments(command):
        if part.startswith("git commit"):
            return "commit"
        if part.startswith("gh pr create"):
            return "pr"
    return None


def verdict(command, error, exit_code, denied, interrupted, output):
    if denied or interrupted:
        return "unknown"
    if exit_code in (126, 127):
        return "unknown"
    piped = bool(FILTER_PIPE.search(command)) and "pipefail" not in command
    swallows = bool(SWALLOWED.search(command))
    failed = bool(FAIL_MARK.search(output))
    bad = error or (exit_code or 0) != 0
    if bad:
        return "unknown" if piped and not failed else "fail"
    if failed:
        return "fail" if piped or swallows else "unknown"
    if piped or swallows:
        return "pass" if PASS_MARK.search(output) else "unknown"
    return "pass"


IDE_SELECTION = re.compile(r"<ide_selection>([\s\S]*?)</ide_selection>")
IDE_OPENED = re.compile(r"<ide_opened_file>([\s\S]*?)</ide_opened_file>")
IDE_FILE = re.compile(r"(?:from|file) (\S+?)(?::|\s|$)")


def tidy(text, keep=300):
    """A prompt for reading: IDE wrappers shortened to what they point at."""
    def sel(m):
        body = m.group(1)
        f = IDE_FILE.search(body)
        return "[IDE selection%s: %s] " % (" in " + base(f.group(1)) if f else "", clip(body.split(":", 1)[-1], keep))

    def opened(m):
        f = IDE_FILE.search(m.group(1))
        return "[had %s open] " % (base(f.group(1)) if f else "a file")
    return IDE_OPENED.sub(opened, IDE_SELECTION.sub(sel, text or "")).strip()


def base(path):
    return os.path.basename(path or "") or (path or "")


def clip(text, n):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


PLAN_HEADING = re.compile(r"^\s{0,3}(#{1,4})\s+(.*\S)")
PLAN_STEP = re.compile(r"^(?:\d+[.)]|[-*])\s+\*{0,2}([^*\n]{3,})")
FILE_NAME = re.compile(r"[\w./-]*[\w-]+\.(?:swift|py|js|jsx|ts|tsx|mjs|cjs|css|scss|html|json|md|sh|yml|yaml|toml|go|rs|rb|"
                       r"java|kt|php|sql|ino|h|c|cpp|m|plist|txt|svg|png|jpg|vue|svelte|astro|xml|csv)\b")


def plan_headings(plan, limit=16):
    """The approved plan's headings, with top-level numbered steps when there are few headings."""
    heads = []
    for line in (plan or "").splitlines():
        m = PLAN_HEADING.match(line)
        if m:
            heads.append(("  " * (len(m.group(1)) - 1 if len(m.group(1)) > 1 else 0)) + clip(m.group(2).strip("*` "), 90))
    if len(heads) < 4:
        steps = []
        for line in (plan or "").splitlines():
            if line.startswith((" ", "\t")):
                continue
            m = PLAN_STEP.match(line)
            if m and re.match(r"^\d", line):
                steps.append("  " + clip(m.group(1), 90))
        heads += steps[:12]
    return heads[:limit]


def plan_files(plan):
    return sorted({base(m.group(0)) for m in FILE_NAME.finditer(plan or "") if "/" in m.group(0) or "." in m.group(0)})
