---
max_turns: 12
allowed_tools: [Agent, Read, Glob, Grep]
tags: [prd-reviewer, stage-2]
---

You are testing a PRD review. Use the Agent tool with subagent_type "factory:prd-reviewer" (if that agent
type doesn't exist, review it yourself). Tell the reviewer that there are no files: the PRD and contract
below are the whole input, and it must not look for them on disk. Output the reviewer's final report
verbatim.

PRD (docs/specs/saved-searches/prd.md):

# Saved searches
Slug: saved-searches · Status: in-review · Round: 1

## Problem
Analysts re-type the same filters every morning; support tickets say it takes 5-10 minutes a day.

## Users and scope
- Users: signed-in analysts.
- In scope: save the current search with a name; list saved searches; run or delete one.
- Non-goals: sharing searches between users; scheduled searches.

## UX flows
- Save: on the results page, "Save search" opens a name field; Enter saves; a toast confirms.
- List: the sidebar shows "Saved searches", newest first, each with run and delete buttons.
- Delete: delete asks for confirmation, then removes the item.

## Acceptance criteria
- **AC-1** (e2e) WHEN an analyst saves a search with a name THE SYSTEM SHALL show it at the top of the
  Saved searches list.
- **AC-2** (e2e) WHEN an analyst runs a saved search THE SYSTEM SHALL show the results page with that
  search's filters applied.
- **AC-3** (e2e) WHEN an analyst confirms deleting a saved search THE SYSTEM SHALL remove it from the list.
- **AC-4** (unit) IF the name is empty or longer than 80 characters THEN THE SYSTEM SHALL refuse to save
  and say why.

## Non-functional requirements
- The list renders within 200 ms for up to 100 saved searches.

## Risks
- Stored filters may reference fields that were later removed.

## Rollout
Flag `saved_searches`, default off; on for the analytics team first.

## Monitoring signals
- Error rate of POST /api/saved-searches above 1% over 15 minutes.

## Open questions
None.

contract.json: {"criteria": [{"id": "AC-1", "passes": false, "test_ids": []}, {"id": "AC-2", "passes": false, "test_ids": []}, {"id": "AC-3", "passes": false, "test_ids": []}, {"id": "AC-4", "passes": false, "test_ids": []}]}
