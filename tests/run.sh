#!/usr/bin/env bash
# Runs every tests/*.test.sh (or the ones named) and exits non-zero if any fails.
# Usage: tests/run.sh [name ...]     e.g. tests/run.sh freeze guard-bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
status=0
if [ $# -gt 0 ]; then
  files=()
  for n in "$@"; do files+=("$here/${n%.test.sh}.test.sh"); done
else
  files=("$here"/*.test.sh)
fi
for f in "${files[@]}"; do
  bash "$f" || status=1
done
[ "$status" -eq 0 ] && echo "all tests passed" || echo "some tests failed"
exit "$status"
