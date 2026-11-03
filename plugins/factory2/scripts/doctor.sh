#!/usr/bin/env bash
# /factory2:init's environment check. One line per check: OK, WARN or FAIL, with the fix.
# Exit 0 when nothing failed, 1 otherwise.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
fail=0
ok() { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
cfgdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

for t in git jq python3; do
  if factory_has "$t"; then ok "$t"; else bad "$t is missing (factory's scripts need it)"; fi
done
why_optional() { case "$1" in gh) echo "draft PRs and github-issue incidents" ;; ffmpeg) echo "mp4 evidence video" ;; docker) echo "pinned Playwright browsers" ;; esac; }
for t in gh ffmpeg docker; do
  if factory_has "$t"; then ok "$t"; else warn "$t not found (optional: $(why_optional "$t"))"; fi
done
ver_ge() { # <have> <want>
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}
ce="$(bash "$FACTORY_SCRIPTS/state.sh" ce-version 2>/dev/null)"
if [ -n "$ce" ]; then ok "ce-compound bundled from compound-engineering $ce"; else bad "the bundled ce-compound manifest is missing; reinstall factory2"; fi
if factory_has claude; then
  v="$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  if [ -n "$v" ] && ver_ge "$v" 2.1.311; then ok "Claude Code $v"; else bad "Claude Code ${v:-unknown} is older than 2.1.311 (claude update)"; fi
else
  warn "claude not on PATH; can't check its version"
fi

settings_files=("$cfgdir/settings.json")
root="${FACTORY_ROOT_DIR:-}"
[ -n "$root" ] && settings_files+=("$root/.claude/settings.json" "$root/.claude/settings.local.json")
for f in "${settings_files[@]}"; do
  [ -f "$f" ] || continue
  for k in disableAllHooks allowManagedHooksOnly; do
    [ "$(jq -r --arg k "$k" '.[$k] // false' "$f" 2>/dev/null)" = "true" ] && bad "$k is set in $f: factory's hooks would not run"
  done
  [ "$(jq -r 'if has("autoMemoryEnabled") then .autoMemoryEnabled else true end | tostring' "$f" 2>/dev/null)" = "false" ] && warn "auto memory is off in $f (autoMemoryEnabled: false). factory loads its agents' calibration memory itself (SubagentStart hook), so runs still learn; only Claude Code's own auto memory of your corrections is off"
done
[ -n "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}" ] && [ "${CLAUDE_CODE_DISABLE_AUTO_MEMORY}" != "0" ] && warn "CLAUDE_CODE_DISABLE_AUTO_MEMORY is set: Claude Code's auto memory is off (factory's agent calibration memory still loads)"
[ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] && warn "CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL overrides every agent's effort, even the Agent tool's effort parameter; unset it for factory runs"

ip="$cfgdir/plugins/installed_plugins.json"
if [ -f "$ip" ]; then
  n="$(jq -r '[.plugins // {} | keys[] | select(startswith("factory2@"))] | length' "$ip" 2>/dev/null)"
  [ "${n:-0}" -gt 1 ] && bad "more than one plugin named factory is installed; plugin hooks may not fire on a name collision"
else
  warn "no $ip; can't check installed plugins"
fi
if factory_has claude; then
  # `enabled` stays true for a plugin that fails to load; .errors says why
  out="$(claude plugin list --json 2>/dev/null | jq -r '.[]? | select(.id | startswith("factory2@")) |
    if .enabled == false then "FAIL  \(.id) is disabled: claude plugin enable \(.id)"
    elif ((.errors // []) | length) > 0 then "FAIL  \(.id) fails to load: \(.errors | join("; "))"
    else empty end' 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; fail=1; fi
fi
exit "$fail"
