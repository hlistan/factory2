---
title: ce-compound skips a lesson the final code already shows; capture context must carry the history
date: 2026-11-02
category: tooling-decisions
module: learning-capture
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Calling compound-engineering:ce-compound non-interactively from a harness"
  - "Writing a fixture for a test that expects ce-compound to write a doc"
tags: [compound-engineering, ce-compound, contract-test, learning]
---

# ce-compound skips a lesson the final code already shows

## Context
The first ce-contract fixture was an off-by-one fix in a pagination helper, with the lesson "state and
test the page base". ce-compound 3.34.0 (depth:full) returned `Documentation skipped`: the code already
said "1-based" and computed `(page - 1) * size`, the test the context mentioned wasn't in the tree, and
there was no investigation or failed attempt to record, "so the doc would only restate the diff". The
interface worked (a correct terminal signal); the content didn't meet its durability bar.

A second fixture carried a failed first attempt in git history (a raised timeout), the investigation
(two worktrees sharing port 3000 with reuseExistingServer), the fix, its verification, and a lesson the
final code doesn't show. It produced `docs/solutions/test-failures/…md` with `problem_type: test_failure`
and `Documentation complete`.

## Guidance
- factory's capture context names: the symptom as first seen, what was tried first and why it was
  wrong, how the cause was found, the fix with commit SHAs and its evidence, and the check for next time.
- `Documentation skipped` is a normal outcome, recorded in history; never retry with inflated wording.
- Contract fixtures must hold a non-obvious lesson, with the history in git, or the test checks ce's
  judgment instead of its interface.

## Why This Matters
Captures that only restate diffs would be skipped silently, and a contract test built on them fails for
the wrong reason, which would mark a working compound-engineering version as broken.
