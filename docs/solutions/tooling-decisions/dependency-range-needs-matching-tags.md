---
title: A plugin dependency range is only as good as the tags it resolves against
date: 2026-11-02
category: tooling-decisions
module: plugin-manifest
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - "A Claude Code plugin declares a versioned dependency on a plugin from another marketplace"
retire_when: "compound-engineering publishes compound-engineering--v<version> tags; check with gh api repos/EveryInc/compound-engineering-plugin/git/matching-refs/tags/compound-engineering--v"
tags: [plugin-dependencies, semver, compound-engineering, marketplace]
---

# A plugin dependency range is only as good as the tags it resolves against

## Context
PRD v2 declared `compound-engineering` at `~3.34`. Claude Code resolves a range against git tags named `<plugin-name>--v<version>` (double dash). compound-engineering tags releases `compound-engineering-v3.34.0` (single dash) and its marketplace entry uses the relative source `./`. With no satisfying tag, the install takes the marketplace's current copy and checks the range at load time, so the day 3.35.0 shipped, factory would have been disabled. `claude plugin validate --strict` passes either way, because the syntax is fine.

## Guidance
- Declare a floor only (`>=3.21.1`, the `mode:non-interactive` rename) unless the dependency publishes `--v` tags.
- Put the real protection in a contract test of the behaviour you depend on, re-run whenever the installed version changes, and record the resolved version per run.
- Test resolution itself: install from a git-source marketplace and assert the dependency is enabled; add a negative test with an unsatisfiable range.

## Why This Matters
A range that cannot resolve gives no pin and a delayed outage. Validation does not exercise resolution.
