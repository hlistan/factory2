---
name: init
description: Set up factory in this project - check Claude Code, hooks and memory, write .factory/config.yaml for the project's stack, and install the monitor scheduler. Run once per project, and again after upgrading factory2.
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*) Read Glob Grep
---

# /factory2:init

`S=${CLAUDE_PLUGIN_ROOT}/scripts`, `T=${CLAUDE_PLUGIN_ROOT}/templates`.

1. **Doctor.** `bash $S/doctor.sh`. It checks: Claude Code ≥ 2.1.311; auto memory (a warning only: factory loads agent memory itself); neither
   `disableAllHooks` nor `allowManagedHooksOnly` set; no other installed plugin named `factory2`;
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
   and qa-evaluator falls back to `playwright-cli --help`). Copy `$T/playwright.demo.config.ts` to the
   project root if there is none; it imports the project's `playwright.config.ts`, so check that file
   passes `FACTORY_PORT` to its `webServer` and `baseURL`. Make sure the browser is installed
   (`npx playwright install chromium`), and recommend ffmpeg for mp4 videos (`brew install ffmpeg`,
   `apt-get install ffmpeg`); without it the review pack keeps WebM videos.
5. **Files.** Append `$T/gitignore.txt` to `.gitignore` (`.factory/runs/`, `.factory/incidents/`), create
   `.factory/history/`, copy `$S/monitor.sh` and `$S/lib/yaml2json.py` to `.factory/bin/` (CI and
   launchd run this copy without the plugin; re-copy after upgrading factory2).
6. **Scheduler**, per `monitor.scheduler`, only if the user wants it now:
   - `local-loop`: nothing to install; stage 8 suggests `/loop <interval> /factory2:monitor <slug>`.
   - `github-actions`: copy `$T/github-actions-monitor.yml` to `.github/workflows/factory-monitor.yml`
     and adjust the cron to `monitor.interval`; add any secrets the checks need to its `env`.
   - `launchd`: fill `$T/launchd-monitor.plist` (`__LABEL__` = `dev.factory2.<repo name>`, `__PROJECT__` =
     the absolute project path, `__INTERVAL_SECONDS__` from `monitor.interval`, `__PATH__` = the current
     `PATH`), write it to `~/Library/LaunchAgents/<label>.plist`, check it with `plutil -lint`, and show
     the `launchctl bootstrap gui/$(id -u) <file>` command for the user to run.
7. Summarise what was written and suggest committing it, then `/factory2:run "<feature>"`.
