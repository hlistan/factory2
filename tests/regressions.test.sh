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
run bash "$S/run-checks.sh" --set fast --live --json "$T_TMP/rc.json"
t_eq "$(jq -r 'map(.name + ":" + (.exit|tostring)) | join(",")' "$T_TMP/rc.json")" "multi:1,bs:0" "--json survives multi-line commands"
# memory-inject: the injected text has no command substitution
mkdir -p "$R/.claude/agent-memory/factory-planner"; printf -- '- x\n' > "$R/.claude/agent-memory/factory-planner/MEMORY.md"
hook "$S/memory-inject.sh" '{"agent_type":"factory2:planner"}'
t_has "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" 'report'"'"'s `lessons` list' "memory-inject text is literal"
t_eq "$ERR" "" "and runs nothing"

# ------------------------------------------------ test-guard: path resolution
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'ship:
  deploy: "make deploy-prod"
checks:
  fast:
    ok: "true"'
mkdir -p "$R/tests" "$R/src" "$R/docs/specs/tg"
printf 'test("x @AC-1")\n' > "$R/tests/a.test.ts"
printf 'export default []\n' > "$R/eslint.config.js"
printf 'export default {}\n' > "$R/vitest.config.ts"
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`: needed rule change\n- `.factory/config.yaml`\n' > "$R/docs/specs/tg/plan.md"
git -C "$R" add -A && git -C "$R" commit -q -m fixture
bash "$S/state.sh" start tg >/dev/null
bash "$S/state.sh" freeze >/dev/null || t_fail "fixture freeze failed"
bash "$S/state.sh" phase code >/dev/null
ln -s a.test.ts "$R/tests/link.ts"
edit() { # <agent or ""> <path> [cwd]
  hook "$S/test-guard.sh" "$(jq -n --arg a "$1" --arg p "$2" --arg c "${3:-}" '{tool_name: "Write", tool_input: {file_path: $p}} + (if $a == "" then {} else {agent_type: $a} end) + (if $c == "" then {} else {cwd: $c} end)')"
}
I=factory2:implementer
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
edit factory2:reviewer-spec "/tmp/factory-outside.txt";     t_code 2 "read-only role blocked outside the project too"
edit $I "$R/src/new.ts";                                   t_code 0 "implementer writes product code"
edit $I "$T_TMP/outside.txt";                              t_code 0 "outside the project is not test-guard's business"
L="$T_TMP/link-root"; ln -s "$R" "$L"
FACTORY_ROOT="$L" edit $I "$L/.claude/agent-memory/factory-new/MEMORY.md"; t_code 2 "symlinked root, memory dir that doesn't exist yet"
# plan Exceptions unlock a named check-defining file for the implementer only, never the config
edit $I "$R/eslint.config.js";                             t_code 0 "Exceptions-named check file: implementer may edit"
edit "" "$R/eslint.config.js";                             t_code 0 "and the main session"
edit factory2:test-author "$R/eslint.config.js";            t_code 2 "but not the test-author"
edit $I "$R/.factory/config.yaml";                         t_code 2 ".factory/config.yaml stays frozen even when named"
# the Exceptions are the ones reviewed at the freeze, and agents can't rewrite the spec or run state
edit $I "$R/docs/specs/tg/plan.md";                        t_code 2 "the implementer can't edit plan.md"
edit factory2:test-author "$R/docs/specs/tg/contract.json"; t_code 2 "nor can the test-author edit contract.json"
edit factory2:planner "$R/docs/specs/tg/plan.md";           t_code 0 "the planner can"
printf -- '- `vitest.config.ts`\n' >> "$R/docs/specs/tg/plan.md"
edit $I "$R/vitest.config.ts";                             t_code 2 "an Exception added after the freeze doesn't unlock the file"
printf 'export default {weak: 1}\n' > "$R/vitest.config.ts"
run bash "$S/state.sh" verify-freeze;                      t_code 1 "and verify-freeze reads the frozen plan, not the live one"
# re-freeze judges changes by the frozen Exceptions too, and the snapshot is hash-checked
printf -- '- `vitest.config.ts`\n' >> "$R/docs/specs/tg/plan.md"
run bash "$S/state.sh" freeze;                             t_code 1 "re-freeze doesn't accept a change the live plan self-grants"
git -C "$R" checkout -q -- vitest.config.ts
cp "$R/.factory/runs/tg/plan.frozen.md" "$T_TMP/pf.bak"; rm "$R/.factory/runs/tg/plan.frozen.md"
run bash "$S/state.sh" verify-freeze;                      t_code 2 "a deleted snapshot is an error, not a fallback to the live plan"
printf -- '- `vitest.config.ts`\n' > "$R/.factory/runs/tg/plan.frozen.md"
run bash "$S/state.sh" verify-freeze;                      t_code 2 "a rewritten snapshot is an error"
run bash "$S/state.sh" freeze;                             t_code 2 "and re-freeze refuses it too"
cp "$T_TMP/pf.bak" "$R/.factory/runs/tg/plan.frozen.md"
run bash "$S/state.sh" freeze;                             t_code 0 "the documented flow: a new Exception with nothing changed yet re-freezes"
t_has "$OUT" "Exceptions recorded since the last freeze: vitest.config.ts" "and names the new Exception for the orchestrator"
git -C "$R" checkout -q -- docs/specs/tg/plan.md
bash "$S/state.sh" freeze >/dev/null
edit $I "$R/.factory/runs/tg/state.json";                  t_code 2 "agents can't write run state"
edit factory2:planner "$R/.factory/history/tg.json";        t_code 2 "or history"

# ------------------------------------------------ guards: broken config or missing tools fail closed
printf 'oops: [\n' >> "$R/.factory/config.yaml"
g() { hook "$S/guard-bash.sh" "$(jq -n --arg c "$1" --arg d "$R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"; }
g 'ls';                                                    t_code 0 "guard-bash: a broken config doesn't block every command"
t_has "$ERR" "last version that did" "it falls back to the last config that parsed"
g 'git push --force origin main';                         t_code 2 "built-in guards still apply"
g 'make deploy-prod';                                     t_code 2 "and the deploy guard keeps the last good ship.deploy"
edit "" "$R/src/new.ts";                                   t_code 0 "test-guard doesn't need the config: fixing it isn't blocked"
git -C "$R" checkout -q -- .factory/config.yaml

# ------------------------------------------------ subagent-stop: an unverifiable freeze blocks
bash "$S/state.sh" set '.frozen = true' >/dev/null
mv "$R/.factory/runs/tg/frozen.tsv" "$R/.factory/runs/tg/frozen.tsv.bak"
hook "$S/subagent-stop.sh" '{"hook_event_name":"SubagentStop","agent_type":"factory2:implementer","agent_id":"s1"}'
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
  budget_usd: -1'
run bash "$S/state.sh" budget-check;                       t_code 0 "a negative limit means no limit"
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
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`\n- `src.txt`\n' > "$R/docs/specs/fb/plan.md"
run bash "$S/state.sh" freeze;                             t_code 0 "re-freeze with a path-only Exception"
printf '{"lockfileVersion": 3, "x": 1}\n' > "$R/package-lock.json"
run bash "$S/state.sh" verify-freeze;                      t_code 1 "a lockfile change with only path tokens in Exceptions"
git -C "$R" checkout -q -- package-lock.json
printf '# Plan\n\n## Exceptions\n- `eslint.config.js`\n- `left-pad`\n' > "$R/docs/specs/fb/plan.md"
run bash "$S/state.sh" freeze;                             t_code 0 "re-freeze with a dependency Exception"
printf '{"lockfileVersion": 3, "x": 1}\n' > "$R/package-lock.json"
run bash "$S/state.sh" verify-freeze;                      t_code 0 "allowed when a dependency is named"

# ------------------------------------------------ red-check --tests (stage 5 fix loop)
mkdir -p "$R/.factory/runs/fb/reports/unit"
cat > "$R/.factory/runs/fb/reports/unit/junit.xml" <<'EOF'
<testsuite><testcase classname="s" name="rejects empty title @AC-2"><failure>no</failure></testcase>
<testcase classname="s" name="old behaviour @AC-1"/></testsuite>
EOF
run bash "$S/state.sh" red-check --test "rejects empty title @AC-2";  t_code 0 "a new failing test is red"
run bash "$S/state.sh" red-check --test "old behaviour @AC-1";        t_code 1 "a passing one is flagged"
run bash "$S/state.sh" red-check --test "never written";              t_code 1 "a missing one is flagged"
printf '%s\n' '<testsuite><testcase classname="s" name="returns 400, not 500"><failure>no</failure></testcase>' \
  '<testcase classname="s" name="returns 400 for a bad id"/><testcase classname="s" name="not 500 ever"/></testsuite>' \
  > "$R/.factory/runs/fb/reports/unit/junit.xml"
run bash "$S/state.sh" red-check --test "returns 400, not 500";       t_code 0 "a name with a comma is one name"
run bash "$S/state.sh" red-check --test "returns 400";                t_code 1 "an ambiguous partial name matches nothing"
t_has "$OUT" "AMBIGUOUS" "and says it is ambiguous"
run bash "$S/state.sh" red-check --tests "x";                         t_code 2 "an unknown flag is a usage error, not the stage 4 check"

# ------------------------------------------------ first freeze in a project below the git top level
M="$(new_repo)"
printf '{"name":"top"}\n' > "$M/package.json"
mkdir -p "$M/app/docs/specs/mono"
printf '{"name":"app"}\n' > "$M/app/package.json"
write_config "$M/app" 'checks:
  fast:
    ok: "true"'
printf '# Plan\n' > "$M/app/docs/specs/mono/plan.md"
git -C "$M" add -A && git -C "$M" commit -q -m mono
FACTORY_ROOT="$M/app" bash "$S/state.sh" start mono >/dev/null
FACTORY_ROOT="$M/app" run bash "$S/state.sh" freeze;      t_code 0 "an unchanged subdirectory project freezes"

# ------------------------------------------------ state.sh branch records the base after switching
B="$(new_repo)"
write_config "$B" 'checks:
  fast:
    ok: "true"'
git -C "$B" add -A && git -C "$B" commit -q -m config
git -C "$B" switch -q -c old && git -C "$B" switch -q main
printf 'x\n' > "$B/new.txt" && git -C "$B" add -A && git -C "$B" commit -q -m upstream
git -C "$B" switch -q old
FACTORY_ROOT="$B" bash "$S/state.sh" start br >/dev/null
git -C "$B" switch -q main
FACTORY_ROOT="$B" run bash "$S/state.sh" branch;          t_code 0 "branch creates factory/br"
t_eq "$(git -C "$B" branch --show-current)" "factory/br" "and switches to it"
t_eq "$(jq -r .base "$B/.factory/runs/br/state.json")" "$(git -C "$B" rev-parse main)" "base is where the branch starts, not where start ran"
printf 'dirty\n' >> "$B/new.txt"
FACTORY_ROOT="$B" run bash "$S/state.sh" branch;          t_code 1 "refuses with uncommitted changes"
git -C "$B" checkout -q -- new.txt
first="$(jq -r .base "$B/.factory/runs/br/state.json")"
printf 'y\n' > "$B/more.txt" && git -C "$B" add -A && git -C "$B" commit -q -m "on the branch"
FACTORY_ROOT="$B" run bash "$S/state.sh" branch;          t_code 0 "branch again (resume)"
t_eq "$(jq -r .base "$B/.factory/runs/br/state.json")" "$first" "the base doesn't move on resume"

# ------------------------------------------------ the state lock: a dead owner's lock is stolen
f="$R/.factory/runs/fb/state.json"
mkdir "$f.lock"; sleep 0 & dead=$!; wait "$dead"; printf '%s\n' "$dead" > "$f.lock/pid"
t0="$(date +%s)"
run bash "$S/state.sh" set '.probe = 1';                   t_code 0 "update succeeds past a dead owner's lock"
[ $(( $(date +%s) - t0 )) -lt 5 ] && t_ok || t_fail "stealing a dead lock took too long"
t_eq "$(jq -r .probe "$f")" "1" "and is applied"
t_done
