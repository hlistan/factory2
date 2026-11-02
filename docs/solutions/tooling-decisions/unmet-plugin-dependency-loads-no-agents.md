---
title: A plugin whose dependency is missing loads no agents, and plugin eval loads the plugin alone
date: 2026-11-02
category: tooling-decisions
module: plugin-manifest
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - "Testing a plugin that declares dependencies with --plugin-dir or claude plugin eval"
  - "Checking whether an installed plugin actually loaded"
tags: [plugin-dependencies, plugin-eval, plugin-dir, testing]
---

# A plugin whose dependency is missing loads no agents

## Context
On Claude Code 2.1.316, `claude -p --plugin-dir plugins/factory` without compound-engineering answered
"Agent type 'factory:planner' not found": with its dependency unmet, factory's agents didn't load.
`claude plugin eval plugins/factory` loads only the plugin under test, so the first eval's "with" arm
ran without factory's agents and scored the same as the baseline. An install with an unsatisfiable range
fails, but the entry stays in `plugin list --json` with `enabled: true`; only `.errors`
("Requires … >=99.0.0, installed 3.34.0") and the text listing ("failed to load") show it.

## Guidance
- Live tests load the dependency too: `--plugin-dir <factory> --plugin-dir <compound-engineering>`.
- Evals run a temporary copy with `dependencies` removed (`tests/eval.sh`); only valid while the
  evaluated agents don't use the dependency.
- To check a plugin loaded, read `.errors` in `plugin list --json`, not `.enabled` (doctor.sh does).
- A "with" arm that scores exactly the baseline is a sign the plugin didn't load; read the trace.
