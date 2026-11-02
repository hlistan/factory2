# Stages 1–3: analyze and plan, PRD review, fix PRD

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. Spec directory: `docs/specs/<slug>/` (`bash $S/state.sh paths`).

## Stage 1: analyze and plan (`state.sh stage 1`, `phase plan`)
1. Branch: `git switch -c factory/<slug>` from an up-to-date `project.default_branch` (or switch to it
   when resuming). The working tree must be clean; if not, stop and ask.
2. Retrieval: spawn `learnings-researcher` (default effort low) with the feature request; it returns past
   lessons from `docs/solutions/` (or the configured docs_root). Skip when `learning.enabled` is false.
3. Optional: when the request depends on outside facts (an API's behaviour, a library's limits, a
   standard), spawn `researcher` (medium) with the specific questions. Skip otherwise.
4. Spawn `planner` (high) with: the request verbatim, the learnings, the research, the spec directory,
   and the instruction to write `prd.md`, `contract.json` and `plan.md` in the prd-format skill's format.
5. Check the files exist and `jq -e '.criteria | length > 0' contract.json`. Commit:
   `factory(<slug>): 1 plan`.

## Stage 2: PRD review (`state.sh stage 2`, `phase prd-review`)
1. `n=$(bash $S/state.sh round prd)`.
2. Spawn `prd-reviewer` (high) as a read-only batch (hash before and after). Brief: spec paths, round n,
   the previous round's findings and the human's feedback files, if any.
3. Human gate (SKILL.md "Human gates"): show the PRD's criteria list, the reviewer's summary and its
   findings grouped by severity, and the open questions. Options: approve, request changes, stop.
   - **Approve** with no blocking findings left open: `bash $S/state.sh approve prd $(git rev-parse HEAD)`,
     set the PRD's Status to approved (planner not needed: a one-line edit by you is allowed here),
     commit, go to stage 4.
   - **Approve while the reviewer has blocking findings**: ask once whether to override; record the
     override in history (`state.sh history '.issues += [...]'`) and proceed only on an explicit yes.
   - **Request changes** or blocking findings: go to stage 3.

## Stage 3: fix PRD and self-improve (`state.sh stage 3`)
1. When `rounds.prd` has reached `limits.prd_rounds`, stop and ask the user how to proceed.
2. Spawn `planner` (high) with the reviewer's findings and the human's feedback file verbatim. It revises
   all three files and lists, per finding, what it changed or why it disagrees.
3. Self-improvement, per `learning.md`:
   - Each issue the **human** raised that the reviewer missed: a history issue
     (`stage: 2, found_by: human`), one calibration line for `prd-reviewer`, and one for `planner` when
     the planner should have covered it.
   - Each blocking reviewer finding the planner accepted: one calibration line for `planner`.
   - Each lesson that generalises beyond this feature: one ce-compound capture.
4. Commit `factory(<slug>): 3 prd round <n>` and go back to stage 2.
