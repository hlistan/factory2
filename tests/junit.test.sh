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

# --base: an AC-tagged test already in the base commit is an earlier feature's (same AC numbers) and
# decides nothing; this run's own tests, and an old test the run retagged, do.
g="$T_TMP/repo"; mkdir -p "$g/web" "$g/api"
git -C "$g" init -q
printf 'func TestAC_1_FunnelIsTheViewsRow(t *testing.T) {}\n' > "$g/api/wizard_test.go"
printf 'test("are Funnel and Feedback under a Wizard group @AC-2", () => {});\ntest("keeps focus @AC-3", () => {});\n' > "$g/web/nav.test.ts"
git -C "$g" add -A && git -C "$g" -c user.email=t@t -c user.name=t commit -q -m base
base="$(git -C "$g" rev-parse HEAD)"
mkdir -p "$T_TMP/scoped/go" "$T_TMP/scoped/web"
cat > "$T_TMP/scoped/go/integration.xml" <<'X'
<testsuite><testcase classname="m/api" name="TestAC_1_FunnelIsTheViewsRow"/><testcase classname="m/api" name="TestAC_1_FunnelIsTheViewsRow/sub"/><testcase classname="m/api" name="TestAC_1_IssuesIsTheOneTable"><failure message="no table"/></testcase></testsuite>
X
cat > "$T_TMP/scoped/web/unit.xml" <<'X'
<testsuite><testcase classname="nav.test.ts" name="the Wizard pages &gt; are Funnel and Feedback under a Wizard group @AC-2"/><testcase classname="inbox.spec.ts" name="on a wide screen › keeps focus @AC-3 @AC-4"/></testsuite>
X
printf '{"criteria":[{"id":"AC-1","text":"a","test_ids":[],"passes":false},{"id":"AC-2","text":"b","test_ids":[],"passes":false},{"id":"AC-4","text":"d","test_ids":[],"passes":false}]}' > "$c"
run python3 -I "$J" red "$c" "$T_TMP/scoped"
t_has "$OUT" "AC-2	PASSES-EARLY" "without --base an old test passes early"
run python3 -I "$J" red "$c" "$T_TMP/scoped" --base "$base" --root "$g"
t_code 1 "red with --base still flags AC-2, which has only an old test"
t_hasnt "$OUT" "AC-2	PASSES-EARLY" "an old test is not a pass before the code exists"
t_has "$OUT" "AC-2	NOT-VISIBLE" "AC-2 has no test of this run"
t_has "$OUT" "AC-1	PRE-EXISTING	m/api::TestAC_1_FunnelIsTheViewsRow existed" "names the old Go test"
t_has "$OUT" "m/api::TestAC_1_FunnelIsTheViewsRow/sub existed" "an old test's subtest is old too"
t_has "$OUT" "AC-2	PRE-EXISTING	nav.test.ts::the Wizard pages > are Funnel" "names the old Vitest test"
t_hasnt "$OUT" "AC-4	NOT-VISIBLE" "a test whose tagged title is new counts (its title changed)"
run python3 -I "$J" sync "$c" "$T_TMP/scoped" --base "$base" --root "$g"
t_eq "$(p AC-1)" "false" "AC-1 is decided by its own failing test, not the old passing one"
t_eq "$(jq -r '.criteria[0].test_ids | join(",")' "$c")" "m/api::TestAC_1_IssuesIsTheOneTable" "AC-1's test_ids are this run's only"
t_eq "$(p AC-2)" "false" "AC-2 with only an old test does not pass"
t_eq "$(p AC-4)" "true" "AC-4 passes on this run's test"
run python3 -I "$J" sync "$c" "$T_TMP/scoped" --base "$base"
t_code 2 "--base without --root is refused"

printf '{"criteria":[{"id":"criterion one"}]}' > "$c"
run python3 -I "$J" sync "$c" "$FIX/junit/mixed"
t_code 2 "rejects ids that aren't AC-<n>"

# A shorter report written over a longer one through a file share that kept the old tail (seen with a
# Vitest report on a Docker Desktop bind mount): the complete document is read, the tail ignored, with a
# warning. Other damage still skips the file.
mkdir -p "$T_TMP/tail"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8" ?>' \
  '<testsuites><testsuite name="s"><testcase classname="a.test.ts" name="nav @AC-1"></testcase>' \
  '</testsuite>' '</testsuites>' 'testcase>' '    </testsuite>' '</testsuites>' > "$T_TMP/tail/unit-web.xml"
printf '<testsuites><testsuite><testcase name="cut @AC-2"' > "$T_TMP/tail/cut.xml"
printf '{"criteria":[{"id":"AC-1","text":"x","test_ids":[],"passes":false},{"id":"AC-2","text":"y","test_ids":[],"passes":false}]}' > "$c"
run python3 -I "$J" sync "$c" "$T_TMP/tail"
t_eq "$(p AC-1)" "true" "a complete report with the old file's tail after it is read"
t_has "$ERR" "read the document, ignored the rest" "and says so"
t_eq "$(p AC-2)" "false" "a cut-off report is still skipped"
t_has "$ERR" "cut.xml: not valid XML" "and named"
t_done
