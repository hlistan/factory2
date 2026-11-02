#!/usr/bin/env bash
# SessionStart hook. Stdout joins the session context, so it stays to a few lines, and prints nothing in
# projects that don't use factory. It:
#   - records this session's transcript path, which state.sh prices for the orchestrator's own spend;
#   - names the active run, if any, and open incidents;
#   - warns when the installed compound-engineering version hasn't passed factory's contract test
#     (recorded in $CLAUDE_PLUGIN_DATA/ce-contract.json by /factory:init or /factory:run);
#   - warns when CLAUDE_CODE_EFFORT_LEVEL is set, because it overrides every agent's effort, the Agent tool's effort parameter included (observed on 2.1.316).
set -u
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_hook_log session-start "$input"
factory_has jq || exit 0
root="$FACTORY_ROOT_DIR"
[ -f "$root/.factory/config.yaml" ] || exit 0
runs="$root/.factory/runs"
mkdir -p "$runs" && { [ -f "$runs/.gitignore" ] || printf '*\n' > "$runs/.gitignore"; }
t="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$t" ] && printf '%s\n' "$t" > "$runs/.main-transcript"

slug="$(factory_active_slug)"
if [ -n "$slug" ] && [ -f "$runs/$slug/state.json" ]; then
  jq -r --arg s "$slug" '"factory: run \($s) is active at stage \(.stage) (\(.phase)). Continue it with /factory:run \($s)."' "$runs/$slug/state.json"
fi
n="$(grep -l -E '^status: *open' "$root"/.factory/incidents/I-*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "${n:-0}" -gt 0 ] && echo "factory: $n open incident(s) in .factory/incidents/. /factory:status lists them; the triager handles them in /factory:run."

data="${CLAUDE_PLUGIN_DATA:-}"
v="$(bash "$FACTORY_SCRIPTS/state.sh" ce-version 2>/dev/null)"
if [ -z "$v" ]; then
  echo "factory: compound-engineering is not installed; factory's learning layer needs it. Run /factory:init for the install commands."
elif [ -n "$data" ]; then
  passed="$(jq -r '.passed_version // empty' "$data/ce-contract.json" 2>/dev/null)"
  [ "$passed" = "$v" ] || echo "factory: compound-engineering $v hasn't passed factory's contract test${passed:+ (last passed: $passed)}; /factory:run runs it before stage 1."
fi
[ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] && echo "factory: CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL is set; it overrides every factory agent's effort, including the Agent tool's effort parameter."
exit 0
