# Learning capture

Three layers: compound-engineering docs (project knowledge), per-agent MEMORY.md calibration lines
(written only by the harness), and Claude Code's auto memory (built in). Skip capture entirely when
`learning.enabled` is false.

## Calibration lines (per-agent memory)
For the agent that missed something, one line, phrased as a check to apply next time:
`bash $S/state.sh calibrate <agent> "<check to apply next time>"`. Specific and testable ("check every
list view has an empty-state criterion"), never a rule that overrides the task, never secrets or user
data. Lines are kept in the committed history file and folded into
`.claude/agent-memory/factory-<agent>/MEMORY.md` at stage 7, where they are reviewed in the PR.

## ce-compound (project knowledge)
At four points: a PRD round where something got past the reviewer; a blocking finding confirmed and
fixed or escalated; a stage 6 issue resolved; an incident postmortem. One learning per call, and only
for lessons that generalise beyond this feature:

Skill tool → `compound-engineering:ce-compound` with arguments
`mode:non-interactive depth:<learning.compound_depth> "<context: what happened, the evidence, the fix, and the lesson>"`

Parse the result:
- Only the **final line** counts: exactly `Documentation complete` or `Documentation skipped` (the header
  line also contains the phrase, so don't substring-match the whole output).
- Read the `Refresh recommendation:` line, if any.
- Record: `bash $S/state.sh history '.compound += [{point: $p, outcome: $o, refresh: $r}]' --arg p <point> --arg o <complete|skipped|error> --arg r "<recommendation or empty>"`.
- When a refresh is recommended, or `learning.refresh_ceiling` runs have passed since the last refresh,
  run `compound-engineering:ce-compound-refresh` with `mode:non-interactive <scope>` once, at the end of
  the stage.

## Issues for stats
Every issue found by a human or a later stage goes into history with what's known:
`state.sh history '.issues += [{stage: $s|tonumber, found_by: $f, class: $c, problem_type: $p, component: $m}]' --arg s … `
