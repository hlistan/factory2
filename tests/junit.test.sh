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
