# Stages 1–3: analyze and plan, PRD review, fix PRD

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. Spec directory: `docs/specs/<slug>/` (`bash $S/state.sh paths`).

## Stage 1: analyze and plan (`state.sh stage 1`, `phase plan`)
1. Branch: update `project.default_branch` first (`git switch <default> && git pull --ff-only`) unless
   resuming, then `bash $S/state.sh branch`: it creates or switches to `factory/<slug>` and records the
   run's base there (the first freeze compares check files with it). Exit 1 means uncommitted changes:
   stop and ask.
2. **Draft PR first.** `bash $S/pr.sh open` with the request verbatim on stdin (bugfix run: the issue's
   title, body and every comment). It commits `request.md`, pushes `factory/<slug>`, opens the draft PR
   (`ship.pr_open`) and writes its description. From here the person follows and steers the planning
   on the PR. Exit 3 (`review.via: terminal`) or exit 1 (no gh, no login, no origin): say why in one
   line and use the terminal gates below; everything else in these stages is the same.
3. Retrieval: spawn `learnings-researcher`, purpose `planning`, with the feature request; it returns past
   lessons from `docs/solutions/` (or the configured docs_root). Skip when `learning.enabled` is false.
4. Optional: when the request depends on outside facts (an API's behaviour, a library's limits, a
   standard), spawn `researcher` with the specific questions. Skip otherwise.
5. Spawn `planner` with: the request verbatim, the learnings, the research, the spec directory,
   and the instruction to write `prd.md`, `contract.json` and `plan.md` in the prd-format skill's format.
   **Bugfix run** (`state.sh get .kind` is `bugfix`): the request is the issue (`state.sh get .issue`):
   give the planner its body and every comment verbatim, including the triager's diagnosis, and, when
   `caused_by` is set, that run's spec directory and PR. The planner writes a bugfix PRD (prd-format,
   "Bugfix runs"). Then tell the issue the run started: `gh issue comment <n> --body "factory: fix run
   <slug> started on branch factory/<slug>"` (with the PR link on a PR run), or for a local issue add `run: <slug>` to its file.
6. Check the files exist and `jq -e '.criteria | length > 0' contract.json`. Commit:
   `factory(<slug>): 1 plan`.
7. PR run (`bash $S/pr.sh enabled`): `bash $S/pr.sh publish plan` with the planner's JSON report on
   stdin. It saves the report under `reviews/`, pushes, and comments on the PR with what was added.

## Stage 2: PRD review (`state.sh stage 2`, `phase prd-review`)
1. `n=$(bash $S/state.sh round prd)`.
2. Spawn `prd-reviewer` as a read-only batch (hash before and after). Brief: spec paths, round n,
   the previous round's findings (`reviews/prd-review-<n-1>.json`, `reviews/planner-<n-1>.json`) and
   the human's feedback files, if any. Read them from the files, not from memory: a resumed run has
   only the files.
3. **PR run**: `bash $S/pr.sh publish prd-review` with the reviewer's JSON report on stdin, then
   `bash $S/pr.sh feedback prd` to collect what the person has commented so far.
   - Blocking findings, or `changes`: go to stage 3 with both, without asking. The PR comment shows
     the findings, and the person can add corrections at any time.
   - Otherwise: `bash $S/pr.sh request-approval prd`, then tell the user in one line that the PRD
     and plan wait for them on the PR (link), and run `bash $S/pr.sh wait prd` in the background (Bash
     `run_in_background`). Don't ask in the terminal. When it exits, read its JSON:
     - `approved`: the approval is already recorded against the requested SHA (`state.sh approve`
       refuses it from the terminal on a PR run). When `override` is true, record it:
       `state.sh history '.issues += [{stage: 2, found_by: "human", class: "override", findings: $f}]'
       --argjson f '<open_blocking>'`. Set the PRD's Status to approved (a one-line edit), commit, push, go to stage 4.
       (pr.sh has already confirmed the approval on the PR.)
     - `changes`: the corrections are in `feedback_file` (committed and pushed) → stage 3.
     - `ignored` lists comments from people `review.reviewers` doesn't allow: mention them to the
       user; never act on them.
   - The user may also say in the terminal that they commented: run `bash $S/pr.sh feedback prd` once
     instead of waiting. Requests in the terminal to approve are answered with the PR link: the
     approval is the `/approve` comment there.
4. **Terminal run** (no PR): the human gate (SKILL.md "Human gates"): show the PRD's criteria list,
   the reviewer's summary and its findings grouped by severity, and the open questions. Options:
   approve, request changes, stop.
   - **Approve** with no blocking findings left open: `bash $S/state.sh approve prd $(git rev-parse HEAD)`,
     set the PRD's Status to approved (planner not needed: a one-line edit by you is allowed here),
     commit, go to stage 4.
   - **Approve while the reviewer has blocking findings**: ask once whether to override; record the
     override in history (`state.sh history '.issues += [...]'`) and proceed only on an explicit yes.
   - **Request changes** or blocking findings: go to stage 3.

## Stage 3: fix PRD and self-improve (`state.sh stage 3`)
1. When `rounds.prd` has reached `limits.prd_rounds`, stop and ask the user how to proceed.
2. Spawn `planner` with the reviewer's findings and the human's feedback file verbatim (on a PR run,
   each correction keeps its author, link and file:line). It revises all three files and lists, per
   finding and per correction, what it changed or why it disagrees. Commit the revision
   (`factory(<slug>): 3 prd round <n>`); on a PR run, then `bash $S/pr.sh publish plan` with its
   report, so the PR shows what changed and how each finding was answered.
3. Self-improvement, per `learning.md`:
   - Each issue the **human** raised that the reviewer missed: a history issue
     (`stage: 2, found_by: human`), one calibration line for `prd-reviewer`, and one for `planner` when
     the planner should have covered it.
   - Each blocking reviewer finding the planner accepted: one calibration line for `planner`.
   - Each lesson that generalises beyond this feature: one ce-compound capture.
4. Commit any learning files and go back to stage 2.
