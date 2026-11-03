---
name: init
description: Set up factory in this project - check Claude Code, hooks and memory, write .factory/config.yaml for the project's stack, and install the monitor scheduler. Run once per project, and again after upgrading factory2.
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*) Read Glob Grep
---

# /factory2:init

`S=${CLAUDE_PLUGIN_ROOT}/scripts`, `T=${CLAUDE_PLUGIN_ROOT}/templates`.

1. **Doctor.** `bash $S/doctor.sh`. It checks: Claude Code ≥ 2.1.311; auto memory (a warning only: factory loads agent memory itself); neither
   `disableAllHooks` nor `allowManagedHooksOnly` set; no other enabled plugin named `factory`;
   `CLAUDE_CODE_EFFORT_LEVEL` unset (it overrides every agent's effort); the bundled ce-compound present;
   git, jq and python3 present (ce-compound's validators use python3); ffmpeg, gh and docker (optional).
   Show its output. Stop on any `FAIL` line and give the fix it prints.
2. **Learning docs.** Lessons go to `docs/solutions/`, or to `<docs_root>/solutions/` when
   `.compound-engineering/config.yaml` sets `docs_root` (the same file compound-engineering reads, so a
   project that also uses compound-engineering shares one knowledge base). Nothing to set up.
3. **Config.** If `.factory/config.yaml` exists, show what differs from the template and ask before
   changing anything. Otherwise copy `$T/factory.config.yaml` and fill it in from the project:
   - read the build files (package.json scripts, Makefile targets, go.mod, Package.swift, pyproject.toml,
     Cargo.toml) and set `checks.fast` (lint, typecheck, unit) and `checks.slow` (integration, e2e) to
     commands that exist and write JUnit XML into `$FACTORY_REPORTS` (see the template's examples);
   - set `checks.check_defining` to the stack's runner, lint and build configs and its lockfile;
   - set `project.start/url/ready`, `evidence.driver` (`playwright` for web apps, `command` or `none`
     otherwise), and leave `ship.deploy/smoke/rollback` empty unless the user gives them.
   Run each check command once with `bash $S/run-checks.sh --set all --live --tail 10` and fix the
   config until every check runs (failing is fine; "command not found" isn't). Show the final file and
   ask the user to confirm it.
4. **Playwright.** For web projects: `npm i -D @playwright/cli` (ask first), then
   `npx playwright-cli install --skills` (installs the project's `playwright-cli` skill, which
   qa-evaluator preloads through `skills:`; it can't call the Skill tool. A missing skill is skipped,
   and qa-evaluator falls back to `playwright-cli --help`). Copy
   `$T/playwright.demo.config.ts` to the project root if there is none (that template arrives with
   the evidence milestone, M5; skip this copy while it is missing and say so).
5. **Files.** Append `$T/gitignore.txt` to `.gitignore` (`.factory/runs/`, `.factory/incidents/`), create
   `.factory/history/`, copy `$S/monitor.sh` to `.factory/bin/monitor.sh` (CI and launchd run this copy; skip while
   `monitor.sh` doesn't exist yet, milestone M6).
6. **Scheduler**, per `monitor.scheduler`, only if the user wants it now: `github-actions` copies
   `$T/github-actions-monitor.yml` to `.github/workflows/factory-monitor.yml`; `launchd` fills
   `$T/launchd-monitor.plist` and shows the `launchctl bootstrap` command for the user to run. (Both templates and `monitor.sh`
   arrive with milestone M6; until then say the scheduler isn't available yet.)
7. Summarise what was written and suggest committing it, then `/factory2:run "<feature>"`.
