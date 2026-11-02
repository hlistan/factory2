#!/usr/bin/env bash
# gate.sh: a gate hook's crash or hang becomes a decision (block in a factory project, or record) instead
# of Claude Code's default of letting the action through.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
write_config "$R" 'project:
  default_branch: main'
F="$T_TMP/fake"; mkdir -p "$F"
printf 'cat >/dev/null; echo boom >&2; exit 1\n' > "$F/crash.sh"
printf 'cat >/dev/null; sleep 30; exit 0\n' > "$F/hang.sh"
printf 'cat >/dev/null; echo "no way" >&2; exit 2\n' > "$F/deny.sh"
# shellcheck disable=SC2034  # CODE, OUT and ERR are read by lib.sh assertions
g() { local o e; o="$T_TMP/.o"; e="$T_TMP/.e"
  printf '%s' "$(jq -n --arg c "${4:-ls}" --arg d "$R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')" | bash "$S/gate.sh" "$1" "$2" "$3" > "$o" 2> "$e"
  CODE=$?; OUT="$(cat "$o")"; ERR="$(cat "$e")"; }

g closed 20 guard-bash.sh "ls -la";                     t_code 0 "real guard: allowed command passes"
g closed 20 guard-bash.sh "git push --force origin main"; t_code 2 "real guard: its block passes through"
t_has "$ERR" "force" "with its message"
g closed 5 "$F/deny.sh";                                t_code 2 "exit 2 passes through"
t_has "$ERR" "no way" "with the script's stderr"
g closed 5 "$F/crash.sh";                               t_code 2 "a crash blocks inside a factory project"
t_has "$ERR" "exit 1" "says it failed"
t_has "$ERR" "boom" "with the script's stderr"
t0="$(date +%s)"
g closed 1 "$F/hang.sh";                                t_code 2 "a hang blocks at the limit"
[ $(( $(date +%s) - t0 )) -lt 8 ] && t_ok || t_fail "the hang wasn't cut at its limit"
t_has "$ERR" "no decision within 1s" "says it timed out"
R2="$(new_repo)"
FACTORY_ROOT="$R2" g closed 5 "$F/crash.sh";            t_code 0 "outside a factory project a broken guard allows"
FACTORY_ROOT="$R2" g closed 1 "$F/hang.sh";             t_code 0 "and so does a hung one"
g record 5 "$F/crash.sh";                               t_code 0 "record: no active run, allowed"
bash "$S/state.sh" start gt >/dev/null
g record 5 "$F/crash.sh";                               t_code 0 "record: allowed"
t_has "$(cat "$R/.factory/runs/gt/gate-errors.log")" "crash" "record: logged"
t_eq "$(jq -r .gate_errors "$R/.factory/runs/gt/state.json")" "1" "record: counted"
g record 5 "$F/deny.sh";                                t_code 2 "record: a deliberate block still blocks"
g bogus 5 "$F/crash.sh";                                t_code 2 "unknown mode is a usage error"
t_done
