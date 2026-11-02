---
title: Before building a workaround, confirm the issue says what you think and is still open
date: 2026-11-02
category: workflow-issues
module: plugin-hooks
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - "A design adds a workaround or test premise because of a GitHub issue"
tags: [issues, workarounds, plugin-hooks, verification]
---

# Before building a workaround, confirm the issue says what you think and is still open

## Context
PRD v2 added no-op settings-level hooks to `/factory:init` for issue #105625 and required git-source installs for issue #86809. #105625 is about `CwdChanged` hooks only and states that `SessionStart` from the same plugin always fires. #86809 was closed by its own reporter six minutes after filing as a measurement error. Both workarounds would have shipped as permanent, unexplained configuration in every target repo.

## Guidance
- Read the issue title, body and every comment, and its state, before citing it.
- Check the documented failure causes first (for plugin hooks: invalid `hooks.json`, a plugin-name collision, wrong event-name case, `disableAllHooks`, `allowManagedHooksOnly`).
- Prefer a test that proves the behaviour over a workaround for a behaviour you have not reproduced.

## Why This Matters
Workarounds outlive the bugs they target and confuse every later reader. A test catches the real failure whether or not the issue was right.
