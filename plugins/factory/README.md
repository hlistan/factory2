# factory

A Claude Code plugin that runs one feature at a time through eight stages, with human gates and
self-learning:

1. **Analyze and plan.** A product-level PRD with EARS acceptance criteria, a `contract.json` and an
   advisory `plan.md`.
2. **PRD review.** A separate reviewer agent, then you.
3. **Fix the PRD.** Revise and loop back to 2; lessons are captured.
4. **Implement, tests first.** Tests at high effort, a red check, a test review, a freeze of the tests
   and the check-defining files, then code at low effort, re-run fresh at high on failure; docs; a
   draft PR.
5. **Review and fix.** Correctness, spec, security and maintainability lenses, a challenger, and a QA
   agent that drives the app; every fix starts with a failing test.
6. **Evidence.** Screenshots per viewport and a video with a chapter per criterion, in a review pack for
   you. Comments are routed as spec gap, defect or cosmetic.
7. **Merge and deploy**, after your confirmation, then a smoke test.
8. **Monitor**, with incidents routed back to stage 5.

Every agent runs on Opus 5.5 with effort set per role; `roles` in `.factory/config.yaml` overrides a
model or effort once `/factory:stats` shows the override holds up on your own runs.

## Install

```sh
claude plugin marketplace add EveryInc/compound-engineering-plugin
claude plugin marketplace add <factory marketplace: git URL or local path>
claude plugin install factory@factory
```

Then run `/factory:init` in each project.

## Commands

| Command | What it does |
|---|---|
| `/factory:init` | Checks the environment, runs the compound-engineering contract test, writes `.factory/config.yaml` for your stack |
| `/factory:run "<feature>"` | Starts a run; `/factory:run <slug>` resumes one |
| `/factory:status` | Where the active run stands |
| `/factory:monitor <slug>` | One round of production checks; use with `/loop 15m` |
| `/factory:stats` | Spend, first-pass rates, human-found issues and QA misses across runs |

## Requirements

- Claude Code 2.1.311 or later.
- `git`, `jq` and `python3` (the harness scripts use nothing else). Optional: `gh` (PRs and incident
  issues), `ffmpeg` (mp4 video), `docker` (pinned Playwright browsers).
- [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin) 3.21.1 or later,
  declared as a dependency and installed with factory.
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
- Deploy and rollback commands are blocked outside an approved stage 7.
- Agents never write their own memory. The orchestrator records one calibration line per miss in the
  run's committed history file, and folds the lines into each agent's `MEMORY.md` once, at stage 7,
  where they are reviewed in the PR. Memory is presented as reference material, not rules. A
  SubagentStart hook loads each agent's `MEMORY.md` (first 200 lines or 25 KB), so this works whether
  Claude Code's auto memory is on or off; agents use no `memory:` frontmatter.

## Credits

- Gate scripts (`guard-bash`, `test-guard`, `run-checks`, `subagent-stop`, `change-diff`) are ported
  from singularity 0.7.0 (MIT).
- Project knowledge capture and retrieval use
  [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin) by Every (MIT);
  `agents/learnings-researcher.md` is a port of its learnings-researcher at commit `f2762dd`.

MIT licensed.
