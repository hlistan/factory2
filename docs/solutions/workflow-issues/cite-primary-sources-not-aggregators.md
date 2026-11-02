---
title: Cite the primary source for every figure, never an aggregator's retelling
date: 2026-11-02
category: workflow-issues
module: prd
problem_type: workflow_issue
component: documentation
severity: high
applies_when:
  - "A PRD, plan or review quotes a benchmark figure, price or vendor claim"
  - "A model-choice decision rests on a comparison between models"
tags: [citations, evidence, model-choice, prd-review]
---

# Cite the primary source for every figure, never an aggregator's retelling

## Context
PRD v1 credited a blog aggregator with "Sonnet 5.5 tied Opus 5.5" and with the "97% at $0.17 vs 95.3% at $0.29" figures. The review found the figures on Anthropic's own cost-optimization page, measured on Opus 5.5 only, and no source at all for the tie. The implementer model choice had been built on the misattribution and had to be redone.

## Guidance
- Open the page that ran the measurement and find the figure there before quoting it.
- Record, next to the figure, the evidence class (vendor, community, peer-reviewed), the sample size, the number of runs, and the model the figure was measured on.
- A figure that cannot be found in a primary source is not used.

## Why This Matters
A decision inherits every error in its evidence. Aggregators compress, merge and re-attribute numbers; the error is invisible until someone opens the original.

## When to Apply
Every time a PRD, plan or review quotes a figure or a source. The `review-rubric` skill runs this as a conditional citation check.
