---
name: prd-format
description: factory's PRD, contract.json and plan.md formats, with EARS acceptance criteria. Preloaded into the planner and prd-reviewer; not for direct use.
user-invocable: false
---

# PRD format (docs/specs/<slug>/)

A factory spec is three files. The PRD is **product level**: what and why, observable behaviour, never
implementation. Errors in the spec cascade into every later stage, so keep technical choices in plan.md.
The person approves the PRD and plan.md together, before any code: plan.md is how they see what will be
built and how, so it must be concrete enough to disagree with.

## prd.md
```markdown
# <Feature name>
Slug: <slug> · Status: draft|in-review|approved · Round: <n>

## Problem
Who has it, how they hit it today, and what it costs them. One paragraph.

## Users and scope
- Users: <roles or personas affected>
- In scope: <bullets>
- Non-goals: <bullets; what a reasonable reader might expect that this won't do>

## UX flows
Per flow: trigger → steps → outcome. Cover every state of each view and action it touches:
- empty (no data yet), loading, error (network, validation, server), permission (not allowed / signed out),
  first use, and the success state.

## Acceptance criteria
Each is EARS, testable, and names its test level.
- **AC-1** (e2e) WHEN <trigger> THE SYSTEM SHALL <observable response>.
- **AC-2** (unit) WHILE <state> THE SYSTEM SHALL <response>.
- **AC-3** (integration) IF <unwanted condition> THEN THE SYSTEM SHALL <response>.
- **AC-4** (e2e) WHERE <feature or config is present> THE SYSTEM SHALL <response>.
- Ubiquitous form, no keyword: THE SYSTEM SHALL <response>.
Rules: one behaviour per criterion; observable from outside the unit it names; no "should", "fast",
"intuitive" without a number; ids are AC-1..AC-n, never reused or renumbered after review starts (a
dropped criterion is struck through, not deleted).

## Non-functional requirements
Performance, accessibility, security, privacy, compatibility: each with a number or a named standard.

## Risks
Each risk, its likelihood, and the mitigation. Note anything on the project's risk list (auth, payments,
personal data, crypto, migrations, public API, concurrency, dependencies).

## Rollout
Feature flag name and default, migration and backfill, how to turn it off.

## Monitoring signals
What would show the feature broken in production: metric or check, threshold, window. These become
monitor.checks entries.

## Open questions
Anything the human must decide. Empty before approval.
```

## Bugfix runs
A run started from an issue (`kind: bugfix`) uses the same three files and the same review, with these
differences:
- **Problem** is the failure as observed: the signal or report, when it started, the evidence (check
  output, logs, screenshots), who is affected, and the issue link. Add a `Fixes: <issue ref>` line under
  the title.
- **AC-1 is the regression criterion**: the reproduction, stated as the correct behaviour (WHEN <the
  steps or condition that failed> THE SYSTEM SHALL <what should have happened>). Its test is written
  first and must fail on the current code. Further criteria cover any related state the fix must not
  break.
- **Root cause** (a section after Problem): the diagnosis so far and how sure it is. It is advisory, like
  plan.md; the regression test decides.
- **Monitoring signals** keep the signal that caught the failure, so the fix is watched by the same check.
- Sections that don't apply (Users and scope beyond the affected users, Rollout when there is no flag)
  say "Unchanged." rather than being dropped.

A PRD may quote a figure or a source only with the source's link, and the figure must appear in that
source; state its evidence class (vendor, peer-reviewed, community, anecdote) and sample size.

## contract.json
Exactly the PRD's criteria, in order. Written by the planner with `test_ids: []` and `passes: false`;
afterwards only the harness (`state.sh contract-sync`) changes `test_ids` and `passes`.
```json
{"criteria": [{"id": "AC-1", "text": "WHEN … THE SYSTEM SHALL …", "level": "e2e",
               "test_ids": [], "passes": false}]}
```

## plan.md (the approved approach)
Written for the person who approves it: plain sentences, real names from the code (read it; don't guess
what exists), no filler. The PR shows it inline in the approval request.
```markdown
# Plan: <slug>
## Summary
What will be built, in 3–5 sentences a non-author can check against the request.
## Approach
How: the components, modules or endpoints added or changed and what each does; data and schema
changes (with migrations); interfaces and contracts between parts; how a request or event flows
through them. Name existing code it builds on (`path/to/file.ts`, `ClassName`).
## Decisions
Each real choice: what was chosen, the alternatives considered, and why. "None" is fine for a small change.
## Steps
1. <small, verifiable step> (AC-n, …) — verify: <command or observable result>
   (tests first: the test-author writes the AC tests before any product code)
## Files likely touched
- `path` — what changes there
## Risks
What could go wrong in the build or in production, and how the plan contains it (flag, migration
order, fallback). "None" is fine.
## Exceptions
Dependencies or check-defining files this work genuinely needs to change, each in backticks with a
reason, e.g. - `date-fns` (new dependency: locale-aware formatting for AC-3).
Write "None." when there are none. Anything not listed here is frozen once the tests are frozen.
```
