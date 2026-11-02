---
title: A real quote can still be inverted; check what the source did, not only what it said
date: 2026-11-02
category: workflow-issues
module: prd
problem_type: workflow_issue
component: documentation
severity: medium
applies_when:
  - "A design choice is justified with a sentence quoted from an article or paper"
tags: [citations, evidence, quotes, prd-review]
---

# A real quote can still be inverted; check what the source did, not only what it said

## Context
PRD v2 justified hiding reviewer rubrics from the implementer with the harness-design post's sentence "the wording of the criteria steered the generator". The sentence is real, but the author gave the criteria to both the generator and the evaluator and read the steering as useful. Three more quotes from the same post were stretched in the same way: a reason for keeping the planner high-level was used to justify plan review, an architectural detail was presented as the fix for a lenient evaluator, and a single-model post was cited next to per-role model choices.

## Guidance
- After finding the quote, read the paragraph around it and the experiment it describes. Ask: did the source do what we are about to do, or the opposite?
- If the design choice is still wanted, state it as a design choice without the citation, and make it measurable (a config switch that `stats` can compare).
- Keep a quote's qualifiers ("on earlier models", "directional, not guarantees").

## Why This Matters
A quote that is verbatim passes a citation check that only looks for the words. The failure is semantic, so the check has to be semantic too.
