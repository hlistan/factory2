# Stage 6: docs, evidence and human approval

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. `state.sh stage 6` (the issue is `documenting`). The evidence skill
describes the capture details; `evidence.sh` does the work.

## 6.0 Docs (`phase docs`)
The behaviour is now reviewed and tested; document it. Spawn `implementer` (`state.sh role implementer`)
in its docs phase: update README, docs and CHANGELOG for the user-visible changes in contract.json, and
nothing else. Then `bash $S/state.sh verify-freeze` and `bash $S/run-checks.sh --set fast` (a docs gate
the project has is a check like any other): any failure goes back to the same implementer once, then
to the user. Commit `factory(<slug>): 6.0 docs`. Every return to stage 6 after a fix loop runs 6.0 again,
so the docs match what is approved.

## 6.1 Evidence (`phase evidence`): recorded once, at the final gate
The recording is what the person approves, not a test: it runs only when nothing else can fail, and once
per approval request.
1. **Preflight, no recording.** `bash $S/run-checks.sh --set all --since-green --known-failures
   <run>/baseline-failures --flakes <run>/flakes` (when only docs changed since stage 5's green full run,
   it runs the fast set and reuses that run) and `bash $S/state.sh contract-sync` must both pass (every check green, every criterion `passes`). A
   failure is a defect: `bash $S/state.sh stage 5 --why "<what failed>"` and the fix loop, without recording
   anything. Then `n=$(bash $S/state.sh round evidence)`. Beyond `limits.evidence_rounds`: stop and ask.
2. **Record.** First request (or after a spec gap, which changes criteria): `bash $S/evidence.sh capture`,
   every criterion. A later round, after fixes or cosmetic changes: `bash $S/evidence.sh capture --ac
   AC-3 --ac AC-7` with only the criteria whose tests or behaviour the fixes touched (the fix commits
   name them); every other criterion keeps its earlier recording (the pack shows the commit it was
   recorded at). It runs the `@AC-n` e2e specs under `playwright.demo.config.ts` (a
   video with the test title, steps and actions overlaid, and a screenshot, per test and per
   `evidence.viewports` size), converts the videos to mp4 when ffmpeg is available, and writes
   `<run>/evidence/` with `manifest.json`. With `evidence.driver: command` it runs `evidence.capture`;
   with `none` it records test results only. A demo test failing on camera after a green preflight is a
   flaky test: back to stage 5 with `--why`, not another recording. Exit 1 means nothing was recorded: read
   `<run>/evidence/run.log` (often a missing browser: `npx playwright install chromium`) and fix it
   before asking anyone to review. Exit 2 is a config problem; a missing demo config: copy
   `${CLAUDE_PLUGIN_ROOT}/templates/playwright.demo.config.ts` to the project root and commit it (it
   isn't one of the frozen check-defining files). When the project's Playwright runs elsewhere (a subdirectory, a
   container), put the config there and set `evidence.playwright` to the command that runs it; the
   config's `evidence` section isn't frozen.
3. `bash $S/evidence.sh pack`: builds `<run>/review-pack/index.html` (per criterion: text, level, pass,
   its demo tests and a card per viewport with the video and screenshot; then the advisory findings from
   `<run>/advisory.json`, spend by stage and the PR link), self-contained with relative paths. When
   `evidence.publish` is set it uploads the folder and prints `url: <url>`.
4. Human gate (SKILL.md "Human gates"). **PR run**: commit and push, then `bash $S/pr.sh
   request-approval evidence --details -` with the pack's URL (`evidence.publish`; without it, say the
   pack is local at its path and attach nothing), the criteria table from contract.json, and the
   advisory findings, with the confirmed flakes (`<run>/flakes`) as advisory lines; then wait. **Terminal run**: give the pack's path or URL, the criteria table, and
   the advisory findings; options approve, comment, stop. Comments go to
   `docs/specs/<slug>/feedback/evidence-<n>.md` either way (pr.sh writes them on a PR run).
5. **Approve** (`approved` from pr.sh, or the terminal answer, then `bash $S/state.sh approve evidence
   $(git rev-parse HEAD)` on a terminal run only): go to 7. The PR stays a draft until the merge. This is the last
   approval: stage 7 merges and deploys on it (on a terminal run, say so when you ask).
   **Analysis.** On a PR run pr.sh posts it on the issue with the approval (`📊 Analysis`): time, tokens
   and money per stage and agent, waits for the person, loops back with their reasons, repeated or slow
   steps, and what to change. On a terminal run, `bash $S/state.sh analysis --md` and show it. Mention
   its first two "What to change" points to the user in one line each.
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
   Then capture lessons per learning.md, and ask the user again when everything is routed. On a PR
   run, `bash $S/pr.sh publish note` with how each comment was routed before the new request.
