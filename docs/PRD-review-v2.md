# Review of `docs/PRD.md` v2 (factory plugin, all-Claude phase)

Reviewed 2026-11-02 against the live sources on that date: Anthropic platform docs, the three Anthropic engineering posts, Claude Code docs and changelog through 2.1.316 (the installed version), the `anthropics/claude-code` issue tracker, the `EveryInc/compound-engineering-plugin` repo at `main`, Playwright 1.64.1 docs and source, Kiro docs, and every third-party source in the PRD's Sources list. Verdicts: TRUE, PARTLY, FALSE, NOT FOUND. Design findings are grounded in the same sources plus the singularity 0.7.0 scripts the PRD plans to port.

## Verdict

v2 is a real improvement. Every v1 finding was applied, the architecture is sound, and almost every platform mechanic now checks out. The remaining problems are of three kinds.

Five items will break or weaken the build at M1 and M3, and three of them come from sources the PRD trusts:

1. The `~3.34` dependency range cannot resolve: compound-engineering has no tags in the format Claude Code resolves against, and because its marketplace source is a relative path the install silently takes the current copy and then disables factory the day 3.35.0 ships.
2. `disallowedTools: ["Skill(compound-engineering:*)"]` removes the whole Skill tool. The docs say so explicitly.
3. Issue #86809 was retracted by its own author six minutes after filing. Issue #105625 is about `CwdChanged` hooks only. The init workaround and the git-source-only test premise built on them have no basis.
4. The test freeze does not cover the files that define what "the checks" are: `package.json` scripts, the unit-runner config, `tsconfig`, lint config and `.factory/config.yaml`. An implementer under SubagentStop pressure can edit `npm test` instead of a frozen spec.
5. The low-effort re-run policy is borrowed from a measurement whose failure signal was the benchmark's hidden tests. Here the failure signal is tests written by the same opus · low implementer.

A second group is evidence that was cited for something it does not say. v1 fixed misattribution; v2 introduced a subtler problem, quotes that are real but inverted or stretched. The clearest case is the harness-design post being used to justify hiding rubrics from the implementer when that post gave the criteria to both agents.

A third group is design gaps a harness engineer would hit while building: an unenforced memory-write rule, a tag mismatch in `contract-sync`, committed append-only files under parallel worktree runs, a missing PR step, a CI incident path that cannot run the triager, an unspecified spend mechanism, and no eval suite for the agents themselves even though `claude plugin eval` now exists.

## 1. Fix before M1

### 1.1 `~3.34` cannot pin compound-engineering, and will disable factory on the next minor release

**What the PRD says.** `dependencies: [{name: "compound-engineering", marketplace: "compound-engineering-plugin", version: "~3.34"}]`, with M1 validating "the `~3.34` dependency syntax".

**What the sources say.**

- Claude Code resolves a version constraint against git tags named `<plugin-name>--v<version>` (double dash): "Tag each release as `<plugin-name>--v<version>`" and "the dependency installs from the highest `secrets-vault--v` tag that satisfies `~2.1.0`" (https://code.claude.com/docs/en/plugins/dependencies.md).
- compound-engineering's tags are `compound-engineering-v3.34.0` (single dash). A query for refs matching `compound-engineering--v` returns zero tags. Its marketplace entry uses `"source": "./"`, a relative path.
- For a relative-path source with no satisfying tag, the docs say: "the install uses the marketplace's current copy instead, and the constraint is checked when the plugin loads. If that copy is outside the range, the dependent plugin stays disabled and `claude plugin list` shows `Requires ... ~2.1.0, installed 3.0.0`."
- compound-engineering has shipped 88 v3 releases since 2026-04-22. 3.35.0 is a matter of days or weeks.

**Consequence.** The range gives no pin today and a hard outage later. `claude plugin validate --strict` will pass because the syntax is fine; the failure is at install and load time, which M1 does not test.

**Recommendation.** Declare a floor only, `>=3.21.1` (the `mode:non-interactive` rename), and move the real protection to the M1 contract test, run by `/factory:init`, after every `/plugin update`, and at the start of each `/factory:run`, with the resolved version recorded in `runs.jsonl`. If a true pin is wanted, the only routes are asking upstream to publish `compound-engineering--v*` tags via `claude plugin tag --push`, or hosting a fork in the factory marketplace with your own tags. Add to M1: a dependency-resolution test that installs factory from a git-source marketplace and asserts `claude plugin list` shows compound-engineering enabled, and a negative test with a range the installed version does not satisfy.

### 1.2 `disallowedTools: Skill(compound-engineering:*)` removes the Skill tool entirely

**What the PRD says.** Every non-orchestrator agent sets `disallowedTools: ["Skill(compound-engineering:*)"]`; the M1 smoke test checks that the syntax works, with a fallback to disallowing `Skill` and preloading via `skills:`.

**What the sources say.** https://code.claude.com/docs/en/sub-agents.md: "A `disallowedTools` entry with a specifier, such as `Bash(git push *)`, still removes the whole tool from the subagent, not only the matching commands. To keep Bash and block specific commands, add a Bash deny rule such as `Bash(git push *)` to `permissions.deny` in your settings." The permission-rule syntax for skills is `Skill(name)` or `Skill(name *)`; the docs add that "`Skill(anthropic *)` doesn't cover `anthropic-skills:pdf`", so there is no documented `Skill(plugin:*)` form (https://code.claude.com/docs/en/skills.md).

**Recommendation.** Make the fallback the design: `disallowedTools: ["Skill"]` on every non-orchestrator agent, with `skills:` preloading what each needs (up to 32, and not skills with `disable-model-invocation: true`). Drop the smoke test for the specifier syntax; it is settled. If per-skill denial is ever needed, it is a settings-level `permissions.deny` rule per skill name, session-wide.

### 1.3 Two of the plugin-hook issues do not say what the PRD says

**What the PRD says.** `/factory:init` "works around issue #105625 (plugin hooks don't fire unless a settings-level hook exists for the same event) by adding a no-op settings-level hook for SessionStart, PreToolUse and SubagentStop". M1 installs "from a git-source marketplace (directory-source installs don't run plugin hooks, issue #86809)".

**What the sources say.**

- #105625 is titled "Plugin-registered CwdChanged hooks never fire unless a settings-level CwdChanged hook exists (2.1.308)". Its body says "`SessionStart` from the same plugin always fires." Open, no fix through 2.1.316. https://github.com/anthropics/claude-code/issues/105625
- #86809 was closed NOT_PLANNED by its reporter six minutes after filing: "Closing this — the report is wrong, and there is no bug here. My instrumentation was measuring a file that never executes." The corrected table says directory-source hooks run, from the live source tree. https://github.com/anthropics/claude-code/issues/86809
- The docs describe no dependency of plugin hooks on settings hooks. Documented reasons plugin hooks do not fire: invalid `hooks.json`, a manifest-name collision between two enabled plugins, wrong event-name case, and the `disableAllHooks` or `allowManagedHooksOnly` settings (https://code.claude.com/docs/en/plugins/troubleshooting.md). The only documented directory-vs-git difference is loading: relative-path plugins from a local-path marketplace load in place and get a `CLAUDE_PLUGIN_ROOT` pointing at the source directory (https://code.claude.com/docs/en/plugins/loading.md).

**Recommendation.** Remove the no-op settings hooks from `/factory:init`; factory uses none of `CwdChanged`. Keep the M1 hook-firing test, which is good engineering regardless, but run it from both a git-source and a directory-source marketplace, and state the real risk it guards: the deploy guard and freeze are safety gates. Keep the name-collision caveat in mind: the plugin is named `factory`, a plausible name for another marketplace's plugin.

### 1.4 The freeze protects the tests but not the definition of "the checks"

**What the PRD says.** Freeze covers spec files, Playwright config, fixtures and test helpers. SubagentStop runs `checks.fast` (`npm run lint`, `npm run typecheck`, `npm test`) and blocks on failure up to 3 times.

**What the gap is.** The ported `test-guard.sh pre-edit` blocks edits only to paths in `frozen-tests.txt`. Nothing stops the implementer from editing `package.json` so `npm test` excludes the failing spec, adding `testPathIgnorePatterns` to the Jest or Vitest config, loosening `tsconfig.json`, disabling an ESLint rule, or, since it is a committed file in the repo, editing `.factory/config.yaml` to change `checks.fast.unit` itself. The SubagentStop block message says "never weaken, skip or delete a test or a check", which is a prompt, not a mechanism.

**Evidence that the gap matters.** METR: frontier models were "attempting (often successfully) to get a higher score by modifying the tests or scoring code"; the concrete examples are an evaluator monkey-patched "to always return a perfect score" and an overwritten equality operator, scoring machinery rather than test files (https://metr.org/blog/2025-06-05-recent-reward-hacking). The New Stack test the PRD already cites: Fable 5.1 "deleted the simulated delay in all five runs, so the test always passes" (https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/). Anthropic's own harness relied on "strongly-worded instructions" and JSON because "the model is less likely to inappropriately change or overwrite JSON files"; it did not claim this was sufficient (https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

**Recommendation.** At freeze time, hash a second list, "check-defining files": `package.json`, lockfile, the unit and e2e runner configs, `tsconfig*.json`, lint and format configs, CI config, and `.factory/config.yaml`. `test-guard pre-edit` blocks edits to them during stage 4(b); `subagent-stop.sh` re-verifies the hashes before running checks and treats a changed hash as a failed check. Have `run-checks.sh` read the check commands from a snapshot taken at freeze, not from the live config. Legitimate dependency additions go through a named exception in `plan.md`, which `test-guard check --plan` already supports.

### 1.5 The failure signal for the opus · low policy is written by the same opus · low agent

**What the PRD says.** The implementer at opus · low writes the `@AC-n` tests (a), then the code (b); failures re-run at opus · high in a fresh subagent, "the measured Anthropic configuration".

**What the source says.** The measurement's two conditions are stated on the page: "First, you need a failure signal (here, the benchmark's own tests); a checker that passes bad work lets those failures through." The tests were the benchmark's hidden tests, written by humans, not by the agent under test. The results are "Anthropic-internal and directional, not guarantees, so measure on your own workload" (https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence). The effort page describes `low` as "Significant token savings with some capability reduction" for "Simpler tasks ... such as subagents" (https://platform.claude.com/docs/en/build-with-claude/effort).

**Why it matters here.** The test-reviewer catches weak tests, but it reviews what a low-effort author produced; a thin test suite with correct-looking assertions passes review and then passes bad code. The freeze then makes that oracle permanent for the run.

**Recommendation.** Split (a) from (b) by effort: write tests at opus · high (tests are a fraction of the tokens of the code they test), then code at opus · low with re-runs at high. This keeps the measured saving where the volume is and buys the oracle with the cheap part. Record first-pass rate and QA false negatives per effort in `stats`, which is what the page tells you to do.

## 2. Evidence cited for something it does not say

### 2.1 The rubric-hiding rationale inverts its source

**What the PRD says.** The implementer sees "the ACs (the shared contract), not reviewer rubrics or memories, so evaluation stays independent. *Harness design*: 'the wording of the criteria steered the generator'."

**What the source says.** The sentence is real, from the frontend experiment, and the author gave the criteria to both sides: "I wrote four grading criteria that I gave to both the generator and evaluator agents in their prompts." The steering was read as useful: "outputs were noticeably better than a baseline with no prompting at all, suggesting the criteria and associated language themselves steered the model away from generic defaults". In the full-stack harness, generator and evaluator "negotiated a sprint contract" together, and the generator was "instructed to self-evaluate its work at the end of each sprint before handing off to QA" (https://www.anthropic.com/engineering/harness-design-long-running-apps).

**Recommendation.** Keep the design if you want it; there is a Goodhart argument for not teaching the implementer the grader's exact words. But state it as a design choice without a citation, and let `stats` test it: run some features with rubric-visible implementers and compare review rounds.

### 2.2 Three more harness-design quotes are stretched

- **"errors in the spec would cascade"** is the post's reason to keep the planner high-level and off "granular technical details", not evidence that planner output is "unverifiable until review". The post never discusses verifying planner output. The PRD's plan-review stage is reasonable on its own; the quote does not support it.
- **"the fix is hard per-criterion thresholds and tuning from its logs."** The stated fix for the lenient evaluator was the tuning loop: "read the evaluator's logs, find examples where its judgment diverged from mine, and update the QAs prompt", plus "few-shot examples with detailed score breakdowns" for the frontend evaluator. Hard thresholds are an architectural detail of the Opus 4.5 sprint evaluator described earlier in the post. Per-criterion pass/fail with evidence is still a good design, and post 2 uses exactly that (`passes: false` per feature), but the PRD should cite the tuning loop as the fix and build it: the qa-evaluator's logs are reviewed at each QA false negative, and its prompt gets a few-shot example from the miss.
- **Per-role models.** The post ran one model for every role (Opus 4.5, then 4.6) and says nothing about effort. Any reading of it as support for per-role model or effort tuning is not in the source. The PRD's table does not claim this directly, but the "Harness design" citations in the model column suggest it; move them to the role descriptions.

### 2.3 "Came out ahead in every case measured" is scoped to earlier models

The full sentence: "the orchestrator's model alone at lower effort came out ahead in every case measured on earlier models", with delegation measured using "workers on Claude Sonnet 5, an earlier model". The one current-model datapoint on the page points the other way or sideways: Haiku 5.5 subagents under Opus 5.5 at `medium` "cut cost per attempt by 32% and the pass rate by about 4 percentage points", "an alternative to lowering effort, not better" (https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence). The PRD's conclusion, Opus everywhere, still follows; the quote needs its qualifier.

### 2.4 The fresh-spawn rationale is wrong even though the decision is right

**What the PRD says.** "A fresh spawn avoids the prompt-cache invalidation from changing effort mid-session."

**What the sources say.** A fresh subagent starts with no conversation prefix, so there is no cache to preserve; a fresh spawn forfeits the cache completely rather than avoiding an invalidation. Separately, on Opus 5.5 the cache survives an effort change anyway: "On Claude Fable 5.1, Claude Mythos 5.1, Claude Opus 5.5 ... use a per-message effort change, which keeps the prompt cache" (https://platform.claude.com/docs/en/build-with-claude/effort; the invalidation row on https://platform.claude.com/docs/en/build-with-claude/prompt-caching says the same). Whether Claude Code uses the per-message form is not documented, so do not rely on either direction.

**Recommendation.** Keep the fresh subagent and cite the actual reasons: a clean context that starts from the failure report, and no accumulated wrong assumptions. Post 2 is the right source for that ("finding a way for agents to quickly understand the state of work when starting with a fresh context window"), with the caveat from post 1 that Opus 4.5 and later needed context resets less.

### 2.5 The review-evidence figures need the precision the PRD's own rubric demands

The PRD's stage 2 rubric requires every figure to carry "the evidence class (vendor, community or peer-reviewed) and sample size". The Models table does not meet it. Corrections:

| PRD text | What the source says | Class, n |
|---|---|---|
| CodeRabbit: "Opus 5.5 recall 63.8% vs 61.3% ... with 40–60% more tokens" | 63.8% is the **Standard** config (51/80); Max was 62.5%. Precision fell: 38.6% and 35.7% vs 39.3%. Tokens +49.2% and +57.6% on the 80-case set, +40.6% and +60.1% on the 13-case Signal set. "Production mix" is undefined. Standard "caught 11 open-source issues that the baseline missed, but missed nine that the baseline caught." | Vendor, n=80 (+13), judge-graded, single run, a 2-bug gap |
| Bug Hunt Bench "43 (one run) vs Opus 41.7 (three runs)" | Correct, but the metric is bugs **fixed** with the fix verified in the diff, not bugs found; the README reports a 9-point run-to-run range on one config and says "a single run is not a measurement of a model". Sonnet 5.5 at max leads at 51.3. | Community, single maintainer, n=105 bugs, answer key private |
| The New Stack "5/5 vs 3/5" | 5 of 5 **runs** vs 3 of 5 runs on the concurrency test, each run needing 3 race conditions fixed; Opus's two misses hit the 128K output cap. The same article: Fable "deleted the simulated delay in all five runs" on a flaky test while Opus "left the code alone in all five runs" and the author scored that test to Opus. | Journalist, one author, 5 runs per test |
| "Review rarely beats the stronger model alone (Zhang & Shrestha 2026)" | Correct title and finding (9 of 96 directions), but a 3-week-old preprint on open-weight models of 3B to 72B, reviewing final answers on QA benchmarks, not code diffs. | Preprint, not peer-reviewed |
| "Self-correction without outside feedback doesn't help (Huang et al., ICLR 2024)" | Correct. 2023-era models, reasoning benchmarks. | Peer-reviewed |
| "*Your Agent May Misevolve* (ICLR 2026) ... The paper's own mitigation is to frame memory as reference material" | Correct. The paper's phrasing is treat memories "as 'references,' rather than 'rules'"; the effect was partial (attack success 20.6% to 13.1%) and the authors call it "preliminary". | Peer-reviewed, small eval sets |
| MemoryGraft; *When Agents Remember Too Much* | Both exist and are about memory poisoning. Testbeds: MetaGPT DataInterpreter on GPT-4o; personal-assistant agents. | Preprints |

The flaky-test behaviour is relevant beyond citation hygiene: it is a documented instance of the exact failure the freeze exists for, from the model the PRD offers as the security-lens override. Mention it where Fable is discussed.

### 2.6 The learnings-researcher pin names the wrong commit

**What the PRD says.** The port is "pinned to commit `64b74f2`".

**What the source says.** `64b74f2` exists (2026-11-01, "test(skill-eval-cell): grade the remaining handoff rows from recorded calls (#1970)") and touches only `tests/skill-eval-cell/*`. The last commit to `skills/ce-plan/references/agents/learnings-researcher.md` is `f2762dd` (2026-09-22, #1757). The v1 review used `64b74f2` as "the repo at commit" for its own check; it was never the file's commit. Pin `f2762dd`, or better, pin the file's blob hash, which is what actually identifies the content.

## 3. Design gaps

### 3.1 "Memory writes happen only on a calibration message" is a wish, not a mechanism

The docs say a memory-enabled subagent gets Read, Write and Edit "automatically enabled so the subagent can manage its memory files", and its system prompt carries "instructions to curate `MEMORY.md`" (https://code.claude.com/docs/en/sub-agents.md). Every memory agent is therefore told to write memory as it works. The `change-diff.sh --hash` check catches reviewer writes *outside* `.claude/agent-memory/`; nothing catches unsanctioned writes *inside* it. The PR review of learning files is the only real safeguard, and it reviews after the fact.

**Recommendation.** Either enforce it, a PreToolUse `Edit|Write` hook that blocks paths under `.claude/agent-memory/` unless `state.json` has an open calibration for that agent, or drop the sentence and keep the PR review and the "reference, not rules" line as the stated mitigations. The hook input for subagent tool calls should be checked at M1 for an `agent_type` field so the rule can be scoped per agent.

Also correct: "memory agents' `tools` must include Read, Write and Edit" is not required; they are auto-enabled. Harmless, but the PRD states it as a rule from the docs. The `<plugin>-<agent>` directory name is observed in #103308, not documented anywhere; the smoke test stays.

### 3.2 `contract-sync` will not find `@AC-n` as written

Playwright's JSON reporter strips the `@`: `tags: test.tags.map(tag => tag.substring(1))` in `packages/playwright/src/reporters/json.ts`, so `@AC-1` appears as `"AC-1"` in `spec.tags`, with per-test outcome in `status` (`expected`, `unexpected`, `flaky`, `skipped`). Unit and integration runners (Vitest, Jest) have no tag concept; an `@AC-1` token in a test title is just text. The PRD says "reporter output mapped by `@AC-n` tags" without naming a format.

**Recommendation.** Require one normalized format from every runner: JUnit XML (Playwright `junit`, Vitest `--reporter=junit`, Jest via `jest-junit`), and match `AC-\d+\b` in test names. A criterion is `passes: true` only when every test naming it passed and at least one exists. Also note `\b` is undocumented for Playwright's `--grep` but valid JavaScript regex; `-` is a non-word character, so quote it in the shell and make sure tags never take a suffix like `@AC-1-extra`.

### 3.3 "Failing at the expected assertion for the expected reason" does not fit e2e before the UI exists

A Playwright spec for a feature that does not exist yet fails at the first locator timeout, not at the behavioural assertion. The test-reviewer's criterion as written will reject every honest red e2e test or pass every one. Give e2e its own red standard: the first assertion is an explicit presence check (`expect(locator).toBeVisible()`) with a short timeout, and the reviewer checks that the later assertions would be reached once the element exists. For unit and integration tests, keep the criterion as is.

### 3.4 Parallel runs via `claude --worktree` conflict on committed files and ports

- `.factory/runs.jsonl` and `.claude/agent-memory/*/MEMORY.md` are committed on each feature branch. Two concurrent branches appending to the same file conflict at merge, and `gh pr merge --squash` refuses an unmergeable PR. Use one file per run (`.factory/runs/<slug>.json`, committed) and let `stats` glob them; make calibration append to a per-run file that the orchestrator folds into `MEMORY.md` once, at stage 7.
- `project.url: http://localhost:3000` is fixed in config, so two worktree runs start two dev servers on one port, and the qa-evaluator drives whichever answered. Derive a port per run and pass it to `start`, Playwright `webServer` and `url`.
- `claude --worktree` puts the worktree at `<repo>/.claude/worktrees/<name>`; `project` memory then lives inside it and only reaches `main` through the branch, which is fine, but say so.

### 3.5 Nobody opens the PR

"All learning files are committed on the feature branch and reviewed in the PR" and stage 7's `gh pr merge --squash` both assume a PR exists. No stage creates one. Open a draft PR at the end of stage 4, mark it ready at stage 6 approval, and record the PR number in `state.json`; stage 7's precondition "no commits since" then has something to check against.

### 3.6 The CI and cloud incident path cannot run the triager

The PRD says that on an anomaly "the triager correlates it with the deploy SHA". The triager is a plugin agent. Cloud sessions and scheduled tasks "don't install the plugins a repository turns on", while `.claude/skills/`, `.claude/agents/` and `.claude/commands/` in the repo do load (https://code.claude.com/docs/en/cloud-environments.md). So the GitHub Actions and cloud paths can run `monitor.sh` and file `incidents/I-n.md`, but not the triager, unless `/factory:init` also commits a copy of the triager agent to `.claude/agents/`. Decide which: commit the triager too, or define the CI path as detect-and-file only, with triage when the next local `/factory:run` resumes. Note `claude -p` in CI needs `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`; name it in the template.

### 3.7 The spend estimate has no named data source and the wrong price

"Subagent token usage times the price table" assumes the orchestrator can see subagent usage. The Agent tool result does not include it. The source that does is the SubagentStop hook input, which carries `agent_transcript_path` (added in 2.0.42), so `subagent-stop.sh` can sum usage from the transcript JSONL per spawn. The price table also needs the cache tiers: Opus 5.5 cache hits are $0.20 per MTok and 1-hour cache writes $8, so flat $4 input overstates a long implementer session several-fold (https://platform.claude.com/docs/en/about-claude/pricing).

### 3.8 There is no eval suite for the agents, and the tooling for one now exists

The e2e test covers one feature. Nothing measures the prd-reviewer, test-reviewer, lenses or qa-evaluator against known defects, so a prompt change in M4 can silently lower recall. Claude Code 2.1.316 ships `claude plugin eval`: cases under `evals/**/case.yaml` or `prompt.md` with `graders/*.md`, three runs per case by default, an optional no-plugin baseline arm, `--max-cost-usd`, and an HTML report. Seed it with fixtures: a PRD missing an empty-state criterion, a test that asserts nothing, a diff with a planted auth bypass, an AC the app fails. Run it per milestone and on every reviewer-prompt change. Also run `claude plugin details factory` at M1; it prints the projected token cost of 13 agent descriptions and 8 skills in every session that enables the plugin.

### 3.9 The citation-check rubric is a lesson about this document, not about feature PRDs

A PRD for "add a dark-mode toggle" cites nothing. Starting every stage 2 review with a citation check will be vacuous almost always. Make it conditional, "when the PRD quotes a figure or a source", so the rubric starts with what matters for features: testability of each criterion and coverage of states.

### 3.10 v1 no longer exists

Line 3 says v2 "applies every finding in `factory2/docs/PRD-review.md`, which reviewed v1 (`factory2/docs/PRD.md`)". The v1 file was overwritten at the same path and `factory2` is not a git repository, so the traceability table points at a version nobody can read. Run `git init` before M1 and keep the PRD under the same review-and-commit discipline the plugin imposes on target repos.

### 3.11 Effort control got simpler since v1 was written

- 2.1.292: "Added an `effort` parameter to the Agent tool, so Claude runs a sub-agent at the effort level you ask for." The orchestrator can spawn one `implementer` definition at `low` and again at `high`; no second agent or config switch is needed.
- 2.1.316: `CLAUDE_CODE_SUBAGENT_EFFORT` sets the default effort for subagents that name none.
- Frontmatter `effort` "Overrides the session effort level, but not the `CLAUDE_CODE_EFFORT_LEVEL` environment variable" (https://code.claude.com/docs/en/sub-agents.md). A user with that variable set gets no per-role tuning; `/factory:init` should warn.
- `model: fable` is a valid alias in agent frontmatter, so the `roles` example is fine as written.

### 3.12 Stage cost allocation

In Anthropic's V2 run, QA passes cost $3 to $4 each against build rounds of $37 to $71 (https://www.anthropic.com/engineering/harness-design-long-running-apps). If that ratio holds, `limits.depth` saves little; the implementer's effort policy and the number of fix rounds dominate spend. Keep `depth`, but let `stats` report spend by stage before tuning review breadth.

## 4. Citation corrections

| PRD claim | Verdict | What the source says | Source |
|---|---|---|---|
| Playwright 1.64.x with `video: {mode:'on', show:{...}}`, `page.screencast.showChapter()`, `showActions()` | PARTLY | The Screencast API shipped in **1.59** (`start`, `stop`, `showActions`, `showChapter`, `showOverlay`). 1.64 added `fps`, the `style` option replacing deprecated `fontSize`, and VP9 encoding. Test config key is `show: { actions: {...}, test: {...} }`; `showActions()` is the page method | https://playwright.dev/docs/release-notes, https://playwright.dev/docs/api/class-screencast |
| "`evidence.sh` converts WebM to H.264 mp4 with ffmpeg" | PARTLY | Output is WebM (VP9 since 1.64), but no Playwright page documents the container, codec or an ffmpeg step. Fine as practice; do not cite Playwright docs for it | https://playwright.dev/docs/videos |
| `--grep "@AC-1\b"` | TRUE | `--grep` is a regular expression; `\b` is valid but undocumented; `-` is a non-word character | https://playwright.dev/docs/test-cli |
| `playwright-cli` "more token-efficient" | TRUE | "CLI invocations are more token-efficient". Package is `@playwright/cli`, binary `playwright-cli`, fallback `npx playwright cli` (not `npx playwright-cli`) | https://github.com/microsoft/playwright-cli |
| Docker `mcr.microsoft.com/playwright:v<version>-noble` | TRUE | Also `-jammy` and a new `-resolute` (Ubuntu 26.04). `../factories` uses `v1.64.1-noble` | https://playwright.dev/docs/docker |
| Kiro EARS "WHEN … THE SYSTEM SHALL …" | TRUE | The feature-spec page documents that one template; the bug-fix page adds "WHEN … THEN the system SHALL …" and "SHALL CONTINUE TO". The `/docs/specs/concepts/` page is 404 | https://kiro.dev/docs/specs/feature-specs/ |
| Claude Code ≥ 2.1.311 "fixes SubagentStop firing about twice a minute" | TRUE | "Fixed `SubagentStop` hooks running about twice a minute for each running subagent instead of once when it finishes". Installed version is 2.1.316. 2.1.312 added a cap of 24 concurrent prompt and agent hooks per session | https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md |
| #103308 "the memory directory lands in the temporary worktree" | PARTLY | The issue's complaint is a stray empty `.claude/agent-memory/<agent>/` under the parent session's cwd; the subagent uses a memory dir inside its worktree. Open. The rule "never combine `memory` with `isolation: worktree`" still holds | https://github.com/anthropics/claude-code/issues/103308 |
| #92750, #92716 | TRUE | Both open and unfixed through 2.1.316. #92750 also reports the skill listing being injected; `omitClaudeMd: true` is the noted workaround | issue tracker |
| Fable "a Covered Model: 30-day retention, no zero data retention, a 400 error" | PARTLY | "not available under ZDR unless expressly authorized by Anthropic". The page's 400 example names Fable 5; Fable 5.1 is covered via the Covered Models list. A ZDR org can enable 30-day retention in one non-default workspace | https://platform.claude.com/docs/en/manage-claude/api-and-data-retention |
| Haiku 5.5 $0.10/$0.50 | PARTLY | Prompts over 100K tokens pay $0.50/$2.50. Unused by factory now | https://platform.claude.com/docs/en/about-claude/pricing |
| Effort page: "low suits subagents and simple tasks" | TRUE | "Simpler tasks that need the best speed and lowest costs, such as subagents". Opus 5.5 default is `medium`; all five levels available | https://platform.claude.com/docs/en/build-with-claude/effort |
| compound-engineering two-track schema | PARTLY | `applies_when` is a knowledge-track optional field, not a both-tracks optional; `symptoms` max 5; bug track also has optional `framework_version`; `problem_type` is a closed enum of 17 values, `severity` and `resolution_type` closed too; `component` and `root_cause` open since v3.22.0 | `skills/ce-compound/references/schema.yaml` |
| ce-compound "can auto-trigger on phrases like 'it's fixed'" | PARTLY | The skill description does not mention phrases. `references/modes.md`: completion phrases "identify the completion checkpoint; they do not establish that a learning is worth documenting. Auto-invoke only when the Preconditions in `SKILL.md` qualify". The risk is real but gated | `skills/ce-compound/references/modes.md` |
| "added the durable-bar gate in 3.x" | PARTLY | v3.25.0 release note: "**ce-compound:** gate capture on durable knowledge (#1624)". "Durable bar" is the marker name in SKILL.md. Release notes live in GitHub Releases, not `CHANGELOG.md` (that file is the CLI's, ending at 3.13.1) | https://github.com/EveryInc/compound-engineering-plugin/releases |
| Final line `Documentation complete` / `Documentation skipped`; `Refresh recommendation:` line | TRUE | Defined in `skills/ce-compound/references/report.md`; header line is `✓ Documentation complete (non-interactive mode)`, so final-line parsing is right. Non-interactive mode never invokes refresh | repo |
| "runs on 14 agent hosts", 25.8k stars, v3.34.0, MIT, `ce-setup`, install commands, `docs_root` default `docs` | TRUE | All verbatim | repo and README |
| Puppeteer in effective-harnesses | TRUE | Post 2 uses the Puppeteer MCP; post 1 uses the Playwright MCP | both posts |
| "removing one component at a time" | TRUE | Verbatim. The post's criterion is impact on the final result after each removal, not whether a loop fires; `stats` should measure what `full` caught that `lite` missed, which the PRD already plans | post 1 |

## 5. Claims that checked out

- Re-run table: "`low`, failures re-run at `high` | About 97% | About $0.17 USD" vs "Everything at `high` | 95.3% | $0.29 USD", Opus 5.5, 478 of a 482-problem SWE-bench Pro subset "not comparable to the public leaderboard", two runs averaged, with both stated conditions. "Use this policy for the saving, not the lift."
- "Tune one model before you add a second ... Build a pairing only if it beats the single model's whole curve of score against spend."
- "Most workloads start with Claude Opus 5.5." Prices for Opus 5.5, Sonnet 5.5 and Fable 5.1.
- Planner $0.46 of $124.70; "the generator under-scoped"; "Out of the box, Claude is a poor QA agent"; separation of generator and evaluator "proves to be a strong lever".
- `memory: project` at `.claude/agent-memory/<name>/`, 200 lines or 25 KB injected, disabled entirely when auto memory is off; supported plugin-agent fields include `memory`, `effort`, `skills`, `isolation`, `disallowedTools`; `mcpServers`, `hooks`, `permissionMode` ignored for plugin agents.
- SubagentStop matcher is the plugin-scoped `^factory:implementer$`; input has `agent_type`, `agent_id`, `agent_transcript_path`, `last_assistant_message`; exit 2 keeps the subagent working; 8-consecutive-continuation cap, reset by each tool call; default command timeout 600 s, explicit `timeout` honoured.
- `allowCrossMarketplaceDependenciesOn` on the root marketplace; `claude plugin validate --strict`.
- `/loop`: idle only, 7-day expiry, no catch-up; cloud scheduled tasks reject sub-hourly cron; cloud sessions never install plugins; `--max-budget-usd` is print-mode only and counts subagents; `claude --worktree` exists.
- `model: fable` is a valid agent alias; `effort` accepts `low` to `max`.
- Kiro uses EARS; healer "Suggests a patch" and may output "a skipped test", so excluding it is right.
- The singularity scripts do what the PRD says: `subagent-stop.sh` counts blocks per `agent_id`, honours a baseline-failures file and exits 2 with the failing output; `test-guard.sh` freezes by git blob hash and blocks `Edit|Write|NotebookEdit` on frozen paths; `change-diff.sh --hash` hashes HEAD, status and the whole change; `guard-bash.sh` calls itself "a seatbelt against mistakes, not a security boundary". Port that sentence into the PRD's Risks.

## 6. Suggested edits to the PRD, in order

1. Replace `version: "~3.34"` with a floor and a contract test at init, update and run start; add the dependency-resolution test to M1 (1.1).
2. `disallowedTools: ["Skill"]` plus `skills:` preloading on every non-orchestrator agent; delete the specifier smoke test (1.2).
3. Remove the #105625 no-op hooks from `/factory:init` and the #86809 citation; keep the hook-firing test on both source types (1.3).
4. Add a check-defining-files freeze list and snapshot the check commands at freeze; SubagentStop verifies hashes first (1.4).
5. Tests at opus · high, code at opus · low with re-runs at high; record outcomes per effort in `stats` (1.5).
6. Rewrite the four harness-design citations and the "every case measured" quote; replace the fresh-spawn rationale (2.1 to 2.4).
7. Add evidence class and sample size to every row of the Models table, per the PRD's own rubric; fix the New Stack and CodeRabbit wording (2.5).
8. Pin learnings-researcher to `f2762dd` or the file's blob hash (2.6).
9. Enforce or drop the memory-write rule; drop "tools must include Read, Write and Edit" (3.1).
10. Specify JUnit XML as the reporter contract and `AC-\d+\b` matching (3.2); give e2e its own red criterion (3.3).
11. One committed file per run; per-run port; open a draft PR at the end of stage 4 (3.4, 3.5).
12. Decide the CI incident path: commit the triager or make CI detect-and-file only (3.6).
13. Name `agent_transcript_path` as the spend source and add cache tiers to the price table (3.7).
14. Add `evals/` with `claude plugin eval` cases per milestone; run `claude plugin details` at M1 (3.8).
15. Make the citation check conditional; `git init` factory2 (3.9, 3.10).
16. Apply the citation corrections in section 4: Playwright 1.59, `show:` config key, `@playwright/cli`, Covered Models wording, the schema details, the issue rewordings.

## Sources

- Anthropic platform: https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence · https://platform.claude.com/docs/en/build-with-claude/effort · https://platform.claude.com/docs/en/build-with-claude/prompt-caching · https://platform.claude.com/docs/en/about-claude/models/choosing-a-model · https://platform.claude.com/docs/en/about-claude/pricing · https://platform.claude.com/docs/en/manage-claude/api-and-data-retention
- Anthropic engineering: https://www.anthropic.com/engineering/harness-design-long-running-apps · https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents · https://www.anthropic.com/engineering/building-effective-agents
- Claude Code docs: https://code.claude.com/docs/en/sub-agents.md · https://code.claude.com/docs/en/hooks.md · https://code.claude.com/docs/en/memory.md · https://code.claude.com/docs/en/skills.md · https://code.claude.com/docs/en/permissions.md · https://code.claude.com/docs/en/plugins/components.md · https://code.claude.com/docs/en/plugins/dependencies.md · https://code.claude.com/docs/en/plugins/loading.md · https://code.claude.com/docs/en/plugins/troubleshooting.md · https://code.claude.com/docs/en/plugins/manifest-reference.md · https://code.claude.com/docs/en/plugins/marketplace-reference.md · https://code.claude.com/docs/en/scheduled-tasks.md · https://code.claude.com/docs/en/routines.md · https://code.claude.com/docs/en/cloud-environments.md · https://code.claude.com/docs/en/cli-reference.md
- Claude Code changelog and issues: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md · issues #103308, #105625, #86809, #92750, #92716
- compound-engineering: https://github.com/EveryInc/compound-engineering-plugin (README, `.claude-plugin/marketplace.json`, `skills/ce-compound/SKILL.md`, `skills/ce-compound/references/{report,modes,schema.yaml,refresh-and-discoverability}.md`, `skills/ce-plan/references/agents/learnings-researcher.md`, releases)
- Playwright: https://playwright.dev/docs/release-notes · https://playwright.dev/docs/api/class-screencast · https://playwright.dev/docs/api/class-testoptions · https://playwright.dev/docs/test-cli · https://playwright.dev/docs/test-annotations · https://playwright.dev/docs/test-reporters · https://playwright.dev/docs/videos · https://playwright.dev/docs/docker · https://playwright.dev/docs/test-agents · https://github.com/microsoft/playwright-cli · `packages/playwright/src/reporters/json.ts`
- Kiro: https://kiro.dev/docs/specs/feature-specs/ · https://kiro.dev/docs/specs/bugfix-specs/
- Review evidence: https://www.coderabbit.ai/blog/opus-5-5-model-review · https://github.com/phuryn/bug-hunt-bench · https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/ · https://arxiv.org/abs/2610.15897 · https://arxiv.org/abs/2310.01798 · https://arxiv.org/abs/2509.26354 · https://arxiv.org/abs/2512.16962 · https://arxiv.org/abs/2607.06595 · https://metr.org/blog/2025-06-05-recent-reward-hacking · https://arxiv.org/abs/2511.18397
- Local: `~/.claude/plugins/cache/singularity/singularity/0.7.0/scripts/*.sh`; `claude --help`, `claude plugin eval --help`, `claude plugin details --help` on 2.1.316
