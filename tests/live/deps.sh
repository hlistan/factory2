#!/usr/bin/env bash
# Live: installation, in an isolated CLAUDE_CONFIG_DIR with no other marketplace (no login needed).
#  1. factory2 installed from a git source (and from this checkout as a directory source) is enabled and
#     loads with no errors and no other plugin: it has no dependencies, and it bundles ce-compound and
#     ce-compound-refresh as its own skills next to its 14 agents.
#  2. the git install is byte-identical to the committed plugin; with a credential, its hooks fire.
# Usage: bash tests/live/deps.sh   (a minute; spends nothing, or about $0.15 with a credential set)
. "$(dirname "$0")/../lib.sh"
D="$T_TMP/cfg"; mkdir -p "$D"
c() { CLAUDE_CONFIG_DIR="$D" claude "$@"; }

# a marketplace whose factory entry is a git source (git-subdir over file://), like an installed release
git clone -q --bare "$REPO" "$T_TMP/factory.git"
mkt() { # <dir> <marketplace name> <git url>
  mkdir -p "$1/.claude-plugin"
  jq -n --arg n "$2" --arg u "$3" '{name: $n, owner: {name: "test"},
    plugins: [{name: "factory2", source: {source: "git-subdir", url: $u, path: "plugins/factory2"}}]}' \
    > "$1/.claude-plugin/marketplace.json"
}
mkt "$T_TMP/mkt" factory-git "file://$T_TMP/factory.git"
list_json() { c plugin list --json 2>/dev/null; }
st() { list_json | jq -r --arg p "$1" '[.[] | select(.id == $p) | .enabled] | first // "absent"'; }

run c plugin marketplace add "$T_TMP/mkt";                        t_code 0 "add the git-source factory marketplace"
run c plugin install factory2@factory2-git;                         t_code 0 "install factory from git"
printf '%s\n%s\n' "$OUT" "$ERR" | sed 's/^/    /' | head -6
t_eq "$(st factory2@factory2-git)" "true" "factory enabled"
t_eq "$(list_json | jq -r '[.[] | select(.id == "factory2@factory2-git") | (.errors // [])[]] | length')" "0" "factory2 loads with no errors"
t_eq "$(list_json | jq -r 'map(.id) | join(" ")')" "factory2@factory2-git" "no other plugin was installed"
det="$(c plugin details factory2@factory2-git 2>&1)"
t_has "$det" "ce-compound" "the bundled ce-compound is one of factory2's skills"
t_has "$det" "ce-compound-refresh" "the bundled ce-compound-refresh is one of factory2's skills"
t_has "$det" "Agents (14)" "all 14 agents load"
ip="$(list_json | jq -r '.[] | select(.id == "factory2@factory2-git") | .installPath')"
[ -f "$ip/hooks/hooks.json" ] && [ -f "$ip/scripts/state.sh" ] && t_ok || t_fail "git install has hooks and scripts ($ip)"
# the hook-firing tests (tests/live/hooks.sh) run the directory copy through --plugin-dir; the git install
# is shown to be the same files, and (with a credential, below) to fire its hooks itself
mkdir -p "$T_TMP/head" && git -C "$REPO" archive HEAD plugins/factory2 | tar -x -C "$T_TMP/head"
d="$(diff -r -q "$ip" "$T_TMP/head/plugins/factory2" 2>&1 | grep -v -e '\.git' -e ': \.in_use$')"
t_eq "$d" "" "the git-installed plugin is byte-identical to the committed directory copy"
list_json | jq -r '.[] | "    \(.id) \(.version) enabled=\(.enabled)"'

# hooks firing from the git install itself, not --plugin-dir: needs a credential the isolated config can
# use (ANTHROPIC_API_KEY, or CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`); skipped without one
if [ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  G="$(new_repo)"
  write_config "$G" 'ship:
  deploy: "echo DEPLOYED > deployed.txt"'
  mkdir -p "$G/.claude/agent-memory/factory-planner"
  printf -- '- The project codename is ZEBRA-42.\n' > "$G/.claude/agent-memory/factory-planner/MEMORY.md"
  git -C "$G" add -A && git -C "$G" commit -q -m fixture
  FACTORY_ROOT="$G" bash "$S/state.sh" start gitprobe >/dev/null
  GL="$T_TMP/gitlog"
  out="$(cd "$G" && FACTORY_HOOK_LOG="$GL" CLAUDE_CONFIG_DIR="$D" claude -p 'This is an automated test of a plugin. 1. Run this exact Bash command: echo DEPLOYED > deployed.txt  2. Use the Agent tool with subagent_type "factory2:planner" and model "sonnet", prompt: "Test step: do not edit anything. Reply with the project codename if your context contains one, else NONE. One line." Report both results.' \
    --model sonnet --settings '{"autoMemoryEnabled": false}' --max-budget-usd 1 --permission-mode acceptEdits \
    --allowedTools "Agent Bash Read" --output-format json < /dev/null 2>/dev/null)"
  printf '    git-install session cost $%s\n' "$(printf '%s' "$out" | jq -r '.total_cost_usd // "?"')"
  ev="$(ls "$GL" 2>/dev/null | sed 's/^[0-9]*-[0-9]*-//; s/\.json$//' | sort -u | tr '\n' ' ')"
  for h in session-start guard-bash memory-inject spend; do t_has "$ev" "$h" "git install: $h hook fired"; done
  [ ! -f "$G/deployed.txt" ] && t_ok || t_fail "git install: ship.deploy ran outside stage 7"
  t_has "$(printf '%s' "$out" | jq -r '.result // empty')" "ZEBRA-42" "git install: planner memory loaded"
else
  echo "    NOTE hooks from the git install not run live: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)"
fi

# the directory source (this checkout), as used in development
run c plugin uninstall factory2@factory2-git
run c plugin marketplace add "$REPO";  t_code 0 "add this checkout as a directory marketplace"
run c plugin install factory2@factory2;  t_code 0 "install factory from the directory marketplace"
t_eq "$(st factory2@factory2)" "true" "directory-source factory enabled"
run c plugin uninstall factory2@factory2

t_done
