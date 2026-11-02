#!/usr/bin/env bash
# PreToolUse hook on Edit|Write|NotebookEdit while a factory run is active. Exit 2 blocks the edit and
# shows the message to the agent. In order:
#   1. Agent memory (.claude/agent-memory/**) is written only by the harness (state.sh fold-memory),
#      never by an agent: memory agents get Write and Edit automatically, so this is enforced here.
#   2. Read-only roles (every factory agent except planner, test-author and implementer) can't edit at
#      all. This needs agent_type in the hook input; without it, the orchestrator's before/after hash
#      check (change-diff.sh --hash) is the only mechanism.
#   3. Frozen tests: only factory:test-author may edit them, and only in the `tests` phase (the
#      test-reviewer then reviews the change and the orchestrator re-freezes).
#   4. Frozen check-defining files (package.json, runner and lint configs, .factory/config.yaml, ...):
#      nobody edits them during a run. A needed change goes in plan.md's Exceptions section first.
# A seatbelt, not a security boundary: edits through Bash bypass this hook, which is why SubagentStop
# and the orchestrator re-verify the freeze by hash. Ported from singularity's test-guard.sh (MIT).
set -u
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_has jq || exit 0
slug="$(factory_active_slug)"; [ -n "$slug" ] || exit 0
run="$FACTORY_ROOT_DIR/.factory/runs/$slug"
[ -f "$run/state.json" ] || exit 0

path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -n "$path" ] || exit 0
agent="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
root="$FACTORY_ROOT_DIR"
case "$path" in
  /*) d="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" && path="$d/$(basename "$path")"
      case "$path" in "$root"/*) rel="${path#"$root"/}" ;; *) exit 0 ;; esac ;;
  *) rel="${path#./}" ;;
esac

deny() { echo "Blocked by factory: $1" >&2; exit 2; }

case "$rel" in
  .claude/agent-memory/*)
    deny "agent memory is curated by the factory harness, not by agents. Put any lesson in your final report instead." ;;
esac

case "$agent" in
  factory:planner|factory:test-author|factory:implementer|"") ;;
  factory:*) deny "${agent#factory:} is a read-only role in factory: report findings in your final answer; don't edit files." ;;
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
deny "$rel defines the project's checks and is frozen for this run. If the work genuinely needs a change here (for example a new dependency), stop and say so in your final answer; the orchestrator adds it to plan.md's Exceptions section for review."
