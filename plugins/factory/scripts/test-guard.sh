#!/usr/bin/env bash
# PreToolUse hook on Edit|Write|NotebookEdit while a factory run is active. Exit 2 blocks the edit and
# shows the message to the agent. In order:
#   1. Agent memory (.claude/agent-memory/**) is written only by the harness (state.sh fold-memory),
#      never by an agent. Agents that can write (planner, test-author, implementer) could otherwise edit it.
#   2. Read-only roles (every factory agent except planner, test-author and implementer) can't edit at
#      all. This needs agent_type in the hook input; without it, the orchestrator's before/after hash
#      check (change-diff.sh --hash) is the only mechanism.
#   3. Frozen tests: only factory:test-author may edit them, and only in the `tests` phase (the
#      test-reviewer then reviews the change and the orchestrator re-freezes).
#   4. Frozen check-defining files (package.json, runner and lint configs, .factory/config.yaml, ...):
#      nobody edits them during a run, except a path that plan.md's reviewed `## Exceptions` section names
#      (implementer or main session only; never .factory/config.yaml).
# A seatbelt, not a security boundary: edits through Bash bypass this hook, which is why SubagentStop
# and the orchestrator re-verify the freeze by hash. Ported from singularity's test-guard.sh (MIT).
set -u
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_hook_log test-guard "$input"
slug="$(factory_active_slug)"; [ -n "$slug" ] || exit 0
run="$FACTORY_ROOT_DIR/.factory/runs/$slug"
[ -f "$run/state.json" ] || exit 0
factory_guard_prereqs   # during a run: exit 1 (gate.sh blocks) without jq/python3 or a parsable config

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -n "$path" ] || exit 0
agent="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
root="$FACTORY_ROOT_DIR"

deny() { echo "Blocked by factory: $1" >&2; exit 2; }

# read-only roles can't edit anything, inside the project or not
case "$agent" in
  factory:planner|factory:test-author|factory:implementer|"") ;;
  factory:*) deny "${agent#factory:} is a read-only role in factory: report findings in your final answer; don't edit files." ;;
esac

# resolve as the filesystem will: .., symlinks, missing directories, and (on a case-insensitive
# filesystem) other spellings of a frozen file. A failure here is a crash, which gate.sh turns into a block.
resolved="$(factory_py "$FACTORY_LIB/pathcheck.py" "$root" "${cwd:-$root}" "$path" "$run/frozen.tsv")" || exit 1
where="${resolved%%	*}"; rel="${resolved#*	}"
[ "$where" = "inside" ] || exit 0
lrel="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"

case "$lrel" in
  .claude/agent-memory/*|.claude/agent-memory-local/*)
    deny "agent memory is curated by the factory harness, not by agents. Put any lesson in your final report instead." ;;
  .claude/settings.json|.claude/settings.local.json)
    deny "Claude Code's project settings can't change during a factory run (they control the hooks that guard it). Ask the user." ;;
esac

frozen="$run/frozen.tsv"
[ -s "$frozen" ] || exit 0
row="$(awk -F '\t' -v p="$rel" '$4 == p { print $1 "\t" $2; exit }' "$frozen")"
[ -n "$row" ] || exit 0
list="${row%%	*}"
phase="$(jq -r '.phase // empty' "$run/state.json")"
if [ "$list" = "tests" ]; then
  # test-author adds AC tests to existing spec files in the tests phase; the test-reviewer reviews the change
  # and the orchestrator re-freezes. An empty agent_type is the main session (or a Claude Code version
  # that doesn't report agent_type to PreToolUse hooks).
  [ "$phase" = "tests" ] && { [ "$agent" = "factory:test-author" ] || [ -z "$agent" ]; } && exit 0
  deny "$rel is a frozen test. It was reviewed and frozen before the code existed; making it pass means changing the code, not the test. If the test itself is wrong, stop and say so in your final answer."
fi
# a check-defining file the plan's reviewed `## Exceptions` section names may be edited by the implementer
# (or the main session); freeze verification accepts the same change. Never .factory/config.yaml.
if [ "$rel" != ".factory/config.yaml" ] && { [ "$agent" = "factory:implementer" ] || [ -z "$agent" ]; }; then
  plan="$root/docs/specs/$slug/plan.md"
  if [ -f "$plan" ] && factory_py "$FACTORY_LIB/freeze.py" exceptions --root "$root" --plan "$plan" 2>/dev/null | grep -Fqx -- "$rel"; then
    exit 0
  fi
fi
deny "$rel defines the project's checks and is frozen for this run. If the work genuinely needs a change here (for example a new dependency), stop and say so in your final answer; the orchestrator adds it to plan.md's Exceptions section for review."
