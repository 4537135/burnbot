#!/bin/zsh
# Replays every recorded session in tools/fixtures/ through the app's own tracker
# and moments (Burnbot --dump-timeline) and compares with what each one expects.
#
#   tools/check-moments.sh              check them all
#   tools/check-moments.sh your-move    check one
#   tools/check-moments.sh --update     accept what the app does now as expected
#
# Builds a quick debug copy of the app first. Times are printed in UTC.
set -euo pipefail
cd "$(dirname "$0")/.."

update=0
only=()
for arg in "$@"; do
  if [[ "$arg" == "--update" ]]; then update=1; else only+=("$arg"); fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 -o "$work/Burnbot" app/*.swift -framework Cocoa -framework WebKit -framework ServiceManagement

failed=0
for dir in tools/fixtures/*/; do
  name="$(basename "$dir")"
  if (( ${#only} )) && [[ ${only[(Ie)$name]} -eq 0 ]]; then continue; fi
  TZ=UTC "$work/Burnbot" --pages public --dump-timeline "$dir" > "$work/$name.txt"
  if (( update )); then
    cp "$work/$name.txt" "$dir/expected.txt"
    echo "updated  $name"
  elif [[ ! -f "$dir/expected.txt" ]]; then
    echo "NEW      $name (no expected.txt yet: run with --update once it looks right)"
    cat "$work/$name.txt" | sed 's/^/         /'
    failed=1
  elif diff -u "$dir/expected.txt" "$work/$name.txt" > "$work/$name.diff"; then
    echo "ok       $name"
  else
    echo "CHANGED  $name"
    sed 's/^/         /' "$work/$name.diff"
    failed=1
  fi
done
exit $failed
