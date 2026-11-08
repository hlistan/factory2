#!/usr/bin/env bash
# run-checks' affected set (only what the change touches) and confirmed flakes (a failure that passes
# when its tests run again alone does not fail the run, and is recorded).
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'checks:
  fast:
    unit: "true"
  slow:
    e2e: "cp \"$E2E_XML\" $FACTORY_REPORTS/junit.xml; exit ${E2E_EXIT:-1}"
  affected:
    pick: "cp \"$FACTORY_CHANGED_FILES\" $FACTORY_REPORTS/changed.txt; printf %s \"$FACTORY_BASE\" > $FACTORY_REPORTS/base.txt"'
bash "$S/state.sh" start speedy >/dev/null 2>&1
run_dir="$R/.factory/runs/speedy"
base="$(jq -r .base "$run_dir/state.json")"

# --- the affected set
printf 'x\n' > "$R/tracked.txt"; git -C "$R" add tracked.txt; git -C "$R" commit -q -m tracked
printf 'y\n' > "$R/untracked.txt"
run bash "$S/run-checks.sh" --set affected
t_code 0 "the affected set runs"
changed="$(cat "$run_dir/reports/pick/changed.txt")"
t_has "$changed" "tracked.txt" "a committed change since the base is listed"
t_has "$changed" "untracked.txt" "a new untracked file is listed"
t_hasnt "$changed" ".factory/runs" "the run's own files are not listed"
t_eq "$(cat "$run_dir/reports/pick/base.txt")" "$base" "FACTORY_BASE is the run's base"
run bash "$S/run-checks.sh" --set all --json "$T_TMP/all.json"
t_eq "$(jq -r '[.[].name] | join(",")' "$T_TMP/all.json")" "unit,e2e" "the full set leaves the affected checks out"

# --- confirmed flakes
fail_xml="$T_TMP/fail.xml"; pass_xml="$T_TMP/pass.xml"
printf '<testsuite><testcase classname="home" name="prompt stays"><failure/></testcase><testcase classname="home" name="other"/></testsuite>\n' > "$fail_xml"
printf '<testsuite><testcase classname="home" name="prompt stays"/><testcase classname="home" name="prompt stays"/></testsuite>\n' > "$pass_xml"
two_xml="$T_TMP/two.xml"
printf '<testsuite><testcase classname="home" name="prompt stays"><failure/></testcase><testcase classname="inbox" name="filter"><failure/></testcase></testsuite>\n' > "$two_xml"

export E2E_XML="$fail_xml"
run bash "$S/run-checks.sh" --set slow
t_code 1 "a failing test fails the run before it is a confirmed flake"

mkdir -p "$run_dir/reruns/e2e"; cp "$fail_xml" "$run_dir/reruns/e2e/junit.xml"
run bash "$S/state.sh" flaky --test "prompt stays"
t_code 1 "a test whose rerun still fails is not a flake"
t_has "$OUT" "prompt stays	FAILS" "says the rerun failed"
t_eq "$(cat "$run_dir/flakes" 2>/dev/null)" "" "nothing recorded for a real failure"

# The reruns go to <run>/reruns/<check>, never over the full run's reports (contract-sync reads those).
mkdir -p "$run_dir/reruns/e2e"; cp "$pass_xml" "$run_dir/reruns/e2e/junit.xml"
run bash "$S/state.sh" flaky --test "missing one"
t_code 1 "a test with no rerun result is not a flake"
t_has "$OUT" "NOT-VISIBLE" "says it was not rerun"
run bash "$S/state.sh" flaky --test "prompt stays"
t_code 0 "a test that passes every rerun is a confirmed flake"
t_has "$(cat "$run_dir/reports/e2e/junit.xml")" "<failure/>" "the full run's report is left as it was"
t_has "$OUT" "prompt stays	FLAKY	2 rerun(s) pass" "reports the reruns"
t_eq "$(cat "$run_dir/flakes")" "home::prompt stays" "the flake is listed for run-checks"
t_eq "$(jq -r '.flakes[0].test' "$R/.factory/history/speedy.json")" "home::prompt stays" "the flake is in the run's history"
bash "$S/state.sh" flaky --test "prompt stays" >/dev/null
t_eq "$(wc -l < "$run_dir/flakes" | tr -d ' ')" "1" "a flake is listed once"

run bash "$S/run-checks.sh" --set slow --flakes "$run_dir/flakes"
t_code 0 "a check whose only failures are confirmed flakes passes"
t_has "$OUT" "FLAKE e2e" "names the check that failed only on flakes"
t_has "$OUT" "home::prompt stays" "names the flake"
export E2E_XML="$two_xml"
run bash "$S/run-checks.sh" --set slow --flakes "$run_dir/flakes"
t_code 1 "another failing test still fails the run"
t_has "$OUT" "FAIL e2e" "reports the real failure"
E2E_XML="$T_TMP/none.xml" run bash "$S/run-checks.sh" --set slow --flakes "$run_dir/flakes"
t_code 1 "a failing check with no test results is never excused as a flake"

# --- reusing the last green full run when only docs changed since
unset E2E_XML
export E2E_XML="$pass_xml" E2E_EXIT=0
git -C "$R" add -A && git -C "$R" commit -q -m all
run bash "$S/run-checks.sh" --set all --since-green
t_code 0 "a full run with nothing green before it runs everything"
t_eq "$(jq -r '.checks_green.commit' "$run_dir/state.json")" "$(git -C "$R" rev-parse HEAD)" "a green full run on a clean tree is recorded"
printf 'notes\n' > "$R/README.md"; git -C "$R" add README.md; git -C "$R" commit -q -m docs
run bash "$S/run-checks.sh" --set all --since-green --json "$T_TMP/g.json"
t_code 0 "only docs changed since the green run"
t_eq "$(jq -r '[.[].name] | join(",")' "$T_TMP/g.json")" "unit" "only the fast set runs after a docs-only change"
t_has "$OUT" "reused the green full run" "says the full run was reused"
printf 'more\n' >> "$R/README.md"
run bash "$S/run-checks.sh" --set all --since-green --json "$T_TMP/g.json"
t_eq "$(jq -r '[.[].name] | join(",")' "$T_TMP/g.json")" "unit" "an uncommitted docs change is still docs-only"
t_eq "$(jq -r '.checks_green.commit' "$run_dir/state.json")" "$(git -C "$R" rev-parse HEAD~1)" "a reused or dirty run records nothing"
git -C "$R" checkout -q README.md
printf 'package x\n' > "$R/x.go"; git -C "$R" add x.go; git -C "$R" commit -q -m code
run bash "$S/run-checks.sh" --set all --since-green --json "$T_TMP/g.json"
t_eq "$(jq -r '[.[].name] | join(",")' "$T_TMP/g.json")" "unit,e2e" "a code change since the green run runs everything"
E2E_EXIT=1 run bash "$S/run-checks.sh" --set all --json "$T_TMP/g.json"
t_eq "$(jq -r '.checks_green' "$run_dir/state.json")" "null" "a failed full run forgets the green one"
run bash "$S/run-checks.sh" --set fast --since-green
t_code 2 "--since-green is for the full set only"

# --- an edit to run-checks.sh during a run doesn't break the run in flight
cp -R "$S" "$T_TMP/scripts"
R2="$(new_repo)"
write_config "$R2" "checks:
  fast:
    edit: \"printf 'garbage (\\\\n' > $T_TMP/scripts/run-checks.sh\""
FACTORY_ROOT="$R2" run bash "$T_TMP/scripts/run-checks.sh" --set fast
t_code 0 "the run finishes after its own script was rewritten under it"
t_has "$OUT" "run-checks: passed (edit)" "and reports its result"

t_done
