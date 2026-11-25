"""Burnbot Pad bridge for macOS and Windows: what app/DeskScreen.swift, PadKeys.swift and PadPages.swift do
for the Claude Pad, without the Mac app. Started at login by install.py; log in ~/.claude/burnbot-pad/bridge.log.

Once a second it sends the pad its B line (level), every 10 s the U (plan usage) and D (today) lines.
Keys: Approve / Deny answer a permission prompt that hook.py hands over. Key 2 held: talk to your latest
session (Whisper on this computer); its reply is read out on the pad's speaker.
"""
import base64, glob, json, os, socket, subprocess, sys, threading, time
import serial
from serial.tools import list_ports

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metrics, voice

DATA = voice.DATA
LETTERS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.,!%/:+&\"()?=_*#;<>@$[]~")
PAD_LETTERS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.,!%/:+&'\"()?=_*#;<>@$|[]~`^{}\\")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------------------------------------------------------------- text the pad can draw (PadPages.swift)
def pad_text(text, limit):
    out = ""
    for c in str(text).upper():
        c = {"|": "/", "'": '"', "`": '"', "{": "(", "}": ")"}.get(c, c)
        c = c if c in LETTERS else " "
        if not (c == " " and out.endswith(" ")):
            out += c
    return out.strip()[:limit]


def duration(m):
    m = max(0, int(m))
    return f"{m // 60}H {m % 60}M" if m >= 60 else f"{m}M"


def tokens(n):
    for size, unit in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if n >= size:
            return f"{n / size:.1f}{unit}" if n < size * 10 and unit != "B" else f"{n / size:.0f}{unit}" if unit != "B" else f"{n / size:.1f}B"
    return str(int(round(n)))


def rate(n):
    for size, unit, wide, mid in ((1e9, "B", "%.2f", "%.2f"), (1e6, "M", "%.0f", "%.1f"), (1e3, "K", "%.0f", "%.1f")):
        if n >= size:
            return ((wide if n >= size * 100 else mid if n >= size * 10 else "%.2f") % (n / size)) + unit
    return str(int(n))


# ---------------------------------------------------------------- the lines
def b_line(a, ask):
    s = a["state"]
    lv = s if s < 6 else -1
    t = time.localtime()
    f = ["B", f"s={s}", f"lv={lv}", "tp=5", "u=-1", f"i={a['intensity']}", f"f={round(a['flame'] * 100)}",
         "c=%d,%d,%d" % metrics.CUTS, "nm=" + metrics.NAMES[s], "cp=" + ("OFF LADDER" if lv < 0 else f"LEVEL {lv} OF 5"),
         "rt=" + rate(a["rate"]), f"tm={t.tm_hour:02d}:{t.tm_min:02d}", f"wk={a['streak']}"]
    line = "|".join(f)
    if ask and ask["whole"]:
        line += "|ky=DENY,,,APPROVE|pr=" + " ".join(ask["shown"].split()).replace("|", "\x7f") + "|pp=" + pad_text(ask["project"], 18)
    return line


def read_json(path):
    try:
        return json.load(open(path, encoding="utf-8")), os.path.getmtime(path)
    except Exception:
        return None, 0


def resets(at, now):
    left = at - now
    if left < 86400:
        return "IN " + duration(-(-left // 60))
    return time.strftime("%a %H:%M", time.localtime(at)).upper()


def u_line(now):
    f = ["U"]
    rates, mod = read_json(os.path.join(DATA, "rates.json"))
    limits = (rates or {}).get("rate_limits") or {}
    any_ = False
    for key, label in (("five_hour", "h"), ("seven_day", "w")):
        lim = limits.get(key) or {}
        used, at = lim.get("used_percentage"), float(lim.get("resets_at") or 0)
        if used is None or (0 < at <= now):
            continue
        f.append(f"{label}={round(used)}")
        if at > 0:
            f.append(f"{label}r=" + resets(at, now))
        any_ = True
    if any_:
        f.append(f"ag={max(0, int((now - mod) / 60))}")
    st, mod = read_json(os.path.join(DATA, "status.json"))
    used = ((st or {}).get("context_window") or {}).get("used_percentage")
    if st and now - mod < 12 * 3600 and used is not None:
        f.append(f"x={round(used)}")
        ws = st.get("workspace") or {}
        name = pad_text(os.path.basename((ws.get("project_dir") or ws.get("current_dir") or st.get("cwd") or "").rstrip("/\\")), 18)
        if name:
            f.append("xn=" + name)
    return "|".join(f)


def d_line(a):
    most = max(a["hours"])
    bars = [0 if h <= 0 or most <= 0 else max(1, round(h / most * 99)) for h in a["hours"]]
    f = ["D", "b=" + ",".join(map(str, bars)), "fm=" + duration(a["engaged"]), f"ss={a['sessions']}"]
    if a["peak"] > 0:
        x = a["peak"] / max(a["usual"], 1)
        f.append("pk=" + ((f"{x:.0f}X" if x >= 10 else f"{x:.1f}X") if a["usual"] > 0 else tokens(a["peak"]) + "/H"))
    return "|".join(f)


# ---------------------------------------------------------------- permission prompts (PadKeys.swift)
def fits(text, cols=25, rows=4):
    full = length = 0
    for w in text.split():
        if len(w) > cols:
            return False
        if length and length + 1 + len(w) > cols:
            full, length = full + 1, 0
        length += (1 if length else 0) + len(w)
    return full < rows


def request(raw):
    """What the pad shows for a permission prompt, and whether that is all of it (only then may it be approved)."""
    tool, inp, cwd = raw.get("tool_name", "?"), raw.get("tool_input") or {}, (raw.get("cwd") or "").replace("\\", "/")
    what, whole = "", True
    if isinstance(inp.get("command"), str):
        what = inp["command"]
        whole = "\n" not in what and "\r" not in what
    elif isinstance(inp.get("file_path") or inp.get("notebook_path") or inp.get("path"), str):
        path = (inp.get("file_path") or inp.get("notebook_path") or inp.get("path")).replace("\\", "/")
        if cwd and path.lower().startswith(cwd.lower() + "/"):
            what = path[len(cwd) + 1:]
        else:
            what, whole = path, False
    elif isinstance(inp.get("url"), str):
        what = inp["url"]
    elif inp:
        whole = False
    shown = (tool + ": " + what if what else tool).replace("\t", " ")
    if any(c != " " and c not in PAD_LETTERS and not ("a" <= c <= "z") for c in shown):
        whole = False
    shown = shown.upper()
    return shown, whole and fits(shown)


def pending_ask(now):
    newest = None
    for p in glob.glob(os.path.join(DATA, "asks", "*.json")):
        try:
            mod = os.path.getmtime(p)
            if now - mod > 65:
                os.remove(p)
                continue
            rid = os.path.basename(p)[:-5]
            if os.path.exists(os.path.join(DATA, "answers", rid + ".json")):
                continue
            raw = json.load(open(p, encoding="utf-8"))
        except Exception:
            continue
        if not newest or mod > newest["t"]:
            shown, whole = request(raw)
            newest = {"id": rid, "t": mod, "shown": shown, "whole": whole,
                      "project": os.path.basename((raw.get("cwd") or "").rstrip("/\\"))}
    return newest


def answer(ask, allow):
    if allow is None:
        body = ""                           # let go: Claude asks on the computer as usual
    else:
        dec = {"behavior": "allow"} if allow else {"behavior": "deny", "message": "Denied from the desk pad."}
        body = json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": dec}})
    path = os.path.join(DATA, "answers", ask["id"] + ".json")
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(path + ".tmp", path)


# ---------------------------------------------------------------- the pad on USB (DeskScreen.swift)
def find_pad():
    if sys.platform == "darwin" and subprocess.run(["pgrep", "-x", "Burnbot"], capture_output=True).returncode == 0:
        return None                         # the Mac app is running and drives the pad itself
    for p in list_ports.comports():
        if p.vid != 0x303A:
            continue
        try:
            s = serial.Serial(p.device, 115200, timeout=0.1)
        except Exception:
            continue                        # busy: another program has it
        try:
            s.reset_input_buffer()
            s.write(b"\nV\n")
            end = time.time() + 1.5
            buf = b""
            while time.time() < end:
                buf += s.read(256)
                if b"BURNBOT" in buf:
                    log("pad found on", p.device)
                    return s
        except Exception:
            pass
        s.close()
    return None


def screen(**f):
    """An S line; text fields made drawable."""
    out = ["S"]
    for k, v in f.items():
        if v is None:
            continue
        if k in ("t", "x", "to"):
            v = pad_text(v, {"t": 27, "x": 300, "to": 19}[k])
        out.append(f"{k}={v}")
    return "|".join(out)


def latest_session():
    best = None
    for p in glob.glob(os.path.join(DATA, "sessions", "*.json")):
        d, _ = read_json(p)
        if d and d.get("msg_socket") and (not best or d.get("updated", 0) > best.get("updated", 0)):
            best = d
    if best:
        best["title"] = best.get("project") or "Claude"
        best["id"] = best["session_id"]
    return best


class Pad:
    def __init__(self, port):
        self.port, self.buf = port, b""
        self.stage, self.s_line = None, ""   # voice: None (home), stt, rev, sent, say, err
        self.pcm, self.text, self.target, self.awaiting = bytearray(), "", None, None
        self.play, self.seq, self.unanswered = b"", 0, 0
        self.whisper = voice.Whisper()

    def send(self, line):
        self.port.write((line + "\n").encode("utf-8", "replace"))

    def lines(self):
        self.buf += self.port.read(self.port.in_waiting or 1)
        *done, self.buf = self.buf.split(b"\n")
        return [l.decode("utf-8", "replace").strip() for l in done]

    def home(self):
        self.stage, self.s_line = None, screen(m="home", mc=1, to=(self.target or {}).get("title"))

    def show(self, stage, **f):
        self.stage, self.s_line, self.at = stage, screen(**f), time.time()
        self.send(self.s_line)

    # -------------------------------------------- voice
    def heard(self, line, ask):
        parts = line.split("|")
        if line == "ERR" or parts[0] in ("BT", "Q", "AE"):
            log("pad:", line)
        if parts[0] == "AS":
            self.pcm = bytearray()
            self.target = latest_session()
            self.whisper.load_model()
        elif parts[0] == "A" and len(parts) == 4:
            self.pcm += base64.b64decode(parts[3])
        elif parts[0] == "AE" and parts[-1] in ("up", "max"):
            if not self.target:
                return self.show("err", m="err", t="NO SESSION", x="Send your Claude session one prompt first.", ky="OK,,,")
            self.show("stt", m="stt", t="TO " + self.target["title"])
            threading.Thread(target=self.transcribe, daemon=True).start()
        elif parts[0] == "PK":
            self.unanswered = max(0, self.unanswered - 1)
        elif parts[0] == "PD" and self.stage == "say":
            self.home()
        elif line in ("K1d", "K4d"):
            if ask:
                answer(ask, line == "K4d")
                log("prompt", "approved" if line == "K4d" else "denied", "on the pad:", ask["shown"][:60])
            elif self.stage == "rev" and line == "K4d":
                err = voice.deliver(self.target, self.text)
                log("voice: sent to", self.target["title"], "->", err or "ok")
                if err:
                    return self.show("err", m="err", t="NOT SENT", x=err, ky="OK,,,")
                try:
                    size = os.path.getsize(self.target["transcript"])
                except OSError:
                    size = 0
                self.awaiting = {"sid": self.target["id"], "t": time.time(), "worked": False, "offset": size,
                                 "transcript": self.target.get("transcript", ""), "title": self.target["title"]}
                self.show("sent", m="sent", t="SENT TO " + self.target["title"])
            elif self.stage == "say" and line == "K1d":
                self.send("PX")
            elif self.stage in ("rev", "err") and line == "K1d":
                self.home()

    def transcribe(self):
        text, err = self.whisper.transcribe(self.pcm)
        if err:
            self.show("err", m="err", t="TRY AGAIN", x=err, ky="OK,,,")
        else:
            self.text = text
            self.show("rev", m="rev", t="TO " + self.target["title"], x=text, ky="CANCEL,,,SEND", kc="r--g")

    def reply(self, now):
        """voice.Voice.poll_reply from the Pad kit, on this bridge's session files."""
        a = self.awaiting
        if self.stage == "sent" and now - self.at > 3:
            self.home()
        if not a:
            return
        st, _ = read_json(os.path.join(DATA, "sessions", a["sid"] + ".json"))
        st = st or {}
        if st.get("state") == "working" and st.get("updated", 0) > a["t"] - 1:
            a["worked"] = True
        if now - a["t"] > 900:
            self.awaiting = None
        if not a["worked"] or st.get("state") == "working" or now - st.get("updated", now) < 0.8:
            return
        self.awaiting = None
        text = voice.speakable(voice.last_reply(a["transcript"], a["offset"]), int(voice.cfg().get("voice_reply_max", 600)))
        if not text:
            return

        def run():
            pcm = voice.tts(text)
            if pcm:
                self.play, self.seq, self.unanswered = pcm, 0, 0
                self.show("say", m="say", t=a["title"], x=text, ky="STOP,,,")
        threading.Thread(target=run, daemon=True).start()

    def stream(self):
        """Sound to the speaker, 30 ms a line, at most 6 lines unanswered (the pad's USB buffer is 16 KB)."""
        while self.play and self.unanswered < 6:
            chunk, self.play = self.play[:960], self.play[960:]
            self.send(f"PL|{self.seq}|" + base64.b64encode(chunk).decode())
            self.seq += 1
            self.unanswered += 1
            if not self.play:
                self.send("PE")


def run_pad(port, logs):
    pad = Pad(port)
    pad.home()
    pad.send("Q")
    a, ask, analyzed, slow, alive = None, None, 0, 0, os.path.join(DATA, "pad-alive")
    heard = time.time()
    while True:
        now = time.time()
        for line in pad.lines():
            if line:
                heard = now
                pad.heard(line, ask)
        pad.stream()
        if now - analyzed >= 1:
            if logs.poll() or not a or now - a["at"] >= 10:
                a = metrics.analyze(logs, now)
                a["at"] = now
            open(alive, "a").close()
            os.utime(alive)
            ask = pending_ask(now)
            if ask and not ask["whole"]:
                answer(ask, None)
                ask = None
            pad.send(b_line(a, ask))
            pad.send(pad.s_line)
            if now - slow >= 10:
                u = u_line(now)
                if u != "U":                # a bare "U" is an ERR on the pad: nothing known yet
                    pad.send(u)
                pad.send(d_line(a))
                slow = now
            pad.reply(now)
            analyzed = now
            if now - heard > 8:
                raise IOError("the pad went quiet")
        time.sleep(0.02)


def main():
    try:                                    # one bridge at a time
        lock = socket.socket()
        lock.bind(("127.0.0.1", 47391))
    except OSError:
        return log("another bridge is already running")
    os.makedirs(os.path.join(DATA, "asks"), exist_ok=True)
    os.makedirs(os.path.join(DATA, "answers"), exist_ok=True)
    logs = metrics.Logs()
    log("bridge started; looking for the pad")
    while True:
        port = find_pad()
        if not port:
            time.sleep(4)
            continue
        try:
            run_pad(port, logs)
        except Exception as ex:
            log("pad gone:", ex)
        try:
            os.remove(os.path.join(DATA, "pad-alive"))
            port.close()
        except OSError:
            pass
        time.sleep(2)


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:         # self-check of the text rules
        assert pad_text("shop's  {x}|y", 18) == 'SHOP"S (X)/Y'
        assert request({"tool_name": "Bash", "tool_input": {"command": "npm test"}}) == ("BASH: NPM TEST", True)
        assert not request({"tool_name": "Bash", "tool_input": {"command": "a\nb"}})[1]
        assert not request({"tool_name": "Write", "tool_input": {"file_path": "/etc/x"}, "cwd": "/home/me"})[1]
        assert rate(28674264) == "28.7M" and rate(950) == "950" and fits("A " * 40) is True
        print("ok")
    else:
        main()
