# Stage 5: review and fix

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. `state.sh stage 5`, `phase review`. Base: `state.sh get .base`.

1. `n=$(bash $S/state.sh round review)`. Beyond `limits.review_rounds`: stop and ask the user.
2. Retrieval: `learnings-researcher`, purpose `review`, with the diff stat (`bash $S/change-diff.sh <base> --stat`).
3. Mechanical checks, **in the background** (Bash `run_in_background`), started before the lenses:
   `bash $S/run-checks.sh --set all --known-failures <run>/baseline-failures --flakes <run>/flakes`, then
   `bash $S/state.sh contract-sync`. The lenses (step 5) read the committed tree while it runs; wait for
   both before step 6. Failures go to triage (step 3a), then to the fix loop as blocking findings.
3a. **Flake triage**, for each test that failed in a check: run it again alone, its check's command
   narrowed to it, `--repeat-each 3` (or the runner's equivalent) on every project that failed it, into
   `FACTORY_REPORTS=<run>/reruns/<check>` (never the check's own report folder, which contract-sync
   reads), then `bash $S/state.sh flaky --test "<name>"`. FLAKY means every rerun
   passed: when neither the test's file nor the code it exercises is in the change (`change-diff.sh
   <base> --stat`), it is a pre-existing flake: it is recorded, later runs pass over it (`--flakes`), it
   is listed at the stage 6 gate as advisory, and stage 7 offers to file it as an issue. It never opens
   a fix round in this run. FAILS, or a flake in code the change touches, is a blocking finding.
4. **Depth.** `limits.depth`: `lite` or `full`; `auto` means `lite` when the diff (tracked and new files,
   `--stat`) is under `limits.lite_max_lines` lines and touches nothing on `risk_list` (judge by paths
   and content: auth, payments, personal data, crypto, migrations, public API, concurrency,
   dependency files). Record it: `state.sh history '.depth = $d' --arg d <lite|full>`.
5. **Lenses**, one read-only batch, in parallel, each briefed with the base, the spec paths, the
   learnings, and its own lens only (`reviewer-spec` also gets the implementers' `deviations` from
   the approved plan.md, to judge whether each still meets the spec):
   - lite: `reviewer-correctness`, `reviewer-spec`.
   - full: plus `reviewer-security` (Fable 5.1 by default) and `reviewer-maintainability` (advisory).
     If the security spawn fails because the model isn't available to the account (Fable 5.1 isn't
     under zero data retention by default), re-spawn it once with model `opus` at the same effort, tell
     the user, and suggest `roles.reviewer-security: {model: opus, effort: high}` in the config.
   - In the same batch, unless the app shares the stack the background checks use (then after they
     finish, so neither disturbs the other's data and timing): start the app (`project.start` with `FACTORY_PORT`, poll `project.url` +
     `project.ready`) and spawn `qa-evaluator` with the criteria, the URL and the evidence directory (it records no media, only a
     screenshot for a visual fail)
     `<run>/evidence/qa/` (`<run>` from `bash $S/state.sh paths`; under `.factory/runs/`, git-ignored, so
     it doesn't trip the read-only hash). Stop the app after.
6. **Challenge** (full depth only): for each blocking finding, a `challenger` tries to refute it,
   all in parallel. `confirmed` stays blocking. `refuted` becomes advisory, and the lens that raised it
   gets a calibration line only when the refutation has execution evidence. `unproven` stays blocking
   and goes to the fix loop, whose first step (a failing test) proves or disproves it: if the
   test-author can't write a test that fails, the finding becomes advisory. At `lite` depth there is no
   challenger: every blocking finding counts as confirmed.
7. **Fix loop** for each confirmed blocking finding and each QA fail:
   1. `bash $S/state.sh phase tests` (test-guard lets only test-author edit frozen tests, and only in
      this phase). Spawn test-author: one failing test that reproduces it, tagged with the criterion it
      violates, or untagged when no criterion covers it. Its report lists the new tests' names.
   2. Red check for the new tests only: run just those tests, with the check's own command narrowed to
      them (e.g. a Playwright `-g "<title>"` on every project, a Go `-run`), **once**, writing their
      report into that check's folder (`FACTORY_REPORTS=<run>/reports/<check>`). A test that reproduces
      a timing-dependent failure (a flake in code the change touches) runs `--repeat-each 3` on the
      projects that matter, never more: three failures in a row prove it deterministic enough, and each
      extra repeat of a slow end-to-end test costs a minute. Then
      `bash $S/state.sh red-check --test "<name>" [--test "<name>" ...]` (one `--test` per new test, its
      exact name from the test-author's report): each named test must fail (exit 0). The whole suite
      runs once, after the fix (step 4), not on every iteration of a test or a fix.
   3. test-reviewer (read-only batch) → commit → `bash $S/state.sh freeze` (extends the freeze).
   4. `bash $S/state.sh phase review`, then a **fresh** implementer at `high`. When it stops, widen in
      three steps, each only once the one before passes:
      1. the targeted tests from step 2; while they fail, the next implementer gets that output;
      2. `bash $S/run-checks.sh --set affected` (exit 3: the project has no affected set, skip it), which
         runs only what the change touches and catches most regressions in minutes;
      3. commit, then the full checks once (`run-checks.sh --set all --known-failures … --flakes
         <run>/flakes`) and contract-sync, in the background, while the re-review (step 8) lenses read
         the commit. Their findings and the checks' failures (after step 3a) go into one fix round.
8. **Re-review** (`state.sh round review` again; beyond `limits.review_rounds` stop and ask): the full
   checks from step 7.4 (already running), with only the lenses that blocked, and QA if it failed, in
   one read-only batch, then steps 6-7 for
   their findings. Repeat until nothing blocks.
9. Self-improvement (learning.md): one calibration line for each agent that missed a confirmed issue
   later found by another lens, QA or a human; ce-compound for each fixed or escalated blocking finding
   that generalises. Advisory findings are listed at the stage 6 gate, not fixed automatically: write
   them, as the lenses reported them (`id`, `lens`, `severity`, `where`, `problem`, `fix`), as a JSON
   list to `<run>/advisory.json`, which `evidence.sh pack` reads.
10. All clear: commit, push, go to stage 6.
