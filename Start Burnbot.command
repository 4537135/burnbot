#!/bin/zsh
# Double-click to start Burnbot: opens the dashboard and puts the robot on your second screen.
# Close this window (or press Ctrl+C) to stop it.
cd "$(dirname "$0")" || exit 1

NODE="$(command -v node)"
for candidate in "$HOME/.local/node/bin/node" /opt/homebrew/bin/node /usr/local/bin/node; do
  [[ -z "$NODE" && -x "$candidate" ]] && NODE="$candidate"
done
if [[ -z "$NODE" ]]; then
  echo "Burnbot needs Node.js 20 or newer. Install it from https://nodejs.org and try again."
  read -k 1 "?Press any key to close."
  exit 1
fi

exec "$NODE" server.mjs --open --display
