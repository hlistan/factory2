#!/usr/bin/env bash
# Regression tests for the bugs found in the M1 code review (one block per finding).
. "$(dirname "$0")/lib.sh"

# ------------------------------------------------ run-checks: multi-line commands and backslashes
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'checks:
  fast:
    multi: |
      echo one
      test 1 = 2
    bs: '"'"'test "$(printf %s "x\y" | wc -c | tr -d " ")" = 3'"'"''
run bash "$S/run-checks.sh" --set fast --live --only multi;  t_code 1 "a multi-line check runs line by line (its failing line fails it)"
run bash "$S/run-checks.sh" --set fast --live --only bs;     t_code 0 "a backslash reaches the command unchanged"

# ------------------------------------------------ test-guard: path resolution
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'checks:
  fast:
    ok: "true"'
mkdir -p "$R/tests" "$R/src" "$R/docs/specs/tg"
printf 'test("x @AC-1")\n' > "$R/tests/a.test.ts"
printf 'export default []\n' > "$R/eslint.config.js"
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`: needed rule change\n- `.factory/config.yaml`\n' > "$R/docs/specs/tg/plan.md"
git -C "$R" add -A && git -C "$R" commit -q -m fixture
bash "$S/state.sh" start tg >/dev/null
bash "$S/state.sh" freeze >/dev/null || t_fail "fixture freeze failed"
bash "$S/state.sh" phase code >/dev/null
ln -s a.test.ts "$R/tests/link.ts"
edit() { # <agent or ""> <path> [cwd]
  hook "$S/test-guard.sh" "$(jq -n --arg a "$1" --arg p "$2" --arg c "${3:-}" '{tool_name: "Write", tool_input: {file_path: $p}} + (if $a == "" then {} else {agent_type: $a} end) + (if $c == "" then {} else {cwd: $c} end)')"
}
I=factory:implementer
edit $I "$R/tests/a.test.ts";                              t_code 2 "frozen test blocked (baseline)"
edit $I "$R/nope/../tests/a.test.ts";                      t_code 2 ".. through a missing directory"
edit $I "tests/../tests/a.test.ts";                        t_code 2 "relative path with .."
edit $I "a.test.ts" "$R/tests";                            t_code 2 "relative path resolved from the input's cwd"
edit $I "$R/tests/link.ts";                                t_code 2 "a symlink to a frozen file"
if [ -e "$R/TESTS/A.TEST.TS" ]; then
  edit $I "$R/TESTS/A.TEST.TS";                            t_code 2 "another spelling on a case-insensitive filesystem"
  edit $I "$R/.CLAUDE/agent-memory/factory-x/MEMORY.md";   t_code 2 "memory path, other case"
fi
edit $I "$R/nope/../.claude/agent-memory/factory-x/MEMORY.md"; t_code 2 "memory path through .."
edit $I "$R/.claude/settings.json";                        t_code 2 "project settings are protected during a run"
edit factory:reviewer-spec "/tmp/factory-outside.txt";     t_code 2 "read-only role blocked outside the project too"
edit $I "$R/src/new.ts";                                   t_code 0 "implementer writes product code"
edit $I "$T_TMP/outside.txt";                              t_code 0 "outside the project is not test-guard's business"
L="$T_TMP/link-root"; ln -s "$R" "$L"
FACTORY_ROOT="$L" edit $I "$L/.claude/agent-memory/factory-new/MEMORY.md"; t_code 2 "symlinked root, memory dir that doesn't exist yet"
# plan Exceptions unlock a named check-defining file for the implementer only, never the config
edit $I "$R/eslint.config.js";                             t_code 0 "Exceptions-named check file: implementer may edit"
edit "" "$R/eslint.config.js";                             t_code 0 "and the main session"
edit factory:test-author "$R/eslint.config.js";            t_code 2 "but not the test-author"
edit $I "$R/.factory/config.yaml";                         t_code 2 ".factory/config.yaml stays frozen even when named"

# ------------------------------------------------ guards: broken config or missing tools fail closed
printf 'oops: [\n' >> "$R/.factory/config.yaml"
g() { hook "$S/guard-bash.sh" "$(jq -n --arg c "$1" --arg d "$R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"; }
g 'ls';                                                    t_code 1 "guard-bash: unparsable config is an error, not a pass"
run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' | bash '$S/gate.sh' closed 10 guard-bash.sh"
t_code 2 "and gate.sh turns it into a block"
t_has "$ERR" "doesn't parse" "naming the cause"
edit $I "$R/src/new.ts";                                   t_code 1 "test-guard: same during a run"
git -C "$R" checkout -q -- .factory/config.yaml

# ------------------------------------------------ subagent-stop: an unverifiable freeze blocks
bash "$S/state.sh" set '.frozen = true' >/dev/null
mv "$R/.factory/runs/tg/frozen.tsv" "$R/.factory/runs/tg/frozen.tsv.bak"
hook "$S/subagent-stop.sh" '{"hook_event_name":"SubagentStop","agent_type":"factory:implementer","agent_id":"s1"}'
t_code 2 "verify-freeze exit 2 (no frozen.tsv) blocks"
mv "$R/.factory/runs/tg/frozen.tsv.bak" "$R/.factory/runs/tg/frozen.tsv"

# ------------------------------------------------ timeout.py: an outer limit reaches the inner group
mark="factory-orphan-$$"
python3 -I "$S/lib/timeout.py" 1 python3 -I "$S/lib/timeout.py" 100 bash -c "exec -a $mark sleep 300" >/dev/null 2>&1
sleep 1
if pgrep -f "$mark" >/dev/null 2>&1; then t_fail "nested timeout left the inner command running"; pkill -f "$mark"; else t_ok; fi

# ------------------------------------------------ fold-memory: idempotent after archiving, verbatim lines
write_config "$R" 'learning:
  memory_max_lines: 8'
for i in 1 2 3 4 5 6 7; do bash "$S/state.sh" calibrate planner "lesson $i C:\temp \d+" >/dev/null; done
bash "$S/state.sh" fold-memory >/dev/null 2>&1
bash "$S/state.sh" fold-memory >/dev/null 2>&1
M="$R/.claude/agent-memory/factory-planner"
t_eq "$(cat "$M/MEMORY.md" "$M/archive.md" | grep -c 'lesson [0-9]')" "7" "each lesson once across MEMORY.md and archive.md after two folds"
t_has "$(cat "$M/MEMORY.md")" 'lesson 7 C:\temp \d+' "backslashes kept"
t_eq "$(wc -l < "$M/MEMORY.md" | tr -d ' ')" "8" "MEMORY.md at the cap"
git -C "$R" checkout -q -- .factory/config.yaml

# ------------------------------------------------ budget-check
write_config "$R" 'limits:
  budget_usd: 0.0'
run bash "$S/state.sh" budget-check;                       t_code 0 "0.0 means no limit"
write_config "$R" 'limits:
  budget_usd: "$20"'
run bash "$S/state.sh" budget-check;                       t_code 2 "a non-number is a config error, not an exceeded budget"
write_config "$R" 'limits:
  budget_usd: 20'
LC_ALL=de_DE.UTF-8 run bash "$S/state.sh" budget-check;   t_code 0 "within budget"
t_has "$OUT" '$0.00 of $20' "dot decimal under a comma locale"
git -C "$R" checkout -q -- .factory/config.yaml

# ------------------------------------------------ first freeze compares with the run's base
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'checks:
  fast:
    ok: "true"'
mkdir -p "$R/docs/specs/fb"
printf 'export default []\n' > "$R/eslint.config.js"
printf '{"name":"x","dependencies":{"a":"1"}}\n' > "$R/package.json"
printf '{"lockfileVersion": 3}\n' > "$R/package-lock.json"
printf 'x\n' > "$R/src.txt"
printf '# Plan\n\n## Exceptions\n' > "$R/docs/specs/fb/plan.md"
git -C "$R" add -A && git -C "$R" commit -q -m fixture
bash "$S/state.sh" start fb >/dev/null
printf 'export default [{rules: {}}]\n' > "$R/eslint.config.js"
git -C "$R" commit -qam "weaken lint"
run bash "$S/state.sh" freeze;                             t_code 1 "first freeze refuses a check file changed since the base"
t_has "$ERR" "eslint.config.js" "names it"
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`\n' > "$R/docs/specs/fb/plan.md"
run bash "$S/state.sh" freeze;                             t_code 0 "accepted once the plan's Exceptions name it"
# a path token doesn't unlock lockfiles; a dependency name does
printf '{"lockfileVersion": 3, "x": 1}\n' > "$R/package-lock.json"
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`\n- `src.txt`\n' > "$R/docs/specs/fb/plan.md"
run bash "$S/state.sh" verify-freeze;                      t_code 1 "a lockfile change with only path tokens in Exceptions"
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`\n- `left-pad`\n' > "$R/docs/specs/fb/plan.md"
run bash "$S/state.sh" verify-freeze;                      t_code 0 "allowed when a dependency is named"

# ------------------------------------------------ red-check --tests (stage 5 fix loop)
mkdir -p "$R/.factory/runs/fb/reports/unit"
cat > "$R/.factory/runs/fb/reports/unit/junit.xml" <<'EOF'
<testsuite><testcase classname="s" name="rejects empty title @AC-2"><failure>no</failure></testcase>
<testcase classname="s" name="old behaviour @AC-1"/></testsuite>
EOF
run bash "$S/state.sh" red-check --tests "rejects empty title @AC-2";  t_code 0 "a new failing test is red"
run bash "$S/state.sh" red-check --tests "old behaviour @AC-1";        t_code 1 "a passing one is flagged"
run bash "$S/state.sh" red-check --tests "never written";              t_code 1 "a missing one is flagged"

# ------------------------------------------------ the state lock: a dead owner's lock is stolen
f="$R/.factory/runs/fb/state.json"
mkdir "$f.lock"; sleep 0 & dead=$!; wait "$dead"; printf '%s\n' "$dead" > "$f.lock/pid"
t0="$(date +%s)"
run bash "$S/state.sh" set '.probe = 1';                   t_code 0 "update succeeds past a dead owner's lock"
[ $(( $(date +%s) - t0 )) -lt 5 ] && t_ok || t_fail "stealing a dead lock took too long"
t_eq "$(jq -r .probe "$f")" "1" "and is applied"
t_done
