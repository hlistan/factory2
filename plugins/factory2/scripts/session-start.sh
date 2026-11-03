#!/usr/bin/env bash
# SessionStart hook. Stdout joins the session context, so it stays to a few lines, and prints nothing in
# projects that don't use factory. It:
#   - records this session's transcript path, which state.sh prices for the orchestrator's own spend;
#   - names the active run, if any, and open incidents;
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
  jq -r --arg s "$slug" '"factory: run \($s) is active at stage \(.stage) (\(.phase)). Continue it with /factory2:run \($s)."' "$runs/$slug/state.json"
fi
n="$(grep -l -E '^status: *open' "$root"/.factory/incidents/I-*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "${n:-0}" -gt 0 ] && echo "factory: $n open incident issue(s) in .factory/incidents/. /factory2:status lists them; fix each with a bugfix run: /factory2:run --issue <file>."

[ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] && echo "factory: CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL is set; it overrides every factory agent's effort, including the Agent tool's effort parameter."
exit 0
