#!/bin/zsh
# Puts the real desktop robot on screen for a few seconds and checks that hiding it, or sending it to
# the second screen, while its head is open or its panel is up never leaves bubbles held back.
# (tools/check-moments.sh covers what the robot notices; this covers the window it lives in.)
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp tools/check-companion.swift "$work/main.swift"     # its top-level code runs only from a main.swift
swiftc -swift-version 5 -o "$work/check" app/Companion.swift app/Pages.swift "$work/main.swift" -framework Cocoa -framework WebKit
"$work/check" public
