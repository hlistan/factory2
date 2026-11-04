#!/usr/bin/env bash
# monitor.sh: checks against the deploy baseline, incidents filed first (file, command, GitHub through a
# fake gh), no duplicate incident for a check that is still failing, auto rollback, the smoke-failure issue,
# and the committed CI copy running without the plugin.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
M="$PLUGIN/scripts/monitor.sh"
LOG="$T_TMP/log"; mkdir -p "$LOG"
base='monitor:
  report: file
  window_hours: 24
  checks:
    - {name: health, cmd: "test ! -f DOWN"}
    - {name: queue, cmd: "test ! -f QUEUE"}'
write_config "$R" "$base"

run bash "$M" --once;                            t_code 0 "healthy, no run (CI-style)"
t_has "$OUT" "ok: health" "one line per check"
touch "$R/DOWN"
run bash "$M" --once;                            t_code 1 "an anomaly is filed"
t_has "$OUT" "FAIL: health" "names the failing check"
t_has "$OUT" "issue: .factory/incidents/I-1.md" "prints the incident reference"
I1="$(cat "$R/.factory/incidents/I-1.md")"
t_has "$I1" "status: open" "incident is open"
t_has "$I1" "check: health" "names the check"
t_has "$I1" "/factory2:run --issue" "says how the fix goes"
run bash "$M" --once;                            t_code 3 "still failing: no second incident"
t_has "$OUT" "open incident .factory/incidents/I-1.md" "points at the open one"
t_eq "$(ls "$R/.factory/incidents" | wc -l | tr -d ' ')" "1" "one incident file"
sed -i '' 's/status: open/status: fixed/' "$R/.factory/incidents/I-1.md" 2>/dev/null || sed -i 's/status: open/status: fixed/' "$R/.factory/incidents/I-1.md"
run bash "$M" --once;                            t_code 1 "a closed incident doesn't hide a new failure"
rm -f "$R/DOWN" "$R/.factory/incidents/"*

# with a run: the baseline and the window
bash "$S/state.sh" start live >/dev/null
touch "$R/QUEUE"
run bash "$M" baseline;                          t_code 0 "baseline"
t_has "$OUT" "queue FAILS" "baseline reports a check already failing"
t_eq "$(bash "$S/state.sh" get .deploy.baseline.health)" "true" "baseline recorded"
run bash "$M" --once live;                       t_code 0 "failing as at the baseline is not an anomaly"
t_has "$OUT" "failing (as at the deploy baseline): queue" "says so"
bash "$S/state.sh" set '.deploy.at = "2020-01-01T00:00:00Z" | .deploy.sha = "abc123"' >/dev/null
run bash "$M" --once;                            t_code 0 "window over"
t_has "$OUT" "monitoring window since the deploy at 2020-01-01T00:00:00Z is over" "says the window is over"

# auto rollback after filing
write_config "$R" "$base
  auto_rollback: true
ship:
  rollback: \"echo \$FACTORY_DEPLOY_SHA > $LOG/rolled\""
touch "$R/DOWN"
run bash "$M" --once;                            t_code 1 "anomaly with auto rollback"
t_has "$OUT" "rolled back (monitor.auto_rollback)" "rolls back"
t_eq "$(cat "$LOG/rolled")" "abc123" "with the deployed commit"
t_has "$(cat "$R/.factory/incidents/I-1.md")" "rolled back automatically" "and notes it on the incident"
t_has "$(cat "$R/.factory/incidents/I-1.md")" "deploy_sha: abc123" "incident names the deploy"
rm -f "$R/DOWN" "$R/.factory/incidents/"*

# command report
write_config "$R" "monitor:
  report: command
  issue_cmd: \"cat > $LOG/body; printf '%s' \\\"\$1\\\" > $LOG/title; echo; echo OPS-42\"
  checks:
    - {name: health, cmd: \"false\"}"
run bash "$M" --once;                            t_code 1 "command report"
t_has "$OUT" "issue: OPS-42" "the tracker's reference is printed"
t_has "$(cat "$LOG/title")" "[health] failing after deploy (live)" "title as \$1"
t_has "$(cat "$LOG/body")" "Failing check" "body on stdin"
write_config "$R" 'monitor: {report: command, checks: [{name: h, cmd: "false"}]}'
run bash "$M" --once;                            t_code 2 "command report without issue_cmd"

# GitHub issues through a fake gh, with an open-issue check
FAKE="$T_TMP/gh"; mkdir -p "$FAKE/bin"; export FAKE
cat > "$FAKE/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
case "$1 $2" in
  "label create") exit 0 ;;
  "issue list") cat "$FAKE/open.json" 2>/dev/null || echo '[]' ;;
  "issue create") echo "https://github.com/o/r/issues/12" ;;
  "issue comment") exit 0 ;;
  *) echo "fake gh: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$FAKE/bin/gh"; export PATH="$FAKE/bin:$PATH"
write_config "$R" 'monitor: {checks: [{name: health, cmd: "false"}]}'
run bash "$M" --once;                            t_code 1 "github-issue is the default report"
t_has "$OUT" "issue: https://github.com/o/r/issues/12" "issue URL printed"
t_has "$(cat "$FAKE/calls")" "issue create --label factory-incident" "labelled factory-incident"
printf '[{"number":12,"title":"[health] failing after deploy (live)"}]' > "$FAKE/open.json"
run bash "$M" --once;                            t_code 3 "an open GitHub incident isn't filed twice"
t_has "$OUT" "open incident #12" "names it"

# the smoke failure issue
printf 'smoke: 2 failed\n' > "$T_TMP/smoke.log"
rm -f "$FAKE/open.json"
run bash "$M" issue --source smoke --output "$T_TMP/smoke.log"; t_code 0 "smoke issue"
t_has "$OUT" "issue: https://github.com/o/r/issues/12" "filed"
run bash "$M" issue --source smoke;              t_code 2 "issue needs --output"

# config errors
write_config "$R" 'monitor: {checks: []}'
run bash "$M" --once;                            t_code 2 "no checks"
write_config "$R" 'monitor: {report: pager, checks: [{name: h, cmd: "false"}]}'
run bash "$M" --once;                            t_code 2 "unknown report"

# the committed CI copy: monitor.sh and yaml2json.py in .factory/bin, no plugin, no run
C="$(new_repo)"
write_config "$C" "monitor: {report: file, checks: [{name: health, cmd: \"false\"}]}"
mkdir -p "$C/.factory/bin"; cp "$M" "$PLUGIN/scripts/lib/yaml2json.py" "$C/.factory/bin/"
CODE=0; OUT="$(cd "$C" && env -u FACTORY_ROOT bash .factory/bin/monitor.sh --once 2>&1)" || CODE=$?
t_code 1 "the CI copy runs on its own"
t_has "$OUT" "issue: .factory/incidents/I-1.md" "and files the incident"
t_has "$(cat "$C/.factory/incidents/I-1.md")" "run: " "without a run"
rm "$C/.factory/bin/yaml2json.py"
CODE=0; (cd "$C" && env -u FACTORY_ROOT bash .factory/bin/monitor.sh --once >/dev/null 2>&1) || CODE=$?
t_code 2 "the CI copy needs yaml2json.py next to it"
t_done
