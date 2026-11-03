---
name: monitor
description: Run factory's production checks once for a deployed run and triage any anomaly. Designed for /loop (e.g. /loop 15m /factory2:monitor <slug>).
argument-hint: "[slug]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*) Read Glob Agent
---

# /factory2:monitor

`S=${CLAUDE_PLUGIN_ROOT}/scripts`.

1. Run `bash $S/monitor.sh --once $ARGUMENTS`. It runs `monitor.checks` and compares them with the
   deploy baseline. On an anomaly it **files an issue first** (`monitor.report`: a GitHub issue labelled
   `factory-incident`, the `monitor.issue_cmd` tracker, or `.factory/incidents/I-n.md`), then rolls back
   only when `monitor.auto_rollback` is true.
2. Exit 0: reply with one line (healthy, time, checks run) and nothing else, so a /loop stays quiet.
3. Exit 1: an issue was filed (its reference is in the output). Read it, then spawn `factory2:triager`
   (model and effort from `bash $S/state.sh role triager`) with the issue, the deploy SHA and the
   run's spec. Post its `issue_comment` on the issue and record the incident in the run's history
   (stages-7-8.md, stage 8 step 4). Report the diagnosis in a few lines, then:
   - if it recommends a rollback, roll back as stages-7-8.md says (stage 8 step 4.3); it needs no
     approval;
   - offer the fix as a bugfix run: `/factory2:run --issue <ref>` (in `claude --worktree` while this run
     holds the checkout). Never start a run or deploy from here unasked.
4. Exit 2: report the configuration error.
5. When `monitor.window_hours` have passed since the deploy with no incident, say the window is over and
   suggest stopping the loop.
