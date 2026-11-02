# Stage 4: implement (tests first)

`S=${CLAUDE_PLUGIN_ROOT}/scripts`. Requires `approvals.prd`. Commit after every sub-phase.

## 4.0 Setup (`state.sh stage 4`)
- `bash $S/state.sh baseline`: records the checks that already fail on the unchanged code
  (`baseline-failures`); they never block this run. Tell the user if any.

## 4a Tests (`phase tests`)
1. Spawn `test-author` (high) with contract.json, the PRD's criteria and test levels, and the project's
   test conventions. It writes one or more tests per criterion, each tagged `@AC-n` in its title (or
   `AC_n` in a Go or Swift function name), and no product code.
2. **Red check (4a1).** `bash $S/run-checks.sh --set all --live --tail 20` (failures expected), then
   `bash $S/state.sh red-check`. `PASSES-EARLY` and `NOT-VISIBLE` lines go to the test-reviewer as
   findings; a suffixed-tag lint line goes straight back to the test-author.
3. **Test review (4a2).** Spawn `test-reviewer` (high), read-only batch, with the red-check output. On
   `revise`, send its findings to the test-author (fresh spawn, high) and repeat from step 2; after 3
   rounds, stop and ask the user.
4. **Freeze.** Commit the tests (`factory(<slug>): 4a tests`), then `bash $S/state.sh freeze`. It hashes
   the tests and the check-defining files and snapshots the check commands; it refuses when a
   check-defining file already differs from the base without a plan Exception, which you report to the
   user. From here, hooks block edits to frozen files and SubagentStop re-verifies them.

## 4b Code (`phase code`)
1. `n=$(bash $S/state.sh round impl)`.
2. Spawn `implementer`. **First pass: effort from `state.sh role implementer low`.** Brief: contract.json,
   the PRD's criteria, plan.md, the red test output, the port (`state.sh get .port`). Run it in the
   foreground (SubagentStop gates it on the fast checks and the freeze).
3. When it stops: `bash $S/state.sh verify-freeze` (exit 1: restore each changed or deleted file with
   `git checkout <frozen_sha> -- <path>` and delete each new check-defining file it names, record an
   incident, and treat the pass as failed; the freeze commit is always made before `state.sh freeze`, so
   `frozen_sha` holds the frozen files), then
   `bash $S/run-checks.sh --set all --known-failures <run>/baseline-failures --tail 40`, then
   `bash $S/state.sh contract-sync`. If `state.sh get '(.gate_timeouts // 0) + (.gate_errors // 0)'`
   grew during the pass, the stop gate didn't check this implementer (see `stop-gate.log` and
   `gate-errors.log` in the run directory): say so in the stage summary; your own checks above decide.
4. Record the pass: `bash $S/state.sh history '.implementer_passes += [{round: $r|tonumber, effort: $e, model: $m, passed: ($p == "true")}]' --arg r <n> --arg e <effort> --arg m <model> --arg p <true|false>`.
5. **Pass** = all checks green (outside the baseline) and contract-sync exits 0. Otherwise a **fresh**
   implementer at effort `high` (role override applied: `state.sh role implementer high`), briefed with
   the failure report: failing checks, contract-sync lines, its predecessor's final report. At most 2
   re-runs, then stop and ask the user.
6. If the implementer reports that a frozen test is wrong or a dependency is missing: don't let it
   proceed. Route a wrong test: `state.sh phase tests` → test-author → test-reviewer → commit →
   `state.sh freeze` → `state.sh phase code`. Route a missing dependency or a needed check-file change:
   planner adds it to plan.md's `## Exceptions` (committed) → the next implementer makes exactly that
   change (test-guard allows Edit/Write to a check-defining file the Exceptions name; dependencies are
   installed with the package manager) → `state.sh freeze` accepts it. Ask the user when unsure.

## 4c Docs (`phase docs`)
Same implementer spawn (or a fresh one at low) to update README, docs and CHANGELOG for the behaviour.
Re-run the fast checks.

## 4d Draft PR
Commit, `git push -u origin factory/<slug>`, run `ship.pr_open` from the config (`bash $S/state.sh config
.ship.pr_open`), and record the PR number: `bash $S/state.sh set '.pr = $n' --argjson n <number>`. A project
with no remote or an empty `pr_open` skips this; say so once.
