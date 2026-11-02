#!/usr/bin/env bash
# Runs a factory gate hook so that a crash or a hang becomes an explicit decision instead of Claude Code's
# default, which is to let the action go ahead (a failed or timed-out command hook is a non-blocking
# error). Usage in hooks.json: gate.sh <closed|record> <seconds> <script> [args...]
#   exit 0 or 2 from the script   passed through (allow, or block with its message)
#   any other exit, or the limit  closed: inside a factory project (.factory/config.yaml exists), block
#                                         with exit 2 and say why; elsewhere allow, so a broken guard
#                                         never takes Bash or Edit away in unrelated projects
#                                 record: allow, and log it in the active run (gate-errors.log and
#                                         state.gate_errors) for the orchestrator, which re-checks anyway
# PreToolUse hooks also set `onFailure: "block"` in hooks.json for the case where this wrapper itself
# fails. SubagentStop ignores onFailure (probed on 2.1.316), which is why the stop gate uses `record`.
set -u
mode="${1:-}"; limit="${2:-}"; script="${3:-}"
[ $# -ge 3 ] && shift 3
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
case "$mode" in closed|record) ;; *) echo "factory gate.sh: mode is closed or record" >&2; exit 2 ;; esac
name="$(basename "$script" .sh)"
err="$(mktemp "${TMPDIR:-/tmp}/factory-gate.XXXXXX")"
trap 'rm -f "$err"' EXIT
case "$script" in /*) path="$script" ;; *) path="$FACTORY_SCRIPTS/$script" ;; esac   # absolute: tests only
printf '%s' "$input" | factory_py "$FACTORY_LIB/timeout.py" "$limit" bash "$path" "$@" 2> "$err"
code=$?
case "$code" in
  0) cat "$err" >&2; exit 0 ;;
  2) cat "$err" >&2; exit 2 ;;
esac
why="exit $code"; [ "$code" -eq 124 ] && why="no decision within ${limit}s"
detail="$(tail -n 5 "$err" | tr '\n' ' ')"
if [ "$mode" = "closed" ]; then
  [ -f "$FACTORY_ROOT_DIR/.factory/config.yaml" ] || exit 0
  echo "Blocked by factory: the $name safety check failed ($why) and factory blocks rather than guess. ${detail:+Details: $detail}Tell the user; run bash ${FACTORY_SCRIPTS}/doctor.sh to check the setup." >&2
  exit 2
fi
slug="$(factory_active_slug)"
if [ -n "$slug" ] && [ -f "$FACTORY_ROOT_DIR/.factory/runs/$slug/state.json" ]; then
  printf '%s\t%s\t%s\t%s\n' "$(now_utc)" "$name" "$why" "$detail" >> "$FACTORY_ROOT_DIR/.factory/runs/$slug/gate-errors.log"
  state_update '.gate_errors = ((.gate_errors // 0) + 1)' 2>/dev/null
fi
echo "factory: the $name gate failed ($why); the action was let through and recorded for the orchestrator." >&2
exit 0
