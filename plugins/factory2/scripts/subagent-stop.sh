#!/usr/bin/env bash
# SubagentStop hook for factory2:implementer (hooks.json matcher ^factory2:implementer$): the implementer
# can't finish while the frozen files changed or the fast checks fail. Ported from singularity's
# subagent-stop.sh (MIT).
#   1. Re-verifies the freeze (tests and check-defining files). A changed hash counts as a failed check,
#      and the message names the file: this catches edits made through Bash, which the PreToolUse hook
#      on Edit|Write can't see.
#   2. Runs the fast checks from the freeze snapshot; checks in the run's baseline-failures were failing
#      before the change and don't block.
# On a failure it exits 2 and Claude Code keeps the implementer working with the message as its next
# instruction. After checks.stop_retries blocks for one agent id (default 3) it lets the agent stop; the
# orchestrator's own checks then report what still fails. Claude Code also caps continuations at 8.
# Time limit: Claude Code cancels a hook at its `timeout` (900 s in hooks.json) and discards its output,
# and a cancelled SubagentStop hook lets the agent stop unchecked (observed on 2.1.316, also with
# `onFailure: block`). So the checks run under this script's own limit of 840 s (FACTORY_GATE_BUDGET
# overrides it for tests). When the limit is hit
# the checks are killed, the stop is let through, and it is recorded (stop-gate.log, state.gate_timeouts)
# for the orchestrator, which re-runs every check itself after each implementer pass anyway.
# Every other agent, an empty agent_type, and a checkout with no active run pass straight through.
set -u
t_start="$(date +%s)"
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_hook_log subagent-stop "$input"
factory_has jq || exit 0

agent="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
[ "$agent" = "factory2:implementer" ] || exit 0
slug="$(factory_active_slug)"; [ -n "$slug" ] || exit 0
run="$FACTORY_ROOT_DIR/.factory/runs/$slug"
[ -f "$run/state.json" ] || exit 0

retries="$(jq -r '.stop_retries // empty' "$run/checks.snapshot.json" 2>/dev/null)"
[ -n "$retries" ] || retries="$(cfg '.checks.stop_retries' 3)"
case "$retries" in ''|*[!0-9]*) retries=3 ;; esac
id="$(printf '%s' "$input" | jq -r '.agent_id // .session_id // "unknown"' | tr -c 'A-Za-z0-9_.-' '_')"
counter="$run/stop-$id.count"
count="$(cat "$counter" 2>/dev/null)"; case "$count" in ''|*[!0-9]*) count=0 ;; esac
if [ "$count" -ge "$retries" ]; then rm -f "$counter"; exit 0; fi

block() { # <kind> <details>
  count=$((count + 1))
  printf '%s\n' "$count" > "$counter"
  printf '%s\t%s\t%s\t%s/%s\t%s\n' "$(now_utc)" "$agent" "$id" "$count" "$retries" "$1" >> "$run/stop-gate.log"
  {
    printf "factory: you can't finish yet (block %s of %s).\n" "$count" "$retries"
    if [ "$1" = "freeze" ]; then
      printf 'Frozen files changed. Tests and the files that define the checks are frozen for this run; restore them\n'
      printf '(git checkout -- <path>) and make the change in the product code instead. A dependency or file the\n'
      printf "work genuinely needs belongs in plan.md's Exceptions section, which the orchestrator handles, not you.\n\n"
    else
      printf 'The fast checks fail. Fix the cause in the code. Never weaken, skip or delete a test or a check.\n'
      printf "If the failure isn't caused by your change, or the plan can't work, stop and say so in your final answer.\n\n"
    fi
    printf '%s\n' "$2"
  } >&2
  exit 2
}

if [ "$(jq -r '.frozen // false' "$run/state.json")" = "true" ]; then
  out="$(bash "$FACTORY_SCRIPTS/state.sh" verify-freeze 2>&1)"
  # any non-zero blocks: 1 is a changed file, 2 means the freeze couldn't be verified (unreadable file,
  # missing frozen.tsv), which is not a pass either
  [ $? -ne 0 ] && block freeze "$out"
fi

budget="${FACTORY_GATE_BUDGET:-840}"   # gate.sh's limit is 870 s (hooks.json 900 s), less the time used so far
case "$budget" in ''|*[!0-9]*) budget=840 ;; esac
limit="$budget"
budget=$((budget - ($(date +%s) - t_start))); [ "$budget" -lt 1 ] && budget=1
known=()
[ -f "$run/baseline-failures" ] && known=(--known-failures "$run/baseline-failures")
out="$(factory_py "$FACTORY_LIB/timeout.py" "$budget" bash "$FACTORY_SCRIPTS/run-checks.sh" --set fast --tail 30 "${known[@]+"${known[@]}"}" 2>&1)"
code=$?
if [ "$code" -eq 124 ]; then
  printf '%s\t%s\t%s\t-\ttimeout after %ss\n' "$(now_utc)" "$agent" "$id" "$limit" >> "$run/stop-gate.log"
  state_update '.gate_timeouts = ((.gate_timeouts // 0) + 1)' 2>/dev/null
  echo "factory: the fast checks took longer than ${limit}s; the stop gate let the implementer finish unchecked. The orchestrator re-runs the checks." >&2
  rm -f "$counter"; exit 0
fi
# 0 passed, 3 nothing to run; anything else (1 failed, 2 config error, a signal) is not a pass
case "$code" in 0|3) ;; *) block checks "$out" ;; esac
rm -f "$counter"
exit 0
