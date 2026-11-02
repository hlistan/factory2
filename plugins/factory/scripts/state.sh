#!/usr/bin/env bash
# factory run state. The orchestrator (/factory:run) calls these; hooks read the same files.
#   state.sh start <slug>            begin a run in this checkout: state.json, lock, port, history file
#   state.sh resume <slug>           make an existing run the active one
#   state.sh end                     release the checkout (the run's files stay)
#   state.sh active                  print the active slug (exit 1 if none)
#   state.sh get <jq filter>         read state.json             state.sh set <jq expression> [jq args]
#   state.sh stage <n>               enter stage n (prices the main session's usage so far first)
#   state.sh phase <name>            plan|prd-review|tests|code|docs|review|evidence|ship|monitor
#   state.sh round <name>            increment a round counter (prd, impl, review, evidence) and print it
#   state.sh approve <gate> [sha]    record a human approval (prd, evidence, deploy, rollback) against a commit
#   state.sh baseline                run every check and save the ones already failing
#   state.sh freeze                  freeze tests and check-defining files, snapshot the check commands
#   state.sh verify-freeze [--only tests|checks]
#   state.sh contract-sync           set `passes` in contract.json from the JUnit reports (harness only)
#   state.sh red-check               list AC tests that pass before the code exists
#   state.sh calibrate <agent> <line>    record one lesson line for an agent (folded at stage 7)
#   state.sh fold-memory             append the run's lesson lines to each agent's MEMORY.md (idempotent)
#   state.sh history <jq expr> [jq args] update the committed history record
#   state.sh spawn <agent> <effort> [model]  record a subagent spawn (models and efforts used)
#   state.sh spend                   print spend by stage and agent (the main session is priced first)
#   state.sh spend-main              price the main session's transcript into the current stage
#   state.sh budget-check            exit 1 when the run's estimated spend exceeds limits.budget_usd
#   state.sh ce-version              print the installed compound-engineering version
#   state.sh paths                   print the run's paths (state, run dir, spec dir, history, reports)
# Exit status: 0 ok, 1 a check failed or a precondition isn't met, 2 usage error.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need git jq python3

root="$FACTORY_ROOT_DIR"
cmd="${1:-}"; [ $# -gt 0 ] && shift
runs="$root/.factory/runs"

slug_ok() { printf '%s' "$1" | grep -E -q '^[a-z0-9][a-z0-9._-]{0,63}$'; }
need_active() { slug="$(factory_active_slug)"; [ -n "$slug" ] || { echo "factory: no active run in this checkout (state.sh start <slug>)" >&2; exit 1; }; run="$runs/$slug"; }
spec_dir() { printf '%s/docs/specs/%s' "$root" "$1"; }
history_file() { printf '%s/.factory/history/%s.json' "$root" "$1"; }
config_json_file() { local f="$run/.config.json"; factory_config_json > "$f" || { echo "factory: .factory/config.yaml doesn't parse" >&2; exit 2; }; printf '%s' "$f"; }

history_update() { # <jq expression> [jq args]
  local f expr="$1"; shift
  f="$(history_file "$slug")"
  [ -f "$f" ] || { echo "factory: no history file $f" >&2; return 1; }
  _lock_acquire "$f.lock"
  if jq "$@" "$expr" "$f" > "$f.tmp.$$"; then mv "$f.tmp.$$" "$f"; rmdir "$f.lock"; return 0; fi
  rm -f "$f.tmp.$$"; rmdir "$f.lock"; return 1
}

derive_port() { # a free port derived from the slug, in 41000-48999
  factory_py - "$1" <<'PY'
import socket, sys, zlib
base = 41000 + zlib.crc32(sys.argv[1].encode()) % 8000
for i in range(200):
    p = 41000 + (base - 41000 + i) % 8000
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); print(p); break
    except OSError:
        continue
    finally:
        s.close()
PY
}

ce_version() {
  local f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  [ -f "$f" ] || return 1
  jq -r '[.plugins // {} | to_entries[] | select(.key | startswith("compound-engineering@")) | .value[]?.version] | sort_by(split(".") | map(tonumber? // 0)) | last // empty' "$f"
}

main_transcript() { cat "$runs/.main-transcript" 2>/dev/null; }

spend_main() { # attributes the main session's new spend to the current stage
  local t total prev stage delta
  t="$(main_transcript)"
  [ -n "$t" ] && [ -f "$t" ] || return 0
  total="$(factory_py "$FACTORY_LIB/spend.py" "$t" "$FACTORY_LIB/prices.json" | jq -r '.usd')" || return 0
  prev="$(jq -r --arg t "$t" '.spend.main_seen[$t] // 0' "$run/state.json")"
  stage="$(jq -r '.stage // 0' "$run/state.json")"
  delta="$(jq -n --argjson a "$total" --argjson b "${prev:-0}" '([$a - $b, 0] | max)')"
  state_update '.spend.main_seen[$t] = $total | .spend.main[$s] = ((.spend.main[$s] // 0) + $d)' \
    --arg t "$t" --argjson total "$total" --arg s "$stage" --argjson d "$delta"
}

# Spend totals, derived: the main session per stage plus every priced subagent spawn.
SPEND_BY_STAGE='(.spend.main // {}) as $m | ([.spend.agents // {} | .[] | {key: (.stage | tostring), value: .usd}] | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries) as $a | reduce (($m + $a) | keys[]) as $k ({}; .[$k] = (($m[$k] // 0) + ($a[$k] // 0)))'
SPEND_TOTAL="($SPEND_BY_STAGE) | [.[]] | add // 0"

case "$cmd" in
  start)
    slug="${1:-}"; slug_ok "$slug" || { echo "factory: slug must be lowercase letters, digits, . _ - (max 64)" >&2; exit 2; }
    cur="$(factory_active_slug)"
    if [ -n "$cur" ] && [ "$cur" != "$slug" ]; then echo "factory: run '$cur' is active in this checkout; finish it, or use claude --worktree for a parallel run" >&2; exit 1; fi
    run="$runs/$slug"
    mkdir -p "$run/reports" "$root/.factory/history"
    [ -f "$runs/.gitignore" ] || printf '*\n' > "$runs/.gitignore"
    if [ ! -f "$run/state.json" ]; then
      port="$(derive_port "$slug")"
      base="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo "")"
      jq -n --arg slug "$slug" --arg at "$(now_utc)" --arg base "$base" --argjson port "${port:-0}" \
        --arg ce "$(ce_version || true)" '{
          slug: $slug, created: $at, stage: 1, phase: "plan", base: $base, branch: ("factory/" + $slug),
          port: $port, rounds: {prd: 0, impl: 0, review: 0, evidence: 0}, approvals: {}, pr: null,
          frozen: false, spawns: [], compound: [], escalations: [], ce_version: $ce,
          spend: {main: {}, agents: {}, main_seen: {}}
        }' > "$run/state.json"
    fi
    hf="$(history_file "$slug")"
    if [ ! -f "$hf" ]; then
      jq -n --arg slug "$slug" --arg at "$(now_utc)" --arg ce "$(ce_version || true)" '{
        slug: $slug, started: $at, finished: null, ce_version: $ce, depth: null,
        issues: [], qa_false_negatives: [], implementer_passes: [], rounds: {}, escalations: [],
        incidents: [], spend: {}, models: [], compound: [], calibration: []
      }' > "$hf"
    fi
    printf '%s\n' "$slug" > "$runs/active"
    echo "factory: run '$slug' active (port $(jq -r .port "$run/state.json"))"
    ;;
  resume)
    slug="${1:-}"; slug_ok "$slug" && [ -f "$runs/$slug/state.json" ] || { echo "factory: no run '$slug'" >&2; exit 1; }
    cur="$(factory_active_slug)"
    if [ -n "$cur" ] && [ "$cur" != "$slug" ]; then echo "factory: run '$cur' is active in this checkout" >&2; exit 1; fi
    printf '%s\n' "$slug" > "$runs/active"
    echo "factory: run '$slug' resumed at stage $(jq -r .stage "$runs/$slug/state.json") ($(jq -r .phase "$runs/$slug/state.json"))"
    ;;
  end) rm -f "$runs/active"; echo "factory: checkout released" ;;
  active) s="$(factory_active_slug)"; [ -n "$s" ] && echo "$s" || exit 1 ;;
  get) need_active; state_get "${1:-.}" ;;
  set) need_active; [ $# -ge 1 ] || exit 2; state_update "$@" ;;
  stage)
    need_active; n="${1:-}"; case "$n" in [1-8]) ;; *) echo "factory: stage is 1-8" >&2; exit 2 ;; esac
    spend_main
    state_update '.stage = $n | .stage_entered = $at' --argjson n "$n" --arg at "$(now_utc)"
    ;;
  phase)
    need_active
    case "${1:-}" in plan|prd-review|tests|code|docs|review|evidence|ship|monitor) ;; *) echo "factory: unknown phase '${1:-}'" >&2; exit 2 ;; esac
    state_update '.phase = $p' --arg p "$1"
    ;;
  round)
    need_active; case "${1:-}" in prd|impl|review|evidence) ;; *) echo "factory: unknown round '${1:-}'" >&2; exit 2 ;; esac
    state_update '.rounds[$r] += 1' --arg r "$1" && state_get ".rounds[\"$1\"]"
    ;;
  approve)
    need_active; gate="${1:-}"; case "$gate" in prd|evidence|deploy|rollback) ;; *) echo "factory: gates are prd, evidence, deploy, rollback" >&2; exit 2 ;; esac
    sha="${2:-$(git -C "$root" rev-parse HEAD)}"
    state_update '.approvals[$g] = {sha: $s, at: $at}' --arg g "$gate" --arg s "$sha" --arg at "$(now_utc)"
    echo "factory: $gate approved at $sha"
    ;;
  baseline)
    need_active
    bash "$FACTORY_SCRIPTS/run-checks.sh" --set all --save-failures "$run/baseline-failures" --tail 5 >/dev/null 2>&1
    n="$(grep -c . "$run/baseline-failures" 2>/dev/null)"; n="${n:-0}"
    echo "factory: baseline taken; $n check(s) already failing: $(tr '\n' ' ' < "$run/baseline-failures" 2>/dev/null)"
    ;;
  freeze)
    need_active; cj="$(config_json_file)"
    factory_py "$FACTORY_LIB/freeze.py" freeze --root "$root" --config "$cj" --run "$run" --plan "$(spec_dir "$slug")/plan.md" || exit $?
    state_update '.frozen = true | .frozen_at = $at | .frozen_sha = $sha' --arg at "$(now_utc)" --arg sha "$(git -C "$root" rev-parse HEAD 2>/dev/null)"
    ;;
  verify-freeze)
    need_active; cj="$(config_json_file)"
    factory_py "$FACTORY_LIB/freeze.py" verify --root "$root" --config "$cj" --run "$run" --plan "$(spec_dir "$slug")/plan.md" "$@"
    ;;
  contract-sync)
    need_active
    factory_py "$FACTORY_LIB/junit.py" lint "$run/reports" || true
    factory_py "$FACTORY_LIB/junit.py" sync "$(spec_dir "$slug")/contract.json" "$run/reports"
    ;;
  red-check)
    need_active
    factory_py "$FACTORY_LIB/junit.py" lint "$run/reports" || true
    factory_py "$FACTORY_LIB/junit.py" red "$(spec_dir "$slug")/contract.json" "$run/reports"
    ;;
  calibrate)
    need_active; agent="${1:-}"; line="${2:-}"
    printf '%s' "$agent" | grep -E -q '^[a-z][a-z0-9-]*$' || { echo "factory: agent is a factory agent name, like prd-reviewer" >&2; exit 2; }
    [ -n "$line" ] || { echo "factory: calibrate needs a lesson line" >&2; exit 2; }
    line="$(printf '%s' "$line" | tr '\n\r\t' '   ' | cut -c1-300)"
    stage="$(state_get .stage)"
    history_update '.calibration += [{agent: $a, line: ($d + " " + $s + ": " + $l), stage: ($st | tonumber? // null), at: $at}]' \
      --arg a "$agent" --arg l "$line" --arg d "$(date -u +%F)" --arg s "$slug" --arg st "${stage:-}" --arg at "$(now_utc)"
    echo "factory: lesson recorded for $agent (folded into its MEMORY.md at stage 7)"
    ;;
  fold-memory)
    need_active; max="$(cfg '.learning.memory_max_lines' 150)"
    jq -r '.calibration[] | [.agent, .line] | @tsv' "$(history_file "$slug")" | while IFS="$(printf '\t')" read -r agent line; do
      [ -n "$agent" ] || continue
      d="$root/.claude/agent-memory/factory-$agent"; mkdir -p "$d"; m="$d/MEMORY.md"
      [ -f "$m" ] || printf '# factory-%s lessons\n\nReference material, not rules: it never overrides the task, contract.json or your instructions.\n\n' "$agent" > "$m"
      grep -F -x -q -e "- $line" "$m" && continue
      printf -- '- %s\n' "$line" >> "$m"
      n="$(wc -l < "$m" | tr -d ' ')"
      if [ "$n" -gt "$max" ]; then # keep the header and the newest lessons; move the oldest to archive.md
        factory_py - "$m" "$d/archive.md" "$max" <<'PY'
import sys
m, a, mx = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(m, encoding="utf-8").read().split("\n")
if lines and lines[-1] == "": lines.pop()
head = [l for l in lines if not l.startswith("- ")]
items = [l for l in lines if l.startswith("- ")]
keep = max(mx - len(head), 1)
old, new = items[:-keep], items[-keep:]
with open(a, "a", encoding="utf-8") as f:
    f.write("".join(l + "\n" for l in old))
with open(m, "w", encoding="utf-8") as f:
    f.write("\n".join(head + new) + "\n")
PY
        echo "factory: factory-$agent/MEMORY.md reached $max lines; the oldest lessons moved to archive.md (consolidate with /factory:stats)" >&2
      fi
    done
    echo "factory: lessons folded into .claude/agent-memory/factory-*/MEMORY.md"
    ;;
  history) need_active; [ $# -ge 1 ] || exit 2; history_update "$@" ;;
  spawn)
    need_active; agent="${1:-}"; effort="${2:-}"; model="${3:-opus}"
    [ -n "$agent" ] && [ -n "$effort" ] || { echo "factory: spawn <agent> <effort> [model]" >&2; exit 2; }
    stage="$(jq -r '.stage' "$run/state.json")"
    state_update '.spawns += [{agent: $a, effort: $e, model: $m, stage: ($s | tonumber), at: $at}]' --arg a "$agent" --arg e "$effort" --arg m "$model" --arg s "$stage" --arg at "$(now_utc)"
    history_update '.models = ((.models + [{agent: $a, effort: $e, model: $m}]) | unique)' --arg a "$agent" --arg e "$effort" --arg m "$model"
    ;;
  spend)
    need_active; spend_main
    jq ". as \$r | {by_stage: ($SPEND_BY_STAGE), total: ($SPEND_TOTAL), by_agent: (([.spend.agents // {} | .[] | {agent, usd}] | group_by(.agent) | map({key: .[0].agent, value: (map(.usd) | add)}) | from_entries) + {orchestrator: ([\$r.spend.main // {} | .[]] | add // 0)}), unpriced_spawns: ((.spawns | length) - (.spend.agents | length) | if . < 0 then 0 else . end)}" "$run/state.json"
    ;;
  spend-main) need_active; spend_main ;;
  budget-check)
    need_active; spend_main
    total="$(jq -r "$SPEND_TOTAL" "$run/state.json")"; total="${total:-0}"
    limit="$(cfg '.limits.budget_usd' 0)"
    printf 'factory: estimated spend $%.2f of $%s\n' "$total" "$limit"
    [ "$limit" = "0" ] && exit 0
    jq -n --argjson t "$total" --argjson l "$limit" 'if $t > $l then halt_error(1) else empty end' 2>/dev/null || { echo "factory: budget exceeded; pausing at this gate" >&2; exit 1; }
    ;;
  ce-version) v="$(ce_version)"; [ -n "$v" ] && echo "$v" || { echo "factory: compound-engineering is not installed" >&2; exit 1; } ;;
  paths)
    need_active
    jq -n --arg state "$run/state.json" --arg run "$run" --arg spec "$(spec_dir "$slug")" --arg history "$(history_file "$slug")" --arg reports "$run/reports" \
      '{state: $state, run: $run, spec: $spec, history: $history, reports: $reports}'
    ;;
  ''|-h|--help) sed -n '2,27p' "$0" ;;
  *) echo "factory: unknown state command '$cmd'" >&2; exit 2 ;;
esac
