#!/usr/bin/env bash
# The run's trace (stages, phases, rounds, waits for the person, timed checks) and its analysis: time,
# tokens and money per stage and agent, loops back with their reasons, repeated steps, what to change.
. "$(dirname "$0")/lib.sh"
A="$S/lib/analysis.py"

# --- analysis.py on a known state: exact numbers
cat > "$T_TMP/state.json" <<'JSON'
{"created": "2026-11-01T10:00:00Z", "stage": 7, "rounds": {"impl": 3, "review": 2, "evidence": 3},
 "trace": [
  {"at": "2026-11-01T11:00:00Z", "kind": "stage", "stage": 2, "from": 1},
  {"at": "2026-11-01T11:10:00Z", "kind": "wait", "for": "approval:prd"},
  {"at": "2026-11-01T13:10:00Z", "kind": "reply", "for": "approval:prd", "outcome": "approved"},
  {"at": "2026-11-01T13:10:00Z", "kind": "stage", "stage": 4, "from": 2},
  {"at": "2026-11-01T15:10:00Z", "kind": "stage", "stage": 6, "from": 4},
  {"at": "2026-11-01T15:20:00Z", "kind": "step", "name": "evidence capture", "secs": 1800, "exit": 0},
  {"at": "2026-11-01T16:00:00Z", "kind": "stage", "stage": 5, "from": 6, "why": "a layout shift in the inbox", "revoked": "evidence"},
  {"at": "2026-11-01T17:00:00Z", "kind": "stage", "stage": 6, "from": 5},
  {"at": "2026-11-01T17:30:00Z", "kind": "step", "name": "evidence capture (re-record AC-3)", "secs": 600, "exit": 1},
  {"at": "2026-11-01T17:40:00Z", "kind": "step", "name": "checks:all", "secs": 300, "exit": 0},
  {"at": "2026-11-01T18:00:00Z", "kind": "stage", "stage": 7, "from": 6}],
 "spawns": [{"agent": "implementer", "stage": 4, "at": "2026-11-01T13:20:00Z"}],
 "spend": {"main": {"1": 1, "4": 2}, "main_tokens": {"4": {"input": 1000, "output": 500}},
   "agents": {"a1": {"agent": "implementer", "stage": 4, "usd": 6, "tokens": {"input": 10, "cache_read": 2000000, "output": 40000}},
              "a2": {"agent": "planner", "stage": 1, "usd": 1, "tokens": {"output": 1000}}}}}
JSON
printf '{"escalations": [{"stage": 5, "reason": "review_rounds 2 used up"}], "issues": [{"found_by": "human"}]}' > "$T_TMP/history.json"
run python3 -I "$A" "$T_TMP/state.json" "$T_TMP/history.json" --now 2026-11-01T18:00:00Z; t_code 0 "analysis"
MD="$(printf '%s' "$OUT" | jq -r .markdown)"; SUM="$(printf '%s' "$OUT" | jq -c .summary)"
t_eq "$(printf '%s' "$SUM" | jq .elapsed_s)" "28800" "elapsed: 8 hours"
t_eq "$(printf '%s' "$SUM" | jq .waiting_s)" "7200" "of which 2 hours waiting for the person"
t_has "$MD" "8h 00m elapsed · 6h 00m working · 2h 00m waiting for a person" "the totals line"
t_eq "$(printf '%s' "$SUM" | jq '.usd | floor')" "10" "dollars: main session plus agents"
t_eq "$(printf '%s' "$SUM" | jq '.stages["4"].tokens')" "2041510" "tokens per stage, main and agents"
t_eq "$(printf '%s' "$SUM" | jq '.stages["6"].visits')" "2" "stage 6 was entered twice"
t_eq "$(printf '%s' "$SUM" | jq '.stages["6"].secs')" "6600" "time per stage sums its visits"
t_has "$MD" "| 4 Implement | 2h 00m | 1 | \$8.00 | 2.0M |" "the stage table"
t_has "$MD" "| implementer | 1 | \$6.00 | 2.0M | 40k |" "the agent table"
t_has "$MD" "stage 6 → 5: a layout shift in the inbox (revoked: evidence) · 1h 00m until back" "the loop back, its reason and cost"
t_has "$MD" "approval:prd 2h 00m (approved)" "the wait for the person"
t_has "$MD" "evidence recording ×2 40m (1 failed)" "repeated recordings, counted together"
t_has "$MD" "**The evidence was recorded 2 times**" "and a tip to record once"
t_has "$MD" "**1 evidence recording(s) failed**" "a failed recording means the checks missed it"
t_has "$MD" "**1 loop(s) back** cost 1h 00m" "loops back cost"
t_has "$MD" "**1 limit(s) were raised mid-run** (review_rounds 2 used up)" "raised limits"
t_has "$MD" "**implementer** cost \$6.00" "the costliest agent"
t_has "$MD" "**The implementer ran 3 times**" "implementer re-runs"
t_has "$MD" "**People found 1 issue(s) the agents missed**" "issues found by people"
t_hasnt "$MD" "estimated" "a fully traced run isn't an estimate"

# --- a run on an older factory, without a trace: stage times from the agents
printf '{"created":"2026-11-01T10:00:00Z","spawns":[{"agent":"planner","stage":1,"at":"2026-11-01T10:00:00Z"},{"agent":"implementer","stage":4,"at":"2026-11-01T12:00:00Z"}]}' > "$T_TMP/old.json"
run python3 -I "$A" "$T_TMP/old.json" --now 2026-11-01T13:00:00Z; t_code 0 "analysis without a trace"
t_eq "$(printf '%s' "$OUT" | jq '.summary.stages["4"].secs')" "3600" "stage 4 from the implementer's spawn"
t_has "$(printf '%s' "$OUT" | jq -r .markdown)" "estimated from the agents" "and says it is an estimate"
t_has "$(printf '%s' "$OUT" | jq -r .markdown)" "Nothing stands out" "no tips for a clean run"

# --- the trace from the scripts
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'checks:
  fast:
    unit: "true"'
bash "$S/state.sh" start demo >/dev/null; bash "$S/state.sh" branch >/dev/null
bash "$S/state.sh" stage 4 >/dev/null; bash "$S/state.sh" phase code >/dev/null; bash "$S/state.sh" round impl >/dev/null
bash "$S/run-checks.sh" --set fast >/dev/null
bash "$S/state.sh" stage 2 --why "the person asked for a new criterion" >/dev/null
run bash "$S/state.sh" trace wait '{"for":"approval:prd"}'; t_code 0 "trace"
run bash "$S/state.sh" trace;                   t_code 2 "trace needs a kind"
T="$(bash "$S/state.sh" get '.trace')"
t_eq "$(printf '%s' "$T" | jq -r '[.[].kind] | join(" ")')" "stage phase round step stage wait" "every event in order"
t_eq "$(printf '%s' "$T" | jq -r '.[3].name')" "checks:fast" "a timed check"
t_eq "$(printf '%s' "$T" | jq -r '.[4] | "\(.from)>\(.stage) \(.why)"')" "4>2 the person asked for a new criterion" "the move back with its reason"
run bash "$S/state.sh" analysis --md;           t_code 0 "state.sh analysis"
t_has "$OUT" "### 📊 Analysis" "prints the analysis"
t_eq "$([ -s "$R/.factory/runs/demo/analysis.md" ] && echo yes)" "yes" "and saves it"
t_has "$(jq -c .analysis "$R/.factory/history/demo.json")" '"loops_back"' "its numbers go to the history"
t_done
