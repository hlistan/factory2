# Plan: `factory`, a Claude Code plugin for an 8-stage development harness (all-Claude phase)

## Context

You want a simple harness that runs one feature through eight stages:

1. analysis and planning
2. PRD review by a model and a human
3. PRD fixes, with self-improvement
4. implementation with unit, integration and Playwright tests, plus docs
5. review and fix, with self-improvement
6. screenshots and video for human approval (back to 2 on rejection)
7. merge and deploy
8. monitoring (back to 5 on an incident)

It is built as a Claude Code plugin.

Decisions so far:

- **This phase uses no OpenHands and no local models.** Sonnet 5.5 implements.
- **Each agent uses the model with the best published evidence for its role.**
- **Generic per-project commands** for deploy and monitoring.
- **Self-learning adopts existing, community-proven machinery** instead of a custom design.
- **The new plugin completely replaces `singularity` 0.7.0.** singularity is installed in three of the author's projects. Its learning system is custom and its orchestrator is heavy.
- **Where to build:** `~/src/factory2`, which is empty today.
- **What to reuse:**
  - singularity's gate scripts (MIT): `guard-bash.sh`, `test-guard.sh`, `run-checks.sh`, `subagent-stop.sh`, from `~/.claude/plugins/cache/singularity/singularity/0.7.0/scripts/`
  - its model research: `~/.claude/plugins/marketplaces/singularity/docs/models-and-effort.md`
  - the Playwright approach from `../factories`: three viewports and a Playwright Docker image matched to the app's version

## Self-learning: three adopted layers, nothing custom

| Layer | What it learns | Adopted from | Why it counts as proven |
|---|---|---|---|
| **1. Project knowledge**: durable lessons about what went wrong and why | One "solution doc" per lesson in `docs/solutions/<category>/*.md`, with YAML frontmatter: `module`, `problem_type`, `component`, `severity`, `symptoms`, `root_cause`, `resolution_type`, `tags`, `applies_when`, `retire_when`. Shared vocabulary goes in `CONCEPTS.md`. | **Every's compound-engineering plugin** (MIT, v3.34.0, about 25.8k stars, used across 14 agent hosts) | Widely adopted. Its "compound" step is the reference implementation of Plan → Work → Review → Compound. It has a **non-interactive mode built for callers like ours**. |
| **2. Per-agent calibration**: how each agent should behave in this project | `.claude/agent-memory/<agent>/MEMORY.md`. The first 200 lines or 25 KB are injected automatically, and the agent curates the file. Committed to the repo. | **Claude Code's built-in subagent `memory: project`** (since v2.1.33) | An official feature. It implements Anthropic's evaluator-tuning loop ("tune the evaluator from logged disagreements") without custom code. |
| **3. User preferences and corrections** typed in chat | Claude Code's auto memory | **Claude Code built-in** | Official. It replaces singularity's custom corrections hook. |

**How the stages use it:**

- **Capture.** Once a fix is verified, the orchestrator calls `/compound-engineering:ce-compound mode:non-interactive depth:full "<context>"`, one learning per call. That happens at these points:
  - after a PRD round where you caught something the reviewer missed (stage 3)
  - after each confirmed blocking finding is fixed, or a task is escalated (stage 5)
  - after an evidence rejection is resolved (stage 6)
  - after each incident's postmortem (stage 8)

  ce-compound applies its own *durable-bar counterfactual*: if the lesson can be recovered from the code or tests, it writes nothing. That keeps noise out. It ends with a parseable `Documentation complete` or `Documentation skipped`, which `state.json` records.
- **Calibration.** At the same points, each agent that missed something gets a message saying what the human or a later stage caught. It updates its own `MEMORY.md`. For example, a reviewer adds a rubric line or a few-shot example.
- **Retrieval.**
  - Before stage 1 and before the stage 5 review, a `learnings-researcher` agent runs. It follows compound-engineering's learnings-researcher method: read `CONCEPTS.md`, grep the frontmatter `tags`, `module` and `applies_when`, then distill.
  - Its output goes into the planner's context, and into the reviewers' context as "known risks, regression traps, missing-test patterns".
  - Each agent's own `MEMORY.md` loads automatically.
- **Maintenance.** `/compound-engineering:ce-compound-refresh mode:non-interactive` runs every `learning.refresh_every` runs, or when ce-compound recommends it. It keeps, updates, consolidates, deletes or marks docs stale.
- **Review.** All learning files (`docs/solutions/`, `CONCEPTS.md`, `.claude/agent-memory/`) are committed in the feature branch, so you review them in the PR. Evolving memory can degrade safety (*Your Agent May Misevolve*, ICLR 2026), which is why they go through review.
- **Measurement.** `.factory/runs.jsonl` records the problems humans found per stage, grouped by `problem_type` and `component`, plus first-pass rates, review rounds, escalations and incidents. `/factory:stats` shows whether repeat problems decline, which is the test of whether learning works.

## Grounding: other proven practices

| Practice | Source | Where |
|---|---|---|
| Separate planner, generator and evaluator. A skeptical standalone evaluator is easier to get right than self-critique. The planner stays at product level because spec errors cascade. The evaluator uses Playwright MCP on the live app. Remove harness parts one at a time as models improve. | Anthropic, *Harness design for long-running apps* (Mar 2026) | Stages 1, 2, 5, `/factory:stats` |
| A JSON criteria list (`passes:false`, tests may not be removed), git commits per step, end-to-end browser checks | Anthropic, *Effective harnesses for long-running agents* | `contract.json`, stage 4 |
| Evaluator-optimizer loops with a maximum iteration count | Anthropic, *Building effective agents* | Every loop is capped |
| Spec → plan → tasks, with acceptance criteria in EARS form | GitHub Spec Kit, Kiro | Stage 1 |
| Opus plans, Sonnet implements (`opusplan`). Retrying failures at higher effort beats raising everyone's effort. | Claude Code docs, Anthropic cost guidance | Models, fix rounds |
| Gates decided by exit codes, frozen tests, a SubagentStop check loop | singularity (ported) | Hooks |
| Playwright 1.59 Screencast API (chapters, action annotations), or `video:'on'` | Playwright release notes | Stage 6 |

## Models per agent (best published evidence, Nov 2026)

Prices per million tokens, input / output: Fable 5.1 $10/$50, Opus 5.5 $4/$20, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50.

| Agent | Model · effort | Evidence |
|---|---|---|
| Orchestrator `/factory:run`; it also invokes ce-compound and ce-compound-refresh | opus · high | Anthropic: "most workloads start with Opus 5.5". |
| `planner` (PRD, `contract.json`, plan) | opus · high | An architect sets the ceiling of an architect/editor pair (Aider 85% vs 79.7%). The planner cost $0.46 of a $124.70 run in Anthropic's harness. |
| `prd-reviewer` | opus · high | A judge is never weaker than what it judges; a separate skeptical evaluator. |
| `learnings-researcher` | sonnet · medium | Retrieval and distillation that the planner or reviewer re-checks. |
| `implementer` (tests, code, docs) | **sonnet · medium**; fix rounds at **high**; **opus · high** after 2 failed rounds | Anthropic: Sonnet 5.5 at medium for well-specified coding. Community tests: Sonnet 5.5 tied Opus 5.5 on coding at half the cost or less. Re-running failures at high scored about 97% at $0.17 per task, vs 95.3% at $0.29 for high on everything. |
| `reviewer` (one per lens), `challenger` | opus · high; the security lens uses **fable · high** on changes in the risk list | CodeRabbit: Opus 5.5 beat its production review baseline. Bug Hunt Bench: Fable 43.0 vs Opus 41.7, about even. The New Stack race-condition test: Fable 5/5 vs Opus 3/5. |
| `qa-evaluator` (Playwright or chrome-devtools MCP) | opus · high | Anthropic's evaluator setup. It checks Sonnet's work. |
| `triager` (sorts human comments, finds the root cause of incidents) | opus · high | Diagnosis without one right answer. |
| `monitor-watch` (runs the checks each interval) | haiku · low; escalates to triager | Mechanical and frequent, with exit codes as the check. |
| `researcher` (optional outside facts) | sonnet · high | The planner and the gate re-check it. |

Every agent sets `effort` explicitly. Nothing defaults to `max`. All of these can be overridden per project with `roles.<agent>.{model,effort}`, so a later phase can rebind `implementer`.

## Stages

| # | What happens | Agents | Gate and loop |
|---|---|---|---|
| 1 Analyze and plan | learnings-researcher first. Then `prd.md`: problem, users, scope and non-goals, UX flows, **EARS AC-n**, NFRs, risks, rollout and feature flag, **monitoring signals**, test level per criterion. Then `contract.json` (`{id,text,test_ids:[],passes:false}`) and `plan.md` (small verifiable steps, tests first). | planner | none |
| 2 PRD review | A fresh-context rubric review: each criterion testable, ambiguity, conflicts with the code, security and privacy, edge cases, observability, rollout. Then the **human gate** shows a one-screen summary plus the findings, and your comments go to `feedback/prd-<n>.md`. | prd-reviewer, you | Approve, or go to 3 |
| 3 Fix PRD and self-improve | The planner revises. Calibration: prd-reviewer and planner update their memory with what you caught. Capture: ce-compound for each lesson that generalizes. | planner, orchestrator | Back to 2, at most 3 rounds |
| 4 Implement | Branch `factory/<slug>` with a baseline of failing checks. **(a)** Tests tagged `@AC-n` (unit, integration, Playwright e2e) that fail for the right reason, then frozen by test-guard. **(b)** The code. **(c)** README, docs and CHANGELOG. The **SubagentStop hook** keeps the implementer working while checks fail, up to `checks.stop_retries`. The harness commits after each phase. | implementer | Hook loop, then the escalation ladder |
| 5 Review and fix | learnings-researcher gives the reviewers known risks. Mechanical checks first, then lenses in parallel: correctness, security and spec-conformance (blocking), maintainability (advisory). A challenger confirms each blocking finding. The qa-evaluator drives the running app per criterion. Each confirmed finding gets a failing test, then the fix. Re-review only the lenses that blocked. Then calibration plus ce-compound. | reviewer, challenger, qa-evaluator, implementer | At most 2 rounds, then opus implementer, then you |
| 6 Evidence | The `@AC-n` e2e specs **are** the demo script. They run under `playwright.demo.config.ts` (Screencast chapters, action annotations, slowMo; `video:'on'` as the fallback), with screenshots at 1440, 768 and 390 widths. `evidence.sh` converts with ffmpeg and builds `review-pack/index.html`: criterion checklist, a clip and screenshots per criterion, test results, resolved findings, diff stats, risks. It opens locally. An optional `evidence.publish` command posts it to the PR. | script, you | Approve, or the triager classifies your comments, **amends the PRD (back to 2)**, and the delta re-runs through 4 and 5. Then calibration and ce-compound. |
| 7 Merge and deploy | Preconditions: approval recorded against the evidence SHA, checks green, no commits since. Then `ship.merge`, `ship.deploy` (after your explicit confirmation), `ship.smoke` (Playwright `@smoke` against production), and `ship.rollback` if smoke fails. The deploy marker and baseline are recorded. | orchestrator | You confirm |
| 8 Monitor | `/loop <interval> /factory:monitor <slug>` (or a cloud routine) for `monitor.window_hours`. monitor-watch runs `monitor.checks` against the baseline. On an anomaly, the triager correlates it with the deploy SHA, rollback runs if `auto_rollback` is set, `incidents/I-n.md` is written, and the run goes **back to 5** with a reproducing test required. Then the postmortem through ce-compound (`depth:full`). | monitor-watch, triager | Back to 5 |

**State:** `.factory/runs/<slug>/state.json` holds the stage, round counters, gate approvals with SHAs, escalations, the models used, and ce-compound outcomes. `/factory:run <slug>` resumes from the recorded stage. One run per checkout, enforced by a lock file; parallel runs use `claude --worktree`.

## Plugin layout (`factory2/`, a marketplace repo)

```
.claude-plugin/marketplace.json     name "factory" → ./plugins/factory;
                                    allowCrossMarketplaceDependenciesOn: ["compound-engineering-plugin"]
plugins/factory/
  .claude-plugin/plugin.json        name, version 0.1.0, description,
                                    dependencies: [{name: "compound-engineering", marketplace: "compound-engineering-plugin", version: ">=3.34.0"}]
  skills/run/SKILL.md               /factory:run <request|slug> [--from <stage>]   (model: opus, effort: high)
  skills/{init,monitor,status,stats}/SKILL.md
  skills/{prd-format,review-rubric,evidence}/SKILL.md     (user-invocable: false, reference only)
  agents/{planner,prd-reviewer,learnings-researcher,implementer,reviewer,challenger,qa-evaluator,triager,monitor-watch,researcher}.md
                                    (memory: project on planner, prd-reviewer, implementer, reviewer, challenger, qa-evaluator, triager)
  hooks/hooks.json   SessionStart (active runs) · PreToolUse Bash (guard; deploy and rollback only in stage 7 with approval)
                     · PreToolUse Edit|Write (frozen tests) · SubagentStop (checks loop)
  scripts/  guard-bash.sh test-guard.sh run-checks.sh subagent-stop.sh   (ported and trimmed from singularity)
            state.sh (state.json, lock, runs.jsonl)  evidence.sh  ship.sh  monitor.sh
  templates/ factory.config.yaml  playwright.demo.config.ts  review-pack.html  gitignore.txt
tests/   bash tests per script (fixtures: a small sample repo)
README.md (credits compound-engineering)  CHANGELOG.md
```

- **`/factory:init`:**
  - checks that compound-engineering is installed and enabled, and if not, prints `/plugin marketplace add EveryInc/compound-engineering-plugin` and `/plugin install compound-engineering`
  - runs `/compound-engineering:ce-setup` (creates `.compound-engineering/config.yaml`)
  - writes `.factory/config.yaml`
  - checks that auto memory is on, since subagent memory depends on it
- **Committed in each target repo:** `.factory/config.yaml`, `.factory/runs.jsonl`, `docs/specs/<slug>/{prd.md,contract.json,plan.md}`, `docs/solutions/`, `CONCEPTS.md`, `.claude/agent-memory/`
- **Git-ignored:** `.factory/runs/<slug>/` (state, reviews, evidence, video)

**Example per-project config:**

```yaml
project:  {default_branch: main, start: "npm run dev", url: http://localhost:3000, ready: /health}
checks:   {lint: "npm run lint", typecheck: "npm run typecheck", unit: "npm test", integration: "...", e2e: "npx playwright test", stop_retries: 3}
roles:    {}   # overrides, e.g. implementer: {model: opus, effort: low}
limits:   {prd_rounds: 3, review_rounds: 2, evidence_rounds: 3}
evidence: {viewports: [1440x900, 768x1024, 390x844], publish: ""}
ship:     {merge: "gh pr merge --squash", deploy: "...", smoke: "BASE_URL=... npx playwright test --grep @smoke", rollback: "..."}
monitor:  {window_hours: 24, interval: 15m, auto_rollback: false, checks: [{name: health, cmd: "curl -fsS .../health"}]}
learning: {enabled: true, compound_depth: full, refresh_every: 10}
```

## Build order

1. **M1.** Marketplace, plugin skeleton and the dependency declaration (`claude plugin validate` must pass with the cross-marketplace dependency). `/factory:init`, `state.sh`, the ported hooks and their tests.
   - **Spike:** confirm that `memory: project` works on *plugin* subagents. The docs list only `hooks`, `mcpServers`, `permissionMode` and `initialPrompt` as ignored, but don't confirm it. If it doesn't work, `/factory:init` installs those agents as project agents in `.claude/agents/`.
2. **M2.** Stages 1–3, including learnings-researcher retrieval, calibration and the ce-compound capture call (parsing the terminal signal).
3. **M3.** Stage 4: implementer, test freeze, the SubagentStop loop, harness commits, the escalation ladder.
4. **M4.** Stage 5: lenses, challenger, qa-evaluator, fix rounds, calibration and capture.
5. **M5.** Stage 6: demo config, `evidence.sh`, the review pack, comment triage that loops back to 2.
6. **M6.** Stages 7–8: `ship.sh`, the deploy guard, `monitor.sh` with monitor-watch, the incident loop back to 5, the postmortem capture.
7. **M7.** `stats` and the scheduled ce-compound-refresh. Then **migrate off singularity**, each step after your OK:
   - remove `singularity@singularity` from the 3 projects' settings and `extraKnownMarketplaces.singularity` from `~/.claude/settings.json`
   - add the compound-engineering and factory marketplaces, install the plugins, and run `/factory:init` in each project

## Verification

- `claude plugin validate --strict plugins/factory`, then run with `claude --plugin-dir plugins/factory` in a sample repo, with compound-engineering installed.
- Bash tests check that the guard blocks force-push, `--no-verify`, and deploy outside stage 7 or without approval; that test-guard blocks edits to frozen tests; that the subagent-stop loop exits 2 while checks fail and stops at its cap; that `run-checks` exit codes are right; and that `state.sh` can resume and enforce the lock.
- **End to end** on a sample Next.js app (`../factories/examples`), feature "add a dark-mode toggle":
  - stages 1–6 with real gates
  - **learning check:** give one deliberate PRD comment about a class of issue, for example "no empty-state criterion". Verify:
    - `prd-reviewer`'s `MEMORY.md` gains a rubric line
    - ce-compound either writes a `docs/solutions/` doc or reports `Documentation skipped` with a reason
    - a second feature run's prd-reviewer flags the same class of issue on its own
  - one evidence rejection: the PRD is amended and the delta re-implemented
  - stage 7 against a local "prod" (`docker compose up` as the deploy, `curl` as the smoke test)
  - stage 8 with an injected fault (a broken `/health`): incident, rollback, back to 5, a postmortem doc in `docs/solutions/`
- `runs.jsonl` records the model used by each agent and the ce-compound outcome per capture point.

## Risks

- **compound-engineering interface drift:** pin `>=3.34.0` and depend only on documented tokens (`mode:non-interactive`, `depth:*`, the terminal signals). The M1 spike checks them.
- **compound-engineering adds 36 skills:** some may trigger on their own. The orchestrator calls only ce-compound, ce-compound-refresh and ce-setup; the rest stay usable on their own.
- **Plugin-subagent memory support:** covered by the M1 spike and the project-agent fallback.
- **Cost of Opus agents:** effort is capped at high, loops are capped, and `stats` reports cost per stage.
- **Evidence video in private repos:** local first, publishing is opt-in.
- **`/loop` is session-scoped:** use a cloud routine for long monitoring windows.

## Sources

- compound-engineering plugin: https://github.com/EveryInc/compound-engineering-plugin
  - ce-compound skill: https://github.com/EveryInc/compound-engineering-plugin/blob/main/skills/ce-compound/SKILL.md
  - ce-compound-refresh: https://github.com/EveryInc/compound-engineering-plugin/blob/main/docs/guides/ce-compound-refresh.md
  - knowledge systems overview: https://deepwiki.com/EveryInc/compound-engineering-plugin/7-knowledge-systems
- Claude Code docs:
  - subagent memory: https://code.claude.com/docs/en/sub-agents.md
  - auto memory: https://code.claude.com/docs/en/memory.md
  - plugin manifest and dependencies: https://code.claude.com/docs/en/plugins/manifest-reference.md
  - hooks: https://code.claude.com/docs/en/hooks.md
  - scheduled tasks: https://code.claude.com/docs/en/scheduled-tasks.md
- Anthropic, harness design: https://www.anthropic.com/engineering/harness-design-long-running-apps
- Anthropic, effective harnesses: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Anthropic, building effective agents: https://www.anthropic.com/engineering/building-effective-agents
- Anthropic model guidance:
  - choosing a model: https://platform.claude.com/docs/en/about-claude/models/choosing-a-model
  - effort: https://platform.claude.com/docs/en/build-with-claude/effort
- Model comparisons:
  - CodeRabbit: https://www.coderabbit.ai/blog/opus-5-5-model-review
  - The New Stack: https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/
  - Morph: https://www.morphllm.com/claude-code-models
- Spec Kit: https://github.github.com/spec-kit/
- Kiro EARS specs: https://codemyspec.com/blog/kiro-specs-explained
- Playwright test agents: https://playwright.dev/docs/test-agents
