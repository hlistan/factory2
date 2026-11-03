# factory2

A Claude Code plugin that runs one feature at a time through eight stages, with human gates and
self-learning:

1. **Analyze and plan.** A draft PR opens with the request, and every planning step is committed and
   announced there. A product-level PRD with EARS acceptance criteria, a `contract.json` and a
   `plan.md` saying how it will be built (approach, decisions, steps, risks).
2. **PRD review.** A separate reviewer agent, then you on the PR: comments are corrections, and
   `/approve` approves the PRD and plan.
3. **Fix the PRD.** Revise and loop back to 2; lessons are captured.
4. **Implement, tests first.** Tests, a red check, a test review, a freeze of the tests
   and the check-defining files, then code at low effort, re-run fresh at high on failure; docs.
5. **Review and fix.** Correctness, spec, security and maintainability lenses, a challenger, and a QA
   agent that drives the app; every fix starts with a failing test.
6. **Evidence.** Screenshots per viewport and a video with a chapter per criterion, in a review pack for
   you. Comments are routed as spec gap, defect or cosmetic.
7. **Merge and deploy** once you've approved the evidence, then a smoke test. No further approval.
8. **Monitor.** An anomaly files an issue first; the fix is a new bugfix run
   (`/factory2:run --issue <ref>`) through every stage and gate. A rollback is a mitigation, run without
   an approval when the smoke test fails or the triager recommends it.

Every agent runs on Opus 5.5 at medium effort, except:

- `learnings-researcher`: Opus 5.5 at high.
- `researcher`: Sonnet 5.5 at high.
- `reviewer-security`: Fable 5.1 at high. If Fable isn't available to your account, set
  `roles.reviewer-security: {model: opus, effort: high}`.
- `implementer`: Opus 5.5 at low, with fresh re-runs at high.

Defaults live in each agent's frontmatter. `roles` in `.factory/config.yaml` overrides a model or effort
once `/factory2:stats` shows the override holds up on your own runs.

## Install

```sh
claude plugin marketplace add <factory2 marketplace: git URL or local path>
claude plugin install factory2@factory2
```

Then run `/factory2:init` in each project.

## Commands

| Command | What it does |
|---|---|
| `/factory2:init` | Checks the environment and writes `.factory/config.yaml` for your stack |
| `/factory2:run "<feature>"` | Starts a run; `/factory2:run <slug>` resumes one |
| `/factory2:run --issue <ref>` | Starts a bugfix run from an issue (GitHub number or URL, or a local incident file) |
| `/factory2:status` | Where the active run stands |
| `/factory2:monitor <slug>` | One round of production checks; use with `/loop 15m` |
| `/factory2:stats` | Spend, first-pass rates, human-found issues and QA misses across runs |

## Requirements

- Claude Code 2.1.311 or later.
- `git`, `jq` and `python3` (the harness scripts and the bundled ce-compound use nothing else). Optional: `gh` (PRs and incident
  issues), `ffmpeg` (mp4 video), `docker` (pinned Playwright browsers).
- For web projects, Playwright 1.59 or later and `@playwright/cli`.

Checks are your project's own commands. Each writes JUnit XML into `$FACTORY_REPORTS`, and a test names
an acceptance criterion with `@AC-n` in its title (or `AC_n` in a Go or Swift function name). The
harness, not an agent, decides that a criterion passes.

## How it stays honest

- Tests and the files that define the checks are frozen before any product code is written. Hooks
  block edits to them, and the implementer can't finish while a frozen file's hash has changed or the
  fast checks fail. In singularity's words, the guards are "a seatbelt against mistakes, not a security
  boundary": the hash checks detect what the hooks can't prevent.
- Read-only agents are checked by hashing the working tree before and after.
- The deploy command is blocked outside stage 7 with the evidence approved; rollback outside stage 7–8.
- Gate hooks fail closed: a guard that crashes or hangs blocks the action inside a factory2 project
  (`scripts/gate.sh`), instead of Claude Code's default of letting it through.
- Agents never write their own memory. The orchestrator records one calibration line per miss in the
  run's committed history file, and folds the lines into each agent's `MEMORY.md` once, at stage 7,
  where they are reviewed in the PR. Memory is presented as reference material, not rules. A
  SubagentStart hook loads each agent's `MEMORY.md` (first 200 lines or 25 KB), so this works whether
  Claude Code's auto memory is on or off; agents use no `memory:` frontmatter.

## Credits

- Gate scripts (`guard-bash`, `test-guard`, `run-checks`, `subagent-stop`, `change-diff`) are ported
  from singularity 0.7.0 (MIT).
- Project knowledge capture and retrieval come from
  [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin) by Every (MIT).
  `skills/ce-compound/` and `skills/ce-compound-refresh/` are unchanged copies from release 3.34.0
  (commit `f1b2499`), and `agents/learnings-researcher.md` is a port of its learnings-researcher
  (commit `f2762dd`, the same file in 3.34.0). `vendor/compound-engineering/` holds the license and the
  manifest the tests check the copies against; `tools/vendor-ce.sh` in the repo updates them.

MIT licensed.
