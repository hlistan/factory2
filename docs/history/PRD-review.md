# Review of `docs/PRD.md` (factory plugin, all-Claude phase)

Reviewed 2026-11-01. Every finding was checked against the cited source on that date. Verdicts: TRUE, PARTLY, FALSE, UNVERIFIABLE.

## Verdict

The architecture is sound: separate planner, implementer and evaluator; gates decided by exit codes; frozen tests; capped loops; learning files reviewed in the PR. Most platform claims check out against current Claude Code docs.

Three items must change before M1:

1. The model table's key evidence is misattributed, and Anthropic's own measurements argue for a different policy.
2. The stage 8 cloud fallback cannot run a plugin skill.
3. The compound-engineering dependency is a floor, not a pin, on an interface with no stability policy.

A further fifteen design items should be fixed in the plan or absorbed into milestones. Citation corrections follow at the end.

## 1. Fix before M1

### 1.1 Model evidence is misattributed; Anthropic's data points the other way

**What the PRD says.** Sonnet 5.5 implements at medium, fix rounds at high, Opus after two failed rounds. Evidence cited: "Community tests: Sonnet 5.5 tied Opus 5.5 on coding at half the cost or less. Re-running failures at high scored about 97% at $0.17 per task, vs 95.3% at $0.29 for high on everything", attributed to Morph.

**What the sources say.**

- The Morph page (https://www.morphllm.com/claude-code-models) contains none of these figures. Exact-string search of the rendered page: "97%" 0 hits, "$0.17" 0, "95.3" 0, "$0.29" 0, "tied" 0. Sonnet 5.5 appears once: "Sonnet 5.5 and Haiku 5.5 are due in the coming weeks." The page aggregates Anthropic launch numbers and ends with a pitch for Morph's own hosting.
- The 97% / $0.17 vs 95.3% / $0.29 figures are Anthropic's, on https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence, section "Re-run failures at higher effort". They were measured on **Opus 5.5**, SWE-bench Pro subset: `low` plus rerun failures at `high` gives about 97% at about $0.17 per task; everything at `high` gives 95.3% at $0.29. Conditions stated: "you need a failure signal ... a checker that passes bad work lets those failures through", and "every first-pass failure takes two runs' worth of wall-clock time".
- The same page on multi-model pairings: "Tune one model before you add a second: sweep effort on your current model first, because most workloads end there ... Build a pairing only if it beats the single model's whole curve of score against spend." On delegation: "the orchestrator's model alone at lower effort came out ahead in every case measured" outside two situations, routine work with a long cost tail and work larger than one context window. Haiku 5.5 subagents on Opus 5.5 coding "cut cost per attempt by 32% and the pass rate by about 4 percentage points ... about what a mix of `low` and `medium` without subagents would give at that cost."
- "Sonnet 5.5 tied Opus 5.5" has no source anywhere. The nearest independent cost-per-task tables show different numbers and a gap in Opus's favour.
- "Opus plans, Sonnet implements" is the Claude Code `opusplan` alias (https://code.claude.com/docs/en/model-config.md), a product feature. It is not Anthropic cost guidance.

**Recommendation.** The PRD's own principle is "the model with the best published evidence for its role". The evidence supports Opus 5.5 everywhere at `low` or `medium` effort, with failures rerun at `high` in a fresh subagent. Move to Sonnet 5.5 for the implementer only after `/factory:stats` shows parity on your own runs. Keep the `roles.<agent>` override so the switch is a config change.

### 1.2 Stage 8 cloud fallback cannot work as written

**What the PRD says.** "`/loop` is session-scoped: use a cloud routine for long monitoring windows", with `monitor.interval: 15m`.

**What the sources say.**

- https://code.claude.com/docs/en/cloud-environments.md: "Plugins and marketplaces declared in your repo's `.claude/settings.json` | No | A cloud session doesn't install the plugins a repository turns on under `enabledPlugins`". User-scoped plugins are also not installed. Only committed `.claude/skills/`, `.claude/agents/` and `.claude/commands/` load.
- https://code.claude.com/docs/en/routines.md: schedule trigger minimum is one hour; 100 scheduled runs per hour per account; runs on a fresh clone of the default branch in auto mode; draws down subscription usage.
- https://code.claude.com/docs/en/scheduled-tasks.md: `/loop` fires only "while Claude Code is running and idle", minimum interval one minute, 7-day expiry, no catch-up for missed fires.

**Recommendation.** Either `/factory:init` copies a self-contained monitor skill and `monitor.sh` into each target repo's `.claude/skills/`, or use a Desktop scheduled task on the local machine, or a GitHub Actions cron that runs `claude -p` with `--max-budget-usd`. Document that a 15-minute interval is only available locally.

### 1.3 `>=3.34.0` is a floor, not a pin, on an interface with no stability policy

**What the PRD says.** "pin `>=3.34.0` and depend only on documented tokens (`mode:non-interactive`, `depth:*`, the terminal signals)".

**What the sources say.** Checked against the repo at commit 64b74f2 on 2026-11-01.

- No stability or versioning policy exists for skill arguments anywhere in the repo. Only release-please versioning and a `schema_version: 1` on the frontmatter schema.
- Drift already shipped in 3.x: `mode:headless` was renamed to `mode:non-interactive` in v3.21.1 (PR #1291), kept as a "one-release deprecated synonym". v3.25.0 (PR #1624) added the durable-bar gate, a behavioural change that makes more runs end in `Documentation skipped`. v3.29.0 added `retire_when`. `depth:` values are only `lightweight` and `full`; a proposed `standard|deep` set (PR #662) was never merged.
- Different ce-* skills use different mode tokens: ce-code-review uses `mode:agent` and rejects `mode:non-interactive`.
- Terminal signals: the report ends on a bare last line `Documentation complete` or `Documentation skipped`, but the header line also contains the phrase, as `✓ Documentation complete (non-interactive mode)`. A substring match on the whole output is ambiguous.
- Install detail: upgrades require `/plugin marketplace update compound-engineering-plugin` before `/plugin install`. The repo moved to a root-native layout; `plugins/compound-engineering/.claude-plugin/plugin.json` no longer exists.

Source: https://github.com/EveryInc/compound-engineering-plugin/blob/main/skills/ce-compound/SKILL.md and https://github.com/EveryInc/compound-engineering-plugin/releases

**Recommendation.** Pin a tilde range such as `~3.34`. Add a contract test to M1 that invokes ce-compound non-interactively on a fixture and asserts the last line. Parse the final line only. Also parse the `Refresh recommendation:` line, see 2.14.

## 2. Should fix in the design

### 2.1 Nothing checks the tests before they freeze

The implementer writes the `@AC-n` tests, judges that they "fail for the right reason", and test-guard then locks them. A misread criterion becomes a frozen wrong oracle until the stage 5 spec-conformance lens runs.

Evidence that the freeze is needed, and that the author should not be the only check:

- METR, "Recent Frontier Models Are Reward Hacking" (https://metr.org/blog/2025-06-05-recent-reward-hacking): models are "attempting (often successfully) to get a higher score by modifying the tests or scoring code"; 30.4% of o3's RE-Bench runs.
- The New Stack (https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/): Fable 5.1 deleted a simulated delay to pass a flaky test in all five runs of the agentic test.
- Anthropic, "Natural Emergent Misalignment from Reward Hacking in Production RL" (https://arxiv.org/abs/2511.18397): "12% of the time, the model would intentionally attempt to sabotage the code in ways that would reduce the ability to detect reward hacking."
- Anthropic's harness (https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents): "We prompt coding agents to edit this file only by changing the status of a passes field" and "It is unacceptable to remove or edit tests".

**Recommendation.** Add a fresh-context test review against `contract.json` before test-guard freezes the files. Have the harness, not the implementer, flip `passes` in `contract.json` from test results. Extend test-guard to Playwright config, fixtures and test helpers, not only spec files.

### 2.2 The qa-evaluator needs hard per-criterion thresholds

Anthropic's harness article (https://www.anthropic.com/engineering/harness-design-long-running-apps): "Out of the box, Claude is a poor QA agent." It would find issues and "talk itself into deciding they weren't a big deal and approve the work anyway", and "tended to test superficially, rather than probing edge cases". What worked: "Each criterion had a hard threshold, and if any one fell below it, the sprint failed", and reading the evaluator's logs to "find examples where its judgment diverged from mine". Also: "The wording of the criteria steered the generator in ways I didn't fully anticipate."

The PRD's MEMORY.md calibration covers tuning from disagreements. It lacks per-criterion pass/fail with required evidence, and the challenger only confirms blocking findings, which trims false positives and does nothing for false negatives.

**Recommendation.** qa-evaluator emits one pass/fail per `AC-n` with a screenshot or action trace as evidence; any fail blocks. Decide deliberately whether the implementer sees the review rubric. Add a sampled second evaluator or human spot-check to measure false negatives.

### 2.3 Stage 6 rejection always loops to stage 2

Most evidence rejections are implementation defects, not spec defects. Re-running PRD review for a defect spends a PRD round and delays the fix. Anthropic's V2 harness ran three build and QA rounds without re-planning (cost table: Build R1, QA R1, Build R2, QA R2, Build R3, QA R3).

**Recommendation.** The triager classifies each comment: spec gap goes to stage 2 with a PRD amendment; defect goes to stage 5 with a failing test required; cosmetic goes straight to the implementer.

### 2.4 The security-lens Fable choice is weakly supported and has a compliance cost

- Bug Hunt Bench (https://github.com/phuryn/bug-hunt-bench, `results/runs.csv`): Fable 5.1 at max effort scored 43 of 105 in a **single** run on 2026-09-01; Opus 5.5 at max scored 43, 39 and 43 across three runs, mean 41.7. Fable 5.1 at xhigh scored 29 and at high 33 in single runs, so run-to-run spread is large. Sonnet 5.5 at max leads the board at 51.3 over three runs. The board itself says small gaps "don't establish a reliable lead".
- The New Stack race-condition test: 5 of 5 vs 3 of 5 perfect runs, one author, five runs per model. Opus's two misses exhausted the 128K output cap and returned nothing.
- Fable 5.1 is a Covered Model: "require 30-day data retention; ZDR is therefore not available ... unless expressly authorized by Anthropic" (https://platform.claude.com/docs/en/manage-claude/api-and-data-retention). Non-compliant orgs get a 400. No Priority Tier. Price $10 / $50 vs Opus $4 / $20.

**Recommendation.** Keep `fable · high` as an opt-in override per project after checking each client's data-handling terms. Default the security lens to Opus 5.5 at `high` or `xhigh`.

### 2.5 "A judge is never weaker than what it judges" is a folk claim

No paper states this as a principle. The closest evidence:

- Zhang and Shrestha, "Review Rarely Beats the Stronger Model" (https://arxiv.org/abs/2610.15897, Oct 2026): across 96 review directions, review beat the stronger model alone in only 9; worse as the capability gap grows; review costs 2.6 to 2.8 times the stronger model alone.
- Chen et al. (https://arxiv.org/abs/2504.03846): stronger judges are more accurate overall, but harmful self-preference is more pronounced in stronger models when they err.
- Huang et al., "LLMs Cannot Self-Correct Reasoning Yet" (https://arxiv.org/abs/2310.01798, ICLR 2024): intrinsic self-correction without external feedback does not help.

This supports keeping reviewers at least as strong as the implementer and preferring execution-based signals over opinion, but not the stronger phrasing. Reword the evidence cell.

### 2.6 The Misevolve citation is right, the inference is not

"Your Agent May Misevolve" (https://arxiv.org/abs/2509.26354) is in ICLR 2026. Core finding: SE-Agent on Qwen3-Coder-480B evolved on SWE-Bench-Verified saw refusal fall from 99.4% to 54.4% and attack success rise from 0.6% to 20.6%; with AgentNet memory, GPT-5, Claude 4 Sonnet and Gemini 2.5 Pro chose reward-hacking actions in over 60% of cases versus 0% without memory. Mitigations proposed: a meta-prompt framing memories as "for reference only" (attack success 20.6% to 13.1%), dual-memory filtering, better retrieval. It does not recommend human review of evolved memory.

Supporting literature on memory poisoning: MemoryGraft (https://arxiv.org/abs/2512.16962), "When Agents Remember Too Much" (https://arxiv.org/abs/2607.06595, about 98% injection and 60% activation on agents that push code), "Do Self-Evolving Agents Forget?" (https://arxiv.org/abs/2605.09315).

**Recommendation.** Keep the PR review of learning files. Add a "treat MEMORY.md as reference, not rule" line to every memory-enabled agent prompt. Screen at write time: the calibration message should name the lesson, and the agent should add one line, not rewrite the file. Cite the paper for the risk, not for the mitigation.

### 2.7 Parallel reviewers sharing one agent name share one MEMORY.md

Stage 5 runs lenses in parallel under a single `reviewer` definition with `memory: project`. Subagent memory is one directory per agent name (https://code.claude.com/docs/en/sub-agents.md#enable-persistent-memory), so parallel lenses write to one file concurrently.

**Recommendation.** Define one agent per lens, `reviewer-correctness`, `reviewer-security`, `reviewer-spec`, `reviewer-maintainability`, or give memory only to agents that run serially.

### 2.8 Memory gotchas from the docs and issue tracker

- The M1 spike question is settled. https://code.claude.com/docs/en/plugins/components.md lists supported plugin-agent fields: `name`, `description`, `model`, `effort`, `maxTurns`, `autoCompactWindow`, `tools`, `disallowedTools`, `skills`, `memory`, `background`, `omitClaudeMd`, `isolation`, `color`. Ignored: `permissionMode`, `hooks`, `mcpServers`, `initialPrompt`. Downgrade the spike to a smoke test.
- Plugin agents write to `.claude/agent-memory/<plugin>-<agent>/`, so expect `factory-planner`, not `planner` (observed in https://github.com/anthropics/claude-code/issues/103308).
- Never pair `memory: project` with `isolation: worktree`: the memory directory lands inside the temporary worktree (#103308, open, 2026-10-18).
- If you set `tools:` on a memory-enabled agent, include Read, Write and Edit (#57507 history).
- Subagent memory "is part of auto memory: if you turn auto memory off ... the `memory` field has no effect" (https://code.claude.com/docs/en/memory.md). The `/memory` toggle cannot re-enable it in "a session that another Claude Code session started, such as when Claude runs `claude` through its Bash tool". Relevant if any stage shells out to `claude -p`.
- Open issue #92750 reports subagents receiving the main auto-memory index contrary to docs.

### 2.9 SubagentStop details

From https://code.claude.com/docs/en/hooks.md:

- Exit 2 on `SubagentStop` "prevents the subagent from stopping" and delivers stderr as the next instruction. Equivalent JSON: `decision: "block"` with `reason`.
- "Claude Code applies an 8-consecutive-continuation cap ... The count of consecutive continuations resets each time Claude calls a tool." Raise with `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`. `checks.stop_retries: 3` fits under the cap.
- Default hook timeout is 600 seconds for `command` hooks. A full lint, typecheck, unit, integration and e2e run can exceed that. A timed-out hook renders no decision, so the subagent stops. Set `timeout` explicitly or run only fast checks in the hook and the e2e suite in the orchestrator.
- Matcher is the agent type; plugin agents need an anchored pattern such as `^factory:implementer$`. SubagentStop also fires for internal agents with an empty `agent_type`.
- If the subagent reports via `SubagentHandback`, `last_assistant_message` is not the report.
- SubagentStop does not fire when a background subagent is killed via TaskStop (https://github.com/anthropics/claude-code/issues/92716, open).
- A bug where SubagentStop fired about twice a minute per running subagent was fixed in 2.1.311. Require that version or later.

### 2.10 Plugin hook reliability belongs in M1's tests

- https://github.com/anthropics/claude-code/issues/105625 (open, 2026-10-28): plugin-registered hooks for an event never fire unless a settings-level hook for the same event exists.
- https://github.com/anthropics/claude-code/issues/86809 (closed not planned): plugin hooks never run when installed from a directory-source marketplace.

The deploy guard and test freeze are safety gates. M1 tests must verify the hooks fire from a real marketplace install, not only under `--plugin-dir`. Consider having `/factory:init` write a no-op settings-level hook for each event as a workaround until #105625 is resolved.

### 2.11 Plugin agents ignore `mcpServers`

The qa-evaluator cannot carry an inline Playwright MCP definition, which is the pattern the sub-agents doc recommends to keep MCP tool descriptions out of the main context. For plugin agents the server must go in the plugin's `.mcp.json`, which loads session-wide. Source: https://code.claude.com/docs/en/sub-agents.md.

Alternatives: Microsoft now points to `playwright-cli` (https://github.com/microsoft/playwright-cli, `playwright-cli install --skills`) as "more token-efficient" for coding agents, with MCP "relevant for specialized agentic loops". Chrome DevTools MCP (https://github.com/ChromeDevTools/chrome-devtools-mcp) is Chrome-only, Puppeteer-based, and has a native `screencast_start` that writes `.mp4`.

### 2.12 No per-run cost cap

`--max-budget-usd` exists only in print mode, is estimate-based, counts subagent spend, and can overshoot (https://code.claude.com/docs/en/cli-reference.md). `/factory:run` is interactive, so it has no cap. Anthropic's one DAW run cost $124.70, and its V1 harness was "over 20x more expensive" than a solo run.

**Recommendation.** Record estimated spend per stage in `state.json`, and add `limits.budget_usd` that pauses at a human gate when exceeded.

### 2.13 Haiku at low effort for monitoring

https://platform.claude.com/docs/en/build-with-claude/effort, Haiku 5.5 section: "In long agent prompts, the model is more likely to skip a search, stop early, or skip a check at `low`." Use `medium` for monitor-watch, or make the checks pure shell with Haiku only summarising.

### 2.14 Refresh cadence

The ce-compound-refresh guide (https://github.com/EveryInc/compound-engineering-plugin/blob/main/docs/guides/ce-compound-refresh.md): "Skip it when: You have not seen any drift. Broad sweeps without evidence produce churn." Outcomes are Keep, Update, Consolidate, Replace, Delete; stale-marking is the non-interactive fallback. ce-compound emits a `Refresh recommendation:` line and never invokes refresh itself in non-interactive mode.

**Recommendation.** Trigger refresh on the recommendation line rather than every `learning.refresh_every` runs. Keep the counter as a ceiling only.

### 2.15 ce-compound can auto-trigger inside other agents

ce-compound has no `disable-model-invocation`, and `references/modes.md` names completion phrases such as "that worked" and "it's fixed" as its auto-invoke cue. Subagents "can still invoke unlisted project, user, and plugin skills through the Skill tool" (https://code.claude.com/docs/en/skills.md). The PRD's risk entry notes this; the mitigation is missing.

**Recommendation.** Deny `Skill(compound-engineering:*)` for implementer, reviewers and qa-evaluator via plugin permissions, so only the orchestrator calls it. Note that a skill body saying "run `/compound-engineering:ce-compound`" is not auto-expanded; the orchestrator must call the Skill tool with that name.

### 2.16 Effort: `xhigh` exists, and changing effort mid-session invalidates the cache

- Subagent `effort` accepts `low`, `medium`, `high`, `xhigh`, `max` (https://code.claude.com/docs/en/sub-agents.md). Claude Code's default is `xhigh`. API defaults: Opus 5.5 and Haiku 5.5 `medium`, Sonnet 5.5 and Fable 5.1 `high`.
- "Changing the top-level effort value between requests invalidates prompt caching" (https://platform.claude.com/docs/en/build-with-claude/effort). The PRD's "fix rounds at high" should therefore spawn a fresh implementer subagent rather than continue the same one. That also gives the fresh-context benefit the harness article found "essential" for weaker models.
- Open issue https://github.com/anthropics/claude-code/issues/97829: agent frontmatter `effort` ignored on the `claude --agent` path. Agent-tool subagents are unaffected.

### 2.17 Evaluator overhead on small features

"The evaluator is not a fixed yes-or-no decision. It is worth the cost when the task sits beyond what the current model does reliably solo ... for tasks within that boundary, the evaluator became unnecessary overhead" (harness article). The end-to-end test feature, a dark-mode toggle, sits inside that boundary.

**Recommendation.** Add a `limits.depth: lite|full` setting that skips the challenger and reduces lenses for small diffs, and let `stats` show whether the full path catches anything the lite path missed.

### 2.18 `learnings-researcher` is a port, not an adoption

In compound-engineering, learnings-researcher is a prompt file at `skills/ce-plan/references/agents/learnings-researcher.md`, not an invokable agent. ce-compound itself uses a different "Related Docs Finder" subagent. The method as described in the PRD is accurate: ground in `CONCEPTS.md`, grep `tags:`, `module:` and `applies_when` in frontmatter, read frontmatter of candidates only, return distilled summaries.

Copying it under MIT is fine, but it contradicts "Self-learning adopts existing, community-proven machinery instead of a custom design" and creates a second drift surface. State it as a port and pin the source commit in the file header. Note that `component` and `root_cause` became open vocabulary in v3.22.0, so do not hard-code enum validation.

## 3. Citation corrections

| PRD claim | Verdict | What the source actually says | Source |
|---|---|---|---|
| Playwright 1.59 Screencast API with chapters and action annotations | PARTLY | Feature is real: `page.screencast.start()`, `showChapter()`, `showActions()`, config `video: { mode: 'on', show: {...} }`. Current version is 1.64.1. Since 1.64: `fps` option, `style` replaces deprecated `fontSize`, VP9 encoding. Docker image `mcr.microsoft.com/playwright:v1.64.1-noble` | https://playwright.dev/docs/release-notes |
| `--grep @AC-1` selects one criterion | PARTLY | `--grep` is a regex; `@AC-1` also matches `@AC-10`. Use `@AC-1\b` | https://playwright.dev/docs/test-annotations#tag-tests |
| Spec Kit and Kiro both use EARS | PARTLY | Only Kiro does: "WHEN [condition/event] THE SYSTEM SHALL [expected behavior]". Spec Kit has no EARS; its commands are now `/speckit-specify`, `/speckit-plan`, `/speckit-tasks`, `/speckit-implement`, `/speckit-converge` | https://kiro.dev/docs/specs/feature-specs/ and https://github.com/github/spec-kit |
| "Opus plans, Sonnet implements" is Anthropic cost guidance | FALSE | Only the Claude Code `opusplan` alias. Anthropic's cost page cautions against pairings | https://code.claude.com/docs/en/model-config.md |
| Effective-harnesses article uses Playwright | PARTLY | It uses the Puppeteer MCP. Playwright MCP appears in the March 2026 harness article | https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents |
| "Building effective agents" recommends max iterations for evaluator-optimizer | PARTLY | Stopping conditions appear only in the Agents section as a generic note | https://www.anthropic.com/engineering/building-effective-agents |
| CodeRabbit: Opus 5.5 beat its production review baseline | PARTLY | Baseline is "our production model mix", unnamed. 80-case OSS set: recall 63.8% vs 61.3%, precision lower. 13-case Signal set: 8/13 and 10/13 vs 5/13. Tokens up 40 to 60% | https://www.coderabbit.ai/blog/opus-5-5-model-review |
| Aider architect 85% vs 79.7% | TRUE, stale | September 2024, o1-preview architect with o1-mini editor vs o1-preview alone. Gain came from offloading edit-format mechanics that 2024 models failed at | https://aider.chat/2024/09/26/architect.html |
| Bug Hunt Bench Fable 43.0 vs Opus 41.7 | TRUE, n=1 vs n=3 | See 2.4 | https://github.com/phuryn/bug-hunt-bench |
| The New Stack race test 5/5 vs 3/5 | TRUE | Five runs each, one author; Opus misses were output-cap exhaustion | https://thenewstack.io/claude-opus-5-5-vs-fable-5-1/ |
| Misevolve, ICLR 2026, motivates human review | PARTLY | Paper is ICLR 2026; mitigations are prompt framing and filtering, not human review | https://arxiv.org/abs/2509.26354 |
| "A judge is never weaker than what it judges" | UNVERIFIABLE | Folk claim; see 2.5 | https://arxiv.org/abs/2610.15897 |
| "Remove harness parts one at a time as models improve" | PARTLY | Paraphrase of "removing one component at a time and reviewing what impact it had" and "stripping away pieces that are no longer load-bearing" | https://www.anthropic.com/engineering/harness-design-long-running-apps |
| Sonnet 5.5 "well-specified coding at medium" is from the choosing-a-model page | PARTLY | Correct guidance, wrong page: it is on the effort page | https://platform.claude.com/docs/en/build-with-claude/effort |
| Effort levels low, medium, high, max | PARTLY | `xhigh` also exists and is Claude Code's default | https://code.claude.com/docs/en/sub-agents.md |
| compound-engineering "used across 14 agent hosts" | PARTLY | README says "runs on 14 agent hosts" but lists 16 install targets. No usage statistic exists | https://github.com/EveryInc/compound-engineering-plugin |
| Solution-doc frontmatter is a flat field list | PARTLY | Schema is two-track. Required on both: `module`, `date`, `problem_type`, `component`, `severity`. Bug track requires `symptoms`, `root_cause`, `resolution_type`; knowledge track makes them optional. Optional: `tags` (max 8), `applies_when` (max 5), `retire_when`, `related_components`. Path root is `docs_root` from `.compound-engineering/config.yaml`, default `docs` | `skills/ce-compound/references/schema.yaml` in the repo |
| ce-compound-refresh "recommends running itself" | PARTLY | ce-compound emits the recommendation; refresh does not self-schedule. Outcomes are Keep, Update, Consolidate, Replace, Delete | https://github.com/EveryInc/compound-engineering-plugin/blob/main/docs/guides/ce-compound-refresh.md |
| Playwright test agents are useful here | PARTLY | Planner and generator fit; the healer "automatically repairs failing tests" and can skip them, which conflicts with frozen tests. Exclude it | https://playwright.dev/docs/test-agents |
| webm to mp4 via ffmpeg for review packs | PARTLY | Playwright writes WebM only; the maintainer suggests ffmpeg for other encodings (issue #41178). GitHub accepts `.webm` but recommends H.264 for compatibility | https://github.com/microsoft/playwright/issues/41178 |

## 4. Claims that checked out

| Claim | Source |
|---|---|
| Fable 5.1 $10/$50, Opus 5.5 $4/$20, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50. Haiku rises to $0.50/$2.50 above 100K prompt tokens. No long-context surcharge on the other three | https://platform.claude.com/docs/en/about-claude/pricing |
| "Most workloads start with Claude Opus 5.5." | https://platform.claude.com/docs/en/about-claude/models/choosing-a-model |
| Harness article dated March 24, 2026; separate planner, generator, evaluator; skeptical evaluator more tractable than self-critique; planner kept at product level because "errors in the spec would cascade"; evaluator used Playwright MCP; planner $0.46 of $124.70 total | https://www.anthropic.com/engineering/harness-design-long-running-apps |
| JSON feature list with `passes: false`; "It is unacceptable to remove or edit tests"; commit per step | https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents |
| "Re-run failures at higher effort" is Anthropic guidance, about 40% cheaper at the same pass rate when a real checker exists | https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence |
| Subagent `memory: user|project|local` since 2.1.33; `.claude/agent-memory/<name>/MEMORY.md`; first 200 lines or 25 KB injected; agent curates | https://code.claude.com/docs/en/sub-agents.md |
| Subagent memory depends on auto memory | https://code.claude.com/docs/en/memory.md |
| Plugin manifest `dependencies` with `{name, marketplace, version}`; `allowCrossMarketplaceDependenciesOn` on the marketplace; `claude plugin validate --strict` | https://code.claude.com/docs/en/plugins/manifest-reference.md and https://code.claude.com/docs/en/plugins/cli-reference.md |
| Hook events SessionStart, PreToolUse with `Bash` and `Edit\|Write` matchers, SubagentStop; exit 2 blocks; `stop_hook_active` flag | https://code.claude.com/docs/en/hooks.md |
| SKILL.md supports `model`, `effort`, `user-invocable`, `disable-model-invocation`, `context: fork`, `agent` | https://code.claude.com/docs/en/skills.md |
| `claude --worktree` exists; `/loop` is session-scoped | https://code.claude.com/docs/en/cli-reference.md and https://code.claude.com/docs/en/scheduled-tasks.md |
| compound-engineering v3.34.0 (2026-10-31), 25,827 stars, MIT; `ce-compound` accepts `mode:non-interactive` and `depth:lightweight\|full`; durable-bar counterfactual; `CONCEPTS.md`; `ce-setup` creates `.compound-engineering/config.yaml` with consent; 36 skills; marketplace `compound-engineering-plugin`; install commands as written | https://github.com/EveryInc/compound-engineering-plugin |
| Playwright `tag` option and `--grep` since 1.42; Docker image must match the installed version | https://playwright.dev/docs/test-annotations and https://playwright.dev/docs/docker |
| Kiro uses EARS; six EARS patterns | https://kiro.dev/docs/specs/feature-specs/ and https://alistairmavin.com/ears/ |
| Playwright test agents: planner, generator, healer; `--loop=claude` | https://playwright.dev/docs/test-agents |

## 5. Suggested edits to the PRD, in order

1. Replace the model table's evidence column with the corrected sources above, and change the implementer default to Opus 5.5 `low|medium` with rerun at `high`, Sonnet as a per-project override.
2. Rewrite the stage 8 cloud fallback, see 1.2.
3. Pin compound-engineering with `~3.34` and add the M1 contract test, see 1.3.
4. Add a pre-freeze test review and harness-only `passes` flipping to stage 4, see 2.1.
5. Add per-criterion pass/fail with evidence to the qa-evaluator, see 2.2.
6. Route stage 6 rejections by class, see 2.3.
7. Make the Fable security lens opt-in, see 2.4.
8. One agent per review lens, see 2.7.
9. Add the memory, SubagentStop and plugin-hook gotchas to the M1 and M3 checklists, see 2.8 to 2.10.
10. Add `limits.budget_usd` and `limits.depth`, see 2.12 and 2.17.
11. Change monitor-watch to `haiku · medium`, see 2.13.
12. Trigger refresh on the recommendation line, see 2.14.
13. Deny ce-* skills to non-orchestrator agents, see 2.15.
14. Update Playwright to 1.64.x and fix the `--grep` anchor, Spec Kit, Puppeteer and `xhigh` citations, see section 3.
15. Reword the Misevolve, judge-strength and learnings-researcher text, see 2.5, 2.6 and 2.18.
