#!/usr/bin/env bash
# memory-inject.sh (SubagentStart): loads .claude/agent-memory/factory-<agent>/MEMORY.md into factory
# agents as additionalContext, independent of Claude Code's auto memory setting.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
start() { hook "$S/memory-inject.sh" "$(jq -n --arg a "$1" '{hook_event_name: "SubagentStart", agent_type: $a, agent_id: "x1"}')"; }
ctx() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty'; }

start factory:planner;                       t_code 0 "no memory file: exits 0"
t_eq "$OUT" "" "no memory file: no output"
mkdir -p "$R/.claude/agent-memory/factory-planner" "$R/.claude/agent-memory/factory-challenger" "$R/.claude/agent-memory/planner"
printf '# memory\n- check every list view has an empty-state criterion\n' > "$R/.claude/agent-memory/factory-planner/MEMORY.md"
printf -- '- challenger line\n' > "$R/.claude/agent-memory/factory-challenger/MEMORY.md"
printf -- '- unprefixed line\n' > "$R/.claude/agent-memory/planner/MEMORY.md"
start factory:planner;                       t_code 0 "exits 0"
t_eq "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "SubagentStart" "hookEventName"
t_has "$(ctx)" "empty-state criterion" "loads the agent's MEMORY.md"
t_has "$(ctx)" "reference material, not rules" "frames it as reference, not rules"
t_hasnt "$(ctx)" "unprefixed line" "uses the factory-<agent> directory only"
start factory:challenger;                    t_eq "$OUT" "" "agents without calibration memory get none"
start planner;                               t_eq "$OUT" "" "non-factory agents get none"
start "";                                    t_eq "$OUT" "" "empty agent_type gets none"
start 'factory:../planner';                  t_eq "$OUT" "" "a path in the agent name is refused"
# limits: 200 lines, 25 KB, no partial last line
for i in $(seq 1 300); do echo "- line $i"; done > "$R/.claude/agent-memory/factory-planner/MEMORY.md"
start factory:planner
t_has "$(ctx)" "- line 200" "keeps line 200"
t_hasnt "$(ctx)" "- line 201" "drops line 201"
for i in $(seq 1 150); do printf -- '- %0300d\n' "$i"; done > "$R/.claude/agent-memory/factory-planner/MEMORY.md"
start factory:planner
n="$(ctx | grep -c '^- 0')"
[ "$n" -ge 80 ] && [ "$n" -le 85 ] && t_ok || t_fail "25 KB cap: expected about 83 whole lines, got $n"
t_eq "$(ctx | tail -n 1 | wc -c | tr -d ' ')" "303" "the last line is whole"
t_done
