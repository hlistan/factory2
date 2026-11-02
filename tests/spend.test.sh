#!/usr/bin/env bash
# spend.py prices transcripts; spend.sh stores a subagent's spend once per agent id; state.sh sums.
. "$(dirname "$0")/lib.sh"
P="$S/lib/prices.json"
run python3 -I "$S/lib/spend.py" "$FIX/transcripts/sample.jsonl" "$P"
t_code 0 "prices a transcript"
t_eq "$(printf '%s' "$OUT" | jq -r '.messages')" "5" "counts each message id once"
# m1 0.034 (5m and 1h cache tiers) + m2 0.00528 (fast x2, US x1.1) + m3 0.0305 (Haiku long prompt) + m5 0.0025 (no split: 5m)
t_eq "$(printf '%s' "$OUT" | jq -r '.usd')" "0.07228" "prices tiers, fast mode, US inference and long Haiku prompts"
t_eq "$(printf '%s' "$OUT" | jq -r '.unpriced_models | join(",")')" "claude-mystery-9" "lists unknown models"
t_eq "$(printf '%s' "$OUT" | jq -r '.tokens.cache_write_1h')" "1000" "keeps the 1-hour tier"

R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'limits:
  budget_usd: 0.05'
bash "$S/state.sh" start s1 >/dev/null
bash "$S/state.sh" stage 4 >/dev/null
ev() { jq -n --arg a "$1" --arg id "$2" --arg t "$3" '{agent_type: $a, agent_id: $id, agent_transcript_path: $t}'; }
hook "$S/spend.sh" "$(ev factory:implementer a1 "$FIX/transcripts/sample.jsonl")"; t_code 0 "spend hook exits 0"
hook "$S/spend.sh" "$(ev factory:implementer a1 "$FIX/transcripts/sample.jsonl")"; t_code 0 "repeat stop of one agent"
hook "$S/spend.sh" "$(ev general-purpose a2 "$FIX/transcripts/sample.jsonl")"; t_code 0 "non-factory agents are ignored"
hook "$S/spend.sh" "$(ev factory:implementer a3 /nonexistent.jsonl)"; t_code 0 "a missing transcript never blocks"
t_eq "$(jq -r '.spend.agents | length' "$R/.factory/runs/s1/state.json")" "1" "one priced spawn, stored once"
run bash "$S/state.sh" spend
t_eq "$(printf '%s' "$OUT" | jq -r '.total')" "0.07228" "total is not double-counted"
t_eq "$(printf '%s' "$OUT" | jq -r '.by_stage["4"]')" "0.07228" "attributed to stage 4"
printf '%s\n' "$FIX/transcripts/sample.jsonl" > "$R/.factory/runs/.main-transcript"
run bash "$S/state.sh" budget-check
t_code 1 "budget exceeded once the orchestrator's own spend is added"
t_has "$OUT" "0.14" "reports the combined estimate"
run bash "$S/state.sh" spend
t_eq "$(printf '%s' "$OUT" | jq -r '.by_agent.orchestrator')" "0.07228" "orchestrator spend from the main transcript"
bash "$S/state.sh" stage 5 >/dev/null
run bash "$S/state.sh" spend
t_eq "$(printf '%s' "$OUT" | jq -r '.by_stage["5"] // 0')" "0" "the main transcript is not counted again in the next stage"
t_done
