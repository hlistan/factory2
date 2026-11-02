---
title: A crashed or timed-out command hook lets the action through
date: 2026-11-02
category: integration-issues
module: hooks
problem_type: integration_issue
component: tooling
severity: high
applies_when:
  - "A hook is a safety gate (blocks deploys, protects files, gates an agent's stop)"
tags: [hooks, fail-open, fail-closed, onFailure, timeout]
retire_when: "Claude Code makes command hooks fail closed by default, or honours onFailure on SubagentStop"
---

# A crashed or timed-out command hook lets the action through

## Context
Hooks docs: a hook exiting with anything but 0 or 2, or reaching its `timeout`, is a non-blocking error
and "the action goes ahead, except for hooks whose failure blocks the action" (`onFailure: "block"`,
2.1.295). Probed on 2.1.316 with throwaway plugins:

| Hook | Failure | `onFailure` | Result |
|---|---|---|---|
| PreToolUse Bash | exit 1 | none | command ran |
| PreToolUse Bash | exit 1 | block | blocked |
| PreToolUse Bash | timeout | block | blocked |
| SubagentStop | exit 1 | block | agent stopped (ignored) |
| SubagentStop | timeout | block | agent stopped (ignored) |

## Guidance
- Make every gate's failure an explicit decision in the script, not the platform's default: factory
  runs guard-bash, test-guard and subagent-stop through `scripts/gate.sh <closed|record> <seconds>`, which
  enforces its own time limit (below the hook timeout) and maps a crash or hang to:
  - `closed` (PreToolUse guards): block with a message inside a factory project; allow elsewhere, so a
    broken guard in a globally installed plugin never takes Bash or Edit away in unrelated projects.
  - `record` (SubagentStop, which can't fail closed): allow, log `gate-errors.log`, count
    `state.gate_errors`; the orchestrator's own checks are the backstop and it reports the miss.
- Also set `onFailure: "block"` on PreToolUse gates, for a failure of the wrapper itself.
- Verify such fields on the event you use with a probe; `plugin validate --strict` accepts them either way.
