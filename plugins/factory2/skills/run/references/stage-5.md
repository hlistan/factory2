# Stage 5: review and fix

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. `state.sh stage 5`, `phase review`. Base: `state.sh get .base`.

1. `n=$(bash $S/state.sh round review)`. Beyond `limits.review_rounds`: stop and ask the user.
2. Retrieval: `learnings-researcher`, purpose `review`, with the diff stat (`bash $S/change-diff.sh <base> --stat`).
3. Mechanical checks: `bash $S/run-checks.sh --set all --known-failures <run>/baseline-failures` and
   `bash $S/state.sh contract-sync`. Failures go straight to the fix loop (step 7) as blocking findings.
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
   - In the same batch: start the app (`project.start` with `FACTORY_PORT`, poll `project.url` +
     `project.ready`) and spawn `qa-evaluator` with the criteria, the URL and the evidence directory
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
   2. Red check for the new tests only: `bash $S/run-checks.sh --set all --live --tail 20`, then
      `bash $S/state.sh red-check --test "<name>" [--test "<name>" ...]` (one `--test` per new test, its
      exact name from the test-author's report): each named test must fail (exit 0).
      `run-checks.sh --live` is right here: the config is frozen, so live and snapshot agree.
   3. test-reviewer (read-only batch) → commit → `bash $S/state.sh freeze` (extends the freeze).
   4. `bash $S/state.sh phase review`, then a **fresh** implementer at `high` → checks and
      contract-sync as in stage 4b.
8. **Re-review** (`state.sh round review` again; beyond `limits.review_rounds` stop and ask): step 3,
   then only the lenses that blocked, and QA if it failed, in one read-only batch, then steps 6-7 for
   their findings. Repeat until nothing blocks.
9. Self-improvement (learning.md): one calibration line for each agent that missed a confirmed issue
   later found by another lens, QA or a human; ce-compound for each fixed or escalated blocking finding
   that generalises. Advisory findings are listed at the stage 6 gate, not fixed automatically: write
   them, as the lenses reported them (`id`, `lens`, `severity`, `where`, `problem`, `fix`), as a JSON
   list to `<run>/advisory.json`, which `evidence.sh pack` reads.
10. All clear: commit, push, go to stage 6.
