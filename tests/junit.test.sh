#!/usr/bin/env bash
# contract-sync and the red check: JUnit XML from Playwright, Vitest, Go (gotestsum) and Swift mapped to
# acceptance criteria. The harness sets `passes`; agents never do.
. "$(dirname "$0")/lib.sh"
J="$S/lib/junit.py"
c="$T_TMP/contract.json"
cp "$FIX/junit/contract.json" "$c"

run python3 -I "$J" sync "$c" "$FIX/junit/mixed"
t_code 1 "sync exits 1 while any criterion fails"
p() { jq -r --arg id "$1" '.criteria[] | select(.id == $id) | .passes' "$c"; }
n() { jq -r --arg id "$1" '.criteria[] | select(.id == $id) | .test_ids | length' "$c"; }
t_eq "$(p AC-1)" "true" "AC-1: Playwright and Vitest tests both pass"
t_eq "$(n AC-1)" "2" "AC-1 has two tests (not AC-10's)"
t_eq "$(p AC-2)" "false" "AC-2: a skipped test is not a pass"
t_eq "$(n AC-2)" "2" "AC-2 counts the Go TestAC_2_ function name"
t_eq "$(p AC-3)" "false" "AC-3: a suffixed tag names nothing"
t_eq "$(n AC-3)" "0" "AC-3 has no tests"
t_eq "$(p AC-4)" "false" "AC-4: Swift test_AC_4_ failure"
t_eq "$(n AC-4)" "1" "AC-4 counts the Swift function name"
t_eq "$(p AC-10)" "false" "AC-10 fails on its own test"
t_eq "$(p AC-11)" "false" "AC-11 with no tests is false"
t_has "$OUT" "AC-11	FAIL	no test names it" "reports the untested criterion"

run python3 -I "$J" lint "$FIX/junit/mixed"
t_code 1 "lint flags a suffixed tag"
t_has "$OUT" "@AC-3-extra" "names the suffixed test"

mkdir -p "$T_TMP/pass/u"
cat > "$T_TMP/pass/u/x.xml" <<'EOF'
<testsuite><testcase classname="a" name="one @AC-1"/><testcase classname="a" name="two (AC-2)"/></testsuite>
EOF
printf '{"criteria":[{"id":"AC-1","text":"a","test_ids":[],"passes":false},{"id":"AC-2","text":"b","test_ids":[],"passes":false}]}' > "$c"
run python3 -I "$J" sync "$c" "$T_TMP/pass"
t_code 0 "sync exits 0 when every criterion passes"

# The same Go test in two reports: skipped by the unit run (no database), passed by the integration run.
mkdir -p "$T_TMP/twice/unit-go" "$T_TMP/twice/integration"
cat > "$T_TMP/twice/unit-go/unit-go.xml" <<'EOF'
<testsuite><testcase classname="m/api" name="TestAC_1_Reads"><skipped message="needs INTEGRATION=1"/></testcase><testcase classname="m/api" name="TestAC_2_Writes"><skipped/></testcase><testcase classname="m/api" name="TestAC_3_Lists"/></testsuite>
EOF
cat > "$T_TMP/twice/integration/integration.xml" <<'EOF'
<testsuite><testcase classname="m/api" name="TestAC_1_Reads"/><testcase classname="m/api" name="TestAC_3_Lists"><failure message="boom"/></testcase></testsuite>
EOF
printf '{"criteria":[{"id":"AC-1","text":"a","test_ids":[],"passes":false},{"id":"AC-2","text":"b","test_ids":[],"passes":false},{"id":"AC-3","text":"c","test_ids":[],"passes":false}]}' > "$c"
run python3 -I "$J" sync "$c" "$T_TMP/twice"
t_code 1 "sync exits 1 while AC-2 and AC-3 fail"
t_eq "$(p AC-1)" "true" "AC-1: skipped by one report, passed by another, passes"
t_eq "$(n AC-1)" "1" "AC-1 counts the test once"
t_eq "$(p AC-2)" "false" "AC-2: skipped in every report is not a pass"
t_eq "$(p AC-3)" "false" "AC-3: passed by one report, failed by another, fails"

# red-tests (stage 5): a skip neither passes nor proves red.
cat > "$T_TMP/twice/integration/integration.xml" <<'EOF'
<testsuite><testcase classname="m/api" name="TestAC_1_Reads"><failure message="404"/></testcase><testcase classname="m/api" name="TestAC_3_Lists"/></testsuite>
EOF
run python3 -I "$J" red-tests "$T_TMP/twice" TestAC_1_Reads
t_code 0 "red-tests: skipped by the unit run, failed by the integration run, is red"
t_has "$OUT" "TestAC_1_Reads	RED" "names the red test"
run python3 -I "$J" red-tests "$T_TMP/twice" TestAC_2_Writes
t_code 1 "red-tests: a test every run skipped is flagged"
t_has "$OUT" "TestAC_2_Writes	NOT-RUN" "says it never ran"
run python3 -I "$J" red-tests "$T_TMP/twice" TestAC_3_Lists
t_code 1 "red-tests: a test that passed anywhere is flagged"
t_has "$OUT" "TestAC_3_Lists	PASSES-EARLY" "says it passes early"
run python3 -I "$J" red-tests "$T_TMP/twice" TestAC_9_Nothing
t_code 1 "red-tests: an unknown test is flagged"
t_has "$OUT" "TestAC_9_Nothing	NOT-VISIBLE" "says it is not visible"

cp "$FIX/junit/contract.json" "$c"
run python3 -I "$J" red "$c" "$FIX/junit/red"
t_code 1 "red check flags problems"
t_has "$OUT" "AC-2	PASSES-EARLY" "flags a test passing before the code exists"
t_has "$OUT" "AC-11	NOT-VISIBLE" "flags a criterion with no visible test"
t_hasnt "$OUT" "AC-1	" "a correctly failing test isn't flagged"

printf '{"criteria":[{"id":"criterion one"}]}' > "$c"
run python3 -I "$J" sync "$c" "$FIX/junit/mixed"
t_code 2 "rejects ids that aren't AC-<n>"
t_done
