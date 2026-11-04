#!/usr/bin/env bash
# ship.sh: verify accepts only what the evidence approval covers (a clean main merge, the bookkeeping
# commit) and green checks; merge, deploy, smoke, rollback and mark. origin is a bare repository; ship.merge
# is a push to main standing in for gh pr merge.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
BARE="$T_TMP/origin.git"; git init -q --bare "$BARE"; git -C "$R" remote add origin "$BARE"
LOG="$T_TMP/log"; mkdir -p "$LOG"
cfg_base="review: {via: terminal}
checks:
  fast:
    ok: \"test ! -f FAILCHECK\"
monitor:
  checks:
    - {name: health, cmd: \"true\"}
    - {name: queue, cmd: \"false\"}
ship:
  merge: \"git push -q origin HEAD:main\""
write_config "$R" "$cfg_base"
printf 'a\n' > "$R/app.txt"; git -C "$R" add -A && git -C "$R" commit -q -m app && git -C "$R" push -q origin main
X="$PLUGIN/scripts/ship.sh"
bash "$S/state.sh" start shipit >/dev/null
bash "$S/state.sh" branch >/dev/null
printf 'feature\n' > "$R/feature.txt"; git -C "$R" add -A && git -C "$R" commit -q -m feature
git -C "$R" push -q origin factory/shipit

bash "$S/state.sh" stage 6 >/dev/null
run bash "$X" verify;                            t_code 1 "verify outside stage 7"
bash "$S/state.sh" stage 7 >/dev/null
run bash "$X" verify;                            t_code 1 "verify without the evidence approval"
t_has "$ERR" "no evidence approval" "says why"
bash "$S/state.sh" approve evidence >/dev/null
EV="$(git -C "$R" rev-parse HEAD)"
run bash "$X" verify;                            t_code 0 "nothing after the approval"

# a clean merge of origin/main is covered
W="$T_TMP/other"; git clone -q "$BARE" "$W"; git -C "$W" config user.email t@e.st; git -C "$W" config user.name t
printf 'main work\n' > "$W/other.txt"; git -C "$W" add -A && git -C "$W" commit -q -m "main moves" && git -C "$W" push -q origin main
git -C "$R" fetch -q origin && git -C "$R" merge -q --no-edit origin/main
run bash "$X" verify;                            t_code 0 "a clean merge of main"
t_has "$OUT" "covered" "reports the commits covered"

# the bookkeeping commit: calibration lines folded into memory, and the run's history
bash "$S/state.sh" calibrate prd-reviewer "2026-11-03 shipit: check every list view for an empty state" >/dev/null
bash "$S/state.sh" fold-memory >/dev/null 2>&1
mkdir -p "$R/docs/solutions/logic-errors"; printf -- '---\ntitle: lesson\n---\n' > "$R/docs/solutions/logic-errors/lesson.md"
git -C "$R" add -A .claude .factory/history docs/solutions && git -C "$R" commit -q -m "factory(shipit): fold memory"
run bash "$X" verify;                            t_code 0 "the memory fold and history commit"

# anything else after the approval is refused
git -C "$R" branch -q keep
printf -- '- 2026-11-03 shipit: a lesson nobody recorded\n' >> "$R/.claude/agent-memory/factory-prd-reviewer/MEMORY.md"
git -C "$R" commit -q -am "sneaky memory"
run bash "$X" verify;                            t_code 1 "a memory line that isn't a calibration line"
t_has "$ERR" "isn't one of the run's calibration lines" "names the problem"
git -C "$R" reset -q --hard keep
printf 'b\n' >> "$R/app.txt"; git -C "$R" commit -q -am "late product change"
run bash "$X" verify;                            t_code 1 "a product commit after the approval"
t_has "$ERR" "late product change: touches app.txt" "names the commit and file"
t_has "$ERR" "back to stage 6" "sends the run back"
git -C "$R" reset -q --hard keep
printf 'm2\n' > "$W/m2.txt"; git -C "$W" add -A && git -C "$W" commit -q -m "main again" && git -C "$W" push -q origin main
git -C "$R" fetch -q origin && git -C "$R" merge -q --no-commit origin/main && printf 'edited during merge\n' > "$R/m2.txt" && git -C "$R" add -A && git -C "$R" commit -q -m "merge main (edited)"
run bash "$X" verify;                            t_code 1 "a merge with edits"
t_has "$ERR" "not a conflict-free, unmodified merge" "says why"
git -C "$R" reset -q --hard keep
touch "$R/FAILCHECK"
run bash "$X" verify;                            t_code 1 "failing checks"
rm -f "$R/FAILCHECK"
git -C "$R" fetch -q origin && git -C "$R" merge -q --no-edit origin/main   # main moved again: merge it cleanly

# merge
run bash "$X" merge;                             t_code 1 "merge before verify on this HEAD"
run bash "$X" verify;                            t_code 0 "verify again"
run bash "$X" merge;                             t_code 1 "merge before the branch is pushed"
t_has "$ERR" "push factory/shipit first" "says to push"
git -C "$R" push -q origin factory/shipit
run bash "$X" deploy;                            t_code 1 "deploy before merge"
run bash "$X" merge;                             t_code 0 "merge"
t_eq "$(bash "$S/state.sh" get .ship.merged.sha)" "$(git -C "$BARE" rev-parse main)" "merged commit recorded from origin"

# deploy, smoke
run bash "$X" deploy;                            t_code 0 "empty ship.deploy is skipped"
t_eq "$(bash "$S/state.sh" get .ship.deployed.skipped)" "true" "and recorded as skipped"
write_config "$R" "$cfg_base
  deploy: \"echo \$FACTORY_DEPLOY_SHA > $LOG/deployed\"
  smoke: \"exit 1\"
  rollback: \"echo rolled > $LOG/rolled\""
run bash "$X" deploy;                            t_code 0 "deploy"
t_eq "$(cat "$LOG/deployed")" "$(git -C "$BARE" rev-parse main)" "deploy gets the merged commit"
run bash "$X" smoke;                             t_code 1 "failing smoke test"
t_has "$ERR" "monitor.sh issue --source smoke" "says to file the issue first"
t_eq "$(bash "$S/state.sh" get .ship.smoke.passed)" "false" "smoke result recorded"
run bash "$X" rollback;                          t_code 0 "rollback at stage 7"
t_eq "$(cat "$LOG/rolled")" "rolled" "rollback ran"

# mark: the deploy marker and the monitoring baseline
run bash "$X" mark;                              t_code 0 "mark"
t_eq "$(bash "$S/state.sh" get .deploy.baseline.health)" "true" "baseline: passing check"
t_eq "$(bash "$S/state.sh" get .deploy.baseline.queue)" "false" "baseline: failing check"
t_eq "$(jq -r .deploy.sha "$R/.factory/history/shipit.json")" "$(git -C "$BARE" rev-parse main)" "deploy in history"

bash "$S/state.sh" stage 8 >/dev/null
run bash "$X" rollback;                          t_code 0 "rollback at stage 8"
run bash "$X" deploy;                            t_code 1 "no deploy at stage 8"
write_config "$R" "$cfg_base"
run bash "$X" rollback;                          t_code 1 "rollback without ship.rollback"
run bash "$X" frobnicate;                        t_code 2 "unknown command"
t_done
