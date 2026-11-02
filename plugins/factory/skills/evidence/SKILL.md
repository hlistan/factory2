---
name: evidence
description: How factory captures stage 6 evidence (Playwright demo video with per-criterion chapters, screenshots per viewport, mp4 conversion, review pack). Background knowledge for /factory:run; not for direct use.
user-invocable: false
---

# Evidence capture (stage 6)

The `@AC-n` e2e specs are the demo script; nothing is recorded by hand.

- **Config.** `templates/playwright.demo.config.ts` extends the project's Playwright config:
  `use.video: { mode: 'on', show: { actions: {...}, test: { level: 'step' } } }`, `use.screenshot: 'on'`,
  one project per `evidence.viewports` size, `webServer` on `$FACTORY_PORT`, output under
  `$FACTORY_EVIDENCE`. Needs Playwright ≥ 1.59 (Screencast API); 1.64+ records VP9 and supports `fps`.
- **Chapters.** A fixture calls `page.screencast.showChapter('AC-n: <criterion text>')` before each
  `@AC-n` test, so the video shows which criterion is on screen.
- **One criterion.** `npx playwright test -c playwright.demo.config.ts --grep '@AC-1\b'` (single quotes:
  `\b` keeps AC-1 from matching AC-10).
- **Reproducible browsers.** When Docker is available: `mcr.microsoft.com/playwright:v<the app's
  Playwright version>-noble`.
- **Video.** Playwright writes WebM. When ffmpeg is installed, `evidence.sh` converts it to H.264 mp4
  (`-c:v libx264 -pix_fmt yuv420p -movflags +faststart`) so it plays everywhere; that's factory's
  practice, not a Playwright feature. Without ffmpeg the WebM is kept.
- **Non-web projects.** `evidence.driver: command` runs `evidence.capture`, which writes screenshots or
  recordings into `$FACTORY_EVIDENCE` (e.g. `xcrun simctl io booted screenshot` or a UI-test attachment
  export); `none` puts only test results in the pack.
- **Review pack.** `evidence.sh pack` writes `<run>/review-pack/index.html`: per criterion its text,
  tests and pass state, screenshots per viewport and the video at its chapter; then advisory findings,
  spend by stage, and the PR link. Self-contained relative paths, so the folder can be zipped or
  published with `evidence.publish`.
