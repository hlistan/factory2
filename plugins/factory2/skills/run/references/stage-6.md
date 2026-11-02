# Stage 6: evidence and human approval

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. `state.sh stage 6`, `phase evidence`. The evidence skill describes the
capture details; `evidence.sh` does the work.

1. `n=$(bash $S/state.sh round evidence)`. Beyond `limits.evidence_rounds`: stop and ask the user.
2. `bash $S/evidence.sh capture`: runs the `@AC-n` e2e specs under the demo config (video with action
   and step overlays, a chapter per criterion, screenshots at each `evidence.viewports` size), converts
   the video to mp4 when ffmpeg is available, and writes `<run>/evidence/`. With `evidence.driver:
   command` it runs `evidence.capture`; with `none` it records test results only.
3. `bash $S/evidence.sh pack`: builds `<run>/review-pack/index.html` (per criterion: text, tests, pass,
   screenshots, video chapter; plus advisory findings, spend, and the PR link). `evidence.publish`, when
   set, uploads it and prints a URL.
4. Human gate: give the pack's path or URL, the criteria table, and the advisory findings. Options:
   approve, comment, stop. Comments go to `docs/specs/<slug>/feedback/evidence-<n>.md`.
5. **Approve**: `bash $S/state.sh approve evidence $(git rev-parse HEAD)`, run `ship.pr_ready`, go to 7.
6. **Comments**: spawn `triager` (read-only) with the comments, the PRD, contract.json and the QA
   report. It classifies each comment:
   - **spec-gap** (the PRD didn't ask for it): planner amends the PRD (new or changed criterion) → stage 2.
   - **defect** (a criterion isn't met): stage 5's fix loop (step 7, which sets `phase tests` for the
     test-author), starting with a failing test.
   - **cosmetic** (no criterion affected): a fresh implementer (`state.sh role implementer`) fixes it directly; fast checks;
     re-capture evidence (step 2).
   Record each as a history issue `{stage: 6, found_by: human, class, problem_type?, component?}`, with
   `class` exactly as the triager spells it (`spec-gap`, `defect`, `cosmetic`).
   A defect on a criterion QA passed is a **QA false negative**:
   `state.sh history '.qa_false_negatives += [{ac: $a, comment: $c}]' --arg a AC-n --arg c "<comment>"`,
   one calibration line for `qa-evaluator`, and an eval-case candidate (stats exports them).
   Then capture lessons per learning.md, and ask the user again when everything is routed.
