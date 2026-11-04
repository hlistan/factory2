// factory2 stage 6 demo config. /factory2:init copies it to the project root; evidence.sh runs
//   npx playwright test -c playwright.demo.config.ts --grep '@AC-(1|2|...)\b'
// It reuses your playwright.config.ts (webServer, baseURL, fixtures) and changes only what evidence needs:
// a video and a screenshot for every test, one project per viewport, and a JSON report that
// evidence.sh turns into the review pack. Edit it like any other project file; it is frozen with the
// tests during a run.
//
// Environment (set by evidence.sh):
//   FACTORY_EVIDENCE   output directory (results.json and the per-test videos and screenshots)
//   FACTORY_VIEWPORTS  comma-separated WIDTHxHEIGHT sizes, from evidence.viewports
//   FACTORY_PORT       this run's port; pass it to your webServer and baseURL in playwright.config.ts
import { defineConfig, devices } from '@playwright/test';
import base from './playwright.config';

const out = process.env.FACTORY_EVIDENCE || 'factory-evidence';
const sizes = (process.env.FACTORY_VIEWPORTS || '1440x900,768x1024,390x844')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .map((s) => {
    const [width, height] = s.split('x').map(Number);
    return { name: s, width, height };
  });

export default defineConfig({
  ...base,
  outputDir: `${out}/tests`,
  retries: 0,
  // the demo should show the app as a user sees it, one test at a time
  workers: 1,
  fullyParallel: false,
  reporter: [['json', { outputFile: `${out}/results.json` }], ['list']],
  use: {
    ...(base.use || {}),
    // Playwright 1.59+ overlays the test title (with its @AC-n tag), each step and each action on the
    // video, so every recording says which criterion is on screen. Older versions ignore `show`.
    video: { mode: 'on', show: { actions: {}, test: { level: 'step' } } },
    screenshot: 'on',
    trace: 'off',
  },
  projects: sizes.map((s) => ({
    name: s.name,
    use: {
      ...devices['Desktop Chrome'],
      viewport: { width: s.width, height: s.height },
      // narrow viewports behave like phones (touch, mobile user agent layout)
      ...(s.width < 600 ? { isMobile: true, hasTouch: true, deviceScaleFactor: 2 } : {}),
    },
  })),
});
