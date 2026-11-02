---
title: jq's // treats false as missing, so a default of true hides an explicit false
date: 2026-11-02
category: logic-errors
module: doctor
problem_type: logic_error
component: tooling
severity: medium
symptoms:
  - "doctor.sh reported auto memory as fine while settings.json had autoMemoryEnabled: false"
root_cause: logic_error
resolution_type: code_fix
tags: [jq, booleans, settings]
---

# jq's `//` treats false as missing

## Problem
`jq -r '.autoMemoryEnabled // true'` prints `true` when the setting is `false`, because `//` replaces
both null and false. The doctor's auto-memory check could never fire, and the user's real settings had
auto memory off, which silently disables subagent memory, factory's calibration layer.

## Solution
`if has("autoMemoryEnabled") then .autoMemoryEnabled else true end`. The same bug was fixed earlier in
`cfg`/`state_get` (`_JQ_TEXT`); any `// <default>` on a boolean is suspect.

## Prevention
Test boolean settings with an explicit `false` fixture, not only absent and `true`.
