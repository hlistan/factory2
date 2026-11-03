# Stages 7–8: merge, deploy, monitor

`S=${CLAUDE_PLUGIN_ROOT}/scripts`.

Production problems never reopen a finished run. Whatever finds one (smoke tests at stage 7, monitoring
at stage 8, a person) **files an issue first**, and the fix goes through a new **bugfix run**
(`/factory2:run --issue <ref>`) with every stage and gate. A rollback is a mitigation that needs no
approval; it doesn't replace the fix.

## Stage 7 (`state.sh stage 7`, `phase ship`)
1. Update from main: `git fetch origin && git merge --no-edit origin/<default_branch>`. A conflict: stop
   and ask; don't resolve conflicts in tests or check files yourself.
2. `bash $S/state.sh fold-memory`, then commit only `.claude/agent-memory/factory-*/` as
   `factory(<slug>): fold memory`. Show the user the added lines (they are part of the PR review).
3. `bash $S/ship.sh verify`: evidence approval recorded; checks green; every commit after the approved
   SHA is a conflict-free merge of origin/main or the fold commit. Any other commit means the evidence
   no longer matches: back to stage 6.
4. Push, then `bash $S/ship.sh merge`.
5. Deploy, without another approval (the evidence approval covers it): `bash $S/ship.sh deploy` and
   `bash $S/ship.sh smoke`. On a PR run, `bash $S/pr.sh publish note` with the deployed commit and the
   smoke result.
6. **Smoke fails** (the change is already merged, so it can't go back to stage 5):
   1. File the issue first: `bash $S/monitor.sh issue --source smoke --output <smoke output file>`. It
      prints the issue reference; record it:
      `bash $S/state.sh history '.incidents += [{issue: $i, source: "smoke", at: $at}]' --arg i <ref> --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"`.
   2. Roll back when `ship.rollback` is set: `bash $S/ship.sh rollback`, then comment the rollback on
      the issue (and on the PR with `pr.sh publish note`) and tell the user.
   3. Finish this run as in step 7 (its history says what happened), and offer
      `/factory2:run --issue <ref> ` for the fix.
7. Success: `bash $S/ship.sh mark` records the deploy SHA, time and monitor baseline. Write the run's
   measurements to history (state.json is git-ignored, history is not):
   `bash $S/state.sh history '.finished = $at | .rounds = $r | .spend = $s' --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$(bash $S/state.sh get .rounds)" --argjson s "$(bash $S/state.sh spend)"`.
   Capture lessons (learning.md), and go to stage 8.
8. **Bugfix run** (`kind: bugfix`), after a successful deploy:
   - Close the issue: the PR says `Fixes #<n>` (stage 4d), so the merge closes a GitHub issue; comment
     the deploy SHA on it. A local issue file gets `status: fixed`, the PR and the deploy SHA.
   - **Postmortem**, now that the cause and the fix are known: one ce-compound capture (learning.md) with
     the symptom, how it was detected, the root cause, the fix and its regression test, and why the
     originating run's gates didn't catch it.
   - Calibration: when `caused_by` is set, one line for each agent of that run that should have caught
     it (usually a review lens, `qa-evaluator` or `test-reviewer`), recorded here with
     `state.sh calibrate`; and record the escape in this run's history:
     `state.sh history '.escape = {caused_by: $c, stage_missed: $m}' --arg c <slug> --arg m <stage that should have caught it>`.

## Stage 8 (`state.sh stage 8`, `phase monitor`)
1. The run keeps this checkout while it is watched: the deploy guard allows `ship.rollback` only for
   the active run at stage 7–8. A bugfix run
   started meanwhile goes in a parallel session (`claude --worktree`); after the window, in this checkout.
2. `bash $S/monitor.sh --once <slug>`: runs `monitor.checks`, compares with the baseline; exit 0
   healthy, 1 anomaly (an issue was filed), 2 config error.
3. Offer the scheduler from `monitor.scheduler`:
   - `local-loop`: suggest `/loop <interval> /factory2:monitor <slug>` (runs only while this session is
     idle, expires after 7 days).
   - `launchd` or `github-actions`: `/factory2:init` installs the template; confirm it is in place.
4. **Anomaly.** `monitor.sh` has already filed the issue (labelled `factory-incident`, with the failing
   check, its output, the deploy SHA, the run slug and the PR) before anything else, and rolled back only
   if `monitor.auto_rollback` is true. Then, in a session (`/factory2:monitor`, or the incident pickup in
   `/factory2:run`):
   1. Spawn `triager` (read-only) with the issue, the deploy marker and the run's diff.
   2. Post its `issue_comment` on the issue (`gh issue comment <n> --body-file <file>`, or append it to
      the local file) and record it in the run's history:
      `state.sh history '.incidents += [{issue: $i, source: "monitor", at: $at}]' …`.
   3. If it recommends a rollback: `ship.sh rollback` (unless `monitor.auto_rollback` already did),
      comment the rollback on the issue, and tell the user.
   4. Offer `/factory2:run --issue <ref>` for the fix, in `claude --worktree` while this run is still
      being watched. Don't start it unasked.
5. When `monitor.window_hours` pass, record `state.sh history '.monitor_done = $at' --arg at …`, run
   `bash $S/state.sh end`, and tell the user the run is complete. Incidents don't extend the window; each one has its own issue and fix
   run.
