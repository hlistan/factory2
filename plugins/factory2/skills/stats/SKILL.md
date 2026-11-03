---
name: stats
description: Report factory's measurements across runs - spend by stage and agent, first-pass rate by implementer effort and model, fix rounds, issues found by humans by stage and type, QA false negatives, ce-compound outcomes, and memory size. Use before tuning roles, effort or depth.
argument-hint: "[--since <date>] [--export-evals]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*) Read Glob
---

# /factory2:stats

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. Read-only unless `--export-evals`.

1. `bash $S/stats.sh $ARGUMENTS` reads every `.factory/history/*.json` and prints the tables:
   - spend by stage and by agent (report this before anyone tunes `limits.depth`)
   - implementer first-pass rate and re-run count by model and effort, and QA false negatives per effort
   - fix rounds per stage, escalations, incidents
   - escapes: bugfix runs (`kind: bugfix`) per originating run (`caused_by`) and the stage that should
     have caught each (`escape.stage_missed`)
   - issues found by humans, by stage, `problem_type` and `component` (from `docs/solutions/` frontmatter)
   - ce-compound outcomes and the bundled compound-engineering version
   - lite vs full depth: defects that reached stage 6 or production under each (ablation)
   - agents whose MEMORY.md is near `learning.memory_max_lines`
2. Explain what the numbers support and what they don't: name the sample size; with fewer than ~10 runs
   per arm, call differences directional only.
3. A `roles` override (e.g. `implementer: {model: sonnet, effort: medium}`) is recommended only when the
   override's runs show parity on first-pass rate, fix rounds and human-found defects.
4. `--export-evals`: `stats.sh` writes each QA false negative as a candidate case under
   `.factory/eval-candidates/`; tell the user to review them before adding them to the plugin's evals.
