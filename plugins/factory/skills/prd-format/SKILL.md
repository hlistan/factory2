---
name: prd-format
description: factory's PRD, contract.json and plan.md formats, with EARS acceptance criteria. Preloaded into the planner and prd-reviewer; not for direct use.
user-invocable: false
---

# PRD format (docs/specs/<slug>/)

A factory spec is three files. The PRD is **product level**: what and why, observable behaviour, never
implementation. Errors in the spec cascade into every later stage, so keep technical choices in plan.md,
which is advisory.

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

A PRD may quote a figure or a source only with the source's link, and the figure must appear in that
source; state its evidence class (vendor, peer-reviewed, community, anecdote) and sample size.

## contract.json
Exactly the PRD's criteria, in order. Written by the planner with `test_ids: []` and `passes: false`;
afterwards only the harness (`state.sh contract-sync`) changes `test_ids` and `passes`.
```json
{"criteria": [{"id": "AC-1", "text": "WHEN … THE SYSTEM SHALL …", "level": "e2e",
               "test_ids": [], "passes": false}]}
```

## plan.md (advisory)
```markdown
# Plan: <slug>
## Steps
1. <small, verifiable step> — verify: <command or observable result>
   (tests first: the test-author writes the AC tests before any product code)
## Files likely touched
## Exceptions
Dependencies or check-defining files this work genuinely needs to change, each in backticks with a
reason, e.g. - `date-fns` (new dependency: locale-aware formatting for AC-3).
Write "None." when there are none. Anything not listed here is frozen once the tests are frozen.
```
