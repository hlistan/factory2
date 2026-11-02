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

_lock_acquire() { # <dir>: a mkdir lock with a stale-lock timeout of 30 s
  local d="$1" i=0
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 300 ]; then rm -rf "$d"; i=0; fi # 300 x 0.1 s: a crashed writer's lock
    sleep 0.1
  done
}

state_update() { # <jq expression> [--arg/--argjson pairs...]: atomically rewrites the active run's state.json
  local f expr="$1"; shift
  f="$(state_file)" || { echo "factory: no active run" >&2; return 1; }
  [ -f "$f" ] || { echo "factory: no state at $f" >&2; return 1; }
  _lock_acquire "$f.lock"
  if jq "$@" "$expr" "$f" > "$f.tmp.$$"; then
    mv "$f.tmp.$$" "$f"
    rmdir "$f.lock" 2>/dev/null
    return 0
  fi
  rm -f "$f.tmp.$$"
  rmdir "$f.lock" 2>/dev/null
  return 1
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

FACTORY_ROOT_DIR="$(factory_root)"
