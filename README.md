# Burnbot

Tracks how hard you are burning Claude tokens, judges it against your own
normal, and turns that into a level. An orange pixel robot on a second screen
shows the level you are on and climbs the ladder with you.

It reads the session logs Claude Code already writes on this Mac
(`~/.claude/projects`). No API key, no account, nothing leaves the machine.
Everything is counted in tokens. There are no money figures anywhere.

## Start it

Open **Burnbot.app**. It is a normal Mac app with its own Dock icon and two
windows: the dashboard and the robot. You can drag it to Applications.

- **One screen**: the robot floats in the bottom-right corner, on top of
  everything and on every desktop, showing the level and the token burn. Make
  the window bigger to get the full ladder. Drag it anywhere; it remembers.
- **A second screen plugged in**: the robot moves there and goes fullscreen by
  itself, and that screen is kept awake. Unplug it and the robot comes back to
  its corner.

| Robot menu | Shortcut |
|---|---|
| Show Dashboard | ⌘1 |
| Show Robot | ⌘2 |
| Robot on the Second Screen | ⌘3 |
| Robot in a Window | ⌘4 |
| Keep Robot on Top | ⌘T |
| Full Screen (also double-click the robot) | ⌃⌘F |

Quitting the app stops the tracker. History lives in
`~/Library/Application Support/Burnbot`, and a log in `~/Library/Logs/Burnbot.log`.

### Rebuilding the app

The app carries its own copy of the code, so rebuild after changing anything:

```bash
./build-app.sh
```

It needs Xcode's Swift compiler and Node.js 20.11 or newer. To check a build
without looking at the screen, run
`open Burnbot.app --args --snapshot /some/folder`: it writes a picture of each
window there and describes them in the log.

### Without the app

The same two screens work in a browser. Double-click **Start Burnbot.command**, or:

```bash
node server.mjs --open --display
```

| Flag | What it does |
|---|---|
| `--open` | Opens the dashboard in your browser |
| `--display` | Puts the robot fullscreen on the second screen in a Chrome window, now and whenever one is plugged in |
| `--port 4747` | Changes the port |
| `--lan` | Also serves other devices on your network, for a tablet or a small standalone screen |

## The desk screen

A small screen of its own for the robot: a Seeed XIAO nRF52840 (Sense or
Sense Plus) with a 2.4" 240 × 320 SPI display (ILI9341), plugged in by USB.
It is the same board and wiring as the FOOOCUS desk screen.

| Display | VCC | GND | DIN | CLK | CS | DC | RST | BL |
|---|---|---|---|---|---|---|---|---|
| XIAO | 3V3 | GND | D10 | D8 | D0 | D1 | D2 | D6 |

It shows the level and its number, tokens per hour, an intensity bar with a
notch where each level begins, and below them the robot in its fire with the
level ladder beside it (a small tick marks your usual level for the hour).

Burnbot finds the board by itself and tells it your level once a second; the
board keeps the fire, the robot and the falling tokens moving in between. The
dashboard shows "Desk screen on" when it is answering, with a **Flip** link if
the picture is upside down. With nothing from the Mac for 15 seconds the robot
goes to sleep and the screen says it is waiting.

**Putting the program on the board.** Quit Burnbot, plug the board in, and
double-click `desk/Upload to the screen.command`. It needs `arduino-cli`
(`brew install arduino-cli`). Do it once, and again only if `desk/` changes.

**One program at a time.** The board holds either this or the FOOOCUS screen
program. Uploading one replaces the other; to go back to FOOOCUS, run the
upload command in its folder. Burnbot leaves a board alone if it runs another
program, and the dashboard says so.

**Seeing a screen without the board:**

```bash
c++ -std=c++11 -O2 -I desk/burnbot_screen desk/tools/sim.cpp -o /tmp/burnbot-sim
/tmp/burnbot-sim /tmp/screen.bmp 'B|s=4|lv=4|tp=5|u=3|i=81|f=78|nm=LOCKED IN|cp=LEVEL 4 OF 5|rt=71.2M|tm=17:29'
open /tmp/screen.bmp
```

The line the Mac sends is `B|key=value|…`, and the board answers `OK`:
`s` the robot's look (0 asleep to 5 on fire, 6 autopilot), `lv` and `tp` the
level and the top level, `u` your usual level, `i` intensity, `f` how hard the
fire burns (0 to 100), `c` where the levels begin, `nm` and `cp` the words,
`rt` tokens per hour, `tm` the time. `V` asks which program the board runs
(`BURNBOT 1`), `O0` / `O2` set which way up.

## The levels

| Level | Name | When |
|---|---|---|
| 0 | Asleep | No Claude activity for 30 minutes |
| 1 | Chilling | Quiet for 5 minutes |
| 2 | Warming up | Working, in your quietest 30% |
| 3 | Cooking | Above your quietest 30%: your usual working pace |
| 4 | Locked in | Your top 25%, after 20 minutes of unbroken work |
| 5 | On fire | Your top 7% |
| A | Autopilot | Off the ladder: Claude is still working but you have gone longer without a prompt than you usually do |

## It calibrates itself

No level is tied to a fixed amount of tokens or typing. Every couple of
seconds Burnbot re-reads your last 30 days and works everything out again:

1. **Three signals, each ranked against you.** A value is scored by how much
   of your own hands-on time it beats.

   | Signal | Weight | Source |
   |---|---|---|
   | Burn | 40% | Tokens per hour: everything Claude read and wrote, cached context included |
   | Typing | 35% | Characters you typed into Claude. Pasted text and system messages are left out |
   | Actions | 25% | Your prompts plus the tool calls Claude made |

2. **Intensity, ranked against you again.** The blend of the three is ranked
   against your own hands-on time once more, so intensity 75 always means
   "hotter than 75% of your time". The levels are cut on that scale, which is
   why "locked in" is your top quarter whether you burn 5M tokens an hour or 500M.
3. **Autopilot timing from your rhythm.** It starts after the gap you leave
   between prompts 85% of the time (kept between 15 and 60 minutes).
4. **Your usual level for the hour** comes from the level you reached around
   that time on your past working days.

Old days fall out of the 30-day window, so the levels drift with you as your
habits change. Until there are two hours of history the robot uses fixed
defaults and says it is still calibrating.

To rename a level, edit its `label` in `STATE_META` at the top of
`public/robot.js`. The shares (30%, 25%, 7%) and time limits are in `CONFIG`
at the top of `lib/metrics.mjs`.

## The two screens

**Robot** (`http://localhost:4747/display`): the robot, the fire, and
- the level you are on, big, with its number
- the whole ladder, lit up to your level, with a tag on the level you usually
  reach at this time of day
- what it takes to reach the next level
- tokens per hour and tokens burned today

Tokens fall into the fire faster the more you burn. Click for fullscreen.
Unplugging the monitor closes the window. Preview every level at
`/display?demo=cycle`.

**Dashboard** (`http://localhost:4747`): the same level and ladder, the three
calibrated signals, today's totals, a 5-minute timeline with your level under
it, 30 days of history, a weekday-by-hour heatmap, and tokens by model and
project. The **Second screen** button opens the robot on any attached monitor.

## Files

```
Burnbot.app         the built app
build-app.sh        builds it
app/main.swift      the native shell: windows, menus, second-screen handling
tools/make-icon.mjs draws the app icon from the same robot
server.mjs          the tracker: web server and live stream
lib/collector.mjs   reads and tails the session logs
lib/metrics.mjs     baseline, intensity, levels
lib/displays.mjs    browser mode only: finds monitors, opens the robot in Chrome
lib/deskscreen.mjs  finds the desk screen on USB and feeds it
desk/               the desk screen's own program, its simulator and upload command
public/             dashboard, robot screen, pixel art
```
