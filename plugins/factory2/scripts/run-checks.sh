#!/usr/bin/env bash
# Runs the project's checks the way CI would, so pass and fail come from exit codes, never from a model's
# reading of the output. Ported from singularity's run-checks.sh (MIT) for factory's config.
# The commands are `checks.fast.<name>` and `checks.slow.<name>`; `all` is both. `checks.affected.<name>`
# (the affected set, never part of `all`) runs only what the change touches: each command gets
#   FACTORY_CHANGED_FILES  a file listing the paths changed since the run's base, one per line
#                          (committed, staged, unstaged and new untracked files)
#   FACTORY_BASE           the run's base commit
# and narrows its own suite with them (Go packages of the changed files, Playwright specs by area). Once the run is frozen they come from
# the run's checks.snapshot.json, never from the live config, so editing .factory/config.yaml can't
# change what "the checks" are.
# Each check runs from the project root with CI=true, no input, and these variables:
#   FACTORY_REPORTS               an empty directory for this check's JUnit XML (<run>/reports/<name>)
#   PLAYWRIGHT_JUNIT_OUTPUT_FILE  $FACTORY_REPORTS/junit.xml     JEST_JUNIT_OUTPUT_DIR  $FACTORY_REPORTS
#   FACTORY_PORT                  the run's port (also exported as PORT when PORT is unset)
# Usage: run-checks.sh [--set fast|slow|all|affected] [--only <name,...>] [--json <file>] [--tail <lines>]
#                      [--save-failures <file>] [--known-failures <file>] [--flakes <file>] [--live]
#   --since-green  with --set all: when every path changed since the last green full run (recorded on a
#             clean tree) matches `checks.docs_only` (globs; default *.md), run only the fast set and
#             reuse that run for the slow one. A failed full run forgets the green one.
#   --flakes  a file of confirmed flaky test ids (state.sh flaky): a check that fails only on those
#             tests, by its JUnit report, counts as passed and is named FLAKE
#   --live  use the live config even when a snapshot exists (only for taking a baseline)
# Exit status: 0 all passed (or failed only where known), 1 a check failed, 2 usage or config error,
# 3 nothing to run.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need jq python3

set_name="fast"; only=""; json=""; tail_lines=40; save_failures=""; known_failures=""; flakes=""; since_green=0; live=0
while [ $# -gt 0 ]; do
  case "$1" in
    --set) set_name="${2:-}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --only) only="${2:-}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --json) json="${2:-}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --tail) tail_lines="${2:-40}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --save-failures) save_failures="${2:-}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --known-failures) known_failures="${2:-}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --flakes) flakes="${2:-}"; shift 2 || { echo "run-checks: $1 needs a value" >&2; exit 2; } ;;
    --since-green) since_green=1; shift ;;
    --live) live=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "run-checks: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$set_name" in fast|slow|all|affected) ;; *) echo "run-checks: --set is fast, slow, all or affected" >&2; exit 2 ;; esac
[ "$since_green" -eq 0 ] || [ "$set_name" = all ] || { echo "run-checks: --since-green goes with --set all" >&2; exit 2; }
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
  affected) list affected > "$plan" ;;
esac
if [ -n "$only" ]; then
  { list fast "$only"; list slow "$only"; } > "$plan"
fi

state="${run:+$run/state.json}"
green=""; reused=""
[ -n "$state" ] && [ -f "$state" ] && green="$(jq -r '.checks_green.commit // empty' "$state")"
docs_only() { # stdin: paths; true when every one matches checks.docs_only
  factory_py -c 'import fnmatch, json, os, sys
pats = json.loads(sys.argv[1]) or ["*.md"]
paths = [p for p in sys.stdin.read().splitlines() if p]
ok = all(any(fnmatch.fnmatch(p, g) or fnmatch.fnmatch(os.path.basename(p), g) for g in pats) for p in paths)
sys.exit(0 if ok else 1)' "$(printf '%s' "$checks_json" | jq -c '.docs_only // []')"
}
if [ "$since_green" -eq 1 ] && [ -z "$only" ] && [ -n "$green" ] && git cat-file -e "$green^{commit}" 2>/dev/null \
   && { git diff --name-only "$green" --; git ls-files --others --exclude-standard; } | docs_only; then
  list fast > "$plan"; reused="$green"
fi
set_state() { # <jq filter> [args]: updates the run's state.json in place
  [ -n "$state" ] && [ -f "$state" ] || return 0
  local t; t="$(mktemp)"; jq "$@" "$state" > "$t" && mv "$t" "$state" || rm -f "$t"
}

reports="${run:+$run/reports}"
[ -n "$reports" ] || reports="$(mktemp -d)"
port="$( [ -n "$run" ] && jq -r '.port // empty' "$run/state.json" 2>/dev/null)"
tmp="$(mktemp -d)"
results="$tmp/results"; : > "$results"
changed="$tmp/changed"; : > "$changed"
base="$( [ -n "$run" ] && jq -r '.base // empty' "$run/state.json" 2>/dev/null)"
if [ "$set_name" = affected ]; then
  [ -n "$base" ] || { echo "run-checks: the affected set needs an active run with a base commit" >&2; exit 2; }
  { git diff --name-only "$base" --; git ls-files --others --exclude-standard; } | sort -u > "$changed"
fi
ran=""; failed=0; known=""; failed_names=""; total_start="$(date +%s)"
trap 'c=$?; rm -rf "$plan" "${tmp:-}"; factory_step "checks:$set_name${only:+:$only}" "$total_start" "$c"' EXIT

failed_ids() { factory_py "$FACTORY_LIB/junit.py" failed "$1" 2>/dev/null; }
only_flakes() { # <report dir>: the check's failed tests are all confirmed flakes (and there is one at least)
  [ -n "$flakes" ] && [ -f "$flakes" ] || return 1
  local ids; ids="$(failed_ids "$1")"
  [ -n "$ids" ] || return 1
  printf '%s\n' "$ids" | grep -F -x -v -q -f "$flakes" && return 1
  return 0
}
is_known() { [ -n "$known_failures" ] && [ -f "$known_failures" ] && grep -F -x -q -e "$1" "$known_failures"; }

while IFS= read -r -d '' name && IFS= read -r -d '' cmd; do
  [ -n "$name" ] || continue
  dir="$reports/$name"; rm -rf "$dir"; mkdir -p "$dir"
  log="$tmp/$name.log"; start="$(date +%s)"
  (
    export CI=true FACTORY_REPORTS="$dir" FACTORY_CHANGED_FILES="$changed" FACTORY_BASE="$base" PLAYWRIGHT_JUNIT_OUTPUT_FILE="$dir/junit.xml" JEST_JUNIT_OUTPUT_DIR="$dir"
    if [ -n "$port" ]; then export FACTORY_PORT="$port"; [ -n "${PORT:-}" ] || export PORT="$port"; fi
    bash -c "$cmd"
  ) > "$log" 2>&1 < /dev/null
  code=$?
  secs=$(( $(date +%s) - start ))
  jq -nc --arg n "$name" --argjson c "$code" --argjson s "$secs" --arg cmd "$cmd" '{name: $n, exit: $c, seconds: $s, command: $cmd}' >> "$results"
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
  if only_flakes "$dir"; then
    known="$known${known:+, }$name (flaky)"
    printf 'run-checks: FLAKE %s (exit %s): it failed only on confirmed flaky tests: %s\n' "$name" "$code" "$(failed_ids "$dir" | paste -sd ';' -)"
    continue
  fi
  failed=$((failed + 1))
  printf 'run-checks: FAIL %s (exit %s, %ss): %s\n' "$name" "$code" "$secs" "$cmd"
  tail -n "$tail_lines" "$log" | sed 's/^/  | /'
done < "$plan"

if [ -n "$json" ]; then
  jq -s '.' "$results" > "$json"
fi
if [ -n "$save_failures" ]; then
  mkdir -p "$(dirname "$save_failures")" 2>/dev/null
  printf '%s' "$failed_names" > "$save_failures"
fi
if [ "$set_name" = all ] && [ -z "$only" ] && [ -z "$reused" ] && [ -n "$ran" ]; then
  if [ "$failed" -gt 0 ]; then set_state 'del(.checks_green)'
  elif [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    set_state '.checks_green = {commit: $c, at: $at}' --arg c "$(git rev-parse HEAD)" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
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
if [ -n "$reused" ]; then
  echo "run-checks: passed ($ran) in $(( $(date +%s) - total_start ))s; reused the green full run at $(printf '%s' "$reused" | cut -c1-12) for the rest (only docs changed since)"
  exit 0
fi
echo "run-checks: passed ($ran) in $(( $(date +%s) - total_start ))s"
exit 0
