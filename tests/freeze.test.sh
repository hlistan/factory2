#!/usr/bin/env bash
# The freeze: test-guard (PreToolUse), freeze.py through state.sh, the check snapshot in run-checks, and
# the SubagentStop gate.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"
export FACTORY_ROOT="$R"
mkdir -p "$R/src" "$R/tests/fixtures" "$R/docs/specs/demo"
cat > "$R/package.json" <<'EOF'
{ "name": "demo", "scripts": { "test": "node tests/run.js" }, "dependencies": { "left-pad": "1.0.0" } }
EOF
printf '{"lockfileVersion": 3}\n' > "$R/package-lock.json"
printf 'export default {}\n' > "$R/vitest.config.ts"
printf 'test("x @AC-1")\n' > "$R/tests/a.test.ts"
printf '{"user": "ann"}\n' > "$R/tests/fixtures/user.json"
printf 'export const a = 1\n' > "$R/src/a.ts"
write_config "$R" 'checks:
  fast:
    unit: "test -f src/ok"
  slow:
    e2e: "true"
  check_defining: [package.json, package-lock.json, "vitest.config.*", "vitest.workspace.*"]
  stop_retries: 2'
printf '# Plan\n\n## Steps\n- do it\n\n## Exceptions\n' > "$R/docs/specs/demo/plan.md"
git -C "$R" add -A && git -C "$R" commit -q -m fixture

edit() { # <agent_type or ""> <path>
  hook "$S/test-guard.sh" "$(jq -n --arg a "$1" --arg p "$2" '{tool_name: "Edit", tool_input: {file_path: $p}} + (if $a == "" then {} else {agent_type: $a} end)')"
}

# --- before any run
edit factory2:implementer "$R/tests/a.test.ts";            t_code 0 "no active run: edits pass"

bash "$S/state.sh" start demo >/dev/null
edit factory2:implementer "$R/.claude/agent-memory/factory-implementer/MEMORY.md"; t_code 2 "agent memory is harness-only"
edit "" "$R/.claude/agent-memory/factory-planner/MEMORY.md";                      t_code 2 "agent memory blocked for the main session too"
edit factory2:reviewer-correctness "$R/src/a.ts";         t_code 2 "read-only role can't edit"
edit factory2:implementer "$R/src/a.ts";                  t_code 0 "implementer edits product code"
edit factory2:implementer "$R/tests/a.test.ts";           t_code 0 "nothing frozen yet"

run bash "$S/state.sh" freeze
t_code 0 "freeze succeeds"
t_has "$OUT" "frozen" "freeze reports counts"
t_eq "$(awk -F '\t' '$4 == "tests/a.test.ts" {print $1}' "$R/.factory/runs/demo/frozen.tsv")" "tests" "test file is on the tests list"
t_eq "$(awk -F '\t' '$4 == "tests/fixtures/user.json" {print $1}' "$R/.factory/runs/demo/frozen.tsv")" "tests" "fixture is on the tests list"
t_eq "$(awk -F '\t' '$4 == "package.json" {print $1 "/" $2}' "$R/.factory/runs/demo/frozen.tsv")" "checks/npm" "package.json is check-defining, kind npm"
t_eq "$(awk -F '\t' '$4 == ".factory/config.yaml" {print $1}' "$R/.factory/runs/demo/frozen.tsv")" "checks" "config is always check-defining"
t_eq "$(jq -r '.fast.unit' "$R/.factory/runs/demo/checks.snapshot.json")" 'test -f src/ok' "check commands snapshotted"
t_eq "$(grep -c 'docs/specs/' "$R/.factory/runs/demo/frozen.tsv")" "0" "factory's own spec files are never frozen"

bash "$S/state.sh" phase code >/dev/null
edit factory2:implementer "$R/tests/a.test.ts";           t_code 2 "implementer can't edit a frozen test"
t_has "$ERR" "frozen test" "frozen-test message"
edit factory2:implementer "$R/tests/fixtures/user.json";  t_code 2 "implementer can't edit a frozen fixture"
edit factory2:implementer "$R/package.json";              t_code 2 "implementer can't edit package.json"
edit factory2:implementer "$R/.factory/config.yaml";      t_code 2 "implementer can't edit the config"
edit factory2:test-author "$R/tests/a.test.ts";           t_code 2 "test-author can't edit frozen tests outside the tests phase"
bash "$S/state.sh" phase tests >/dev/null
edit factory2:test-author "$R/tests/a.test.ts";           t_code 0 "test-author edits frozen tests in the tests phase"
edit factory2:test-author "$R/package.json";              t_code 2 "test-author still can't edit check-defining files"
bash "$S/state.sh" phase code >/dev/null

run bash "$S/state.sh" verify-freeze;                    t_code 0 "fresh freeze verifies"

# --- package.json: scripts are frozen, dependencies need a plan exception
jq '.scripts.test = "echo skip"' "$R/package.json" > "$R/p.tmp" && mv "$R/p.tmp" "$R/package.json"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "a changed npm script is caught (as a Bash edit would be)"
t_has "$OUT" "package.json: a check-defining file changed" "names package.json"
git -C "$R" checkout -q -- package.json
jq '.dependencies.zod = "3.0.0"' "$R/package.json" > "$R/p.tmp" && mv "$R/p.tmp" "$R/package.json"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "an unplanned dependency is caught"
t_has "$OUT" "zod" "names the dependency"
printf -- '- add `zod` for input validation\n' >> "$R/docs/specs/demo/plan.md"
printf '{"lockfileVersion": 3, "zod": true}\n' > "$R/package-lock.json"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "an Exception added after the freeze doesn't count yet"
run bash "$S/state.sh" freeze;                           t_code 1 "nor does a re-freeze accept a change made before its Exception was frozen"
cp -R "$R/.factory/runs/demo" "$T_TMP/demo-run.bak"   # the re-freeze below is undone afterwards
git -C "$R" checkout -q -- package.json package-lock.json
run bash "$S/state.sh" freeze;                           t_code 0 "the documented flow: the planner's Exception is frozen first"
jq '.dependencies.zod = "3.0.0"' "$R/package.json" > "$R/p.tmp" && mv "$R/p.tmp" "$R/package.json"
printf '{"lockfileVersion": 3, "zod": true}\n' > "$R/package-lock.json"
run bash "$S/state.sh" verify-freeze;                    t_code 0 "then the planned dependency and its lockfile pass"
git -C "$R" checkout -q -- package.json package-lock.json docs/specs/demo/plan.md
rm -rf "$R/.factory/runs/demo" && mv "$T_TMP/demo-run.bak" "$R/.factory/runs/demo"
printf '{"lockfileVersion": 3, "x": 1}\n' > "$R/package-lock.json"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "a lockfile change with no planned dependency is caught"
git -C "$R" checkout -q -- package-lock.json

# --- tests, new check files, the config
printf 'test("x @AC-1", () => {})\n' > "$R/tests/a.test.ts"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "a changed frozen test is caught"
git -C "$R" checkout -q -- tests/a.test.ts
printf 'export default []\n' > "$R/vitest.workspace.ts"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "a new check-defining file is caught"
t_has "$OUT" "new check-defining file" "names the new file"
rm "$R/vitest.workspace.ts"
printf 'test("new @AC-2")\n' > "$R/tests/b.test.ts"
run bash "$S/state.sh" verify-freeze;                    t_code 0 "a new test file is allowed"
rm "$R/tests/b.test.ts"
printf -- '- `.factory/config.yaml`\n' >> "$R/docs/specs/demo/plan.md"
printf 'checks:\n  fast:\n    unit: "true"\n' > "$R/.factory/config.yaml"
run bash "$S/state.sh" verify-freeze;                    t_code 1 "the config can't be excepted"

# --- run-checks reads the snapshot, not the live (weakened) config
run bash "$S/run-checks.sh" --set fast;                  t_code 1 "snapshot command still fails although the live config says true"
t_has "$OUT" "freeze snapshot" "names the snapshot as the source"

# --- re-freeze refuses while a check-defining file differs
run bash "$S/state.sh" freeze;                           t_code 1 "re-freeze refuses a changed check file"
git -C "$R" checkout -q -- .factory/config.yaml docs/specs/demo/plan.md
printf 'test("x @AC-1"); test("y @AC-2")\n' > "$R/tests/a.test.ts"
run bash "$S/state.sh" freeze;                           t_code 0 "re-freeze accepts reviewed test changes"
run bash "$S/state.sh" verify-freeze;                    t_code 0 "and verifies afterwards"
git -C "$R" add -A && git -C "$R" commit -q -m "tests reviewed"
bash "$S/state.sh" freeze >/dev/null

# --- SubagentStop
stop() { hook "$S/subagent-stop.sh" "$(jq -n --arg a "$1" --arg id "$2" '{hook_event_name: "SubagentStop", agent_type: $a, agent_id: $id}')"; }
stop factory2:reviewer-spec a1;                           t_code 0 "other agents pass"
stop "" a1;                                              t_code 0 "empty agent_type passes"
stop factory2:implementer i1;                             t_code 2 "failing fast check blocks"
t_has "$ERR" "block 1 of 2" "counts blocks"
t_has "$ERR" "FAIL unit" "includes the failing output"
stop factory2:implementer i1;                             t_code 2 "blocks again"
stop factory2:implementer i1;                             t_code 0 "lets go after stop_retries"
touch "$R/src/ok"
stop factory2:implementer i2;                             t_code 0 "passing checks let the implementer stop"
jq '.scripts.test = "true"' "$R/package.json" > "$R/p.tmp" && mv "$R/p.tmp" "$R/package.json"
stop factory2:implementer i3;                             t_code 2 "a frozen-file change blocks before the checks run"
t_has "$ERR" "Frozen files changed" "freeze message"
t_has "$ERR" "package.json" "names the file"
git -C "$R" checkout -q -- package.json
rm "$R/src/ok"
printf 'unit\n' > "$R/.factory/runs/demo/baseline-failures"
stop factory2:implementer i4;                             t_code 0 "a check already failing at the baseline doesn't block"
# the gate's own time limit: a hung check is killed and the stop let through (and recorded), because
# Claude Code would cancel the hook at its timeout and let the agent stop unchecked anyway
snap="$R/.factory/runs/demo/checks.snapshot.json"; cp "$snap" "$snap.bak"
jq '.fast = {hang: "sleep 30; echo still-here > hung.txt"}' "$snap.bak" > "$snap"
t0="$(date +%s)"
FACTORY_GATE_BUDGET=2 stop factory2:implementer i5;       t_code 0 "a check over the gate's time limit lets the stop through"
[ $(( $(date +%s) - t0 )) -lt 12 ] && t_ok || t_fail "the gate didn't stop at its time limit"
t_has "$ERR" "longer than 2s" "says the checks timed out"
t_has "$(cat "$R/.factory/runs/demo/stop-gate.log")" "timeout after 2s" "the timeout is in stop-gate.log"
t_eq "$(jq -r '.gate_timeouts' "$R/.factory/runs/demo/state.json")" "1" "and counted in state"
sleep 1; [ ! -f "$R/hung.txt" ] && t_ok || t_fail "the hung check's process group survived the gate"
mv "$snap.bak" "$snap"
t_done
