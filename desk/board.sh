#!/bin/bash
# One command for the boards Burnbot's desk screen can run on:
#   the Seeed XIAO nRF52840 (Sense / Sense Plus), which shows up as /dev/cu.usbmodem…
#   an ESP32 dev board (a CP2102 or CH340 on it), which shows up as /dev/cu.usbserial-…
#   the Claude Pad (LCDwiki ES3C28P, an ESP32-S3 with a 2.8" screen and four keys), /dev/cu.usbmodem…
#
#   desk/board.sh                      which boards are plugged in, and what they run
#   desk/board.sh listen [SECONDS]     what the board prints; type a line to send it, Ctrl-C stops
#   desk/board.sh send LINE…           send lines and show what comes back (each LINE is one line)
#   desk/board.sh upload SKETCH        build a sketch (its folder or its .ino) and put it on the board
#   desk/board.sh screen               put Burnbot's screen program on the board (the XIAO, for now)
#   desk/board.sh perch                put Burnbot on the Desk Buddy Perch (ESP32 + 1.5" OLED + six keys)
#   desk/board.sh pad                  put Burnbot on the Claude Pad (ESP32-S3 + 2.8" screen + four keys)
#   desk/board.sh pad-test             the Claude Pad's screen and keys, without Burnbot
#   desk/board.sh backup [FILE]        ESP32 or pad: save everything on it (to desk/backup/ unless FILE)
#   desk/board.sh restore FILE         ESP32 or pad: put a saved FILE back, replacing everything on it
#   desk/board.sh setup                install arduino-cli and what the boards need
#
# Options, anywhere on the line:
#   --esp32, --xiao, --pad   which board, when several are plugged in (setup: only that board's tools)
#   --port /dev/cu.…   that port exactly
#   --build-only       upload, screen: build, and do not need a board
#   --reset            listen: restart the ESP32 first, to see it from the beginning
#
# Only one program can talk to a board at a time: stop a listen (or `screen`) before
# uploading, and quit Burnbot before uploading to the XIAO (it keeps asking that port).
set -e
DESK="$(cd "$(dirname "$0")" && pwd)"
ME="$0"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
PY=/usr/bin/python3

XIAO_FQBN="${XIAO_FQBN:-Seeeduino:nrf52:xiaonRF52840SensePlus}"   # a plain Sense: Seeeduino:nrf52:xiaonRF52840Sense
ESP32_FQBN="${ESP32_FQBN:-esp32:esp32:esp32:UploadSpeed=230400}"   # faster than this garbles on some cables
ESP32_BAUD="${ESP32_BAUD:-230400}"                                  # the same, for backup and restore
PAD_FQBN="${PAD_FQBN:-esp32:esp32:esp32s3:CDCOnBoot=cdc,PSRAM=opi,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB}"
PAD_BAUD="${PAD_BAUD:-921600}"                                      # the S3's own USB: fast and clean
SEEED_URL=https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
ESP32_URL=https://espressif.github.io/arduino-esp32/package_esp32_index.json

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
label() { case "$1" in esp32) printf 'ESP32' ;; pad) printf 'Claude Pad' ;; *) printf 'XIAO' ;; esac; }
is_esp() { [ "$1" = esp32 ] || [ "$1" = pad ]; }   # esptool works on it: backups, restores, piece-wise uploads
fqbn_of() { case "$1" in esp32) echo "$ESP32_FQBN" ;; pad) echo "$PAD_FQBN" ;; *) echo "$XIAO_FQBN" ;; esac; }
baud_of() { if [ "$1" = pad ]; then echo "$PAD_BAUD"; else echo "$ESP32_BAUD"; fi; }

# ---------- talking to a board over USB ----------
# Always at 115200. Never 1200: opening a XIAO at 1200 tells it to wait for a new program.
SERIAL_PY=$(cat <<'PY'
import codecs, fcntl, os, re, select, struct, sys, termios, time

def opened(port):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, a)
    # macOS keeps what came in while the port was closed, mostly NUL bytes after a long
    # idle (hundreds of KB once); none of it is wanted.
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd

def take(fd):
    """What the board sent since the last look: b"" for nothing yet, None when it is gone."""
    try:
        data = os.read(fd, 4096)
    except BlockingIOError:
        return b""
    except OSError:
        return None
    # NULs are never text from a board: they are the line noise the driver keeps.
    return data.replace(b"\0", b"") if data else None

def collect(fd, seconds):
    out, until = b"", time.time() + seconds
    while time.time() < until:
        if select.select([fd], [], [], 0.05)[0]:
            got = take(fd)
            if got is None:
                break
            out += got
    return out

decoder = codecs.getincrementaldecoder("utf-8")("replace")
def readable(data):
    text = decoder.decode(data).replace("\r", "")
    return "".join(c if c in "\n\t" or c.isprintable() else "·" for c in text)

def restart(fd):
    # ESP32 dev boards: RTS holds the chip in reset; DTR stays off so it starts its program, not its uploader.
    TIOCMBIS, TIOCMBIC, DTR, RTS = 0x8004746C, 0x8004746B, 0x002, 0x004
    fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", DTR))
    fcntl.ioctl(fd, TIOCMBIS, struct.pack("I", RTS))
    time.sleep(0.15)
    termios.tcflush(fd, termios.TCIFLUSH)
    fcntl.ioctl(fd, TIOCMBIC, struct.pack("I", RTS))

mode, port = sys.argv[1], sys.argv[2]
try:
    fd = opened(port)
except OSError as e:
    sys.exit(f"Could not open {port}: {e.strerror}")

if mode == "ask":
    # Which program it runs ("BURNBOT 3", "FOOOCUS 2", ...), and the first other thing it said.
    os.write(fd, b"\nV\n")
    program, said = "", ""
    for line in re.split(r"[\r\n]+", collect(fd, 1.5).decode("latin1")):
        line = line.strip()
        if not program and re.match(r"^[A-Z]+ \d+$", line):
            program = line
        elif not said and line and all(32 <= ord(c) < 127 for c in line):
            said = line[:60]
    print(program + "\t" + said)

elif mode == "send":
    for line in sys.argv[3:]:
        os.write(fd, line.encode() + b"\n")
        time.sleep(0.05)
    sys.stdout.write(readable(collect(fd, 1.5)))

elif mode == "listen":
    seconds, reset = float(sys.argv[3]), sys.argv[4] == "1"
    if reset:
        restart(fd)
    if seconds:
        print(f"Listening to {port} for {seconds:g} seconds…", file=sys.stderr)
    else:
        print(f"Listening to {port}. Type a line and press Return to send it. Ctrl-C stops.", file=sys.stderr)
    watch = [fd, 0]
    until = time.time() + seconds if seconds else None
    try:
        while until is None or time.time() < until:
            ready = select.select(watch, [], [], 0.1)[0]
            if fd in ready:
                got = take(fd)
                if got is None:
                    sys.exit("\n(the board went away)")
                sys.stdout.write(readable(got))
                sys.stdout.flush()
            if 0 in ready:
                typed = os.read(0, 4096)
                if typed:
                    os.write(fd, typed.replace(b"\r\n", b"\n"))
                else:
                    watch.remove(0)      # nothing more to send (stdin closed); keep listening
    except KeyboardInterrupt:
        print(file=sys.stderr)
PY
)
serial() { "$PY" -I -c "$SERIAL_PY" "$@"; }

# ---------- finding the boards ----------
esp_ports() { ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* 2>/dev/null || true; }
# The XIAO and the pad both show up as /dev/cu.usbmodem…; their USB vendor tells them apart
# (Seeed 0x2886, Espressif 0x303A). Prints "PORT VENDOR" for each usbmodem port.
usbmodem_vendors() {
  ioreg -r -c IOUSBHostDevice -l -w0 2>/dev/null | "$PY" -I -c '
import re, sys
vid = None
for line in sys.stdin:
    m = re.search(r"\"idVendor\" = (\d+)", line)
    if m: vid = int(m.group(1))
    m = re.search(r"\"IOCalloutDevice\" = \"(/dev/cu\.usbmodem[^\"]*)\"", line)
    if m and vid is not None: print(m.group(1), hex(vid))
'
}
modem_ports() { usbmodem_vendors | awk -v v="$1" '$2 == v { print $1 }'; }
xiao_ports() { modem_ports 0x2886; }
pad_ports() { modem_ports 0x303a; }
kind_of() {
  case "$1" in
    *usbmodem*) if usbmodem_vendors | grep -q "^$1 0x303a"; then echo pad; else echo xiao; fi ;;
    *) echo esp32 ;;
  esac
}

# Which program has a port open, if one does ("Burnbot", "screen", …).
holder() { lsof -Fc "$1" 2>/dev/null | sed -n 's/^c//p' | head -1; }
free_port() {
  local who
  who=$(holder "$PORT")
  if [ -n "$who" ]; then
    die "$who is using $PORT. Close it first (in screen: Ctrl-A, then K, then Y), then run this again."
  fi
}

# Sets KIND (esp32 or xiao) and PORT from the options and what is plugged in.
# $1: 1 when a board has to be plugged in. $2: the kind to assume when nothing is plugged in.
pick() {
  local need=$1 assume=$2 esp xiao pad
  if [ -n "$PORT" ]; then
    [ -e "$PORT" ] || die "There is no $PORT. Plugged in now:$(printf ' %s' $(esp_ports) $(xiao_ports) $(pad_ports))"
    [ -n "$KIND" ] || KIND=$(kind_of "$PORT")
    return 0
  fi
  esp=$(esp_ports | head -1)
  xiao=$(xiao_ports | head -1)
  pad=$(pad_ports | head -1)
  case "$KIND" in
    esp32) PORT=$esp ;;
    xiao) PORT=$xiao ;;
    pad) PORT=$pad ;;
    *)
      if [ $(printf '%s\n' "$esp" "$xiao" "$pad" | grep -c .) -gt 1 ]; then
        die "Several boards are plugged in ($(printf '%s ' $esp $xiao $pad)). Add --esp32, --xiao or --pad."
      elif [ -n "$esp" ]; then KIND=esp32 PORT=$esp
      elif [ -n "$xiao" ]; then KIND=xiao PORT=$xiao
      elif [ -n "$pad" ]; then KIND=pad PORT=$pad
      elif [ -n "$assume" ]; then KIND=$assume
      fi ;;
  esac
  [ -n "$KIND" ] || die "No board is plugged in. (To only build, add --esp32, --xiao or --pad and --build-only.)"
  if [ "$need" = 1 ] && [ -z "$PORT" ]; then
    die "The $(label "$KIND") is not plugged in. Plug it in by USB and run this again."
  fi
  return 0
}

# ---------- tools ----------
need_cli() {
  command -v arduino-cli >/dev/null || die "arduino-cli is not installed. Run:  $ME setup"
}

ensure_core() {
  local core url
  need_cli
  if is_esp "$1"; then core=esp32:esp32 url=$ESP32_URL; else core=Seeeduino:nrf52 url=$SEEED_URL; fi
  if arduino-cli core list 2>/dev/null | grep -q "^$core "; then return 0; fi
  say "Installing what the $(label "$1") needs (once; a large download)…"
  arduino-cli config init >/dev/null 2>&1 || true
  if ! arduino-cli config dump | grep -qF "$url"; then
    arduino-cli config add board_manager.additional_urls "$url"
  fi
  arduino-cli core update-index
  arduino-cli core install "$core"
}

ensure_screen_library() {
  arduino-cli lib list 2>/dev/null | grep -q "Adafruit ILI9341" || arduino-cli lib install "Adafruit ILI9341"
}

esptool_bin() {
  local found
  found=$(ls "$HOME"/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool 2>/dev/null | tail -1)
  [ -n "$found" ] || found=$(command -v esptool || command -v esptool.py || true)
  [ -n "$found" ] || die "esptool is missing. Run:  $ME setup --esp32"
  echo "$found"
}

# ---------- building ----------
WORK=""
workspace() {
  [ -z "$WORK" ] || return 0
  # Seeed's tools break on spaces in a path and want a program called "python", so
  # everything is built from a copy in a plain folder.
  WORK="$(mktemp -d /tmp/burnbot-board.XXXXXX)"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/bin" "$WORK/out"
  printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' > "$WORK/bin/python"
  chmod +x "$WORK/bin/python"
  export PATH="$WORK/bin:$PATH"
}

# Copies a sketch (its folder, or one .ino and what sits beside it) to $WORK/sketch/<name>/
# and sets SKETCH. Arduino wants the folder named after the .ino; the copy always is.
prepare_sketch() {
  local src=${1%/} dir ino name inos
  workspace
  if [ -f "$src" ]; then
    case "$src" in *.ino) ;; *) die "$src is not a sketch (a .ino file or the folder it is in)." ;; esac
    dir=$(dirname "$src")
    ino=$(basename "$src")
  elif [ -d "$src" ]; then
    dir=$src
    name=$(basename "$(cd "$src" && pwd)")
    if [ -f "$src/$name.ino" ]; then
      ino="$name.ino"
    else
      inos=("$src"/*.ino)
      [ -f "${inos[0]}" ] || die "There is no .ino in $src."
      [ ${#inos[@]} -eq 1 ] || die "$src has more than one .ino and none is named $name.ino. Name the one to upload."
      ino=$(basename "${inos[0]}")
    fi
  else
    die "There is no sketch at $src."
  fi
  name=${ino%.ino}
  SKETCH="$WORK/sketch/$name"
  mkdir -p "$SKETCH"
  cp -R "$dir"/. "$SKETCH"/
  if [ -f "$src" ]; then   # only this sketch, not others kept in the same folder
    find "$SKETCH" -maxdepth 1 -name '*.ino' ! -name "$ino" -delete
  fi
}

build() {
  local fqbn
  ensure_core "$KIND"
  fqbn=$(fqbn_of "$KIND")
  say "Building $(basename "$SKETCH") for the $(label "$KIND")…"
  arduino-cli compile --fqbn "$fqbn" --build-path "$WORK/out" "$SKETCH"
}

# ---------- uploading ----------
# Whether the XIAO runs a program ("program") or waits for one ("upload"), from its USB
# product number: Seeed's programs use 0x80xx, its uploader the same without the 0x8000.
xiao_mode() {
  ioreg -p IOUSB -l -w0 2>/dev/null | "$PY" -I -c '
import re, sys
for node in sys.stdin.read().split("+-o ")[1:]:
    v = re.search(r"\"idVendor\" = (\d+)", node)
    p = re.search(r"\"idProduct\" = (\d+)", node)
    if v and p and int(v.group(1)) == 0x2886:
        print("program" if int(p.group(1)) & 0x8000 else "upload")
        break
'
}

upload_xiao() {
  local nrfutil zip mode
  if pgrep -x Burnbot >/dev/null; then
    die "Burnbot is running and keeps asking the XIAO's port. Quit it, then run this again."
  fi
  free_port
  nrfutil=$(ls "$HOME"/Library/Arduino15/packages/Seeeduino/hardware/nrf52/*/tools/adafruit-nrfutil/macos/adafruit-nrfutil 2>/dev/null | tail -1)
  [ -n "$nrfutil" ] || die "Seeed's upload tool is missing. Run:  $ME setup --xiao"
  zip=$(ls "$WORK"/out/*.ino.zip 2>/dev/null | head -1)
  [ -n "$zip" ] || die "The build left no .zip to upload."

  mode=$(xiao_mode)
  if [ -z "$mode" ]; then   # could not tell from USB: a board that answers runs a program
    if [ -n "$(serial ask "$PORT" | cut -f1)" ]; then mode=program; else mode=upload; fi
  fi
  if [ "$mode" = program ]; then
    say "The XIAO runs a program. Putting it in upload mode…"
    stty -f "$PORT" 1200 >/dev/null 2>&1 || true   # opening at 1200 and closing is the signal
    # It restarts as an uploader under the same name. Talking to it before it is
    # ready leaves it stuck, so wait for it properly.
    sleep 6
    PORT=$(xiao_ports | head -1)
    [ -n "$PORT" ] || die "The XIAO did not come back as an uploader. Unplug it, plug it back in, and run this again."
  else
    say "The XIAO is waiting for a program."
  fi

  say "Uploading to $PORT…"
  UPLOADED=1
  "$nrfutil" dfu serial -pkg "$zip" -p "$PORT" -b 115200 --singlebank || UPLOADED=0
  sleep 5
  PORT=$(xiao_ports | head -1)
}

upload_esp32() {
  free_port
  say "Uploading to $PORT…"
  if ! arduino-cli upload -p "$PORT" --fqbn "$(fqbn_of "$KIND")" --input-dir "$WORK/out" "$SKETCH"; then
    say
    say "That stopped partway. Writing it again in small pieces, each tried until it takes…"
    upload_esp32_pieces || die "The upload did not take. If it stopped at \"Connecting…\", hold the board's BOOT button while it tries, and run this again."
  fi
}

# Some USB cables drop a few bytes now and then; esptool gives up on the whole upload when
# that happens. This writes the same files 64 KB at a time at 115200, tries each piece up to
# five times, then has the chip check every file against what was sent.
upload_esp32_pieces() {
  local et name out boot_app0 pieces off size at try f
  et=$(esptool_bin)
  name=$(basename "$SKETCH")
  out="$WORK/out"
  boot_app0=$(ls "$HOME"/Library/Arduino15/packages/esp32/hardware/esp32/*/tools/partitions/boot_app0.bin 2>/dev/null | tail -1)
  [ -f "$out/$name.ino.bin" ] && [ -f "$out/$name.ino.bootloader.bin" ] && [ -f "$out/$name.ino.partitions.bin" ] && [ -f "$boot_app0" ] || return 1
  pieces="$WORK/pieces"
  rm -rf "$pieces" && mkdir -p "$pieces"
  # offset file, for each thing to write
  local boot=0x1000
  [ "$KIND" != pad ] || boot=0x0   # the S3 keeps its bootloader at the start
  local plan=("$boot $out/$name.ino.bootloader.bin" "0x8000 $out/$name.ino.partitions.bin" "0xe000 $boot_app0")
  size=$(stat -f%z "$out/$name.ino.bin")
  for ((at = 0; at < size; at += 65536)); do
    f="$pieces/app-$at.bin"
    dd if="$out/$name.ino.bin" of="$f" bs=65536 skip=$((at / 65536)) count=1 2>/dev/null
    plan+=("$(printf '0x%x' $((0x10000 + at))) $f")
  done
  for step in "${plan[@]}"; do
    off=${step%% *}
    f=${step#* }
    for try in 1 2 3 4 5; do
      if "$et" --port "$PORT" -b 115200 write-flash "$off" "$f" >"$WORK/piece.log" 2>&1; then
        say "  $off ok"
        break
      fi
      [ "$try" = 5 ] && { tail -3 "$WORK/piece.log"; return 1; }
    done
  done
  for try in 1 2 3; do
    if "$et" --port "$PORT" -b 115200 verify-flash "$boot" "$out/$name.ino.bootloader.bin" 0x8000 "$out/$name.ino.partitions.bin" 0xe000 "$boot_app0" 0x10000 "$out/$name.ino.bin" >"$WORK/piece.log" 2>&1; then
      say "  checked: the board holds exactly what was built"
      return 0
    fi
  done
  tail -3 "$WORK/piece.log"
  return 1
}

# ---------- commands ----------
cmd_status() {
  local found=0 p kind who reply program said
  for p in $(esp_ports) $(xiao_ports) $(pad_ports); do
    found=1
    kind=$(kind_of "$p")
    who=$(holder "$p")
    if [ -n "$who" ]; then
      say "$(label "$kind")  $p  in use by $who"
      continue
    fi
    reply=$(serial ask "$p")
    program=${reply%%$'\t'*}
    said=${reply#*$'\t'}
    case "$program" in
      BURNBOT*) say "$(label "$kind")  $p  runs Burnbot's screen program ($program)" ;;
      ?*) say "$(label "$kind")  $p  runs $program" ;;
      *)
        if [ -n "$said" ]; then say "$(label "$kind")  $p  runs another program; it says: $said"
        elif [ "$kind" = xiao ] && [ "$(xiao_mode)" = upload ]; then say "$(label "$kind")  $p  is waiting for a program (upload mode)"
        else say "$(label "$kind")  $p  runs a program that does not answer"
        fi ;;
    esac
  done
  if [ "$found" = 0 ]; then
    say "No board is plugged in. (The XIAO and the Claude Pad show up as /dev/cu.usbmodem…, the ESP32 as /dev/cu.usbserial-…)"
  fi
  return 0
}

cmd_listen() {
  local reset=0
  pick 1 ""
  free_port
  if [ "$RESET" = 1 ]; then
    if is_esp "$KIND"; then reset=1; else say "(--reset is for the ESP32; listening without it)"; fi
  fi
  serial listen "$PORT" "${1:-0}" "$reset"
}

cmd_send() {
  [ $# -gt 0 ] || die "What to send? For example:  $ME send V"
  pick 1 ""
  free_port
  serial send "$PORT" "$@"
}

cmd_upload() {
  [ -n "$1" ] || die "Which sketch? For example:  $ME upload ~/Arduino/blink"
  if [ "$BUILD_ONLY" = 1 ]; then pick 0 ""; else pick 1 ""; fi
  prepare_sketch "$1"
  build
  if [ "$BUILD_ONLY" = 1 ]; then say "Built. Not uploaded."; return 0; fi
  if is_esp "$KIND"; then
    upload_esp32
    say "Done: the $(label "$KIND") runs $(basename "$SKETCH"). To see what it prints:  $ME listen --reset"
  else
    upload_xiao
    if [ "$UPLOADED" = 1 ]; then
      say "Done: the XIAO runs $(basename "$SKETCH"). To see what it prints:  $ME listen"
    else
      die "The upload tool reported a problem (above). Unplug the XIAO, plug it back in, and run this again."
    fi
  fi
}

cmd_screen() {
  local now
  if [ "$BUILD_ONLY" = 1 ]; then pick 0 xiao; else pick 1 xiao; fi
  ensure_core "$KIND"
  ensure_screen_library
  prepare_sketch "$DESK/burnbot_screen"
  build
  if [ "$BUILD_ONLY" = 1 ]; then say "Built. Not uploaded."; return 0; fi
  if is_esp "$KIND"; then
    upload_esp32
    sleep 2   # it restarts after the upload
  else
    upload_xiao
  fi
  now=""
  [ -z "$PORT" ] || now=$(serial ask "$PORT" | cut -f1)
  case "$now" in
    BURNBOT*)
      say
      say "Done: the board runs $now. The robot is asleep on the screen, waiting for the Mac. Open Burnbot and it wakes up." ;;
    *)
      say
      say "The upload did not take: the board answers \"${now:-nothing}\"."
      die "Unplug the board, plug it back in, and run this again." ;;
  esac
}

cmd_perch() {
  local now
  if [ "$BUILD_ONLY" = 1 ]; then pick 0 esp32; else pick 1 esp32; fi
  [ "$KIND" = esp32 ] || die "The Perch is an ESP32; the board plugged in is a $(label "$KIND")."
  ensure_core esp32
  arduino-cli lib list 2>/dev/null | grep -q "Adafruit SH110X" || arduino-cli lib install "Adafruit SH110X"
  prepare_sketch "$DESK/burnbot_perch"
  cp "$DESK/burnbot_screen/render.h" "$DESK/burnbot_screen/perch.h" "$SKETCH"/   # the drawing it shares with the colour screen
  build
  if [ "$BUILD_ONLY" = 1 ]; then say "Built. Not uploaded."; return 0; fi
  upload_esp32
  sleep 2   # it restarts after the upload
  now=$(serial ask "$PORT" | cut -f1)
  case "$now" in
    BURNBOT*)
      say
      say "Done: the Perch runs $now. The robot is asleep on the OLED, waiting for the Mac. Open Burnbot and it wakes up."
      say "A press of any key closes the card on screen, like a knock. \"$ME send s\" shows the OLED and the keys." ;;
    *)
      say
      say "The upload did not take: the board answers \"${now:-nothing}\"."
      die "Unplug the board, plug it back in, and run this again." ;;
  esac
}

cmd_pad_test() {
  if [ "$BUILD_ONLY" = 1 ]; then pick 0 pad; else pick 1 pad; fi
  [ "$KIND" = pad ] || die "That is a $(label "$KIND"), not the Claude Pad. (Add --pad if several boards are plugged in.)"
  ensure_core pad
  ensure_screen_library
  prepare_sketch "$DESK/pad_test"
  build
  if [ "$BUILD_ONLY" = 1 ]; then say "Built. Not uploaded."; return 0; fi
  upload_esp32
  say
  say "Done: the pad shows colour bars and four key boxes; each box lights while its key is down."
  say "To see the key presses here:  $ME listen --pad"
}

cmd_pad() {
  local now
  if [ "$BUILD_ONLY" = 1 ]; then pick 0 pad; else pick 1 pad; fi
  [ "$KIND" = pad ] || die "That is a $(label "$KIND"), not the Claude Pad. (Add --pad if several boards are plugged in.)"
  ensure_core pad
  ensure_screen_library
  prepare_sketch "$DESK/burnbot_pad"
  cp "$DESK/burnbot_screen/render.h" "$DESK/burnbot_screen/pad.h" "$SKETCH"/   # the drawing it shares with the other screens
  build
  if [ "$BUILD_ONLY" = 1 ]; then say "Built. Not uploaded."; return 0; fi
  upload_esp32
  sleep 3   # it restarts after the upload, and its USB port comes back
  PORT=$(pad_ports | head -1)
  now=""
  [ -z "$PORT" ] || now=$(serial ask "$PORT" | cut -f1)
  case "$now" in
    BURNBOT*)
      say
      say "Done: the pad runs $now. The robot is asleep on the screen, waiting for the Mac. Open Burnbot and it wakes up."
      say "Keys, left to right: Deny, Talk (hold), Show, Approve." ;;
    *)
      say
      say "The upload did not take: the board answers \"${now:-nothing}\"."
      die "Unplug the pad, plug it back in, and run this again." ;;
  esac
}

cmd_backup() {
  local file et
  [ "$KIND" != xiao ] || die "Backups are for the ESP32. A XIAO does not let its program be read back; keep the sketch instead."
  pick 1 esp32
  is_esp "$KIND" || die "Backups are for the ESP32. A XIAO does not let its program be read back; keep the sketch instead."
  file=${1:-"$DESK/backup/$KIND-$(date +%Y-%m-%d-%H%M).bin"}
  [ ! -e "$file" ] || die "$file already exists. Give another name:  $ME backup FILE"
  et=$(esptool_bin)
  free_port
  mkdir -p "$(dirname "$file")"
  say "Saving everything on the $(label "$KIND") to $file (ESP32 4 MB: about 3 minutes; pad 16 MB: about 1)…"
  "$et" --port "$PORT" -b "$(baud_of "$KIND")" read-flash 0 ALL "$file"
  say "Checking the file against the board…"
  "$et" --port "$PORT" -b "$(baud_of "$KIND")" verify-flash 0 "$file" >/dev/null ||
    die "The file does not match what is on the board. Run the backup again."
  say "Saved and checked. To put it back:  $ME restore \"$file\""
}

cmd_restore() {
  local et
  [ "$KIND" != xiao ] || die "Restore is for the ESP32."
  pick 1 esp32
  is_esp "$KIND" || die "Restore is for the ESP32."
  if [ -z "$1" ]; then
    say "Which file? Saved so far:"
    ls -1 "$DESK"/backup/*.bin 2>/dev/null | sed 's/^/  /' || say "  (none)"
    die "Run:  $ME restore FILE"
  fi
  [ -f "$1" ] || die "There is no file at $1."
  et=$(esptool_bin)
  free_port
  say "Putting $1 on the $(label "$KIND"). This replaces everything on it…"
  "$et" --port "$PORT" -b "$(baud_of "$KIND")" write-flash 0 "$1"
  say "Done: it restarted and runs what the file holds."
}

cmd_setup() {
  if ! command -v arduino-cli >/dev/null; then
    command -v brew >/dev/null || die "Install Homebrew first (https://brew.sh), then run this again."
    brew install arduino-cli
  fi
  if [ "$KIND" != esp32 ]; then ensure_core xiao; fi
  if [ "$KIND" != xiao ]; then ensure_core esp32; fi   # the pad uses the same core
  ensure_screen_library
  say "Ready. Plug a board in and run:  $ME"
}

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---------- the command line ----------
KIND="" PORT="" BUILD_ONLY=0 RESET=0 UPLOADED=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --esp32) KIND=esp32 ;;
    --xiao) KIND=xiao ;;
    --pad) KIND=pad ;;
    --port) [ -n "$2" ] || die "--port needs a port, for example --port /dev/cu.usbserial-0001"; PORT=$2; shift ;;
    --port=*) PORT=${1#--port=} ;;
    --build-only) BUILD_ONLY=1 ;;
    --reset) RESET=1 ;;
    -h|--help|help) usage; exit 0 ;;
    -*) die "Unknown option $1. See:  $ME help" ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

COMMAND=${ARGS[0]:-status}
REST=("${ARGS[@]:1}")
case "$COMMAND" in
  status|info) cmd_status ;;
  listen|monitor) cmd_listen "${REST[@]}" ;;
  send) cmd_send "${REST[@]}" ;;
  upload) cmd_upload "${REST[@]}" ;;
  screen) cmd_screen ;;
  perch) cmd_perch ;;
  pad) cmd_pad ;;
  pad-test) cmd_pad_test ;;
  backup) cmd_backup "${REST[@]}" ;;
  restore) cmd_restore "${REST[@]}" ;;
  setup) cmd_setup ;;
  *) die "Unknown command $COMMAND. See:  $ME help" ;;
esac
