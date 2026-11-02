#!/usr/bin/env bash
# state.sh: the lock, resume, counters, approvals, calibration and the memory fold; run-checks' JUnit
# environment; change-diff --hash catching a write; session-start's context lines.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'checks:
  fast:
    unit: "printf %s \"$FACTORY_PORT\" > $FACTORY_REPORTS/port.txt; cp u.xml $FACTORY_REPORTS/u.xml"
    lint: "exit 3"
  slow:
    e2e: "echo $PLAYWRIGHT_JUNIT_OUTPUT_FILE > $FACTORY_REPORTS/where.txt"
learning:
  memory_max_lines: 8'

printf '<testsuite><testcase classname="a" name="t @AC-1"/></testsuite>\n' > "$R/u.xml"
run bash "$S/state.sh" active;            t_code 1 "no active run"
run bash "$S/state.sh" start "Bad Slug";  t_code 2 "slug is validated"
run bash "$S/state.sh" start dark-mode;   t_code 0 "start"
t_eq "$(cat "$R/.factory/runs/active")" "dark-mode" "active file"
t_eq "$(cat "$R/.factory/runs/.gitignore")" "*" "runs/ is git-ignored"
port="$(jq -r .port "$R/.factory/runs/dark-mode/state.json")"
case "$port" in 4[1-8][0-9][0-9][0-9]) t_ok ;; *) t_fail "port in range: $port" ;; esac
t_eq "$(jq -r .slug "$R/.factory/history/dark-mode.json")" "dark-mode" "history file created"
run bash "$S/state.sh" start other;       t_code 1 "a second run is refused in the same checkout"
t_has "$ERR" "worktree" "points to claude --worktree"
run bash "$S/state.sh" start dark-mode;   t_code 0 "restarting the same run is idempotent"
t_eq "$(jq -r .port "$R/.factory/runs/dark-mode/state.json")" "$port" "port is stable"

run bash "$S/state.sh" phase nonsense;    t_code 2 "phase is validated"
bash "$S/state.sh" phase tests >/dev/null
t_eq "$(bash "$S/state.sh" get .phase)" "tests" "phase set"
t_eq "$(bash "$S/state.sh" round impl)" "1" "round counter"
t_eq "$(bash "$S/state.sh" round impl)" "2" "round counter increments"
run bash "$S/state.sh" approve merge;     t_code 2 "unknown gate"
bash "$S/state.sh" approve prd abc123 >/dev/null
t_eq "$(bash "$S/state.sh" get .approvals.prd.sha)" "abc123" "approval records the sha"
bash "$S/state.sh" spawn implementer low opus >/dev/null
bash "$S/state.sh" spawn implementer high opus >/dev/null
t_eq "$(jq -c '[.models[] | .effort]' "$R/.factory/history/dark-mode.json")" '["high","low"]' "efforts used are recorded in history"
t_eq "$(bash "$S/state.sh" get false)" "false" "get prints false, not nothing"

# --- run-checks environment and JUnit placement
run bash "$S/run-checks.sh" --set fast
t_code 1 "a failing check fails the run"
t_has "$OUT" "FAIL lint (exit 3" "names the failing check"
t_eq "$(cat "$R/.factory/runs/dark-mode/reports/unit/port.txt")" "$port" "FACTORY_PORT is the run's port"
run bash "$S/run-checks.sh" --set fast --only unit --json "$T_TMP/r.json"
t_code 0 "--only runs one check"
t_eq "$(jq -r '.[0].name + ":" + (.[0].exit | tostring)' "$T_TMP/r.json")" "unit:0" "json results"
run bash "$S/run-checks.sh" --set slow
t_eq "$(cat "$R/.factory/runs/dark-mode/reports/e2e/where.txt")" "$R/.factory/runs/dark-mode/reports/e2e/junit.xml" "Playwright's JUnit output goes to the check's report dir"
printf 'lint\n' > "$T_TMP/known"
run bash "$S/run-checks.sh" --set fast --known-failures "$T_TMP/known"
t_code 0 "known failures don't fail the run"
mkdir -p "$R/docs/specs/dark-mode"
printf '{"criteria":[{"id":"AC-1","text":"x","test_ids":[],"passes":false}]}\n' > "$R/docs/specs/dark-mode/contract.json"
bash "$S/run-checks.sh" --set fast --only unit >/dev/null
run bash "$S/state.sh" contract-sync
t_code 0 "contract-sync reads the run's reports"
t_eq "$(jq -r '.criteria[0].passes' "$R/docs/specs/dark-mode/contract.json")" "true" "passes set by the harness"

# --- calibration and the memory fold
run bash "$S/state.sh" calibrate "Bad Agent" "x"; t_code 2 "agent name is validated"
bash "$S/state.sh" calibrate prd-reviewer "check every list view has an empty-state criterion" >/dev/null
bash "$S/state.sh" calibrate prd-reviewer "$(printf 'multi\nline\tlesson')" >/dev/null
t_eq "$(jq -r '.calibration | length' "$R/.factory/history/dark-mode.json")" "2" "lessons recorded in history"
t_has "$(jq -r '.calibration[1].line' "$R/.factory/history/dark-mode.json")" "multi line lesson" "newlines and tabs flattened"
t_has "$(jq -r '.calibration[0].line' "$R/.factory/history/dark-mode.json")" "dark-mode: check every list view" "line carries the slug"
bash "$S/state.sh" fold-memory >/dev/null 2>&1
m="$R/.claude/agent-memory/factory-prd-reviewer/MEMORY.md"
t_has "$(cat "$m")" "Reference material, not rules" "MEMORY.md header"
t_eq "$(grep -c '^- ' "$m")" "2" "two lessons folded"
bash "$S/state.sh" fold-memory >/dev/null 2>&1
t_eq "$(grep -c '^- ' "$m")" "2" "fold is idempotent"
for i in 1 2 3 4 5 6; do bash "$S/state.sh" calibrate prd-reviewer "lesson $i" >/dev/null; done
run bash "$S/state.sh" fold-memory
t_has "$ERR" "archive.md" "cap reported"
t_eq "$(wc -l < "$m" | tr -d ' ')" "8" "MEMORY.md held at memory_max_lines"
t_has "$(tail -n 1 "$m")" "lesson 6" "newest lesson kept"
t_has "$(cat "$R/.claude/agent-memory/factory-prd-reviewer/archive.md")" "empty-state" "oldest lesson archived"

# --- change-diff --hash sees a write anywhere, memory included
base="$(git -C "$R" rev-parse HEAD)"
h1="$(bash "$S/change-diff.sh" "$base" --hash --root "$R")"
printf 'x\n' >> "$m"
h2="$(bash "$S/change-diff.sh" "$base" --hash --root "$R")"
[ "$h1" != "$h2" ] && t_ok || t_fail "hash changes after a memory write"
printf 'scratch\n' > "$R/.factory/runs/dark-mode/scratch.txt"
h3="$(bash "$S/change-diff.sh" "$base" --hash --root "$R")"
t_eq "$h3" "$h2" "run state (git-ignored) doesn't change the hash"

# --- session-start context and resume
run bash "$S/state.sh" end; t_code 0 "end releases the checkout"
run bash "$S/state.sh" resume nope; t_code 1 "resume needs an existing run"
run bash "$S/state.sh" resume dark-mode; t_code 0 "resume"
mkdir -p "$T_TMP/cfgdir/plugins" "$T_TMP/data"
printf '{"version":2,"plugins":{"compound-engineering@compound-engineering-plugin":[{"version":"3.34.0"}]}}' > "$T_TMP/cfgdir/plugins/installed_plugins.json"
printf '{"passed_version":"3.33.2"}' > "$T_TMP/data/ce-contract.json"
CLAUDE_CONFIG_DIR="$T_TMP/cfgdir" CLAUDE_PLUGIN_DATA="$T_TMP/data" CLAUDE_CODE_EFFORT_LEVEL=high \
  hook "$S/session-start.sh" '{"hook_event_name":"SessionStart","transcript_path":"/tmp/t.jsonl"}'
t_has "$OUT" "run dark-mode is active at stage 1" "names the active run"
t_has "$OUT" "3.34.0 hasn't passed" "flags an untested compound-engineering version"
t_has "$OUT" "CLAUDE_CODE_EFFORT_LEVEL" "warns about the effort override"
t_eq "$(cat "$R/.factory/runs/.main-transcript")" "/tmp/t.jsonl" "records the transcript path"
printf '{"passed_version":"3.34.0"}' > "$T_TMP/data/ce-contract.json"
CLAUDE_CONFIG_DIR="$T_TMP/cfgdir" CLAUDE_PLUGIN_DATA="$T_TMP/data" hook "$S/session-start.sh" '{}'
t_hasnt "$OUT" "contract test" "quiet once the version passed"
R2="$(new_repo)"
FACTORY_ROOT="$R2" hook "$S/session-start.sh" '{}'
t_eq "$OUT" "" "silent in a project without factory"
# CLAUDE_CODE_EFFORT_LEVEL overrides the Agent tool's effort parameter: start/resume refuse unless told
R3="$(new_repo)"
CLAUDE_CODE_EFFORT_LEVEL=high FACTORY_ROOT="$R3" run bash "$S/state.sh" start eff
t_code 3 "start refuses while CLAUDE_CODE_EFFORT_LEVEL is set"
t_has "$ERR" "--effort-env-ok" "says how to proceed"
[ ! -f "$R3/.factory/runs/eff/state.json" ] && t_ok || t_fail "a refused start created state"
CLAUDE_CODE_EFFORT_LEVEL=high FACTORY_ROOT="$R3" run bash "$S/state.sh" start eff --effort-env-ok
t_code 0 "--effort-env-ok starts it"
t_eq "$(jq -r .effort_env "$R3/.factory/runs/eff/state.json")" "high" "records the level"
CLAUDE_CODE_EFFORT_LEVEL=low FACTORY_ROOT="$R3" run bash "$S/state.sh" resume eff
t_code 3 "resume refuses too"
FACTORY_ROOT="$R3" run bash "$S/state.sh" resume eff
t_code 0 "resume without the variable"
t_eq "$(jq -r .effort_env "$R3/.factory/runs/eff/state.json")" "null" "clears the recorded level"
# bugfix runs: start --issue records the issue and the run that caused it, in state and history
R4="$(new_repo)"
FACTORY_ROOT="$R4" run bash "$S/state.sh" start fix-12-login --issue 12 --caused-by dark-mode
t_code 0 "start --issue"
t_eq "$(jq -r '.kind + " " + .issue + " " + .caused_by' "$R4/.factory/runs/fix-12-login/state.json")" "bugfix 12 dark-mode" "state records a bugfix run"
t_eq "$(jq -r '.kind + " " + .issue + " " + .caused_by' "$R4/.factory/history/fix-12-login.json")" "bugfix 12 dark-mode" "history records it too"
FACTORY_ROOT="$R4" bash "$S/state.sh" end >/dev/null
FACTORY_ROOT="$R4" run bash "$S/state.sh" start plain
t_eq "$(jq -r '.kind, .issue' "$R4/.factory/runs/plain/state.json" | tr '\n' ' ')" "feature null " "a plain start is a feature run"
FACTORY_ROOT="$R4" bash "$S/state.sh" end >/dev/null
FACTORY_ROOT="$R4" run bash "$S/state.sh" start x --issue;            t_code 2 "--issue needs a reference"
FACTORY_ROOT="$R4" run bash "$S/state.sh" start x --caused-by "Bad"; t_code 2 "--caused-by needs a slug"
FACTORY_ROOT="$R4" run bash "$S/state.sh" start x --bogus;            t_code 2 "unknown start options are refused"
CLAUDE_CODE_EFFORT_LEVEL=high FACTORY_ROOT="$R4" run bash "$S/state.sh" start y --issue 3 --effort-env-ok
t_code 0 "--effort-env-ok works in any position"
t_done
