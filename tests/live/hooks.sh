#!/usr/bin/env bash
# Live: factory's hooks fire in a real session, and the platform behaves as factory assumes. Runs
# `claude -p --plugin-dir` (factory and compound-engineering: factory loads no agents without its
# dependency) under your normal login, in throwaway repos, with spend caps, and auto memory forced OFF for
# the test sessions (--settings): factory's agent memory must not depend on it. FACTORY_HOOK_LOG (a
# directory) captures every hook input as a file.
#  A (main session + read-only subagent + memory + Skill gating):
#    - SessionStart, PreToolUse Bash and PreToolUse Write fire
#    - guard-bash blocks ship.deploy outside an approved stage 7
#    - PreToolUse input for a subagent's tool call carries agent_type "factory:<agent>"
#    - test-guard blocks a Write from a read-only agent
#    - test-guard blocks writes to agent memory (shown from the main session: agents' prompts already
#      forbid it, so a subagent probe never reaches the hook)
#    - SubagentStart (memory-inject) loads .claude/agent-memory/factory-<agent>/MEMORY.md with auto memory off
#    - the Agent tool's `model` parameter takes effect (subagent transcript model)
#    - a subagent with disallowedTools: Skill can't invoke compound-engineering:ce-compound
#  B (implementer gate):
#    - SubagentStop ^factory2:implementer$ fires, blocks while a fast check fails, stops at stop_retries
#    - SubagentStop ^factory: fires for other agents (spend recorded in state.json)
#    - the Agent tool's effort parameter overrides the agent's frontmatter effort
#  C: CLAUDE_CODE_EFFORT_LEVEL overrides the Agent tool's effort parameter (why state.sh start refuses it)
#  D: the stop gate's own time limit: a hung fast check is killed, the stop let through and recorded
# Usage: bash tests/live/hooks.sh [--ce <compound-engineering dir>]   (about $2-6)
. "$(dirname "$0")/../lib.sh"
CE=""
[ "${1:-}" = "--ce" ] && CE="${2:-}"
[ -n "$CE" ] || CE="$(bash "$S/state.sh" ce-path 2>/dev/null)"
LOG="$T_TMP/hooks"
cl() { # <budget> <prompt>: claude -p in the current repo with factory (and ce, when found) loaded
  local extra=()
  [ -n "$CE" ] && extra=(--plugin-dir "$CE") || { echo "hooks.sh: compound-engineering not found (--ce <dir>)" >&2; exit 2; }
  FACTORY_HOOK_LOG="$LOG" claude -p "$2" --plugin-dir "$PLUGIN" "${extra[@]}" --model sonnet \
    --settings '{"autoMemoryEnabled": false}' --max-budget-usd "$1" --permission-mode acceptEdits --allowedTools "Agent Bash Read Write Glob Grep" \
    --output-format json < /dev/null 2> "$T_TMP/cl.err"
}
events() { ls "$LOG" 2>/dev/null | sed 's/^[0-9]*-[0-9]*-//; s/\.json$//' | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }
logs() { cat "$LOG"/*-"$1".json 2>/dev/null; }   # every logged input of one hook, one JSON per line
nlog() { local f n=0; for f in "$LOG"/*-"$1".json; do [ -f "$f" ] && n=$((n + 1)); done; echo "$n"; }

# ---------------------------------------------------------------- A
R="$(new_repo)"; cd "$R" || exit 2
write_config "$R" 'ship:
  deploy: "echo DEPLOYED > deployed.txt"
checks:
  fast:
    ok: "true"'
mkdir -p .claude/agent-memory/factory-researcher .claude/agent-memory/researcher .claude/agent-memory/factory-planner
printf '# memory\n- The project codename is ZEBRA-42.\n' > .claude/agent-memory/factory-planner/MEMORY.md
printf '# memory\n- The project codename is OTTER-17.\n' > .claude/agent-memory/researcher/MEMORY.md
git add -A && git commit -q -m fixture
FACTORY_ROOT="$R" bash "$S/state.sh" start probe >/dev/null   # test-guard and spend act only during a run
promptA='This is an automated test of a plugin. Do exactly these steps in order and report each result:
1. Run this exact Bash command: echo DEPLOYED > deployed.txt
2. Use the Agent tool with subagent_type "factory2:reviewer-spec" and model "sonnet", prompt: "Test step: first run the Bash command: echo probe-bash. Then use the Write tool to create probe.txt containing x. Reply with exactly what each tool returned, and stop."
2b. Use the Write tool yourself to create .claude/agent-memory/factory-test-author/MEMORY.md containing the line "- probe", and report what the tool returned.
3. Use the Agent tool with subagent_type "factory2:planner" and model "sonnet", prompt: "Test step: do not edit anything. Reply with the project codename if your memory contains one, else NONE. One line."
4. Use the Agent tool with subagent_type "factory2:researcher" and model "sonnet", prompt: "Test step: list the names of all tools you have. Then, if you have a tool named Skill, use it to invoke compound-engineering:ce-compound with no arguments; otherwise say NO-SKILL-TOOL. Reply in two lines."
Finish with one line per step: STEP<n>: <result>.'
outA="$(cl 3 "$promptA")"
resA="$(printf '%s' "$outA" | jq -r '.result // empty')"
printf '%s\n' "$resA" | tail -n 8 | sed 's/^/    A| /'
printf '    A cost $%s; hook events: %s\n' "$(printf '%s' "$outA" | jq -r '.total_cost_usd // "?"')" "$(events)"

t_eq "$(nlog session-start)" "1" "SessionStart fired"
t_has "$(logs guard-bash)" "deployed.txt" "PreToolUse Bash fired on the deploy command"
[ ! -f deployed.txt ] && t_ok || t_fail "ship.deploy ran outside stage 7"
t_has "$(logs guard-bash | grep 'probe-bash')" '"agent_type":"factory2:reviewer-spec"' "PreToolUse input for a subagent's tool call carries agent_type"
w="$(logs test-guard | grep 'probe.txt')"
if [ -n "$w" ]; then t_has "$w" '"agent_type":"factory2:reviewer-spec"' "the subagent's Write reached test-guard with agent_type"
else echo "    NOTE reviewer-spec didn't attempt the Write this time; the block is covered by tests/state and the unit tests"; fi
[ ! -f probe.txt ] && t_ok || t_fail "a read-only agent's Write was not blocked"
t_has "$(logs test-guard)" 'factory-test-author/MEMORY.md' "a memory write reached test-guard"
[ ! -f .claude/agent-memory/factory-test-author/MEMORY.md ] && t_ok || t_fail "a write to agent memory was not blocked"
t_has "$(logs memory-inject)" '"agent_type":"factory2:planner"' "SubagentStart fired for the planner"
t_has "$resA" "ZEBRA-42" "planner gets .claude/agent-memory/factory-planner/MEMORY.md with auto memory off"
t_hasnt "$resA" "OTTER-17" "the unprefixed agent-memory dir is not used"
t_has "$resA" "NO-SKILL-TOOL" "a subagent with disallowedTools: Skill has no Skill tool"
t_hasnt "$(cat "$LOG"/*.json)" '"skill":"compound-engineering:ce-compound"' "ce-compound was not invoked"
# the Agent tool's model parameter: the spend hook saw the subagent transcripts
tp="$(logs spend | head -n1 | jq -r '.agent_transcript_path // empty')"
if [ -n "$tp" ] && [ -f "$tp" ]; then
  t_has "$(jq -r 'select(.type == "assistant") | .message.model // empty' "$tp" | sort -u | tr '\n' ' ')" "sonnet" "Agent tool model parameter took effect"
else
  t_fail "no SubagentStop spend input with an agent_transcript_path"
fi
t_eq "$(nlog spend)" "3" "SubagentStop ^factory: fired once per factory subagent"
t_eq "$(jq -r '.spend.agents | length' "$R/.factory/runs/probe/state.json")" "3" "spend recorded per subagent"

# ---------------------------------------------------------------- B
rm -rf "$LOG"
R2="$(new_repo)"; cd "$R2" || exit 2
write_config "$R2" 'checks:
  fast:
    marker: "test -f done.marker"
  stop_retries: 1'
git add -A && git commit -q -m config
FACTORY_ROOT="$R2" bash "$S/state.sh" start hooktest >/dev/null
promptB='This is an automated test of a plugin. Use the Agent tool with subagent_type "factory2:implementer", model "sonnet" and effort "medium", prompt: "Test step: create hello.txt containing hello, then stop. Do not create any other file unless a hook message tells you exactly what to do." When it returns, reply with its final message and whether it was told it could not finish yet.'
outB="$(cl 2 "$promptB")"
printf '    B cost $%s; hook events: %s\n' "$(printf '%s' "$outB" | jq -r '.total_cost_usd // "?"')" "$(events)"
t_has "$(logs subagent-stop)" '"agent_type":"factory2:implementer"' "SubagentStop ^factory2:implementer\$ fired"
g="$(cat "$R2/.factory/runs/hooktest/stop-gate.log" 2>/dev/null)"
t_has "$g" "1/1" "the implementer was blocked once (stop_retries 1)"
t_eq "$(nlog subagent-stop)" "2" "after the cap the second stop is let through"
t_eq "$(jq -r '.spend.agents | length' "$R2/.factory/runs/hooktest/state.json")" "1" "spend hook recorded the implementer spawn"
# the effort actually sent is in the subagent transcript's request config (output_config.effort)
sent_effort() { grep -o '"output_config":{"effort":"[a-z]*"' "$1" 2>/dev/null | sed 's/.*"effort":"//; s/"$//' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
tp="$(logs subagent-stop | head -n1 | jq -r '.agent_transcript_path // empty')"
t_eq "$(sent_effort "$tp")" "medium" "the Agent tool's effort parameter overrides the frontmatter (low)"

# ---------------------------------------------------------------- C: does CLAUDE_CODE_EFFORT_LEVEL override the parameter?
rm -rf "$LOG"
promptC='This is an automated test of a plugin. Use the Agent tool with subagent_type "factory2:researcher", model "sonnet" and effort "low", prompt: "Test step: reply OK and stop." Then reply DONE.'
outC="$(CLAUDE_CODE_EFFORT_LEVEL=high cl 1 "$promptC")"
tp="$(logs spend | head -n1 | jq -r '.agent_transcript_path // empty')"
eC="$(sent_effort "$tp")"
printf '    C cost $%s; with CLAUDE_CODE_EFFORT_LEVEL=high and effort "low" the subagent ran at: %s\n' "$(printf '%s' "$outC" | jq -r '.total_cost_usd // "?"')" "${eC:-unknown}"
# observed on 2.1.316: the env var wins, so /factory2:run refuses to start while it is set
t_eq "$eC" "high" "CLAUDE_CODE_EFFORT_LEVEL overrides the Agent tool's effort parameter (factory relies on knowing this)"

# ---------------------------------------------------------------- D: the stop gate's time limit
rm -rf "$LOG"
R4="$(new_repo)"; cd "$R4" || exit 2
write_config "$R4" 'checks:
  fast:
    hang: "sleep 60"'
git add -A && git commit -q -m config
FACTORY_ROOT="$R4" bash "$S/state.sh" start gate >/dev/null
promptD='This is an automated test of a plugin. Use the Agent tool with subagent_type "factory2:implementer", model "sonnet" and effort "low", prompt: "Test step: create hello.txt containing hello, then stop." Then reply DONE.'
t0="$(date +%s)"
outD="$(FACTORY_GATE_BUDGET=5 cl 1 "$promptD")"
printf '    D cost $%s in %ss\n' "$(printf '%s' "$outD" | jq -r '.total_cost_usd // "?"')" "$(( $(date +%s) - t0 ))"
t_has "$(cat "$R4/.factory/runs/gate/stop-gate.log" 2>/dev/null)" "timeout after 5s" "the gate stopped the hung check at its own limit"
t_eq "$(jq -r '.gate_timeouts // 0' "$R4/.factory/runs/gate/state.json")" "1" "and recorded it for the orchestrator"
t_done
