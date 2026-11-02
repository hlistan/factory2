# Plan v3: `factory`, a Claude Code plugin for an 8-stage development harness (all-Claude phase)

v3 applies every finding in `factory2/docs/PRD-review-v2.md`. v1, v2 and the first review were overwritten in place and `factory2` has no git history. M0 restores them from this session's transcript into `docs/history/` and runs `git init`, so both traceability tables point at files someone can read. The v1-review table now lives in `docs/history/PRD-v2.md`. The **Review traceability** section at the end maps each v2-review item to its change.

## Context

You want a simple harness that runs one feature through eight stages: analysis and planning; PRD review by a model and a human; PRD fixes with self-improvement; implementation with unit, integration and Playwright tests plus docs; review and fix with self-improvement; screenshots and video for human approval; merge and deploy; and monitoring. It is built as a Claude Code plugin.

These decisions are unchanged from earlier rounds:

- **All-Claude this phase.** No local models and no OpenHands.
- **Every agent runs on Opus 5.5, with effort set per role.**
  - The implementer writes code at **low** effort, and failures are re-run at **high** (your choice).
  - Sonnet is a per-project override, used only when the project's own stats justify it.
- **Deploy and monitoring are generic per-project commands.**
- **Self-learning reuses existing tools:** compound-engineering plus Claude Code's built-in memory.
- **Replaces `singularity` 0.7.0** in three of the author's projects.
- **Built in** `~/src/factory2`.
- **Reused code:**
  - singularity's gate scripts (MIT): `guard-bash.sh`, `test-guard.sh`, `run-checks.sh`, `subagent-stop.sh` and `change-diff.sh`, from `~/.claude/plugins/cache/singularity/singularity/0.7.0/scripts/`
  - the Playwright approach from `../factories`

**Minimum versions:**

- Claude Code ≥ 2.1.311. That release fixed SubagentStop firing about twice a minute, and it includes the Agent tool's `effort` parameter, added in 2.1.292.
- Development uses the installed 2.1.316 for `claude plugin eval`.
- Playwright ≥ 1.59, which added the Screencast API. 1.64.x is recommended for VP9, `fps` and `style`.

## Models per agent

The orchestrator sets effort on every spawn through the Agent tool's `effort` parameter, and overrides models through its `model` parameter. One agent definition therefore serves several effort levels, and `roles` overrides need no file rewriting. Frontmatter holds only the default. No agent uses `max`.

| Agent | Model · effort | Rationale (evidence is in the next table) |
|---|---|---|
| Orchestrator (`/factory:run` skill, main session) | opus · high | Gates, routing, calibration lines, and ce-compound calls |
| `planner` | opus · high | Writes a **product-level** PRD. Technical detail goes in `plan.md`, which is advisory. The post's reason for keeping the planner high-level: "errors in the spec would cascade" (E5). |
| `prd-reviewer` | opus · high | Reviews in a fresh context, separate from the author (E11) |
| `learnings-researcher` | opus · low | Retrieval only; the caller re-checks what it returns (E3) |
| `test-author` (new) | opus · high | Writes the `@AC-n` tests, which become the failure signal for the low-effort policy. Tests are a small share of the tokens (E1). |
| `test-reviewer` | opus · high | A wrong frozen test is a wrong oracle for the whole run |
| `implementer` | opus · low on the first pass; opus · high in a **fresh** spawn for each re-run and fix round | Your choice, based on E1. The fresh spawn starts from the failure report and carries no wrong assumptions from the earlier attempt (E6). |
| `reviewer-correctness`, `reviewer-spec` (blocking) | opus · high | Execution evidence is preferred over opinion |
| `reviewer-security` (blocking) | opus · high; opus · xhigh on risk-list changes | Fable 5.1 only as an opt-in through `roles` (see the Fable note and E9) |
| `reviewer-maintainability` (advisory) | opus · medium | Advisory findings only |
| `challenger` | opus · high | Confirms each blocking finding. No memory, because challengers run in parallel. |
| `qa-evaluator` | opus · high | "Out of the box, Claude is a poor QA agent"; it improves through the tuning loop (E5) |
| `triager` | opus · high | Routes human comments; diagnoses incident issues for the bugfix run |
| `researcher` (optional) | opus · medium | Gathers outside facts; the planner and the gate re-check them |

- **Sonnet.** `roles.implementer: {model: sonnet, effort: medium}` is set only after `/factory:stats` shows parity on your own runs: first-pass rate, fix rounds, and defects found by humans. This follows "tune one model before you add a second" (E2).
- **Effort variables.**
  - `CLAUDE_CODE_EFFORT_LEVEL` overrides frontmatter `effort`, so `/factory:init` warns when it is set.
  - M1 checks whether it also overrides the Agent tool parameter.
  - `CLAUDE_CODE_SUBAGENT_EFFORT` is not needed, because every spawn names its effort.
- **Fable 5.1.**
  - It is "not available under ZDR unless expressly authorized by Anthropic". A ZDR org can enable 30-day retention in one non-default workspace.
  - In The New Stack's test it deleted a flaky test's simulated delay in all five runs (E9). That is exactly the failure the freeze below exists for.

**Prices per million tokens**, from the pricing page on 2026-11-02. `spend.sh` uses these rates.

| Model | Input | 5-minute cache write | 1-hour cache write | Cache hit | Output |
|---|---|---|---|---|---|
| Opus 5.5 | $4 | $5 | $8 | $0.20 | $20 |
| Sonnet 5.5 | $2 | $2.50 | $4 | $0.10 | $10 |
| Fable 5.1 | $10 | $12.50 | $20 | $0.25 | $50 |

Spend is an estimate at standard prices. It ignores fast mode (Opus 5.5 at $8 / $40) and the ×1.1 multiplier for US-only inference.

### Evidence: class and sample size for each claim, per the PRD's own rubric

| # | Source and what it says | Class, n | What factory uses it for |
|---|---|---|---|
| E1 | **Anthropic, *Optimizing for cost and intelligence*.** Opus 5.5 at `low` with failures re-run at `high` scored about 97% at about $0.17 per task; everything at `high` scored 95.3% at $0.29.<ul><li>Run on 478 of a 482-problem SWE-bench Pro subset, "not comparable to the public leaderboard", with two runs averaged.</li><li>It needs a failure signal ("here, the benchmark's own tests"), and every failure costs a second run of wall-clock time.</li><li>"Use this policy for the saving, not the lift." The results are "Anthropic-internal and directional".</li></ul> | Vendor; n=478; 2 runs | The implementer's code phase only. The failure signal here is written at high effort and reviewed (see 1.5 in the traceability table). `stats` records first-pass rate and QA false negatives per effort level. |
| E2 | **Same page.**<ul><li>"Tune one model before you add a second … Build a pairing only if it beats the single model's whole curve of score against spend."</li><li>The orchestrator's model alone at lower effort "came out ahead in every case measured **on earlier models**" (workers on Sonnet 5).</li><li>Current-model datapoint: Haiku 5.5 subagents under Opus 5.5 at `medium` "cut cost per attempt by 32% and the pass rate by about 4 percentage points", "an alternative to lowering effort, not better".</li></ul> | Vendor; n not stated for the pairing results | Opus everywhere; Sonnet only as a measured override |
| E3 | **Effort page.** `low` suits "Simpler tasks that need the best speed and lowest costs, such as subagents", with "Significant token savings with some capability reduction". The Opus 5.5 default is `medium`. | Vendor docs | learnings-researcher; the implementer's first pass |
| E4 | ***Choosing a model*.** "Most workloads start with Claude Opus 5.5." | Vendor docs | The default model |
| E5 | **Anthropic, *Harness design*.**<ul><li>The planner cost $0.46 of a $124.70 run and was kept because without it "the generator under-scoped".</li><li>"Errors in the spec would cascade" is the post's reason for keeping the planner at a high level.</li><li>"Out of the box, Claude is a poor QA agent". The fix: read the evaluator's logs, find where its judgment diverged, update its prompt, and add few-shot examples with score breakdowns.</li><li>Separating the generator from the evaluator "proves to be a strong lever".</li><li>The post used one model for every role (Opus 4.5, then 4.6) and doesn't discuss effort.</li><li>QA passes cost $3–4 each, against build rounds of $37–71.</li></ul> | Vendor engineering blog; a few runs on one author's apps | Planner scope; the QA tuning loop; separating generator from evaluator; stage cost. **Not** per-role model choice. |
| E6 | **Anthropic, *Effective harnesses*.**<ul><li>A feature list with `passes: false` per feature; "unacceptable to remove or edit tests".</li><li>It relied on "strongly-worded instructions" and on JSON, because the model "is less likely to inappropriately change or overwrite JSON files".</li><li>Agents should "quickly understand the state of work when starting with a fresh context window". *Harness design* notes that Opus 4.5 and later needed context resets less.</li></ul> | Vendor engineering blog; qualitative | `contract.json`; the harness, not an agent, sets `passes`; fresh re-run spawns |
| E7 | **CodeRabbit.**<ul><li>Recall: Opus 5.5 Standard 63.8% (51/80), Max 62.5%, baseline 61.3%.</li><li>Precision fell: 38.6% and 35.7%, against 39.3%.</li><li>Tokens: +49.2% and +57.6%.</li><li>Standard caught 11 issues the baseline missed and missed 9 that it caught.</li></ul> | Vendor; n=80 (+13); judge-graded; single run; a 2-bug gap | Opus reviewers are roughly at parity, at more tokens; not a measured gain |
| E8 | **Bug Hunt Bench**, scoring bugs *fixed*, with each fix verified in the diff.<ul><li>Fable 43 (one run), Opus 41.7 (three runs), Sonnet 5.5 at max 51.3 (the leader).</li><li>A 9-point run-to-run range on a single configuration; "a single run is not a measurement of a model".</li></ul> | Community; single maintainer; n=105 bugs; private answer key | Not decisive for any role. Sonnet's lead is a reason to keep the override measurable. |
| E9 | **The New Stack.**<ul><li>Concurrency test: Fable passed 5 of 5 runs, Opus 3 of 5. Opus's two misses hit the 128K output cap.</li><li>Flaky test: Fable deleted the simulated delay in all five runs; Opus left the code alone in all five.</li></ul> | Journalist; 5 runs per test | Fable stays opt-in. Evidence that models do weaken tests. |
| E10 | **Zhang & Shrestha 2026.** Review beat the stronger model alone in 9 of 96 directions. Open-weight models of 3B to 72B, reviewing final answers on QA benchmarks, not code diffs. | Preprint, about 3 weeks old | Weak support for reviewers at least as strong as the author; stated as a design choice |
| E11 | **Huang et al., ICLR 2024.** Self-correction without outside feedback doesn't help. 2023-era models, reasoning benchmarks. | Peer-reviewed | A separate reviewer context, with execution evidence as the outside signal |
| E12 | ***Your Agent May Misevolve*, ICLR 2026.** Evolved memory raises reward hacking and attack success. Treating memories "as 'references,' rather than 'rules'" cut attack success from 20.6% to 13.1%; the authors call this "preliminary". | Peer-reviewed; small eval sets | The "reference, not rules" line in prompts; only the harness writes memory |
| E13 | ***MemoryGraft*; *When Agents Remember Too Much*.** Memory poisoning, shown on MetaGPT DataInterpreter with GPT-4o and on personal-assistant agents. | Preprints | Memory lines are reviewed in the PR |
| E14 | **METR.** Models were "attempting (often successfully) to get a higher score by modifying the tests or scoring code", including a monkey-patched evaluator and an overwritten equality operator. | Research org; qualitative examples | Freezing the files that define the checks |

## Self-learning: adopted layers

| Layer | Adopted tool | How factory uses it |
|---|---|---|
| **1. Project knowledge** | **compound-engineering** (Every, MIT, v3.34.0, about 25.8k stars, "runs on 14 agent hosts"). Its `ce-compound` skill writes one doc per lesson to `<docs_root>/solutions/`. `docs_root` comes from `.compound-engineering/config.yaml` and defaults to `docs`. | factory validates no frontmatter itself. `/factory:stats` groups lessons by `problem_type` (a closed list of 17 values) and by `component` (open vocabulary since v3.22.0). |
| **2. Per-agent calibration** | Claude Code subagent `memory: project` | Memory lives in `.claude/agent-memory/factory-<agent>/MEMORY.md`, and the first 200 lines or 25 KB are injected into the agent. Claude Code handles reading natively; **the harness does all the writing** (see below). |
| **3. User corrections** | Claude Code auto memory | Built in. Layer 2 depends on it, so `/factory:init` checks that it is on. |

**Capture.** The orchestrator calls the Skill tool for `compound-engineering:ce-compound` with `mode:non-interactive depth:full "<context>"`, one learning per call. It does this at four points:

- after a PRD round where something got past the reviewer
- after a blocking finding is confirmed and fixed, or escalated
- after a stage 6 issue is resolved
- after an incident postmortem

Parsing the result:

- Only the **final line** counts: `Documentation complete` or `Documentation skipped`. The header line `✓ Documentation complete (non-interactive mode)` also contains the phrase, so a substring match would be wrong.
- The orchestrator also parses the `Refresh recommendation:` line.
- Both are recorded in the run's history file.

**Dependency contract (review 1.1).**

- `plugin.json` declares a floor only: `>=3.21.1`, the release that renamed the flag to `mode:non-interactive`. A range like `~3.34` cannot pin anything:
  - compound-engineering tags its releases `compound-engineering-v*`, not the `compound-engineering--v*` format Claude Code resolves against.
  - Its marketplace source is the relative path `./`, so the install takes the current copy. Factory would then be disabled the day 3.35.0 shipped.
- The real protection is `tests/ce-contract.sh`. It runs ce-compound non-interactively on a fixture and asserts the final line and the refresh line.
- When the contract test runs:
  - `/factory:init` runs it.
  - The SessionStart hook compares the installed version with the last version that passed, stored in `${CLAUDE_PLUGIN_DATA}/ce-contract.json`. If they differ, `/factory:run` runs the test before stage 1. This also covers `/plugin update`.
- Each run's history file records the version it resolved.
- A true pin would need upstream to publish `--v` tags (`claude plugin tag --push`), or a fork in the factory marketplace with its own tags. Neither is done this phase.

**Maintenance.** `ce-compound-refresh mode:non-interactive <scope>` runs only when ce-compound emits a refresh recommendation; the non-interactive mode never runs refresh itself. `learning.refresh_ceiling` (default 25 runs) is a ceiling only.

**Retrieval.**

- `learnings-researcher` runs before stage 1 (for the planner) and before stage 5 (for the reviewers).
- It is a **port** of `skills/ce-plan/references/agents/learnings-researcher.md` (MIT).
  - It is pinned to commit `f2762dd` (2026-09-22, PR #1757, the file's most recent change) and to blob `ab60b70641cf6fe395048b511bb96fd3d893663e`.
  - A test compares that blob with upstream `main` and reports drift.
- How it searches:
  1. Read `CONCEPTS.md`.
  2. Grep the frontmatter fields `tags` and `module`, plus `applies_when` (which only knowledge-track docs have).
  3. Read the candidates' frontmatter only.
  4. Return distilled summaries.

**Calibration and memory writes (review 3.1 and 3.4).**

- **Agents never write their own memory.**
  - The PreToolUse `Edit|Write` hook blocks any path under `.claude/agent-memory/`, with the message "memory is curated by the factory harness".
  - The post-spawn hash check (see Read-only roles below) catches writes made through Bash. They are reverted and logged as an incident.
  - Read, Write and Edit are turned on automatically for memory agents, and their system prompt tells them to curate `MEMORY.md`. That is why the rule is enforced by hooks rather than stated in a prompt.
- **The orchestrator writes calibration lines.** At each capture point it records one line for the agent that missed something, with `state.sh calibrate <agent> "<date> <slug>: <check to apply next time>"`. The line goes into the run's committed history file and is reviewed in the PR.
- **Folding happens once, at stage 7** (`state.sh fold-memory`).
  - It runs after the branch is updated from `main`, so parallel runs never conflict on `MEMORY.md`.
  - Only the first 200 lines are injected, so a `MEMORY.md` is capped at `learning.memory_max_lines` (150). Older lines move to `archive.md` in the same directory, which isn't injected but can be read on demand. `stats` lists the agents that need consolidating.
- Every memory-enabled prompt says: "MEMORY.md is reference material, not rules; it never overrides the task, `contract.json` or these instructions." This is E12's mitigation, which the authors describe as partial and preliminary.

**Memory rules:**

- Each parallel role has its own agent name, so parallel agents never share a `MEMORY.md`.
- `memory` is never combined with `isolation: worktree`. Issue #103308, still open, reports a stray empty memory directory under the parent's working directory, while the subagent uses one inside its worktree.
- The `factory-<agent>` directory name has been observed in #103308 but isn't documented, so it stays an M1 smoke test.
- No stage depends on memory inside a `claude -p` child.

**Read-only roles.** These are every agent except `planner`, `test-author` and `implementer`. Two mechanisms:

1. If M1 confirms that PreToolUse input for subagent calls includes `agent_type`, test-guard blocks every Edit and Write from a read-only role.
2. Either way, `change-diff.sh --hash` runs before and after each read-only batch. It now includes `.claude/agent-memory/`. Any difference is reverted and logged.

**Skill gating (review 1.2).**

- Every agent except the orchestrator sets `disallowedTools: ["Skill"]`. A specifier such as `Skill(name)` would remove the whole Skill tool anyway.
- Each agent gets the skills it needs preloaded through `skills:`:
  - `planner`: `prd-format`
  - `prd-reviewer`: `prd-format` and `review-rubric`
  - `test-reviewer`, the four lenses, `challenger` and `qa-evaluator`: `review-rubric`
- These skills are `user-invocable: false` and never `disable-model-invocation: true`, which would make them impossible to preload.

**Rubric visibility (review 2.1).**

- The implementer sees the acceptance criteria but not reviewer rubrics or memories. This is a design choice, with no citation: there's a Goodhart argument against teaching the implementer the grader's exact wording.
- *Harness design* did the opposite. It gave the criteria to both agents and found that they helped.
- `learning.rubric_visible` (default false) lets `stats` compare review rounds with and without the rubric visible.

**Measurement.** Each run writes one committed file, `.factory/history/<slug>.json`. `stats` reads all of them. Each file records:

- issues humans found, by stage, `problem_type` and `component`
- QA false negatives: stage 6 defects on criteria that QA passed
- first-pass rate and QA false negatives per implementer effort
- fix rounds, escalations and incidents
- spend per stage and per agent
- the compound-engineering version and the ce-compound outcomes
- calibration lines

Two things `stats` supports:

- **Spend by stage, reported before anyone tunes `limits.depth`.** In E5's run, QA passes cost $3–4 against build rounds of $37–71. The implementer's effort and the number of fix rounds probably dominate spend.
- **Ablation,** following "removing one component at a time". The criterion is impact on the final result: defects that reach stage 6 or production, compared with a component on and off (for example `lite` vs `full`).

**Agent evals (review 3.8).**

- The plugin repo has an `evals/` directory, run with `claude plugin eval`: three runs per case by default, an optional no-plugin baseline arm, `--max-cost-usd`, and an HTML report.
- Seed cases:
  - a PRD with no empty-state criterion (`prd-reviewer`)
  - a test that asserts nothing (`test-reviewer`)
  - a diff with a planted auth bypass (`reviewer-security`)
  - an acceptance criterion the app fails (`qa-evaluator`)
  - an edit to a `package.json` script that weakens the tests (the freeze)
- Evals run at each milestone and on every agent-prompt change.
- QA false negatives exported by `stats` become new `qa-evaluator` cases and few-shot examples in its prompt. This is E5's tuning loop.

## Stages

| # | What happens | Gate and loop |
|---|---|---|
| 1 Analyze and plan | `learnings-researcher` runs, then the planner writes three files:<ul><li>`prd.md`, at product level: the problem, users, scope and non-goals, UX flows including empty, loading, error and permission states, **EARS acceptance criteria** (Kiro's "WHEN … THE SYSTEM SHALL …"), NFRs, risks, rollout and feature flag, **monitoring signals**, and the test level for each criterion</li><li>`contract.json`: `{id, text, test_ids: [], passes: false}` per criterion</li><li>`plan.md`: small verifiable steps, plus an `## Exceptions` list of dependencies to add. It is advisory.</li></ul> | none |
| 2 PRD review | The `prd-reviewer`'s rubric starts with whether each criterion is testable and whether the states are covered. A **citation check** applies only **when the PRD quotes a figure or a source**: the figure must appear in the cited source, with its evidence class and sample size.<br><br>Then the **human gate**: a one-screen summary plus the findings. Your comments go to `feedback/prd-<n>.md`. | Approve, or go to 3 |
| 3 Fix PRD and self-improve | The planner revises the PRD. Calibration lines go to the `prd-reviewer` and the planner, and ce-compound runs for each lesson that generalizes. | Back to 2, at most `limits.prd_rounds` (3) times |
| 4 Implement | Branch `factory/<slug>`, with a port for this run and a baseline of currently failing checks.<ul><li>**(a)** `test-author` (opus · high) writes tests at the level the PRD names. Each test has `@AC-n` **in its title**, never with a suffix such as `@AC-1-extra`.</li><li>**(a1)** `run-checks.sh red`: every new test must fail against the unchanged code. A test that already passes is flagged to the test-reviewer.</li><li>**(a2)** `test-reviewer` checks every criterion is covered and every assertion means something:<ul><li>unit and integration tests must fail at the expected assertion, for the expected reason</li><li>an e2e test must start with an explicit presence check (`await expect(locator).toBeVisible({timeout: 5000})`), and its later assertions must be reachable once the element exists</li></ul>Problems go back to (a).</li><li>**Freeze.** test-guard hashes two lists:<ol><li>**tests:** specs, Playwright config, fixtures and helpers</li><li>**check-defining files** (`checks.check_defining`): `package.json` (hashed without its dependency fields), the lockfile, unit and e2e runner configs, `tsconfig*.json`, lint and format configs, CI config, and `.factory/config.yaml`</li></ol>The check commands are snapshotted to `.factory/runs/<slug>/checks.snapshot.json`, and `run-checks.sh` reads only that snapshot. A dependency named in `plan.md`'s exceptions may change the dependency fields and the lockfile (`test-guard check --plan`).</li><li>**(b)** The implementer writes the code (opus · low). **(c)** README, docs and CHANGELOG.</li></ul>**SubagentStop** (matcher `^factory:implementer$`, empty `agent_type` ignored, `timeout: 900`):<ul><li>first re-checks both hash lists; a changed hash counts as a failed check and the message names the file</li><li>then runs the fast checks from the snapshot</li><li>blocks with exit 2 up to `checks.stop_retries` (3) times, under Claude Code's limit of 8 consecutive continuations</li></ul>The orchestrator then runs integration and e2e checks from the snapshot.<br><br>**`contract-sync`:**<ul><li>Every check writes JUnit XML: Playwright's `junit` reporter, Vitest `--reporter=junit`, Jest through `jest-junit`.</li><li>`state.sh contract-sync` matches `AC-\d+\b` in test-case names.</li><li>A criterion gets `passes: true` only when at least one test names it and every test that names it passed.</li><li>The harness sets `passes`; no agent does.</li></ul>There is a commit after each sub-phase. At the end of the stage the branch is pushed and a **draft PR** is opened (`ship.pr_open`), with its number recorded in `state.json`. | On a failing pass: a fresh implementer at opus · high, at most 2 rounds, then you |
| 5 Review and fix | `learnings-researcher` runs first, then the mechanical checks.<ul><li>**`limits.depth`:** `lite` (diff under `lite_max_lines` and nothing on the risk list) runs correctness and spec only, with no challenger. `full` runs all four lenses plus the challenger on each blocking finding.</li><li>**`qa-evaluator`** drives the running app with `playwright-cli` (package `@playwright/cli`, fallback `npx playwright cli`). It gives **one pass or fail per `AC-n`, with a screenshot or trace path as evidence**. Any fail blocks.</li><li>Each confirmed finding goes through `test-author` (a failing test), then `test-reviewer`, then an extension of the freeze, then a fresh implementer at opus · high. Only the lenses that blocked review again.</li><li>Calibration lines and ce-compound follow.</li></ul> | At most `limits.review_rounds` (2), then you |
| 6 Evidence | The `@AC-n` e2e specs are the demo script, run under `playwright.demo.config.ts`:<ul><li>`use.video: {mode: 'on', show: {actions: {...}, test: {level: 'step'}}}`, with `page.screencast.showChapter()` for each criterion (Screencast API since 1.59)</li><li>Docker image `mcr.microsoft.com/playwright:v<the app's Playwright version>-noble` (`-jammy` and `-resolute` also exist)</li><li>a single criterion is selected with `--grep '@AC-1\b'`, in single quotes</li><li>screenshots at 1440, 768 and 390 pixels wide</li></ul>`evidence.sh` converts the WebM video (VP9 since 1.64) to H.264 mp4 with ffmpeg. That step is factory's own practice, not a Playwright feature. It also builds `review-pack/index.html`.<br><br>The **triager routes each of your comments by class:**<ul><li>spec gap: a PRD amendment, then stage 2</li><li>defect: stage 5, with a failing test first</li><li>cosmetic: a direct fix by the implementer, then evidence re-captured</li></ul>A defect on a criterion QA passed is a **QA false negative**. It gets a `qa-evaluator` calibration line and becomes a candidate eval case.<br><br>On approval, the evidence SHA is recorded and the PR is marked ready (`ship.pr_ready`). | Approve, or route by class, at most `limits.evidence_rounds` (3) |
| 7 Merge and deploy | `ship.sh verify` checks that:<ul><li>approval was recorded against the evidence SHA</li><li>checks are green</li><li>every commit after the approved SHA is either a conflict-free merge of `origin/main` or the harness's memory-fold commit (only `.claude/agent-memory/factory-*/`, with lines taken from the approved history file)</li></ul>Then the order is: update from `main`, run `fold-memory`, then `ship.merge` → `ship.deploy` → `ship.smoke`. If smoke fails, an issue is filed first, then `ship.rollback` is offered; the fix is a bugfix run (see stage 8).<ul><li>`ship.deploy` waits for your explicit confirmation. The guard hook blocks deploy and rollback commands outside stage 7.</li><li>`ship.smoke` runs the `@smoke` tests against production.</li></ul>The deploy marker and baseline are recorded. | You confirm |
| 8 Monitor | **`monitor.sh` is pure shell.**<ul><li>It runs `monitor.checks` and compares the results with the baseline.</li><li>On an anomaly it **files an issue first**: a GitHub issue labelled `factory-incident` (`monitor.report: github-issue`, the default), the tracker command `monitor.issue_cmd` (`command`), or `.factory/incidents/I-n.md` (`file`). It runs `ship.rollback` only if `auto_rollback: true`, then exits non-zero. `monitor.sh issue` files the same kind of issue for a smoke failure at stage 7.</li></ul>Schedulers:<ul><li>**local** `/loop 15m /factory:monitor <slug>`: runs only while the session is idle, expires after 7 days, and doesn't catch up on missed runs. The triager runs immediately on an anomaly.</li><li>**launchd or cron**, or a Desktop scheduled task: runs `monitor.sh` and shows a macOS notification on an anomaly.</li><li>**GitHub Actions cron:** runs the committed copy `.factory/bin/monitor.sh`. It only detects and files: no `claude -p`, so CI needs no Anthropic credential.</li></ul>Issues filed by CI or launchd are picked up by the next local `/factory:run` or `/factory:status`. The triager correlates the incident with the deploy SHA and posts its diagnosis and a proposed regression criterion on the issue; a rollback is offered as mitigation. The fix is a **new bugfix run**, `/factory:run --issue <ref>`, through every stage and gate: a bugfix PRD whose AC-1 reproduces the failure, tests first, review, evidence, deploy. Its PR says `Fixes #n`. The postmortem goes through ce-compound at the bugfix run's stage 7, and the originating run's agents that missed it get calibration lines. The originating run is never reopened. Cloud routines are not offered: they run at most hourly and can't install plugins. | An issue, then a bugfix run |

**State, spend and parallel runs:**

- **State.** `.factory/runs/<slug>/state.json` (git-ignored) holds the stage, round counters, gate approvals with their SHAs, the PR number, the port, freeze hashes, the models and efforts used, and spend. `.factory/history/<slug>.json` (committed) is the measurement record.
- **Spend (review 3.7).**
  - A second SubagentStop hook, matcher `^factory:`, runs `spend.sh` and always exits 0. It sums `usage` from `agent_transcript_path`, per spawn, into the current stage.
  - The orchestrator's own usage comes from the main `transcript_path` at each stage boundary.
  - Usage is priced with the table above, including the cache tiers.
  - Spawns stopped with TaskStop may never fire SubagentStop (#92716). They are reported as unpriced.
- **Budget.** `limits.budget_usd` pauses the run at the next gate. `--max-budget-usd` exists only in print mode, so interactive runs need this setting.
- **Resume and lock.** `/factory:run <slug>` resumes from the recorded stage. A lock allows one run per checkout.
- **Parallel runs** use `claude --worktree`:
  - The worktree lives at `<repo>/.claude/worktrees/<name>`, so project memory inside it reaches `main` only through the branch. That is intended.
  - Each run gets its own port. It is derived from the slug, checked to be free, and passed as `FACTORY_PORT` to `project.start`, Playwright's `webServer` and `project.url`.

## Plugin layout (`factory2/`, a git-hosted marketplace repo)

```
.claude-plugin/marketplace.json     "factory" → ./plugins/factory; allowCrossMarketplaceDependenciesOn: ["compound-engineering-plugin"]
plugins/factory/
  .claude-plugin/plugin.json        version 0.1.0; dependencies: [{name: "compound-engineering",
                                    marketplace: "compound-engineering-plugin", version: ">=3.21.1"}]
  skills/run/SKILL.md               /factory:run <request|slug> [--from <stage>]  (model: opus, effort: high)
  skills/{init,monitor,status,stats}/SKILL.md
  skills/{prd-format,review-rubric,evidence}/SKILL.md   (user-invocable: false; preloaded through skills:)
  agents/  planner prd-reviewer learnings-researcher (port, f2762dd / blob ab60b70) test-author test-reviewer
           implementer reviewer-{correctness,spec,security,maintainability} challenger qa-evaluator triager researcher
           (disallowedTools: [Skill] on all; memory: project on all but learnings-researcher, challenger, researcher)
  hooks/hooks.json  SessionStart (ce version check, settings check)
                    PreToolUse Bash (guard-bash) · PreToolUse Edit|Write (test-guard: frozen lists, memory paths, read-only roles)
                    SubagentStop ^factory:implementer$ (hash re-check, then fast checks; timeout 900) · SubagentStop ^factory: (spend)
  scripts/  guard-bash test-guard run-checks subagent-stop change-diff     (ported from singularity, trimmed)
            state (state, lock, history, contract-sync, calibrate, fold-memory, budget)  spend  evidence  ship  monitor
  templates/ factory.config.yaml  playwright.demo.config.ts  review-pack.html
             github-actions-monitor.yml  launchd-monitor.plist  gitignore.txt
evals/   claude plugin eval cases and graders, per agent
tests/   bash tests per script · ce contract test · dependency-resolution tests · hook-firing tests (git and directory sources)
docs/    PRD.md (v3)  PRD-review-v2.md  history/ (PRD-v1.md, PRD-v2.md, PRD-review.md)  solutions/
README.md (credits compound-engineering and singularity)  CHANGELOG.md
```

**`/factory:init`:**

- **Checks:**
  - Claude Code ≥ 2.1.311 and auto memory on
  - neither `disableAllHooks` nor `allowManagedHooksOnly` set
  - no other enabled plugin named `factory`: a name collision is a documented reason plugin hooks don't fire
  - a warning if `CLAUDE_CODE_EFFORT_LEVEL` is set
- **compound-engineering:** confirms it is installed and enabled, or prints the install commands. Then it runs the contract test and `ce-setup`.
- **Installs and writes:**
  - installs `@playwright/cli`
  - writes `.factory/config.yaml`
  - copies `monitor.sh` to `.factory/bin/` with a version header
  - adds the GitHub Actions or launchd template if you ask for it
- **No settings-level hooks.** The v2 workaround rested on misread issues.

**Files in each target repo:**

- Committed: `.factory/config.yaml`, `.factory/history/<slug>.json`, `.factory/bin/monitor.sh`, `docs/specs/<slug>/{prd.md,contract.json,plan.md}`, `<docs_root>/solutions/`, `CONCEPTS.md`, `.claude/agent-memory/factory-*/`
- Git-ignored: `.factory/runs/`, `.factory/incidents/`

**Example per-project config:**

```yaml
project:  {default_branch: main, start: "PORT=$FACTORY_PORT npm run dev", url: "http://localhost:$FACTORY_PORT", ready: /health}
checks:   {fast: {lint: "npm run lint", typecheck: "npm run typecheck", unit: "npx vitest run --reporter=junit --outputFile=$FACTORY_REPORTS/unit.xml"},
           slow: {integration: "...", e2e: "npx playwright test --reporter=junit"},   # every check writes JUnit XML into $FACTORY_REPORTS
           check_defining: [package.json, package-lock.json, "vitest.config.*", "playwright.config.*", "tsconfig*.json", "eslint.config.*", ".github/workflows/*"],
           stop_retries: 3, hook_timeout: 900}
roles:    {}   # e.g. implementer: {model: sonnet, effort: medium}; reviewer-security: {model: fable, effort: high}
limits:   {prd_rounds: 3, review_rounds: 2, evidence_rounds: 3, depth: auto, lite_max_lines: 150, budget_usd: 60}
risk_list: [auth, payments, personal-data, crypto, migrations, public-api, concurrency, dependencies]
evidence: {viewports: [1440x900, 768x1024, 390x844], publish: ""}
ship:     {pr_open: "gh pr create --draft --fill", pr_ready: "gh pr ready", merge: "gh pr merge --squash",
           deploy: "...", smoke: "BASE_URL=... npx playwright test --grep @smoke", rollback: "..."}
monitor:  {window_hours: 24, scheduler: local-loop, interval: 15m, report: file, auto_rollback: false,
           checks: [{name: health, cmd: "curl -fsS .../health"}]}
learning: {enabled: true, compound_depth: full, refresh_ceiling: 25, memory_max_lines: 150, rubric_visible: false}
```

## Build order

0. **M0: self-improvement on both reviews.**
   - Run `git init` in factory2.
   - Restore the v1 plan, the v2 plan (the current `docs/PRD.md`) and the first review from this session's transcript into `docs/history/`, and commit them.
   - Write `docs/PRD.md` v3. From then on, every PRD change goes through review and a commit.
   - Seed factory's own `docs/solutions/` with five lessons:
     - "cite primary sources; aggregators don't contain the figures"
     - "a dependency range is only as good as the tags it resolves against"
     - "a real quote can still be inverted; check what the source did, not only what it said"
     - "a tool-level deny with a specifier removes the whole tool"
     - "before building a workaround, confirm the issue says what you think and is still open"
   - Seed the `review-rubric` skill with the conditional citation check.
1. **M1: platform proof.**
   - Marketplace and skeleton; `claude plugin validate --strict`; `claude plugin details factory` (the projected token cost of the agent and skill descriptions); `state.sh`; the ported scripts and their bash tests.
   - **Dependency resolution:** install factory from a git-source marketplace and check that `claude plugin list` shows compound-engineering enabled. A negative test with an unsatisfiable range must show factory disabled with a `Requires …` message.
   - **ce contract test.**
   - **Hook-firing test** from both a git-source and a directory-source marketplace. Every hook must fire, because the deploy guard and the freeze are safety gates.
   - **Smoke tests:**
     - a plugin agent's memory directory is `factory-<agent>`
     - PreToolUse input for subagent calls includes `agent_type`
     - the SubagentStop matcher and timeout behave as configured
     - the Agent tool's `effort` and `model` parameters take effect, and whether `CLAUDE_CODE_EFFORT_LEVEL` overrides them
     - a subagent with `disallowedTools: [Skill]` cannot run ce-compound
     - the status of #92750 and its noted `omitClaudeMd` workaround
   - The `evals/` scaffold with its first case.
2. **M2: stages 1–3.** Planner, `prd-reviewer`, the human gate, calibration lines and capture; `prd-reviewer` eval cases.
3. **M3: stage 4.**
   - `test-author`, the red check and `test-reviewer`
   - the two-list freeze, the checks snapshot, and the SubagentStop hash re-check
   - JUnit `contract-sync`, the draft PR, fresh-spawn re-runs, the spend hook and the budget
   - eval cases for `test-reviewer` and the freeze
4. **M4: stage 5.** Four lenses, the challenger, `limits.depth`, `qa-evaluator` with `playwright-cli`, and read-only enforcement; eval cases for the lenses and QA.
5. **M5: stage 6.** Demo config, `evidence.sh`, the review pack, routing by class, and exporting QA false negatives as eval cases.
6. **M6: stages 7–8.** `ship.sh` (including `verify` and `fold-memory`), the deploy guard, `monitor.sh`, the three schedulers, and incident pickup.
7. **M7: `stats`.** Then **migrate off singularity**, each step only after your OK:
   - remove `singularity@singularity` and its marketplace entry
   - install compound-engineering and factory, and run `/factory:init` in the 3 projects

## Verification

- **M1 tests**, as listed above.
- **Bash tests:**
  - `guard-bash`: blocks force-push, `--no-verify`, and deploy or rollback outside stage 7 or without approval.
  - `test-guard`:
    - blocks edits to frozen tests, check-defining files and memory paths
    - blocks Edit and Write from read-only roles, if `agent_type` is present
    - allows a dependency named in the plan
  - `subagent-stop`:
    - a `package.json` script edit or a `testPathIgnorePatterns` change made through Bash fails the hash re-check
    - blocks while checks fail, stops at its cap, and ignores other agents
  - `run-checks`: reads only the snapshot.
  - `contract-sync`:
    - parses JUnit fixtures from Playwright, Vitest and Jest
    - `AC-1` does not match `AC-10`
    - a criterion with no tests stays false
    - a suffixed tag is rejected
  - `change-diff --hash`: catches a reviewer writing anywhere, including memory, and the change is reverted.
  - `state.sh`:
    - resume, lock and budget work
    - `fold-memory` is idempotent and archives lines past the cap
    - `spend` prices a fixture transcript correctly across cache tiers
  - `ship.sh verify`: accepts a merge from `main` and the fold commit, and rejects any other commit.
- **`claude plugin eval`** passes the seeded cases at each milestone, with a no-plugin baseline arm for the reviewers.
- **End to end** on a sample Next.js app, with the feature "add a dark-mode toggle". Run it once at `depth: lite` and once at `full`, plus a second feature in parallel through `claude --worktree`: the two runs must use different ports and both PRs must merge cleanly.
  - **Learning check:**
    - A PRD comment ("no empty-state criterion") produces one calibration line in the history file.
    - The line is folded into `factory-prd-reviewer/MEMORY.md` at stage 7, and a ce-compound final line is recorded.
    - The next run's `prd-reviewer` raises the same class of issue on its own.
  - **Freeze check:** `test-reviewer` rejects a deliberately weak test. After the freeze, the implementer cannot change a fixture, a `package.json` script or `.factory/config.yaml`, whether through Edit or through Bash.
  - **Stage 6:** one comment of each class (spec gap, defect, cosmetic) routes to stage 2, stage 5 and a direct fix respectively.
  - **Stage 7:** the PR goes from draft to ready to merged, and deploys to a local "prod" run with `docker compose`.
  - **Stage 8:**
    - Under launchd, a broken `/health` is caught. It files an issue first; the next local session triages it onto the issue, rolls back on approval, and a bugfix run started from the issue fixes it, closes the issue and writes the postmortem doc.
    - A GitHub Actions run opens a `factory-incident` issue.
- **History files** show the model and effort per agent, spend per stage, the compound-engineering version, and the ce-compound outcomes.

## Risks

- **compound-engineering drift.** It has no stability policy and has shipped 88 v3 releases since 2026-04-22.
  - Mitigations: the floor, the contract test whenever the version changes, parsing only the final line, and the version recorded in history.
  - A true pin needs upstream `--v` tags or a fork.
- **Cost of Opus everywhere.**
  - Mitigations: low effort for code and retrieval, `budget_usd`, and per-stage spend read from transcripts.
  - Estimates ignore fast mode and US-only inference.
- **Plugin hooks may not fire.**
  - The documented causes are an invalid `hooks.json`, a plugin-name collision, wrong event-name case, and the `disableAllHooks` or `allowManagedHooksOnly` settings. `/factory:init` checks the last three.
  - The M1 hook test runs from both source types.
- **The guards are seatbelts.** In singularity's words, `guard-bash` is "a seatbelt against mistakes, not a security boundary". The same holds for `test-guard` against writes made through Bash. The hash re-checks at SubagentStop and after each review batch are the actual mechanism, and they detect rather than prevent.
- **Agents gaming the tests (E9, E14).** Mitigations: freezing both lists, the harness setting `passes`, the red check, and a freeze eval case.
- **Open issues to recheck at M1:**
  - #92750: subagents receive the main auto-memory index and the skill listing; `omitClaudeMd: true` is the noted workaround.
  - #92716: SubagentStop doesn't fire on TaskStop. The implementer runs in the foreground, and spawns without a price are reported.
  - #103308.

## Review traceability (`docs/PRD-review-v2.md`)

| Review item | Change in v3 |
|---|---|
| 1.1 `~3.34` can't pin | Floor `>=3.21.1`. The contract test runs at init and whenever the version changes. The resolved version goes in history. M1 adds a resolution test and a negative test. |
| 1.2 the `Skill(...)` specifier removes the whole tool | `disallowedTools: ["Skill"]` plus `skills:` preloading. The smoke test now checks only that ce-compound can't be invoked. |
| 1.3 #105625 and #86809 misread | No settings-level hooks; both citations removed. The hook test runs from git and directory sources. Init checks the documented failure causes. |
| 1.4 the check definitions weren't frozen | A check-defining list, hashed at the freeze. A checks snapshot. SubagentStop re-checks hashes first. Dependencies named in the plan are the one exception. |
| 1.5 the oracle was written at low effort | `test-author` at opus · high; code at low with re-runs at high; `stats` per effort level. This also fixes a v2 defect: SubagentStop would have demanded green unit tests while the (a) tests were red by design. |
| 2.1 rubric-hiding citation inverted | Now a design choice with no citation, plus the `learning.rubric_visible` experiment. |
| 2.2 stretched quotes | "Cascade" now supports a product-level PRD. The QA fix is the tuning loop. *Harness design* is no longer cited for model choices. |
| 2.3 "every case measured" | Qualifier "on earlier models" added, plus the Haiku-subagent datapoint (E2). |
| 2.4 fresh-spawn rationale | Now: a clean context that starts from the failure report (E6). The prompt-cache claim is removed. |
| 2.5 evidence precision | A new Evidence table with class and n for every claim. CodeRabbit, Bug Hunt Bench and The New Stack corrected. Fable's flaky-test behaviour noted. |
| 2.6 wrong commit | Pinned to `f2762dd` and blob `ab60b70…`, verified on 2026-11-02, with a drift test. |
| 3.1 memory-write rule unenforced | Only the harness writes memory, enforced by the hook and the hash check. Auto-enabled Read, Write and Edit are now stated as the reason. `factory-<agent>` stays a smoke test. |
| 3.2 `contract-sync` tags | JUnit XML from every runner; `AC-\d+\b` matching; at least one test, all passing; no suffixed tags. |
| 3.3 e2e red standard | An e2e test starts with an explicit presence check. |
| 3.4 parallel runs | One history file per run. Calibration is folded once at stage 7, after updating from `main`. A port per run. The worktree location is stated. |
| 3.5 nobody opens the PR | A draft PR at the end of stage 4, marked ready on approval, with its number in state. `ship.sh verify` at stage 7. |
| 3.6 CI can't run the triager | CI only detects and files (a GitHub issue), with no `claude -p` and no Anthropic credential. Triage happens in local sessions. |
| 3.7 spend source and prices | A SubagentStop spend hook reads `agent_transcript_path`. Cache tiers are in the price table. |
| 3.8 no agent evals | `evals/` with `claude plugin eval`: seeded cases, run per milestone and on every prompt change. `plugin details` runs at M1. |
| 3.9 citation check not relevant to feature PRDs | Made conditional. The rubric starts with testability and state coverage. |
| 3.10 v1 no longer exists | `git init`; history restored from the transcript into `docs/history/`. |
| 3.11 effort control is simpler now | The Agent tool's `effort` and `model` parameters, and a warning about `CLAUDE_CODE_EFFORT_LEVEL`. |
| 3.12 stage cost allocation | `stats` reports spend by stage before anyone tunes `depth`. |
| §4 citations | Playwright ≥ 1.59 for Screencast, `video.show: {actions, test}` (verified on the TestOptions page), VP9, ffmpeg described as factory's practice. `@playwright/cli`. Docker tag variants. #103308 reworded. Fable's ZDR wording. Haiku dropped as unused. Opus default effort `medium`. Schema details. The durable bar shipped in v3.25.0 (#1624), recorded in GitHub Releases. Auto-trigger is gated, and moot once Skill is disallowed. The ablation criterion. |
| §5 | The seatbelt sentence added to Risks. |

## Sources

- Anthropic platform:
  - https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence
  - https://platform.claude.com/docs/en/build-with-claude/effort
  - https://platform.claude.com/docs/en/about-claude/models/choosing-a-model
  - https://platform.claude.com/docs/en/about-claude/pricing
  - https://platform.claude.com/docs/en/manage-claude/api-and-data-retention
- Anthropic engineering:
  - https://www.anthropic.com/engineering/harness-design-long-running-apps
  - https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Claude Code docs:
  - subagents: https://code.claude.com/docs/en/sub-agents.md
  - hooks: https://code.claude.com/docs/en/hooks.md
  - memory: https://code.claude.com/docs/en/memory.md
  - skills: https://code.claude.com/docs/en/skills.md
  - plugins:
    - https://code.claude.com/docs/en/plugins/dependencies.md
    - https://code.claude.com/docs/en/plugins/loading.md
    - https://code.claude.com/docs/en/plugins/troubleshooting.md
    - https://code.claude.com/docs/en/plugins/manifest-reference.md
    - https://code.claude.com/docs/en/plugins/marketplace-reference.md
  - scheduled tasks: https://code.claude.com/docs/en/scheduled-tasks.md
  - cloud environments: https://code.claude.com/docs/en/cloud-environments.md
  - CLI reference: https://code.claude.com/docs/en/cli-reference.md
  - changelog: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
  - issues #92716, #92750 and #103308
- compound-engineering: https://github.com/EveryInc/compound-engineering-plugin
  - `skills/ce-compound/{SKILL.md, references/report.md, references/modes.md, references/schema.yaml}`
  - learnings-researcher at `f2762dd`
  - GitHub Releases
- Playwright:
  - https://playwright.dev/docs/release-notes
  - https://playwright.dev/docs/api/class-screencast
  - https://playwright.dev/docs/api/class-testoptions
  - https://playwright.dev/docs/test-reporters
  - https://playwright.dev/docs/docker
  - https://playwright.dev/docs/test-agents
  - https://github.com/microsoft/playwright-cli
- Kiro EARS: https://kiro.dev/docs/specs/feature-specs/
- Review evidence:
  - CodeRabbit: https://www.coderabbit.ai/blog/opus-5-5-model-review
  - Bug Hunt Bench: https://github.com/phuryn/bug-hunt-bench
  - The New Stack: https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/
  - Zhang & Shrestha: https://arxiv.org/abs/2610.15897
  - Huang et al.: https://arxiv.org/abs/2310.01798
  - *Your Agent May Misevolve*: https://arxiv.org/abs/2509.26354
  - memory poisoning: https://arxiv.org/abs/2512.16962 and https://arxiv.org/abs/2607.06595
  - METR: https://metr.org/blog/2025-06-05-recent-reward-hacking
  - https://arxiv.org/abs/2511.18397

## M1 findings (2026-11-02, Claude Code 2.1.316, compound-engineering 3.34.0)

Verified by `tests/live/deps.sh`, `tests/live/hooks.sh`, `plugins/factory/scripts/ce-contract.sh` and
`tests/eval.sh`; lessons in `docs/solutions/`. Deltas to the plan above:

- **Dependency resolution works from a git source** (git-subdir over `file://`): installing factory pulls
  compound-engineering 3.34.0, both enabled. An unsatisfiable range fails the install, but the entry
  stays with `enabled: true`; `.errors` carries "Requires …". doctor checks `.errors`.
- **Without its dependency, factory loads no agents.** Live tests load both plugin dirs. `claude plugin
  eval` loads the plugin alone, so evals run a copy without `dependencies` (`tests/eval.sh`). Eval
  directory is `plugins/factory/evals/`.
- **Hooks fire** (directory source via `--plugin-dir`; the git install is byte-identical to the committed
  tree): SessionStart; PreToolUse Bash (deploy guard blocked `ship.deploy` at stage 1); PreToolUse Write
  (read-only role and memory path blocked); SubagentStop `^factory:implementer$` blocked once at
  `stop_retries: 1` and then let the agent stop; SubagentStop `^factory:` priced every spawn. The 900 s
  timeout itself was not exercised.
- **PreToolUse input for subagent tool calls carries `agent_type: "factory:<agent>"`**, so test-guard's
  read-only rule is active (not only the hash check).
- **Memory directory is `.claude/agent-memory/factory-<agent>/`**, and MEMORY.md is injected; memory
  agents do get Write and Edit. Subagent memory needs auto memory on: **this machine's
  `~/.claude/settings.json` has `autoMemoryEnabled: false`**, which disables layer 2 entirely; doctor
  now fails on it (it didn't before, see the jq lesson).
- **Agent tool `model` and `effort` parameters take effect**, and the effort parameter wins over
  frontmatter. **`CLAUDE_CODE_EFFORT_LEVEL` overrides the parameter too**, so `/factory:run` refuses to
  start while it is set (was: a warning).
- **`disallowedTools: Skill`**: the subagent has no Skill tool and ce-compound wasn't invoked.
- **ce-compound contract holds on 3.34.0** (final line, refresh line, doc with a closed-list
  `problem_type`), but its durability bar skips lessons the final code already shows. Capture context
  must carry the failed attempts and investigation; `Documentation skipped` is a normal outcome. The
  contract test lives in the plugin (`scripts/ce-contract.sh`) so `/factory:init` can run it; ~$1.
- **Spend** prices fast mode and US-only inference from transcript fields (the "ignores" note under
  Prices is outdated). AC tags also accept `AC_n` function names (Go, Swift). `checks.hook_timeout` is
  dropped (900 s is fixed in hooks.json). `evidence.driver: playwright|command|none` covers non-web apps
  (a Swift app project). Scripts need only bash, git, jq and python3 (a YAML-subset parser replaces yq).
- **#92750 is still open** (subagents receive the auto-memory index and skill listing). Not worked
  around in M1: factory's agents can't invoke skills, and the extra context is read-only.
- First eval case (`prd-reviewer-empty-state`, one run per arm): with 1.00, without 0.25. Directional.

## M1 follow-up fixes (2026-11-02)

- **Agent memory no longer depends on auto memory.** The `memory: project` frontmatter is removed from
  all agents; a SubagentStart hook (`memory-inject.sh`, matcher `^factory:`) loads
  `.claude/agent-memory/factory-<agent>/MEMORY.md` (200 lines / 25 KB) as `additionalContext`. Works
  with `autoMemoryEnabled: false` (live-verified), gives read-only agents no auto-enabled Write/Edit,
  and sidesteps #103308. doctor downgrades auto memory to a warning. Supersedes the memory row of
  "Self-learning: adopted layers" and the "Memory rules" list.
- **The stop gate has its own time limit.** A timed-out SubagentStop hook lets the implementer stop
  unchecked, even with `onFailure: "block"` (probed live). `subagent-stop.sh` runs the fast checks
  under 840 s (`lib/timeout.py`, kills the process group), then lets the stop through and records
  `gate_timeouts`; the orchestrator's own re-run of all checks is the backstop. `state.sh baseline`
  times the fast set and warns past 420 s.
- **`CLAUDE_CODE_EFFORT_LEVEL` is refused by the script**, not only by the orchestrator: `state.sh
  start|resume` exit 3 while it is set; `--effort-env-ok` after the user agrees, recorded as
  `state.effort_env`.
- **Hooks from the git install** fire live in `tests/live/deps.sh` when `ANTHROPIC_API_KEY` or
  `CLAUDE_CODE_OAUTH_TOKEN` is set (the isolated config has no login otherwise); without one the
  byte-identity check remains the evidence.
- After the memory change, three runs per arm: with 1.00 (3/3), without 0.17 (Δ +0.83), $1.18. One judge vote of nine dissented on the with-arm criteria grader.
- **Gate hooks fail closed** (probed: by default a crashed or timed-out command hook lets the action
  through; `onFailure: "block"` works on PreToolUse but is ignored on SubagentStop). guard-bash,
  test-guard and subagent-stop run through `scripts/gate.sh`, which applies its own time limit and turns a
  crash or hang into a decision: block inside a factory project for the PreToolUse guards (allow in
  unrelated projects), record-and-allow for the stop gate (`gate_errors`, reported by the orchestrator).
  PreToolUse entries also carry `onFailure: "block"` and a 30 s timeout.

## Code review fixes (2026-11-02)

Two independent reviews (scripts; prompts against scripts) found 22 defects; all are fixed, with
regression tests in `tests/regressions.test.sh` and the per-script suites. The behaviour changes:

- **Safety gates.** test-guard resolves paths like the filesystem does (`lib/pathcheck.py`: `..`
  through missing directories, symlinks, a symlinked root, the input's `cwd`, other spellings of a
  frozen file on case-insensitive filesystems by inode). It blocks read-only roles everywhere, blocks
  `.claude/settings*.json` during a run, and allows a check-defining file that plan.md's Exceptions name
  (implementer or main session only, never `.factory/config.yaml`). guard-bash and test-guard fail closed
  inside a factory project when jq or python3 is missing or the config doesn't parse. guard-bash sees
  through `command -p`, `exec -a` and `xargs`. A rollback needs its own approval.
- **Approvals hold for one pass.** `state.sh stage <n>` going back revokes approvals of gates at n or
  later (prd 2, evidence 6, deploy and rollback 7).
- **Freeze.** The first freeze compares check-defining files with the run's base commit (Exceptions
  apply). Lockfile changes need a dependency name in Exceptions, not just any token.
- **Stop gate.** Any non-zero from verify-freeze, and any run-checks result other than pass or
  nothing-to-run, blocks. The time budget subtracts the time already used; `timeout.py` forwards
  signals to its process group, so nested limits don't orphan test runners.
- **run-checks** passes commands NUL-separated: multi-line commands and backslashes reach bash unchanged
  (before, a multi-line check could pass while failing).
- **State.** The lock records its owner's pid and is stolen only from a dead owner. `.config.json` is
  written atomically. fold-memory is in Python, idempotent across MEMORY.md and archive.md, verbatim.
  budget-check: 0 or less is no limit, a non-number is a config error, output is locale-independent.
- **Orchestrator.** Stage 5 fix loop sets `phase tests` for the test-author, red-checks only the new
  tests (`state.sh red-check --tests`), and handles `unproven` challenger verdicts and lite depth.
  Regression tests with no criterion are untagged (no `@AC-0`). QA gets `<run>/evidence/qa/`. Stage 7
  writes rounds and spend to history; escalations are recorded. Agent `lessons` are candidates only.
  qa-evaluator preloads the `playwright-cli` skill. Templates and scripts of later milestones are marked.
- **Second review pass (11 more).** Exceptions are snapshotted at each freeze (`<run>/plan.frozen.md`);
  verify-freeze and test-guard read only that copy, so an agent editing plan.md can't grant itself an
  exception (flow: planner adds it → `state.sh freeze` → implementer → `state.sh freeze`). Implementer
  and test-author can't edit `docs/specs/**`; no agent edits `.factory/runs/**` or `.factory/history/**`.
  A config that doesn't parse no longer deadlocks a session: guard-bash uses the last config that parsed
  (`.factory/runs/.config.lastgood.json`), test-guard doesn't need it, and `state.sh start` refuses an
  unparsable config. `state.sh branch` creates the run branch and records the base there. The first
  freeze works in projects below the git top level. `red-check --test` takes one name per flag
  (commas allowed; partial names only when unambiguous). `run-checks --json` handles multi-line
  commands. Negative budget means no limit. xargs option arity fixed. memory-inject's text no longer
  contains a command substitution.
- **Third review pass (6 more).** Re-freeze judges changes by the frozen Exceptions, not the live
  plan.md, and prints the Exceptions added since the last freeze for the orchestrator to check against
  the planner's report. The snapshot's sha256 is in state.json (`frozen_plan_sha`): a missing or
  rewritten `plan.frozen.md` makes verify-freeze and re-freeze exit 2 (the stop gate blocks). `state.sh
  branch` records the base only when it creates the branch. `red-check` rejects unknown flags and
  reports ambiguous partial names. guard-bash skips xargs long options that take a separate value.
  Residual, by design: a Bash edit that rewrites both run state and the snapshot isn't caught by
  hooks; hooks are seatbelts, and the PR diff and the human gates remain the boundary.

## Change: incidents become issues, fixed by bugfix runs (2026-11-02)

Requested by the user: a monitoring incident creates an issue first, then goes through the normal
development flow.

- **Issue first.** `monitor.sh` (stage 8) and the stage 7 smoke failure file an issue before anything
  else: GitHub (`factory-incident` label, the new default), any tracker through `monitor.issue_cmd`, or
  a local file. A rollback is a separate mitigation the user approves.
- **Normal flow.** `/factory:run --issue <ref>` starts a bugfix run (`state.sh start <slug> --issue <ref>
  [--caused-by <slug>]`; `kind: bugfix` in state and history). It goes through all eight stages and
  gates. The bugfix PRD (prd-format, "Bugfix runs") states the observed failure, a root-cause section,
  and AC-1 as the regression criterion, written as a failing test first.
- **No reopening.** A deployed run is never sent back to stage 5. It keeps the checkout while it is
  monitored, because a rollback approval belongs to it, so a fix run starts in `claude --worktree`.
- **Learning.** The triager's diagnosis goes on the issue for the planner to read. The postmortem
  (ce-compound) and calibration lines for the originating run's agents happen at the bugfix run's
  stage 7, once the cause is known. `stats` reports escapes per originating run.
