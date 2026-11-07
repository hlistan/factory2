#!/usr/bin/env bash
# factory stage 7: ship what the person approved, and nothing else.
#   ship.sh verify      the evidence approval is recorded and is an ancestor of HEAD; every commit after it
#                       (first-parent) is either a conflict-free, unmodified merge of origin/<default_branch>
#                       or the harness's bookkeeping commit (only .claude/agent-memory/factory-*/, this run's
#                       .factory/history/<slug>.json, lesson docs under <docs_root>/solutions/ and pr.sh's
#                       record of the PR's comments, docs/specs/<slug>/feedback/*.md, and every
#                       memory line it adds is one of the run's calibration lines or moved within the
#                       commit); and every check is green (the frozen
#                       snapshot; failures known at the baseline are allowed). Records ship.verified.
#   ship.sh merge       HEAD must be the verified commit and pushed. With a PR, takes it out of draft and
#                       waits for its checks on GitHub (pr.sh ready): any failed, no merge. Runs ship.merge, then records the merged
#                       commit on origin/<default_branch> as ship.merged. The issue closes when this was its
#                       last open PR (issue-flow.sh merged).
#   ship.sh deploy      runs ship.deploy (FACTORY_DEPLOY_SHA = the merged commit). Stage 7, evidence approved,
#                       merged. An empty ship.deploy is skipped (exit 0) and recorded as skipped.
#   ship.sh smoke       runs ship.smoke against the deployment; output in <run>/smoke.log. Empty: skipped.
#   ship.sh rollback    runs ship.rollback (stage 7 or 8). Exit 1 when it is empty or fails.
#   ship.sh mark        records the deploy marker (commit, time) and the monitoring baseline
#                       (monitor.sh baseline) in state, and the deploy in the run's history.
# Commands run from the project root with CI=true and no input. No step asks a person: the evidence
# approval at stage 6 covers merge, deploy, smoke and rollback.
# Exit status: 0 ok (or skipped), 1 a check or precondition failed, 2 usage or config error.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need git jq python3

root="$FACTORY_ROOT_DIR"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;; esac
slug="$(factory_active_slug)"
[ -n "$slug" ] || { echo "factory: no active run in this checkout" >&2; exit 1; }
run="$root/.factory/runs/$slug"
factory_config_json >/dev/null || { echo "factory: .factory/config.yaml doesn't parse" >&2; exit 2; }
G() { git -C "$root" "$@"; }
die() { echo "factory: $*" >&2; exit 1; }
default="$(cfg '.project.default_branch' main)"
stage="$(state_get '.stage // empty')"
ev="$(state_get '.approvals.evidence.sha // empty')"
history="$root/.factory/history/$slug.json"

need_stage() { # <stages...>
  local s
  for s in "$@"; do [ "$stage" = "$s" ] && return 0; done
  die "ship.sh $cmd runs at stage $* (the run is at stage ${stage:-?})"
}
need_evidence() { [ -n "$ev" ] || die "no evidence approval recorded; stage 6 comes first"; }
run_cmd() { # <config key> <log file>: runs the configured command, output to the terminal and the log
  local c="$1" log="$2"
  (cd "$root" && CI=true bash -c "$c" </dev/null) 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

bookkeeping_ok() { # <commit>: only memory folders and this run's history, memory lines from calibration
  local dr
  dr="$(sed -n 's/^docs_root:[[:space:]]*["'"'"']\{0,1\}\([^"'"'"'#]*\).*/\1/p' "$root/.compound-engineering/config.yaml" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')"
  factory_py - "$root" "$1" "$history" "$slug" "${dr:-docs}" <<'PY'
import json, re, subprocess, sys
root, c, hist, slug, docs = sys.argv[1:6]
def git(*a):
    return subprocess.run(["git", "-C", root, *a], capture_output=True, text=True, check=True).stdout
files = [f for f in git("diff-tree", "--no-commit-id", "--name-only", "-r", c).splitlines() if f]
allowed_hist = f".factory/history/{slug}.json"
sol = docs.strip("/") + "/solutions/"
# pr.sh's record of the person's comments on the run's PR, the approval among them
fb = re.compile(r"^docs/specs/" + re.escape(slug) + r"/feedback/[A-Za-z0-9_.-]+\.md$")
bad = [f for f in files if not (re.match(r"^\.claude/agent-memory/factory-[A-Za-z0-9_-]+/(MEMORY|archive)\.md$", f)
                                or f == allowed_hist or (f.startswith(sol) and f.endswith(".md")) or fb.match(f))]
if bad:
    print("touches " + ", ".join(bad)); sys.exit(1)
try:
    # stripped, as the added lines are below: a line cut at calibrate's length limit can end in a space
    cal = {(x.get("line") or "").replace("\n", " ").strip() for x in json.load(open(hist)).get("calibration") or []}
except Exception:
    cal = set()
added, removed = [], set()
for line in git("show", "--format=", "--unified=0", c, "--", ".claude/agent-memory").splitlines():
    if line.startswith("+++") or line.startswith("---"):
        continue
    if line.startswith("+"):
        added.append(line[1:])
    elif line.startswith("-"):
        removed.add(line[1:])
for a in added:
    s = a.strip()
    if not s or s in removed or s.startswith("# factory-") or s.startswith("Reference material, not rules"):
        continue
    if s.startswith("- ") and s[2:] in cal:
        continue
    print("adds a memory line that isn't one of the run's calibration lines: " + s[:120]); sys.exit(1)
PY
}

case "$cmd" in
  verify)
    need_stage 7; need_evidence
    G rev-parse --verify -q "$ev^{commit}" >/dev/null || die "the approved commit $ev isn't in this repository"
    G merge-base --is-ancestor "$ev" HEAD || die "HEAD doesn't contain the approved commit ${ev:0:12}; back to stage 6"
    G fetch -q origin "$default" 2>/dev/null || echo "factory: couldn't fetch origin/$default; using the local copy" >&2
    main_ref="origin/$default"; G rev-parse --verify -q "$main_ref" >/dev/null || main_ref="$default"
    bad=""
    for c in $(G rev-list --first-parent --reverse "$ev..HEAD"); do
      parents=($(G rev-list --parents -n 1 "$c")); n=$((${#parents[@]} - 1)); s="$(G log -1 --format='%h %s' "$c")"
      if [ "$n" -eq 2 ]; then
        p2="${parents[2]}"
        if ! G merge-base --is-ancestor "$p2" "$main_ref"; then bad="$bad\n  $s: merges something other than $main_ref"; continue; fi
        tree="$(G merge-tree --write-tree "${parents[1]}" "$p2" 2>/dev/null | head -n 1)" || tree=""
        [ -n "$tree" ] && [ "$tree" = "$(G rev-parse "$c^{tree}")" ] || bad="$bad\n  $s: not a conflict-free, unmodified merge of $main_ref"
      elif [ "$n" -eq 1 ]; then
        why="$(bookkeeping_ok "$c")" || bad="$bad\n  $s: $why"
      else
        bad="$bad\n  $s: a merge of $n parents"
      fi
    done
    if [ -n "$bad" ]; then
      printf 'factory: commits after the approved evidence (%s) that it doesn'"'"'t cover:%b\nThe evidence no longer matches: back to stage 6.\n' "${ev:0:12}" "$bad" >&2
      exit 1
    fi
    known=(); [ -f "$run/baseline-failures" ] && known=(--known-failures "$run/baseline-failures")
    rc=0; bash "$FACTORY_SCRIPTS/run-checks.sh" --set all ${known[@]+"${known[@]}"} --tail 20 || rc=$?
    case "$rc" in 0|3) ;; *) die "checks aren't green; fix them before shipping (stage 5)" ;; esac
    state_update '.ship.verified = {head: $h, at: $at}' --arg h "$(G rev-parse HEAD)" --arg at "$(now_utc)"
    echo "factory: verified: $(G rev-list --count "$ev..HEAD") commit(s) after the approved evidence, all covered; checks green"
    ;;

  merge)
    need_stage 7; need_evidence
    v="$(state_get '.ship.verified.head // empty')"; head="$(G rev-parse HEAD)"
    [ "$v" = "$head" ] || die "HEAD isn't the verified commit; run ship.sh verify first"
    br="$(G symbolic-ref --short -q HEAD)"
    [ -n "$br" ] && [ "$(G ls-remote origin "refs/heads/$br" 2>/dev/null | cut -f1)" = "$head" ] || die "push $br first: the PR must contain exactly the verified commit"
    if [ -n "$(state_get '.pr // empty')" ]; then   # out of draft, and every check on GitHub passed
      prc=0; bash "$FACTORY_SCRIPTS/pr.sh" ready || prc=$?
      case "$prc" in 0) ;; 4) die "the PR's checks are still running; run ship.sh merge again" ;; *) die "the PR isn't ready to merge: its checks failed (stage 5)" ;; esac
    fi
    m="$(cfg '.ship.merge' 'gh pr merge --squash')"
    run_cmd "$m" "$run/merge.log" || die "ship.merge failed: $m"
    G fetch -q origin "$default" || die "couldn't fetch origin/$default after the merge"
    merged="$(G rev-parse "origin/$default")"
    state_update '.ship.merged = {sha: $s, at: $at}' --arg s "$merged" --arg at "$(now_utc)"
    if [ -n "$(state_get '.pr // empty')" ]; then   # best effort: the issue is done once its last PR merged
      (cd "$root" && bash "$FACTORY_SCRIPTS/issue-flow.sh" merged "$(state_get .pr)") || echo "factory: issue-flow.sh merged failed; run it by hand" >&2
    fi
    echo "factory: merged; origin/$default is at ${merged:0:12}"
    ;;

  deploy)
    need_stage 7; need_evidence
    merged="$(state_get '.ship.merged.sha // empty')"
    [ -n "$merged" ] || die "not merged yet; run ship.sh merge first"
    d="$(cfg '.ship.deploy')"
    if [ -z "$d" ] || [ "$d" = "..." ]; then
      state_update '.ship.deployed = {sha: $s, at: $at, skipped: true}' --arg s "$merged" --arg at "$(now_utc)"
      echo "factory: ship.deploy is empty; nothing deployed (set it to deploy from stage 7)"; exit 0
    fi
    FACTORY_DEPLOY_SHA="$merged" run_cmd "$d" "$run/deploy.log" || die "ship.deploy failed (log: $run/deploy.log)"
    state_update '.ship.deployed = {sha: $s, at: $at}' --arg s "$merged" --arg at "$(now_utc)"
    echo "factory: deployed ${merged:0:12}"
    ;;

  smoke)
    need_stage 7
    sm="$(cfg '.ship.smoke')"
    if [ -z "$sm" ] || [ "$sm" = "..." ]; then echo "factory: ship.smoke is empty; no smoke test run"; exit 0; fi
    FACTORY_DEPLOY_SHA="$(state_get '.ship.merged.sha // empty')" run_cmd "$sm" "$run/smoke.log"
    rc=$?
    state_update '.ship.smoke = {passed: ($rc == "0"), at: $at}' --arg rc "$rc" --arg at "$(now_utc)"
    [ "$rc" = 0 ] || die "smoke test failed (output: $run/smoke.log); file the issue first: monitor.sh issue --source smoke --output $run/smoke.log"
    echo "factory: smoke test passed"
    ;;

  rollback)
    need_stage 7 8
    rb="$(cfg '.ship.rollback')"
    [ -n "$rb" ] && [ "$rb" != "..." ] || die "ship.rollback is empty; roll back by hand"
    sha="$(state_get '.ship.deployed.sha // .ship.merged.sha // empty')"
    FACTORY_DEPLOY_SHA="$sha" run_cmd "$rb" "$run/rollback.log"
    rc=$?
    state_update '.ship.rollbacks = ((.ship.rollbacks // []) + [{sha: $s, at: $at, ok: ($rc == "0")}])' --arg s "$sha" --arg at "$(now_utc)" --arg rc "$rc"
    [ "$rc" = 0 ] || die "ship.rollback failed (log: $run/rollback.log)"
    echo "factory: rolled back the deploy of ${sha:0:12}"
    ;;

  mark)
    need_stage 7
    sha="$(state_get '.ship.deployed.sha // .ship.merged.sha // empty')"
    [ -n "$sha" ] || die "nothing deployed or merged to mark"
    at="$(now_utc)"
    state_update '.deploy = {sha: $s, at: $at}' --arg s "$sha" --arg at "$at"
    bash "$FACTORY_SCRIPTS/monitor.sh" baseline "$slug" || echo "factory: no monitoring baseline (monitor.checks failed to run); anomalies will be any failing check" >&2
    bash "$FACTORY_SCRIPTS/state.sh" history '.deploy = {sha: $s, at: $at}' --arg s "$sha" --arg at "$at" >/dev/null
    echo "factory: deploy marker ${sha:0:12} at $at"
    ;;

  *) echo "factory: ship.sh verify|merge|deploy|smoke|rollback|mark" >&2; exit 2 ;;
esac
