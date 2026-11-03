---
title: A floor-only plugin dependency changes behaviour under you; bundle the small part you use
date: 2026-11-03
category: tooling-decisions
module: plugin-manifest
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - "A plugin depends on another plugin whose marketplace source is a relative path or which publishes no <name>--v<version> tags"
  - "A harness parses another skill's output or relies on what that skill writes"
tags: [plugin-dependencies, vendoring, compound-engineering, ce-compound]
---

# A floor-only plugin dependency changes behaviour under you

## Context
factory2 declared `compound-engineering >=3.21.1`, because a range couldn't pin anything (see
`dependency-range-needs-matching-tags.md`), and relied on a contract test run whenever the installed
version changed. Two things on 2026-11-03 showed the gap:
- The installed copy reported `3.34.0` but was a later snapshot of upstream `main` (`77cc431`), because
  a `./` marketplace source installs whatever the clone holds. The version check compared labels, not code.
- Release 3.35.0 made non-interactive `ce-compound` write tests, lint-rule changes and coding standards
  without asking. The contract test (final line, refresh line, one doc) would still have passed, yet
  inside a run the learning step could now edit frozen tests and check-defining files.

## Guidance
- When you use a small, licensed part of a fast-moving plugin, copy it unchanged, pinned to a release
  tag, with a manifest of per-file hashes and a test that the copy matches it (factory2:
  `tools/vendor-ce.sh`, `vendor/compound-engineering/upstream.json`, `tests/plugin.test.sh`).
- Report upstream drift as information, and update by reading the diff, not by default.
- A contract test of output format doesn't catch a change in what the skill writes. When re-vendoring,
  read the diff for new writes as well as format changes.
- Pin to a release tag, not to an installed copy: the installed copy's version string may not match
  its contents.

## Why This Matters
The learning layer is supposed to observe a run, not change its checks. A silent upstream change to
what it writes would have broken the freeze's guarantee without failing any test.
