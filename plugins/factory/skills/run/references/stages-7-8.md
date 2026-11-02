# Stages 7–8: merge, deploy, monitor

`S=${CLAUDE_PLUGIN_ROOT}/scripts`.

## Stage 7 (`state.sh stage 7`, `phase ship`)
1. Update from main: `git fetch origin && git merge --no-edit origin/<default_branch>`. A conflict: stop
   and ask; don't resolve conflicts in tests or check files yourself.
2. `bash $S/state.sh fold-memory`, then commit only `.claude/agent-memory/factory-*/` as
   `factory(<slug>): fold memory`. Show the user the added lines (they are part of the PR review).
3. `bash $S/ship.sh verify`: evidence approval recorded; checks green; every commit after the approved
   SHA is a conflict-free merge of origin/main or the fold commit. Any other commit means the evidence
   no longer matches: back to stage 6.
4. Push, then `bash $S/ship.sh merge`.
5. Deploy gate: show the deploy command (`ship.deploy`), the PR, and the rollback command; ask the user.
   Only on an explicit yes: `bash $S/state.sh approve deploy $(git rev-parse HEAD)` and
   `bash $S/ship.sh deploy`. Then `bash $S/ship.sh smoke`.
6. Smoke fails: tell the user and ask to roll back; on yes, `bash $S/state.sh approve rollback` and
   `bash $S/ship.sh rollback`, record an incident, and go to stage 5 with the smoke output.
7. Success: `bash $S/ship.sh mark` records the deploy SHA, time and monitor baseline. Write the run's
   measurements to history (state.json is git-ignored, history is not):
   `bash $S/state.sh history '.finished = $at | .rounds = $r | .spend = $s' --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$(bash $S/state.sh get .rounds)" --argjson s "$(bash $S/state.sh spend)"`.
   Capture lessons (learning.md), and go to stage 8.

## Stage 8 (`state.sh stage 8`, `phase monitor`)
1. `bash $S/monitor.sh --once`: runs `monitor.checks`, compares with the baseline; exit 0 healthy,
   1 anomaly (an incident was filed), 2 config error.
2. Offer the scheduler from `monitor.scheduler`:
   - `local-loop`: suggest `/loop <interval> /factory:monitor <slug>` (runs only while this session is
     idle, expires after 7 days).
   - `launchd` or `github-actions`: `/factory:init` installs the template; confirm it is in place.
3. The run stays at stage 8 until `monitor.window_hours` pass without an incident; then
   `bash $S/state.sh end` and tell the user the run is complete.
4. **Incident** (from monitor, CI, or launchd): spawn `triager` (high) with the incident file, the deploy
   SHA (`state.sh get .deploy`) and the diff. If the user approves a rollback: `approve rollback`,
   `ship.sh rollback`. Then stage 5 with a reproducing test first, and a postmortem capture
   (learning.md). Mark the incident `status: triaged` with the run it went to.
