# shellcheck shell=bash disable=SC2034
# Sourced by every factory script. Needs bash 3.2+, git, jq and python3 (checked by /factory:init).
#
# Layout in a target repo:
#   .factory/config.yaml              per-project config (committed)
#   .factory/history/<slug>.json      one measurement record per run (committed)
#   .factory/bin/monitor.sh           pure-shell monitor copy for CI (committed)
#   .factory/runs/active              slug of the run active in this checkout (git-ignored, like all of runs/)
#   .factory/runs/<slug>/state.json   stage, rounds, approvals, freeze, spend
#   .factory/runs/<slug>/frozen.tsv   list <TAB> kind <TAB> hash <TAB> path
#   .factory/runs/<slug>/checks.snapshot.json, reports/, stop-*.count, stop-gate.log

FACTORY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_SCRIPTS="$(dirname "$FACTORY_LIB")"
FACTORY_PLUGIN="$(dirname "$FACTORY_SCRIPTS")"

factory_root() { # the project root: $FACTORY_ROOT, else $CLAUDE_PROJECT_DIR, else the git top level, else $PWD
  local r="${FACTORY_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
  [ -n "$r" ] || r="$(git rev-parse --show-toplevel 2>/dev/null)" || true
  [ -n "$r" ] || r="$PWD"
  (cd "$r" 2>/dev/null && pwd -P)
}

factory_has() { command -v "$1" >/dev/null 2>&1; }

factory_need() { # <tool>...: exit 2 with a message if any is missing
  local t missing=""
  for t in "$@"; do factory_has "$t" || missing="$missing $t"; done
  [ -z "$missing" ] && return 0
  echo "factory: missing required tool(s):$missing (run /factory:init for setup help)" >&2
  exit 2
}

factory_py() { python3 -I "$@"; } # isolated mode: never imports from the cwd

# jq: a value as text; null and "" print nothing, false prints false, arrays and objects print as JSON
_JQ_TEXT='if . == null or . == "" then empty elif (type == "array" or type == "object") then tojson else tostring end'

_FACTORY_CFG=""
factory_config_json() { # the project's config as JSON; {} when there is none
  if [ -z "$_FACTORY_CFG" ]; then
    local f="$FACTORY_ROOT_DIR/.factory/config.yaml"
    if [ -f "$f" ]; then
      _FACTORY_CFG="$(factory_py "$FACTORY_LIB/yaml2json.py" "$f")" || return 2
    else
      _FACTORY_CFG="{}"
    fi
  fi
  printf '%s' "$_FACTORY_CFG"
}

cfg() { # <jq filter> [default]: a config value as raw text; the default when null, missing or ""
  local v
  v="$(factory_config_json | jq -r "($1) | $_JQ_TEXT" 2>/dev/null)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "${2:-}"
}

factory_active_slug() { # the active run's slug, or nothing
  local f="$FACTORY_ROOT_DIR/.factory/runs/active"
  [ -f "$f" ] && head -n 1 "$f" | tr -cd 'A-Za-z0-9._-'
}

factory_run_dir() { # [slug]: the run directory (not created)
  local s="${1:-$(factory_active_slug)}"
  [ -n "$s" ] || return 1
  printf '%s/.factory/runs/%s' "$FACTORY_ROOT_DIR" "$s"
}

state_file() { local d; d="$(factory_run_dir "${1:-}")" || return 1; printf '%s/state.json' "$d"; }

state_get() { # <jq filter> [slug]: from the run's state.json, raw
  local f
  f="$(state_file "${2:-}")" || return 1
  [ -f "$f" ] || return 1
  jq -r "($1) | $_JQ_TEXT" "$f"
}

_lock_acquire() { # <dir>: a mkdir lock holding the owner's pid; a lock whose owner is dead is stale
  local d="$1" i=0 pid
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1))
    if [ $((i % 10)) -eq 0 ]; then # every second: steal the lock only if its owner is gone
      pid="$(cat "$d/pid" 2>/dev/null)"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        # rename first, then check the pid again: another waiter may already have stolen and re-taken it
        if mv "$d" "$d.stale.$$" 2>/dev/null; then
          if [ "$(cat "$d.stale.$$/pid" 2>/dev/null)" = "$pid" ]; then rm -rf "$d.stale.$$"
          else mv "$d.stale.$$" "$d" 2>/dev/null || rm -rf "$d.stale.$$"; fi
        fi
      elif [ -z "$pid" ] && [ "$i" -gt 600 ]; then # no pid for 60 s: a writer died between mkdir and pid
        rm -rf "$d"; i=0
      fi
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" > "$d/pid"
}

state_update() { # <jq expression> [--arg/--argjson pairs...]: atomically rewrites the active run's state.json
  local f expr="$1"; shift
  f="$(state_file)" || { echo "factory: no active run" >&2; return 1; }
  [ -f "$f" ] || { echo "factory: no state at $f" >&2; return 1; }
  _lock_acquire "$f.lock"
  if jq "$@" "$expr" "$f" > "$f.tmp.$$"; then
    mv "$f.tmp.$$" "$f"
    rm -rf "$f.lock"
    return 0
  fi
  rm -f "$f.tmp.$$"
  rm -rf "$f.lock"
  return 1
}

factory_guard_prereqs() { # guards: outside a factory project, nothing to guard (exit 0); inside one, a
  # missing jq or python3, or a .factory/config.yaml that doesn't parse, must not switch the guard off:
  # exit 1, which gate.sh turns into a block with an explanation
  [ -f "$FACTORY_ROOT_DIR/.factory/config.yaml" ] || { factory_has jq || exit 0; return 0; }
  factory_has jq || { echo "factory: jq is missing" >&2; exit 1; }
  factory_has python3 || { echo "factory: python3 is missing" >&2; exit 1; }
  factory_config_json >/dev/null 2>&1 || { echo "factory: .factory/config.yaml doesn't parse" >&2; exit 1; }
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

factory_hook_log() { # <hook> <input>: with $FACTORY_HOOK_LOG set (a directory), saves the raw hook input
  # as one file per call, <epoch>-<pid>-<hook>.json, for the live tests. One file per call because
  # hooks run in parallel and long appends to a shared file interleave.
  [ -n "${FACTORY_HOOK_LOG:-}" ] || return 0
  mkdir -p "$FACTORY_HOOK_LOG" 2>/dev/null && printf '%s\n' "$2" > "$FACTORY_HOOK_LOG/$(date +%s)-$$-$1.json" 2>/dev/null
  return 0
}

FACTORY_ROOT_DIR="$(factory_root)"
