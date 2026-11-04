#!/usr/bin/env bash
# stats.sh: tables from .factory/history/*.json, --since, --export-evals, and the small-sample warning.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
X="$PLUGIN/scripts/stats.sh"
run bash "$X";                                   t_code 0 "no history"
t_has "$OUT" "No history yet" "says so"
H="$R/.factory/history"; mkdir -p "$H"
cat > "$H/dark-mode.json" <<'J'
{"slug":"dark-mode","started":"2026-10-01T10:00:00Z","finished":"2026-10-01T15:00:00Z","kind":"feature","depth":"full","ce_version":"3.34.0",
 "rounds":{"prd":2,"impl":1,"review":1,"evidence":1},"escalations":[],"incidents":[{"issue":"12"}],
 "implementer_passes":[{"round":1,"effort":"low","model":"opus","passed":false},{"round":2,"effort":"high","model":"opus","passed":true}],
 "issues":[{"stage":2,"found_by":"human","class":"missing-state","problem_type":"logic_error","component":"ui"},{"stage":6,"found_by":"human","class":"defect"}],
 "qa_false_negatives":[{"ac":"AC-2","comment":"The toggle doesn't persist after reload."}],
 "spend":{"by_stage":{"1":2.5,"4":10,"5":4},"total":16.5,"by_agent":{"implementer":8,"orchestrator":3}},
 "compound":[{"point":"prd","outcome":"complete"},{"point":"review","outcome":"skipped"}],"calibration":[]}
J
cat > "$H/fix-12-toggle.json" <<'J'
{"slug":"fix-12-toggle","started":"2026-10-05T10:00:00Z","finished":"2026-10-05T12:00:00Z","kind":"bugfix","caused_by":"dark-mode","depth":"lite",
 "escape":{"caused_by":"dark-mode","stage_missed":"5"},"ce_version":"3.34.0",
 "implementer_passes":[{"round":1,"effort":"low","model":"opus","passed":true}],"spend":{"by_stage":{"4":3},"total":3},"compound":[{"outcome":"complete"}]}
J
printf 'not json' > "$H/broken.json"
mkdir -p "$R/.claude/agent-memory/factory-prd-reviewer"
for i in $(seq 1 130); do echo "- lesson $i"; done > "$R/.claude/agent-memory/factory-prd-reviewer/MEMORY.md"
mkdir -p "$R/docs/solutions/logic-errors"; printf -- '---\ntitle: x\nproblem_type: logic_error\n---\nbody\n' > "$R/docs/solutions/logic-errors/x.md"

run bash "$X";                                   t_code 0 "stats"
t_has "$OUT" "2 run(s): 1 feature, 1 bugfix" "run counts"
t_has "$OUT" "skipped unreadable .factory/history/broken.json" "a broken file is skipped, not fatal"
t_has "$OUT" "Fewer than 10 runs" "small samples are directional"
t_has "$OUT" "| 4 | \$13.00 | 67% |" "spend by stage summed across runs"
t_has "$OUT" "| opus | low | 2 | 50% (1/2) | 1 | 1 |" "first-pass rate by model and effort, with QA misses"
t_has "$OUT" "| dark-mode | fix-12-toggle | 5 |" "escapes per originating run"
t_has "$OUT" "| 2 | missing-state | logic_error | ui | 1 |" "issues people found"
t_has "$OUT" "| full | 1 | 1 | 1 |" "depth ablation"
t_has "$OUT" "| complete | 2 |" "ce-compound outcomes"
t_has "$OUT" "| prd-reviewer | 130 | 150 | consolidate |" "memory near the cap"
t_has "$OUT" "| logic_error | 1 |" "lessons by problem type"
run bash "$X" --since 2026-10-03;                t_code 0 "--since"
t_has "$OUT" "1 run(s): 0 feature, 1 bugfix" "filters by start date"
run bash "$X" --export-evals;                    t_code 0 "export evals"
t_has "$(cat "$R/.factory/eval-candidates/qa-dark-mode-ac-2.md")" "doesn't persist after reload" "candidate case written"
run bash "$X" --bogus;                           t_code 2 "unknown option"
t_done
