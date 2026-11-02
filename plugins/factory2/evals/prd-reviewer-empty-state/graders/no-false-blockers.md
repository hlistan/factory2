---
type: llm
weight: 1
---

The response must not mark as blocking anything that is actually fine in this PRD: the criteria are in
EARS form, each names a test level, non-goals are stated, rollout and a monitoring signal exist. Other
real gaps (for example the loading or error state of the list, the stored-filter risk without a
criterion, or contract.json entries missing their text) may be raised at any severity. Pass if every
blocking finding points to a real gap; fail if any blocking finding is wrong about the PRD.
