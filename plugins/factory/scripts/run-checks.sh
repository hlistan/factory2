#!/usr/bin/env bash
# Runs the project's checks the way CI would, so pass and fail come from exit codes, never from a model's
# reading of the output. Ported from singularity's run-checks.sh (MIT) for factory's config.
# The commands are `checks.fast.<name>` and `checks.slow.<name>`. Once the run is frozen they come from
# the run's checks.snapshot.json, never from the live config, so editing .factory/config.yaml can't
# change what "the checks" are.
# Each check runs from the project root with CI=true, no input, and these variables:
#   FACTORY_REPORTS               an empty directory for this check's JUnit XML (<run>/reports/<name>)
#   PLAYWRIGHT_JUNIT_OUTPUT_FILE  $FACTORY_REPORTS/junit.xml     JEST_JUNIT_OUTPUT_DIR  $FACTORY_REPORTS
#   FACTORY_PORT                  the run's port (also exported as PORT when PORT is unset)
# Usage: run-checks.sh [--set fast|slow|all] [--only <name,...>] [--json <file>] [--tail <lines>]
#                      [--save-failures <file>] [--known-failures <file>] [--live]
#   --live  use the live config even when a snapshot exists (only for taking a baseline)
# Exit status: 0 all passed (or failed only where known), 1 a check failed, 2 usage or config error,
# 3 nothing to run.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need jq python3

set_name="fast"; only=""; json=""; tail_lines=40; save_failures=""; known_failures=""; live=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set) set_name="${2:-}"; shift 2 ;;
    --only) only="${2:-}"; shift 2 ;;
    --json) json="${2:-}"; shift 2 ;;
    --tail) tail_lines="${2:-40}"; shift 2 ;;
    --save-failures) save_failures="${2:-}"; shift 2 ;;
    --known-failures) known_failures="${2:-}"; shift 2 ;;
    --live) live=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "run-checks: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$set_name" in fast|slow|all) ;; *) echo "run-checks: --set is fast, slow or all" >&2; exit 2 ;; esac
case "$tail_lines" in ''|*[!0-9]*) echo "run-checks: --tail needs a number" >&2; exit 2 ;; esac
root="$FACTORY_ROOT_DIR"
cd "$root" || exit 2

slug="$(factory_active_slug)"
run=""; [ -n "$slug" ] && run="$root/.factory/runs/$slug"
snapshot="${run:+$run/checks.snapshot.json}"
if [ "$live" -eq 0 ] && [ -n "$snapshot" ] && [ -f "$snapshot" ]; then
  checks_json="$(cat "$snapshot")"; source_desc="the freeze snapshot"
else
  checks_json="$(factory_config_json | jq '.checks // {}')" || { echo "run-checks: .factory/config.yaml doesn't parse" >&2; exit 2; }
  source_desc=".factory/config.yaml"
fi

list() { # <fast|slow> [only]: name NUL command NUL, in config order, skipping empty and TODO. NUL-separated
  # so multi-line commands and backslashes reach bash exactly as written (@tsv would escape them).
  printf '%s' "$checks_json" | jq -j --arg s "$1" --arg only "${2:-}" '(.[$s] // {}) | to_entries[]
    | select(.value != null and (.value | type) == "string" and .value != "" and (.value | test("^\\s*(TODO|todo)") | not))
    | select(. as $e | $only == "" or ((("," + $only + ",") | index("," + $e.key + ",")) != null))
    | .key, "\u0000", .value, "\u0000"'
}
plan="$(mktemp)"
trap 'rm -rf "$plan" "${tmp:-}"' EXIT
case "$set_name" in
  fast) list fast > "$plan" ;;
  slow) list slow > "$plan" ;;
  all) { list fast; list slow; } > "$plan" ;;
esac
if [ -n "$only" ]; then
  { list fast "$only"; list slow "$only"; } > "$plan"
fi

reports="${run:+$run/reports}"
[ -n "$reports" ] || reports="$(mktemp -d)"
port="$( [ -n "$run" ] && jq -r '.port // empty' "$run/state.json" 2>/dev/null)"
tmp="$(mktemp -d)"
results="$tmp/results"; : > "$results"
ran=""; failed=0; known=""; failed_names=""; total_start="$(date +%s)"

is_known() { [ -n "$known_failures" ] && [ -f "$known_failures" ] && grep -F -x -q -e "$1" "$known_failures"; }

while IFS= read -r -d '' name && IFS= read -r -d '' cmd; do
  [ -n "$name" ] || continue
  dir="$reports/$name"; rm -rf "$dir"; mkdir -p "$dir"
  log="$tmp/$name.log"; start="$(date +%s)"
  (
    export CI=true FACTORY_REPORTS="$dir" PLAYWRIGHT_JUNIT_OUTPUT_FILE="$dir/junit.xml" JEST_JUNIT_OUTPUT_DIR="$dir"
    if [ -n "$port" ]; then export FACTORY_PORT="$port"; [ -n "${PORT:-}" ] || export PORT="$port"; fi
    bash -c "$cmd"
  ) > "$log" 2>&1 < /dev/null
  code=$?
  secs=$(( $(date +%s) - start ))
  printf '%s\t%s\t%s\t%s\n' "$name" "$code" "$secs" "$cmd" >> "$results"
  ran="$ran${ran:+, }$name"
  [ "$code" -eq 0 ] && continue
  failed_names="$failed_names$name
"
  if is_known "$name"; then
    known="$known${known:+, }$name"
    printf 'run-checks: KNOWN FAIL %s (exit %s; it already failed before this change): %s\n' "$name" "$code" "$cmd"
    tail -n 5 "$log" | sed 's/^/  | /'
    continue
  fi
  failed=$((failed + 1))
  printf 'run-checks: FAIL %s (exit %s, %ss): %s\n' "$name" "$code" "$secs" "$cmd"
  tail -n "$tail_lines" "$log" | sed 's/^/  | /'
done < "$plan"

if [ -n "$json" ]; then
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], exit: (.[1] | tonumber), seconds: (.[2] | tonumber), command: (.[3:] | join("\t"))})' "$results" > "$json"
fi
if [ -n "$save_failures" ]; then
  mkdir -p "$(dirname "$save_failures")" 2>/dev/null
  printf '%s' "$failed_names" > "$save_failures"
fi
if [ -z "$ran" ]; then
  echo "run-checks: nothing to run in the $set_name set: set checks.fast / checks.slow in .factory/config.yaml"
  exit 3
fi
if [ "$failed" -gt 0 ]; then
  echo "run-checks: $failed check(s) failed of: $ran${known:+ (already failing before the change: $known)} [commands from $source_desc]"
  exit 1
fi
if [ -n "$known" ]; then
  echo "run-checks: passed ($ran), except checks that already failed before the change: $known"
  exit 0
fi
echo "run-checks: passed ($ran) in $(( $(date +%s) - total_start ))s"
exit 0
