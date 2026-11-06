---
name: status
description: Show factory's state in this checkout - the active run, its stage, rounds, approvals, spend, open incidents. Use when the user asks where a factory run stands.
argument-hint: "[slug]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*) Read Glob
---

# /factory2:status

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. Read-only: change nothing.

1. No `.factory/config.yaml`: say factory isn't set up here and suggest `/factory2:init`.
2. Runs: list `.factory/runs/*/state.json` with slug, stage, phase, and last change; mark the active one
   (`bash $S/state.sh active`). With an argument, show only that run.
3. For the active (or named) run: stage and phase, rounds vs `limits`, approvals with their SHAs (and,
   for one given on the PR, who and the comment link), the PR (`.pr_url`; `review_via` says whether
   planning is followed there), whether an approval request or a question is waiting (`.approval_request`, `.question`: the link;
   on GitHub, `gh issue list --label blocked` lists every feature waiting for someone, and
   `bash $S/issue-flow.sh show <issue>` the run's issue with its PRs), the
   newest review's open findings from `docs/specs/<slug>/reviews/`,
   frozen or not, the criteria table from `docs/specs/<slug>/contract.json` (id, passes, test count), and
   `bash $S/state.sh spend` against `limits.budget_usd`.
4. Open incident issues: open issues whose title starts with `Incident: ` (`gh issue list --state open
   --search 'Incident in:title'`, with `monitor.report: github-issue`) or `.factory/incidents/I-*.md` with `status: open`. For each, the bugfix run that
   claims it (a run or history file whose `issue` matches) and its stage, or "no fix run yet: start one
   with `/factory2:run --issue <ref>`".
5. End with the next step: the command that continues the run (`/factory2:run <slug>`).
Keep it to one screen.
