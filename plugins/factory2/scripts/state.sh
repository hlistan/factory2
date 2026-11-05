#!/usr/bin/env bash
# factory run state. The orchestrator (/factory2:run) calls these; hooks read the same files.
#   state.sh start <slug> [--effort-env-ok] [--issue <ref> [--feature]] [--caused-by <slug>]
#                                    begin a run in this checkout: state.json, lock, port, history. --issue
#                                    makes it a bugfix run for that tracker issue (GitHub number, URL, or a
#                                    local .factory/incidents/I-n.md); with --feature, a feature run that
#                                    builds what the issue asks for. --caused-by names the run that shipped
#                                    the regression, when known.
#   state.sh resume <slug> [--effort-env-ok]  make an existing run the active one
#                                    Both exit 3 while CLAUDE_CODE_EFFORT_LEVEL is set: it overrides every
#                                    agent's effort, even the Agent tool's parameter. --effort-env-ok (after
#                                    the user agreed) runs anyway and records the level in state.effort_env.
#   state.sh branch                  switch to (or create) factory/<slug> and record the run's base there
#   state.sh end                     release the checkout (the run's files stay)
#   state.sh active                  print the active slug (exit 1 if none)
#   state.sh get <jq filter>         read state.json             state.sh set <jq expression> [jq args]
#   state.sh stage <n>               enter stage n (prices the main session's usage so far first); going
#                                    back revokes the approvals of gates at stage n or later. The stage
#                                    label on the run's PR and GitHub issue follows (pr.sh labels).
#   state.sh phase <name>            plan|prd-review|tests|code|docs|review|evidence|ship|monitor
#   state.sh round <name>            increment a round counter (prd, impl, review, evidence) and print it
#   state.sh approve <gate> [sha] [--via-pr <url> --by <login>]
#                                    record a human approval (prd: the PRD and plan; evidence: what was
#                                    built, before merge) against a commit. Deploy and rollback aren't gates.
#                                    On a run tracked on a PR, every approval needs --via-pr:
#                                    pr.sh feedback records it from the person's /approve comment.
#   state.sh baseline                run every check and save the ones already failing
#   state.sh freeze                  freeze tests and check-defining files, snapshot the check commands
#   state.sh verify-freeze [--only tests|checks]
#   state.sh contract-sync           set `passes` in contract.json from the JUnit reports (harness only)
#   state.sh red-check [--test <name>...]  list AC tests that pass before the code exists; with
#                                    --test (stage 5, once per new test), check that each named test fails
#   state.sh calibrate <agent> <line>    record one lesson line for an agent (folded at stage 7)
#   state.sh fold-memory             append the run's lesson lines to each agent's MEMORY.md (idempotent)
#   state.sh history <jq expr> [jq args] update the committed history record
#   state.sh spawn <agent> <effort> [model]  record a subagent spawn (models and efforts used)
#   state.sh spend                   print spend by stage and agent (the main session is priced first)
#   state.sh spend-main              price the main session's transcript into the current stage
#   state.sh budget-check            exit 1 when the run's estimated spend exceeds limits.budget_usd
#   state.sh ce-version              the compound-engineering release the bundled ce-compound comes from
#   state.sh config <jq> [default]   read .factory/config.yaml
#   state.sh role <agent> [effort]   "<model> <effort>" for a spawn: roles.<agent> in the config, else the
#                                    given effort (the implementer's re-runs at high), else the agent's
#                                    frontmatter model and effort
#   state.sh paths                   print the run's paths (state, run dir, spec dir, history, reports)
# Exit status: 0 ok, 1 a check failed or a precondition isn't met, 2 usage error.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need git jq python3

root="$FACTORY_ROOT_DIR"
cmd="${1:-}"; [ $# -gt 0 ] && shift
runs="$root/.factory/runs"

effort_env_gate() { # [--effort-env-ok]: refuse to start or resume while CLAUDE_CODE_EFFORT_LEVEL is set
  [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ] || return 0
  [ "${1:-}" = "--effort-env-ok" ] && return 0
  echo "factory: CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL overrides the effort of every agent spawn, including the Agent tool's effort parameter, so factory's per-role effort (implementer low, re-runs high) would be ignored. Unset it and restart Claude Code, or, if the user agrees to run every agent at that level, repeat with --effort-env-ok." >&2
  exit 3
}

sha256_of() { # <file>: hex sha256, or nothing when the file is missing
  [ -f "$1" ] && factory_py -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

slug_ok() { printf '%s' "$1" | grep -E -q '^[a-z0-9][a-z0-9._-]{0,63}$'; }
need_active() { slug="$(factory_active_slug)"; [ -n "$slug" ] || { echo "factory: no active run in this checkout (state.sh start <slug>)" >&2; exit 1; }; run="$runs/$slug"; }
spec_dir() { printf '%s/docs/specs/%s' "$root" "$1"; }
history_file() { printf '%s/.factory/history/%s.json' "$root" "$1"; }
refresh_labels() { # best effort: the stage label on the run's PR and GitHub issue; the next pr.sh call retries
  local i; i="$(state_get '.issue // empty')"; [ "$(cfg '.issues.labels' true)" = false ] && i=""
  case "$i" in
    [0-9]*|'#'[0-9]*|https://*/issues/[0-9]*) ;;
    *) [ "$(state_get '.review_via // empty')" = pr ] || return 0 ;;
  esac
  bash "$FACTORY_SCRIPTS/pr.sh" labels >/dev/null 2>&1 || true
}
config_json_file() { # written atomically: hooks and the orchestrator may call this at the same time
  local f="$run/.config.json"
  factory_config_json > "$f.tmp.$$" || { rm -f "$f.tmp.$$"; echo "factory: .factory/config.yaml doesn't parse" >&2; exit 2; }
  mv "$f.tmp.$$" "$f"; printf '%s' "$f"
}

history_update() { # <jq expression> [jq args]
  local f expr="$1"; shift
  f="$(history_file "$slug")"
  [ -f "$f" ] || { echo "factory: no history file $f" >&2; return 1; }
  _lock_acquire "$f.lock"
  if jq "$@" "$expr" "$f" > "$f.tmp.$$"; then mv "$f.tmp.$$" "$f"; rm -rf "$f.lock"; return 0; fi
  rm -f "$f.tmp.$$"; rm -rf "$f.lock"; return 1
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

ce_version() {   # the release the bundled ce-compound and ce-compound-refresh were copied from
  jq -r '.version // empty' "$FACTORY_SCRIPTS/../vendor/compound-engineering/upstream.json" 2>/dev/null
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
    slug="${1:-}"; [ $# -gt 0 ] && shift
    eok=""; issue=""; caused=""; feature=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --effort-env-ok) eok="$1"; shift ;;
        --issue) [ -n "${2:-}" ] || { echo "factory: --issue needs a reference" >&2; exit 2; }; issue="$2"; shift 2 ;;
        --feature) feature=1; shift ;;
        --caused-by) slug_ok "${2:-}" || { echo "factory: --caused-by needs a run slug" >&2; exit 2; }; caused="$2"; shift 2 ;;
        *) echo "factory: unknown start option '$1'" >&2; exit 2 ;;
      esac
    done
    [ -z "$feature" ] || [ -n "$issue" ] || { echo "factory: --feature needs --issue" >&2; exit 2; }
    kind=bugfix; [ -z "$issue" ] || [ -z "$feature" ] || kind=feature
    effort_env_gate "$eok"
    slug_ok "$slug" || { echo "factory: slug must be lowercase letters, digits, . _ - (max 64)" >&2; exit 2; }
    cur="$(factory_active_slug)"
    if [ -n "$cur" ] && [ "$cur" != "$slug" ]; then echo "factory: run '$cur' is active in this checkout; finish it, or use claude --worktree for a parallel run" >&2; exit 1; fi
    run="$runs/$slug"
    mkdir -p "$run/reports" "$root/.factory/history"
    factory_config_json >/dev/null || { echo "factory: .factory/config.yaml doesn't parse; fix it before starting a run" >&2; exit 2; }
    [ -f "$runs/.gitignore" ] || printf '*\n' > "$runs/.gitignore"
    if [ ! -f "$run/state.json" ]; then
      port="$(derive_port "$slug")"
      base="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo "")"
      jq -n --arg slug "$slug" --arg at "$(now_utc)" --arg base "$base" --argjson port "${port:-0}" \
        --arg ce "$(ce_version || true)" --arg issue "$issue" --arg caused "$caused" --arg kind "$kind" '{
          slug: $slug, created: $at, stage: 1, phase: "plan", base: $base, branch: ("factory/" + $slug),
          kind: (if $issue == "" then "feature" else $kind end),
          issue: (if $issue == "" then null else $issue end), caused_by: (if $caused == "" then null else $caused end),
          port: $port, rounds: {prd: 0, impl: 0, review: 0, evidence: 0}, approvals: {}, pr: null,
          frozen: false, spawns: [], compound: [], escalations: [], ce_version: $ce,
          spend: {main: {}, agents: {}, main_seen: {}}
        }' > "$run/state.json"
    fi
    hf="$(history_file "$slug")"
    if [ ! -f "$hf" ]; then
      jq -n --arg slug "$slug" --arg at "$(now_utc)" --arg ce "$(ce_version || true)" --arg issue "$issue" --arg caused "$caused" --arg kind "$kind" '{
        slug: $slug, started: $at, finished: null, ce_version: $ce, depth: null,
        kind: (if $issue == "" then "feature" else $kind end),
        issue: (if $issue == "" then null else $issue end), caused_by: (if $caused == "" then null else $caused end),
        issues: [], qa_false_negatives: [], implementer_passes: [], rounds: {}, escalations: [],
        incidents: [], spend: {}, models: [], compound: [], calibration: []
      }' > "$hf"
    fi
    printf '%s\n' "$slug" > "$runs/active"
    state_update '.effort_env = (if $e == "" then null else $e end)' --arg e "${CLAUDE_CODE_EFFORT_LEVEL:-}"
    echo "factory: run '$slug' active (port $(jq -r .port "$run/state.json"))"
    refresh_labels
    ;;
  branch)
    # stage 1: switch to (or create) factory/<slug>, then record the run's base as the commit the branch
    # starts from, so the first freeze compares with the tree the run actually started on
    need_active
    [ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ] || { echo "factory: the working tree has uncommitted changes; commit or stash them first" >&2; exit 1; }
    b="factory/$slug"
    if git -C "$root" rev-parse --verify -q "refs/heads/$b" >/dev/null; then
      # resuming: the base stays where the branch was created, so commits made on the branch before
      # the first freeze are still compared with it
      git -C "$root" switch -q "$b" || exit 1
    else
      git -C "$root" switch -q -c "$b" || exit 1
      state_update '.base = $b | .branch = $br' --arg b "$(git -C "$root" rev-parse HEAD)" --arg br "$b"
    fi
    echo "factory: on $b (base $(state_get .base | cut -c1-12))"
    ;;
  resume)
    effort_env_gate "${2:-}"
    slug="${1:-}"; slug_ok "$slug" && [ -f "$runs/$slug/state.json" ] || { echo "factory: no run '$slug'" >&2; exit 1; }
    cur="$(factory_active_slug)"
    if [ -n "$cur" ] && [ "$cur" != "$slug" ]; then echo "factory: run '$cur' is active in this checkout" >&2; exit 1; fi
    printf '%s\n' "$slug" > "$runs/active"
    state_update '.effort_env = (if $e == "" then null else $e end)' --arg e "${CLAUDE_CODE_EFFORT_LEVEL:-}"
    echo "factory: run '$slug' resumed at stage $(jq -r .stage "$runs/$slug/state.json") ($(jq -r .phase "$runs/$slug/state.json"))"
    ;;
  end) rm -f "$runs/active"; echo "factory: checkout released" ;;
  active) s="$(factory_active_slug)"; [ -n "$s" ] && echo "$s" || exit 1 ;;
  get) need_active; state_get "${1:-.}" ;;
  set) need_active; [ $# -ge 1 ] || exit 2; state_update "$@" ;;
  stage)
    need_active; n="${1:-}"; case "$n" in [1-8]) ;; *) echo "factory: stage is 1-8" >&2; exit 2 ;; esac
    spend_main
    # going back (a spec gap to stage 2, a defect or incident to stage 5, ...) revokes every approval
    # given at that stage or later: an approval holds only for the pass through the stages it was given in
    revoked="$(jq -r --argjson n "$n" 'if $n < (.stage // 1) then [.approvals // {} | keys[] | select(({prd: 2, evidence: 6}[.] // 0) >= $n)] | join(" ") else "" end' "$(state_file)")"
    state_update '(if $n < (.stage // 1) then .approvals |= with_entries(select(({prd: 2, evidence: 6}[.key] // 0) < $n)) else . end) | .stage = $n | .stage_entered = $at' --argjson n "$n" --arg at "$(now_utc)"
    [ -z "$revoked" ] || echo "factory: back to stage $n; approvals revoked: $revoked"
    refresh_labels
    # before stage 7 the change is in progress: its PR is a draft (best effort; pr.sh ready undoes it)
    if [ "$n" -lt 7 ] && [ -n "$(state_get '.pr // empty')" ]; then bash "$FACTORY_SCRIPTS/pr.sh" draft >/dev/null 2>&1 || true; fi
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
    need_active; gate="${1:-}"; case "$gate" in prd|evidence) ;; *) echo "factory: gates are prd and evidence (deploy and rollback need no approval)" >&2; exit 2 ;; esac
    shift; sha=""; via=""; by=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --via-pr) via="${2:-}"; shift 2 || { echo "factory: $1 needs a value" >&2; exit 2; } ;;
        --by) by="${2:-}"; shift 2 || { echo "factory: $1 needs a value" >&2; exit 2; } ;;
        -*) echo "factory: approve <gate> [sha] [--via-pr <comment url> --by <login>]" >&2; exit 2 ;;
        *) sha="$1"; shift ;;
      esac
    done
    sha="${sha:-$(git -C "$root" rev-parse HEAD)}"
    # a run tracked on a PR takes every approval only from the person's /approve there (pr.sh feedback)
    if [ "$(state_get '.review_via // empty')" = pr ] && [ -z "$via" ]; then
      echo "factory: this run's approvals are given on its PR: the person replies /approve to the approval request (pr.sh request-approval $gate, then pr.sh wait $gate)" >&2; exit 1
    fi
    state_update '.approvals[$g] = ({sha: $s, at: $at} + (if $u == "" then {} else {url: $u, by: $b} end))' \
      --arg g "$gate" --arg s "$sha" --arg at "$(now_utc)" --arg u "$via" --arg b "$by"
    echo "factory: $gate approved at $sha"
    ;;
  baseline)
    need_active
    # the fast set is timed: the implementer's stop gate runs it under a limit of 840 s
    t0="$(date +%s)"
    bash "$FACTORY_SCRIPTS/run-checks.sh" --set fast --save-failures "$run/baseline-failures.fast" --tail 5 >/dev/null 2>&1
    fast_s=$(( $(date +%s) - t0 ))
    bash "$FACTORY_SCRIPTS/run-checks.sh" --set slow --save-failures "$run/baseline-failures.slow" --tail 5 >/dev/null 2>&1
    cat "$run/baseline-failures.fast" "$run/baseline-failures.slow" 2>/dev/null > "$run/baseline-failures"
    rm -f "$run/baseline-failures.fast" "$run/baseline-failures.slow"
    state_update '.fast_checks_seconds = ($s | tonumber)' --arg s "$fast_s"
    n="$(grep -c . "$run/baseline-failures" 2>/dev/null)"; n="${n:-0}"
    echo "factory: baseline taken; $n check(s) already failing: $(tr '\n' ' ' < "$run/baseline-failures" 2>/dev/null)"
    if [ $((fast_s * 2)) -gt 840 ]; then
      echo "factory: WARNING the fast checks took ${fast_s}s, more than half the stop gate's 840 s limit; move slow checks from checks.fast to checks.slow, or the gate will time out and let the implementer stop unchecked"
    fi
    ;;
  freeze)
    need_active; cj="$(config_json_file)"
    base="$(jq -r '.base // empty' "$run/state.json")"
    want="$(jq -r '.frozen_plan_sha // empty' "$run/state.json")"
    if [ -n "$want" ] && [ "$(sha256_of "$run/plan.frozen.md")" != "$want" ]; then
      echo "factory: $run/plan.frozen.md is missing or was changed after the last freeze; not re-freezing. Tell the user." >&2; exit 2
    fi
    factory_py "$FACTORY_LIB/freeze.py" freeze --root "$root" --config "$cj" --run "$run" --plan "$(spec_dir "$slug")/plan.md" ${base:+--base "$base"} || exit $?
    # the snapshot's hash, so a deleted or rewritten plan.frozen.md is caught by verify-freeze
    state_update '.frozen = true | .frozen_at = $at | .frozen_sha = $sha | .frozen_plan_sha = $p' --arg at "$(now_utc)" \
      --arg sha "$(git -C "$root" rev-parse HEAD 2>/dev/null)" --arg p "$(sha256_of "$run/plan.frozen.md")"
    # Test results from before this freeze are the red check's, failing by design; contract-sync fails a
    # test that any report failed, so they would outlive the code that makes them pass. Keep them as
    # evidence in red-reports/<time>/; the review reports (files, not directories) stay.
    if [ -d "$run/reports" ] && [ -n "$(find "$run/reports" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
      red="$run/red-reports/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$red"
      find "$run/reports" -mindepth 1 -maxdepth 1 -type d -exec mv {} "$red/" \;
      echo "freeze: earlier test results moved to ${red#"$root"/}"
    fi
    ;;
  verify-freeze)
    need_active; cj="$(config_json_file)"
    # the plan as it was at the last freeze (orchestrator-reviewed), never the live file. Its hash is in
    # state.json: a missing or changed snapshot is an error (exit 2, which the stop gate blocks on).
    plan="$run/plan.frozen.md"
    want="$(jq -r '.frozen_plan_sha // empty' "$run/state.json")"
    if [ -n "$want" ]; then
      [ "$(sha256_of "$plan")" = "$want" ] || { echo "factory: $plan is missing or was changed after the freeze" >&2; exit 2; }
    else
      [ -f "$plan" ] || plan="$(spec_dir "$slug")/plan.md"   # a run frozen before snapshots existed
    fi
    factory_py "$FACTORY_LIB/freeze.py" verify --root "$root" --config "$cj" --run "$run" --plan "$plan" "$@"
    ;;
  contract-sync)
    need_active
    factory_py "$FACTORY_LIB/junit.py" lint "$run/reports" || true
    factory_py "$FACTORY_LIB/junit.py" sync "$(spec_dir "$slug")/contract.json" "$run/reports"
    ;;
  red-check)
    need_active
    factory_py "$FACTORY_LIB/junit.py" lint "$run/reports" || true
    [ $# -eq 0 ] || [ "$1" = "--test" ] || { echo "factory: red-check [--test <name> ...]" >&2; exit 2; }
    if [ "${1:-}" = "--test" ]; then
      names=()
      while [ $# -gt 0 ]; do
        [ "$1" = "--test" ] && [ $# -ge 2 ] || { echo "factory: red-check --test <name> [--test <name>...]" >&2; exit 2; }
        names+=("$2"); shift 2
      done
      factory_py "$FACTORY_LIB/junit.py" red-tests "$run/reports" "${names[@]}"
    else
      factory_py "$FACTORY_LIB/junit.py" red "$(spec_dir "$slug")/contract.json" "$run/reports"
    fi
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
    case "$max" in ''|*[!0-9]*) max=150 ;; esac
    factory_py "$FACTORY_LIB/fold.py" "$(history_file "$slug")" "$root" "$max" || exit $?
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
    # numbers only (a "$20" or "20 USD" is a config error, not an exceeded budget); 0 or less means no limit
    printf '%s' "$limit" | grep -E -q '^-?[0-9]+([.][0-9]+)?$' || { echo "factory: limits.budget_usd must be a number of dollars, like 60 (got '$limit')" >&2; exit 2; }
    echo "factory: estimated spend \$$(LC_ALL=C awk -v t="$total" 'BEGIN { printf "%.2f", t }') of \$$limit"
    jq -n --argjson t "$total" --argjson l "$limit" 'if $l > 0 and $t > $l then halt_error(1) else empty end' 2>/dev/null || { echo "factory: budget exceeded; pausing at this gate" >&2; exit 1; }
    ;;
  ce-version) v="$(ce_version)"; [ -n "$v" ] && echo "$v" || { echo "factory: the bundled ce-compound manifest is missing" >&2; exit 1; } ;;
  config) cfg "${1:-.}" "${2:-}"; echo ;;
  role)
    # <agent> [effort]: prints "<model> <effort>" for a spawn. Precedence: roles.<agent> in the config,
    # then the effort argument (the implementer's fresh re-runs at high), then the agent's frontmatter.
    agent="${1:-}"
    case "$agent" in ''|*[!a-z0-9-]*) echo "factory: role needs an agent name" >&2; exit 2 ;; esac
    af="$FACTORY_SCRIPTS/../agents/$agent.md"
    [ -f "$af" ] || { echo "factory: no agent '$agent'" >&2; exit 2; }
    fm() { awk -v k="$1" 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f && index($0, k ": ") == 1 { sub(/^[^:]*: */, ""); print; exit }' "$af"; }
    def_model="$(fm model)"; def_effort="${2:-$(fm effort)}"
    printf '%s %s\n' "$(cfg ".roles[\"$agent\"].model" "${def_model:-opus}")" "$(cfg ".roles[\"$agent\"].effort" "${def_effort:-medium}")"
    ;;
  paths)
    need_active
    jq -n --arg state "$run/state.json" --arg run "$run" --arg spec "$(spec_dir "$slug")" --arg history "$(history_file "$slug")" --arg reports "$run/reports" \
      '{state: $state, run: $run, spec: $spec, history: $history, reports: $reports}'
    ;;
  ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' ;;
  *) echo "factory: unknown state command '$cmd'" >&2; exit 2 ;;
esac
