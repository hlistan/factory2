#!/usr/bin/env bash
# SubagentStop hook for every factory agent (hooks.json matcher ^factory:). Prices the subagent's
# transcript (agent_transcript_path) and stores it under its agent id in the active run's state, so
# repeated stops of one subagent (SubagentStop fires again after each exit-2 continuation) overwrite
# rather than add. Always exits 0: spend tracking never blocks work. Subagents ended with TaskStop may not
# fire SubagentStop (anthropics/claude-code#92716); `state.sh spend` reports them as unpriced spawns.
set -u
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_hook_log spend "$input"
factory_has jq && factory_has python3 || exit 0
slug="$(factory_active_slug)"; [ -n "$slug" ] || exit 0
run="$FACTORY_ROOT_DIR/.factory/runs/$slug"
[ -f "$run/state.json" ] || exit 0
agent="$(printf '%s' "$input" | jq -r '.agent_type // empty')"
id="$(printf '%s' "$input" | jq -r '.agent_id // empty')"
t="$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty')"
case "$agent" in factory2:*) ;; *) exit 0 ;; esac
[ -n "$id" ] && [ -n "$t" ] && [ -f "$t" ] || exit 0
priced="$(factory_py "$FACTORY_LIB/spend.py" "$t" "$FACTORY_LIB/prices.json" 2>/dev/null)" || exit 0
state_update '.spend.agents[$id] = ({agent: $a, stage: (.stage // 0), at: $at} + ($p | {usd, tokens, by_model, unpriced_models}))' \
  --arg id "$id" --arg a "${agent#factory2:}" --arg at "$(now_utc)" --argjson p "$priced" 2>/dev/null
exit 0
