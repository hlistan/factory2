---
name: monitor
description: Run factory's production checks once for a deployed run and triage any anomaly. Designed for /loop (e.g. /loop 15m /factory:monitor <slug>).
argument-hint: "[slug]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*) Read Glob Agent
---

# /factory:monitor

`S=${CLAUDE_PLUGIN_ROOT}/scripts`.

1. Run `bash $S/monitor.sh --once $ARGUMENTS`. It runs `monitor.checks`, compares them with the deploy
   baseline, and files an incident on an anomaly (a file in `.factory/incidents/`, or a GitHub issue
   labelled `factory-incident`). It rolls back only when `monitor.auto_rollback` is true.
2. Exit 0: reply with one line (healthy, time, checks run) and nothing else, so a /loop stays quiet.
3. Exit 1: an incident was filed. Read it, then spawn `factory:triager` (model and effort from
   `bash $S/state.sh role triager high`) with the incident, the deploy SHA and the run's spec. Report its
   diagnosis and recommend: roll back, or continue the run at stage 5 with `/factory:run <slug>`. Never
   roll back or deploy from here without the user's explicit yes.
4. Exit 2: report the configuration error.
5. When `monitor.window_hours` have passed since the deploy with no incident, say the window is over and
   suggest stopping the loop.
