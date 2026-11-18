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
#
# The work is done by board.sh, next to this file, which also handles the ESP32:
#   desk/board.sh help
# A plain XIAO Sense:  XIAO_FQBN=Seeeduino:nrf52:xiaonRF52840Sense
cd "$(dirname "$0")"
exec ./board.sh --xiao screen "$@"
