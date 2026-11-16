#!/bin/bash
# Double-click: builds the Burnbot desk screen's program and puts it on the board
# (Seeed XIAO nRF52840 Sense Plus, plugged in by USB). Needed once, and again
# only when the screen's program changes.
#
# Needs arduino-cli (brew install arduino-cli). Quit Burnbot first: two
# programs can't talk to the board at once.
#
# This replaces whatever program the board has. To go back to the FOOOCUS
# screen, run the "Upload to the screen.command" in the FOOOCUS folder.
set -e
cd "$(dirname "$0")"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
FQBN="${FQBN:-Seeeduino:nrf52:xiaonRF52840SensePlus}"     # a plain Sense: Seeeduino:nrf52:xiaonRF52840Sense

if ! command -v arduino-cli >/dev/null; then
  echo "arduino-cli is not installed. Install it with:  brew install arduino-cli"
  exit 1
fi

# Seeed's tools break on spaces in a path and want a program called "python".
WORK="$(mktemp -d /tmp/burnbot-screen.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/burnbot_screen" "$WORK/bin" "$WORK/out"
cp burnbot_screen/burnbot_screen.ino burnbot_screen/render.h "$WORK/burnbot_screen/"
printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' > "$WORK/bin/python"
chmod +x "$WORK/bin/python"
export PATH="$WORK/bin:$PATH"

if ! arduino-cli core list | grep -q "Seeeduino:nrf52"; then
  arduino-cli config add board_manager.additional_urls https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json 2>/dev/null || true
  arduino-cli core update-index
  arduino-cli core install Seeeduino:nrf52
fi
arduino-cli lib list | grep -q "Adafruit ILI9341" || arduino-cli lib install "Adafruit ILI9341"

echo "Building…"
arduino-cli compile --fqbn "$FQBN" --build-path "$WORK/out" "$WORK/burnbot_screen"
if [ "$1" = "--build-only" ]; then
  echo "Built. Not uploaded."
  exit 0
fi

if pgrep -x Burnbot >/dev/null; then
  echo "Burnbot is running and talking to the board. Quit it, then run this again."
  exit 1
fi
port() { ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true; }
PORT=$(port)
if [ -z "$PORT" ]; then
  echo "The board is not plugged in (no /dev/cu.usbmodem…). Plug it in by USB and run this again."
  exit 1
fi

# Asks the board which program it runs ("BURNBOT 1", "FOOOCUS 2", …). Prints
# nothing when it does not answer, which is the case in upload mode.
ask() {
  /usr/bin/python3 - "$1" <<'PY'
import os, re, select, sys, termios, time
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = termios.B115200          # never 1200: that speed means "go to upload mode"
    termios.tcsetattr(fd, termios.TCSANOW, a)
    os.write(fd, b"\nV\n")
    heard, until = b"", time.time() + 1.5
    while time.time() < until:
        if select.select([fd], [], [], 0.1)[0]:
            heard += os.read(fd, 256)
    os.close(fd)
    for line in re.split(r"[\r\n]+", heard.decode("latin1")):
        if re.match(r"^[A-Z]+ \d+$", line.strip()):
            print(line.strip())
            break
except OSError:
    pass
PY
}

NRFUTIL=$(ls "$HOME"/Library/Arduino15/packages/Seeeduino/hardware/nrf52/*/tools/adafruit-nrfutil/macos/adafruit-nrfutil 2>/dev/null | tail -1)
if [ -z "$NRFUTIL" ]; then
  echo "Seeed's upload tool is missing. Run:  arduino-cli core install Seeeduino:nrf52"
  exit 1
fi

RUNS=$(ask "$PORT")
if [ -n "$RUNS" ]; then
  echo "The board runs $RUNS. Putting it in upload mode…"
  stty -f "$PORT" 1200 >/dev/null 2>&1 || true   # opening at 1200 and closing is the signal
  # It restarts as an uploader under the same name. Talking to it before it is
  # ready leaves it stuck, so wait for it properly.
  sleep 6
  PORT=$(port)
else
  echo "The board does not answer, so it should already be in upload mode."
fi

echo "Uploading to ${PORT}…"
"$NRFUTIL" dfu serial -pkg "$WORK/out/burnbot_screen.ino.zip" -p "$PORT" -b 115200 --singlebank || true
sleep 5
PORT=$(port)
NOW=$(ask "$PORT")
case "$NOW" in
  BURNBOT*)
    echo
    echo "Done: the board runs $NOW. The robot is asleep on the screen, waiting for the Mac. Open Burnbot and it wakes up."
    ;;
  *)
    echo
    echo "The upload did not take: the board answers \"${NOW:-nothing}\"."
    echo "Unplug the board, plug it back in, and run this again."
    exit 1
    ;;
esac
