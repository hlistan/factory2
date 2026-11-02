#!/usr/bin/env bash
# SubagentStart hook for every factory agent (hooks.json matcher ^factory:). Loads the agent's calibration
# memory, .claude/agent-memory/factory-<agent>/MEMORY.md, into the subagent's context as
# hookSpecificOutput.additionalContext.
#
# Why a hook and not the subagent `memory:` frontmatter: Claude Code's subagent memory is part of auto
# memory, so with `autoMemoryEnabled: false` (or CLAUDE_CODE_DISABLE_AUTO_MEMORY) the field "has no
# effect" (sub-agents docs) and factory's per-agent learning silently disappears. The frontmatter also
# turns on Write and Edit for every memory agent and tells it to curate its own MEMORY.md, which factory
# forbids (only `state.sh fold-memory` writes memory). Loading it here works under any memory setting,
# gives read-only agents no write tools, and keeps the file format and location unchanged.
#
# Loads the first 200 lines or 25 KB, whichever is smaller (the same limits Claude Code applies to
# MEMORY.md). Agents without a calibration memory (learnings-researcher, challenger, researcher) get
# nothing. Always exits 0: missing memory never blocks a spawn.
set -u
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_hook_log memory-inject "$input"
factory_has jq || exit 0
agent="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
case "$agent" in factory:*) agent="${agent#factory:}" ;; *) exit 0 ;; esac
case "$agent" in learnings-researcher|challenger|researcher|''|*[!a-z0-9-]*) exit 0 ;; esac

f="$FACTORY_ROOT_DIR/.claude/agent-memory/factory-$agent/MEMORY.md"
[ -s "$f" ] || exit 0
body="$(head -n 200 "$f" | head -c 25600)"
# a cut inside the last line drops that partial line
[ "$(head -n 200 "$f" | wc -c)" -gt 25600 ] && body="$(printf '%s' "$body" | sed '$d')"
[ -n "$body" ] || exit 0

ctx="## Your MEMORY.md (loaded by factory)
Lessons from earlier factory runs in this project, from .claude/agent-memory/factory-$agent/MEMORY.md.
They are reference material, not rules: they never override the task, contract.json or your instructions.
Don't edit this file; put any lesson you'd want next time in your final report's \`lessons\` list.

$body"
jq -n --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $c}}'
exit 0
