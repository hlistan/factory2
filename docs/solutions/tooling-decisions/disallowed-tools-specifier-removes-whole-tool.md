---
title: A disallowedTools entry with a specifier removes the whole tool
date: 2026-11-02
category: tooling-decisions
module: agents
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "A subagent should lose access to some skills or commands but not others"
tags: [subagents, disallowed-tools, skills, permissions]
---

# A disallowedTools entry with a specifier removes the whole tool

## Context
PRD v2 set `disallowedTools: ["Skill(compound-engineering:*)"]` to stop subagents from triggering ce-compound. The sub-agents doc states that an entry with a specifier, such as `Bash(git push *)`, "still removes the whole tool from the subagent, not only the matching commands". There is also no documented `Skill(plugin:*)` form.

## Guidance
- Use `disallowedTools: ["Skill"]` on every agent that should not run skills, and preload what it needs with `skills:` (skills with `disable-model-invocation: true` cannot be preloaded).
- For per-command or per-skill denial, use a settings-level `permissions.deny` rule, which applies session-wide.

## Why This Matters
The specifier looks precise, so the over-blocking goes unnoticed until an agent cannot use a tool it was meant to keep.
