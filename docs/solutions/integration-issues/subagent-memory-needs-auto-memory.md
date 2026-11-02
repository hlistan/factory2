---
title: Subagent memory frontmatter does nothing when auto memory is off
date: 2026-11-02
category: integration-issues
module: agent-memory
problem_type: integration_issue
component: tooling
severity: high
applies_when:
  - "A plugin relies on subagent `memory:` frontmatter for learning"
tags: [memory, subagents, hooks, settings]
retire_when: "Never, while factory loads memory through its own hook; re-check if moving back to `memory:`"
---

# Subagent memory frontmatter does nothing when auto memory is off

## Context
Sub-agents docs: "Subagent memory is part of auto memory: if you turn auto memory off, with the
`autoMemoryEnabled` setting or `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, the `memory` field has no effect".
The user's `~/.claude/settings.json` had `autoMemoryEnabled: false`, so factory's per-agent calibration
(layer 2) would have silently done nothing. Making a plugin's core feature depend on a personal setting
is fragile; asking users to change it is a workaround, not a fix. The frontmatter also gives every
memory agent Write and Edit and tells it to curate its MEMORY.md, which factory forbids.

## Guidance
- Load memory with a SubagentStart hook (matcher `^factory:`) that returns
  `hookSpecificOutput.additionalContext` with the file's first 200 lines or 25 KB
  (`scripts/memory-inject.sh`). Verified live on 2.1.316 with auto memory forced off
  (`tests/live/hooks.sh`, planner reads its codename).
- Keep the same path (`.claude/agent-memory/factory-<agent>/MEMORY.md`), so the harness-only writer
  (`state.sh fold-memory`) and the test-guard block are unchanged.
- doctor now only warns about auto memory: it affects Claude Code's own memory of the user's
  corrections, not factory's.
