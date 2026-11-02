# Stage 5: review and fix

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. `state.sh stage 5`, `phase review`. Base: `state.sh get .base`.

1. `n=$(bash $S/state.sh round review)`. Beyond `limits.review_rounds`: stop and ask the user.
2. Retrieval: `learnings-researcher` (low) with the diff stat (`bash $S/change-diff.sh <base> --stat`).
3. Mechanical checks: `bash $S/run-checks.sh --set all --known-failures <run>/baseline-failures` and
   `bash $S/state.sh contract-sync`. Failures go straight to the fix loop (step 7) as blocking findings.
4. **Depth.** `limits.depth`: `lite` or `full`; `auto` means `lite` when the diff (tracked and new files,
   `--stat`) is under `limits.lite_max_lines` lines and touches nothing on `risk_list` (judge by paths
   and content: auth, payments, personal data, crypto, migrations, public API, concurrency,
   dependency files). Record it: `state.sh history '.depth = $d' --arg d <lite|full>`.
5. **Lenses**, one read-only batch, in parallel, each briefed with the base, the spec paths, the
   learnings, and its own lens only:
   - lite: `reviewer-correctness`, `reviewer-spec` (high).
   - full: plus `reviewer-security` (high; `xhigh` when the diff touches the risk list) and
     `reviewer-maintainability` (medium, advisory).
   - In the same batch: start the app (`project.start` with `FACTORY_PORT`, poll `project.url` +
     `project.ready`) and spawn `qa-evaluator` (high) with the criteria and the URL. Stop the app after.
6. **Challenge** (full depth only): for each blocking finding, a `challenger` (high) tries to refute it,
   all in parallel. A refuted finding becomes advisory, and the lens that raised it gets a calibration
   line only when the refutation has execution evidence.
7. **Fix loop** for each confirmed blocking finding and each QA fail:
   test-author (a failing test that reproduces it, tagged with the criterion it violates, or a new
   regression test) → red check → test-reviewer → `state.sh freeze` (extends the freeze) → a **fresh**
   implementer at `high` → checks and contract-sync as in stage 4b.
8. Re-review only with the lenses that blocked (and QA, if it failed), then back to step 1.
9. Self-improvement (learning.md): one calibration line for each agent that missed a confirmed issue
   later found by another lens, QA or a human; ce-compound for each fixed or escalated blocking finding
   that generalises. Advisory findings are listed at the stage 6 gate, not fixed automatically.
10. All clear: commit, push, go to stage 6.
