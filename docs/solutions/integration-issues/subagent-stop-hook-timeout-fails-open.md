---
title: A SubagentStop gate that times out lets the agent stop unchecked
date: 2026-11-02
category: integration-issues
module: stop-gate
problem_type: integration_issue
component: tooling
severity: high
applies_when:
  - "A hook gates an agent on checks that can run long (test suites, builds)"
tags: [hooks, timeout, subagent-stop, fail-open]
retire_when: "Claude Code documents and honours a fail-closed timeout for SubagentStop; re-run the probe in this doc"
---

# A SubagentStop gate that times out lets the agent stop unchecked

## Context
The hooks docs: Claude Code "cancels a `command` … hook that reaches its `timeout`, discarding the
hook's output, so on most events a timed-out hook renders no decision". `onFailure: "block"` (2.1.295)
is documented as making failures block. Probe on 2.1.316: the implementer's SubagentStop hook with
`timeout: 5`, `onFailure: "block"`, and a fast check of `sleep 20`. The hook fired once, was cancelled,
and the implementer finished: no block, no message. Passing `claude plugin validate --strict` says
nothing about whether a field is honoured on a given event.

## Guidance
- Never let the platform's timeout decide a gate. Run the slow part under the script's own limit
  (`scripts/lib/timeout.py`: own process group, SIGTERM then SIGKILL, exit 124), comfortably below the
  hook timeout (840 s of 900), and make the decision explicitly: factory lets the stop through, logs
  `timeout` in `stop-gate.log` and counts `state.gate_timeouts`.
- Keep a backstop outside the hook: the orchestrator re-runs every check after each implementer pass.
- Measure the gated work up front: `state.sh baseline` times the fast set and warns past half the limit.
- Test the timeout path with a short limit (`FACTORY_GATE_BUDGET`), in unit tests and in
  `tests/live/hooks.sh` part D, rather than waiting out the real one.
