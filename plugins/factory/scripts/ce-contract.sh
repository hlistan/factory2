#!/usr/bin/env bash
# compound-engineering contract test: factory depends on ce-compound's non-interactive interface, which has
# no stability policy. This runs it once on a throwaway fixture repo, under your normal login, and checks:
#   - the final non-empty line is exactly `Documentation complete` (or `Documentation skipped`)
#   - a `Refresh recommendation:` line is present on completion
#   - one doc was written under docs/solutions/<category>/ with a problem_type from ce's closed list
# On a pass it records the version in $CLAUDE_PLUGIN_DATA/ce-contract.json (when set), which the
# SessionStart hook compares with the installed version.
# Usage: ce-contract.sh [--plugin-dir <compound-engineering dir>] [--depth full|lightweight] [--budget <usd>]
# Default plugin dir: the installed copy (state.sh ce-path). Exit 0 pass, 1 fail, 2 setup error.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need jq git
ce=""; depth="full"; budget="4"
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-dir) ce="${2:-}"; shift 2 ;;
    --depth) depth="${2:-}"; shift 2 ;;
    --budget) budget="${2:-}"; shift 2 ;;
    *) echo "ce-contract: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$ce" ] || ce="$(bash "$FACTORY_SCRIPTS/state.sh" ce-path 2>/dev/null)"
[ -n "$ce" ] && [ -f "$ce/skills/ce-compound/SKILL.md" ] || { echo "ce-contract: compound-engineering not found (pass --plugin-dir)" >&2; exit 2; }
factory_has claude || { echo "ce-contract: claude not on PATH" >&2; exit 2; }
version="$(jq -r '.version // empty' "$ce/.claude-plugin/plugin.json" 2>/dev/null)"

w="$(mktemp -d "${TMPDIR:-/tmp}/factory-ce-contract.XXXXXX")"
trap 'rm -rf "$w"' EXIT
git -C "$w" init -q -b main
git -C "$w" config user.email ce-contract@example.com; git -C "$w" config user.name ce-contract
# A lesson the final code doesn't show: a flaky e2e suite whose first "fix" (a longer timeout) hid the
# cause, which was two parallel runs' dev servers sharing port 3000. ce-compound's durable bar skips
# lessons that the code already makes obvious, so the fixture carries the failed attempt in history.
mkdir -p "$w/e2e"
printf '{"scripts":{"dev":"next dev -p 3000","e2e":"playwright test"}}\n' > "$w/package.json"
cat > "$w/playwright.config.js" <<'JS'
module.exports = { use: { baseURL: 'http://localhost:3000' }, webServer: { command: 'npm run dev', port: 3000, reuseExistingServer: true } };
JS
printf "test('@AC-1 toggle', async ({ page }) => { await page.goto('/'); });\n" > "$w/e2e/toggle.spec.js"
git -C "$w" add -A && git -C "$w" commit -q -m "e2e suite"
sed -i.bak 's/^module.exports = { use/module.exports = { timeout: 120000, use/' "$w/playwright.config.js" && rm -f "$w/playwright.config.js.bak"
git -C "$w" commit -q -am "e2e: raise timeout to 120s (flaky toggle test)"
cat > "$w/playwright.config.js" <<'JS'
const port = Number(process.env.PORT || 3000);
module.exports = { use: { baseURL: `http://localhost:${port}` }, webServer: { command: `npm run dev -- -p ${port}`, port, reuseExistingServer: false } };
JS
printf '{"scripts":{"dev":"next dev","e2e":"playwright test"}}\n' > "$w/package.json"
git -C "$w" commit -q -am "e2e: per-run port, never reuse a server; revert the timeout"
context='Flaky e2e: @AC-1 toggle failed about 1 run in 4, only when two feature branches ran their suites at the same time in separate git worktrees. First attempt (commit 2) raised the Playwright timeout to 120s; failures dropped but the suite got slow and the toggle test still passed against the wrong app sometimes. Investigation: both worktrees started next dev on port 3000, and reuseExistingServer: true let the second run attach to the first worktree'"'"'s server, so tests ran against the other branch'"'"'s code. Fix (commit 3): each run gets its own PORT, webServer and baseURL read it, reuseExistingServer is false, timeout reverted. Verified by running two worktrees in parallel 20 times with zero failures. Lesson: when e2e tests flake only under parallel runs, check for a shared dev-server port with reuseExistingServer before touching timeouts; a longer timeout hides it.'
prompt="Use the Skill tool to invoke compound-engineering:ce-compound with these arguments, exactly:
mode:non-interactive depth:$depth \"$context\"
After the skill finishes, output nothing further."

out="$w/out.json"
( cd "$w" && claude -p "$prompt" --plugin-dir "$ce" --model opus --max-budget-usd "$budget" \
    --permission-mode acceptEdits --allowedTools "Skill Read Write Edit Glob Grep Bash" \
    --output-format json < /dev/null > "$out" 2> "$w/err.txt" )
code=$?
result="$(jq -r '.result // empty' "$out" 2>/dev/null)"
cost="$(jq -r '.total_cost_usd // empty' "$out" 2>/dev/null)"
fail=0
say() { printf '%s\n' "$*"; }
[ "$code" -eq 0 ] || { say "FAIL claude exited $code: $(head -c 400 "$w/err.txt")"; fail=1; }
last="$(printf '%s\n' "$result" | sed '/^[[:space:]]*$/d' | tail -n 1 | sed 's/[[:space:]]*$//')"
case "$last" in
  "Documentation complete") say "OK   final line: Documentation complete" ;;
  "Documentation skipped") say "FAIL final line: Documentation skipped (the fixture should document)"; fail=1 ;;
  *) say "FAIL final line is not a ce-compound terminal signal: [$last]"; fail=1 ;;
esac
if printf '%s\n' "$result" | grep -q '^Refresh recommendation:'; then say "OK   Refresh recommendation line present"
else say "FAIL no 'Refresh recommendation:' line"; fail=1; fi
docs="$(cd "$w" && find docs/solutions -mindepth 2 -name '*.md' 2>/dev/null)"
n="$(printf '%s' "$docs" | grep -c .)"
if [ "$n" -ge 1 ]; then say "OK   $n doc(s): $(printf '%s' "$docs" | tr '\n' ' ')"; else say "FAIL no doc under docs/solutions/<category>/"; fail=1; fi
schema="$ce/skills/ce-compound/references/schema.yaml"
for d in $docs; do
  pt="$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$w/$d" | sed -n 's/^problem_type: *//p' | tr -d '"'"'" | head -n1)"
  if [ -n "$pt" ] && grep -q -- "- $pt\$" "$schema"; then say "OK   $d problem_type: $pt"
  else say "FAIL $d problem_type [$pt] is not in ce's schema"; fail=1; fi
done
say "     compound-engineering $version, depth $depth, cost \$${cost:-?}"
if [ "$fail" -eq 0 ] && [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  jq -n --arg v "$version" --arg at "$(now_utc)" --arg d "$depth" '{passed_version: $v, at: $at, depth: $d}' > "$CLAUDE_PLUGIN_DATA/ce-contract.json"
fi
[ "$fail" -eq 0 ] && say "ce-contract: PASS" || { say "ce-contract: FAIL (result tail below)"; printf '%s\n' "$result" | tail -n 25 | sed 's/^/  | /'; }
exit "$fail"
