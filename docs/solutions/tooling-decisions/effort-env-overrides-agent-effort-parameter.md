---
title: CLAUDE_CODE_EFFORT_LEVEL overrides the Agent tool's effort parameter too
date: 2026-11-02
category: tooling-decisions
module: agent-spawning
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - "A harness sets per-spawn effort through the Agent tool's effort parameter"
tags: [effort, subagents, environment, measurement]
retire_when: "A Claude Code release documents that the Agent tool's effort parameter wins over CLAUDE_CODE_EFFORT_LEVEL; re-run tests/live/hooks.sh part C"
---

# CLAUDE_CODE_EFFORT_LEVEL overrides the Agent tool's effort parameter

## Context
The docs say the variable overrides frontmatter `effort`; they don't say what it does to the Agent
tool's `effort` parameter (2.1.292). On 2.1.316, a spawn with `effort: "low"` under
`CLAUDE_CODE_EFFORT_LEVEL=high` ran at high: the subagent transcript's request had
`"output_config":{"effort":"high"}`. Without the variable the parameter wins over frontmatter
(implementer frontmatter low, parameter medium, sent medium).

## Guidance
- factory's low-then-high implementer policy and its per-effort stats are meaningless with the variable
  set, so `/factory:run` stops and asks; doctor and session-start say why.
- Verify effort from the transcript (`output_config.effort`, or the subagent's `.meta.json`), never from
  what the spawn asked for.
