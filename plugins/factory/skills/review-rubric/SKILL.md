---
name: review-rubric
description: factory's review rubric for PRDs, tests, code lenses and QA, with severity rules and the finding format. Preloaded into factory's reviewers; not for direct use.
user-invocable: false
---

# Review rubric

Severity: **blocking** means the change would be wrong, unsafe, untestable or not what the PRD says;
**advisory** is everything else. A blocking finding needs evidence: a failing command, a quoted line, a
reproduction, or the PRD text it contradicts. Opinion without evidence is advisory at most. No findings
is a valid result; don't pad.

Each finding: what is wrong, where (file:line or PRD section / AC-n), why it matters, the smallest fix.

## PRD
In order:
1. **Testability.** Each criterion can be decided pass or fail by a test at the level it names; one
   behaviour per criterion; no unmeasured adjectives.
2. **State coverage.** Empty, loading, error, permission and first-use states for every view and action.
   A list or collection view without an empty-state criterion is a blocking gap.
3. **Scope.** Non-goals are stated and nothing in the criteria contradicts them; rollout and flag defined.
4. **Monitoring.** Signals with thresholds that would show the feature broken in production.
5. **Contract.** contract.json has exactly the PRD's criteria, ids AC-1..AC-n, `passes: false`.
6. **Plan.** Tests come first; Exceptions names every dependency or check-file change the steps need.
7. **Citation check, only when the PRD quotes a figure or a source.** The figure appears in the cited
   source (not an aggregator), the quote isn't inverted by what the source actually did, and its
   evidence class and sample size are stated.

## Tests (before the freeze)
1. Every criterion has at least one test, at the level the PRD names, tagged `@AC-n` in its title (or
   `AC_n` in the function name for Go and Swift), never with a suffix such as `@AC-1-extra`.
2. Every test fails against the unchanged code, at the expected assertion, for the expected reason. A
   test that passes early asserts nothing new or tests behaviour that already exists.
3. Assertions mean something: no `expect(true)`, no snapshot-only tests for behaviour, no asserting on
   mocks of the thing under test, no assertions that can't be reached.
4. An e2e test starts with an explicit presence check
   (`await expect(locator).toBeVisible({ timeout: 5000 })`) and its later assertions are reachable once
   the element exists. No fixed sleeps; no retries to hide flakiness.
5. Tests are deterministic: time, randomness, network and ports are controlled; the app's port comes
   from `$FACTORY_PORT`.

## Code lenses
- **Correctness** (blocking): logic errors, unhandled states the PRD names, races, resource leaks, error
  paths, data loss. Run the code or a test to show it.
- **Spec** (blocking): every criterion is implemented as written; nothing outside scope; docs, README
  and CHANGELOG match the behaviour.
- **Security** (blocking): authn/authz on every new path, input validation, injection, secrets in code or
  logs, unsafe deserialisation, dependency risk, personal data handling.
- **Maintainability** (advisory): duplication, naming, dead code, layering, test readability.
A lens reviews only its own concern; leave the others to their lenses.

## QA
One verdict per AC-n: pass or fail, each with evidence (screenshot path, trace path, or the observed
output). Behave like a skeptical user: try the empty, error and permission states, and the edges of
inputs. A criterion you could not exercise is a fail with the reason, never a pass.
