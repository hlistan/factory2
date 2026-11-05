#!/usr/bin/env bash
# factory's pull request: the person follows and steers a run on its draft PR, open from the first commit.
#   pr.sh open                     stdin: the request (or the issue) verbatim. Writes
#                                  docs/specs/<slug>/request.md, commits it, pushes factory/<slug> and opens
#                                  the draft PR with ship.pr_open, or reuses the branch's open PR.
#                                  Exit 3 when review.via is terminal; exit 1 when gh, its login or an
#                                  origin remote is missing (the run then uses terminal gates).
#   pr.sh enabled                  exit 0 when this run is tracked on a PR
#   pr.sh publish <kind>           stdin: plan → the planner's JSON report; prd-review → the prd-reviewer's
#                                  JSON report; note → markdown. Saves a report under
#                                  docs/specs/<slug>/reviews/, commits it, pushes, posts a comment saying
#                                  what was added or changed since the previous one, refreshes the PR body.
#   pr.sh request-approval <gate> [--details <file>|-]
#                                  posts the approval request for the pushed HEAD (pushed first), with
#                                  --details' markdown (a file, or - for stdin) such as the review-pack
#                                  link. Gates: prd (the plan: the request for it shows the criteria and
#                                  plan.md inline, so the person reads what will be built and how) and
#                                  evidence (what was built, before merge). Deploy and rollback aren't gates.
#   pr.sh feedback <gate>          reads the PR's new comments and reviews. Corrections are saved verbatim to
#                                  feedback/<gate>-<round>.md (committed and pushed); a valid /approve
#                                  records the approval. Prints {status: none|changes|approved, ...}.
#   pr.sh wait <gate> [--timeout <s>]  repeats feedback every review.poll_seconds until it isn't none
#                                  (exit 4 on timeout)
#   pr.sh body                     refreshes the PR description (artifacts, approvals, review ledger) and
#                                  the labels
#   pr.sh labels                   sets the factory2 labels from the run state, on the run's GitHub issue
#                                  (state .issue, also on a terminal run): factory2,
#                                  factory2:stage-<n>-<name>, factory2:awaiting-approval and
#                                  factory2:awaiting-<gate> while a request waits, factory2:approved-<gate>
#                                  per approval held; or, with issues.stage_labels set, exactly the
#                                  project's label mapped to the stage ("merged" after ship.sh merge); none
#                                  with issues.labels: false. A run with an issue labels its PR with
#                                  nothing (the PR follows the issue); a run without one labels the PR.
#                                  state.sh start and stage, and ship.sh merge, call it, so the issue list
#                                  shows where each run is.
#   pr.sh ready [--timeout <s>]    the change is ready to merge: takes the PR out of draft (ship.pr_ready) and
#                                  waits for its checks on GitHub, every review.poll_seconds, up to --timeout
#                                  (default ship.checks_timeout, 3600 s). Exit 0 when every check passed or
#                                  was skipped, or the PR has none; 1 when one failed or was cancelled (it
#                                  names them, and the PR goes back to draft); 4 on timeout.
#   pr.sh draft                    the change is in progress: puts the PR back in draft when it isn't.
#                                  state.sh stage calls it when the run goes back before stage 7.
#   pr.sh notify                   stdin: markdown that informs the person and needs no reply (a bugfix run
#                                  started, the deploy); posted on the run's issues, else the PR.
#   pr.sh ask                      stdin: a question for the person (an escalation: a round or budget limit,
#                                  a conflict), with its options and an example reply. Posted where the
#                                  person acts (the run's issues, else the PR); labels factory2:awaiting-input.
#   pr.sh answer [--timeout <s>]   waits for the reply; saves it verbatim to feedback/question-<n>.md
#                                  (committed and pushed). Prints {status: answered, file, authors}; exit 4 on timeout.
# Everything that needs a person goes to the issues the run works on (the issue is what is built; the PR
# is how), or to the PR when the run has no issue: approval requests, questions, and the replies to
# them. Each says exactly what to reply, with examples. The PR keeps the planning trail (pr.sh publish).
# Approval: a comment whose first line is issues.commands.approve (default /approve). With issues.flow
# set, the plan (prd gate) is approved by the project's own issue flow instead: factory writes
# docs/specs/<slug>/issue-plan.md into the issue's body, posts issues.flow.submit, and the gate passes
# when the issue carries one of issues.flow.approved; until the issue carries one of
# issues.flow.ready_for_plan, factory asks the owner to accept the idea (issues.flow.accept_idea) first.
# A comment whose first line is another slash command (the issue flow's) is never a change request,
# except issues.flow.changes.
# Only people allowed by review.reviewers (default: the repository's owners, members and collaborators)
# are read; other comments are reported as ignored. factory's own comments carry a marker,
# <!-- factory2:<slug>:<kind> -->, and are never read as the person's.
# Exit status: 0 ok, 1 a precondition isn't met, 2 usage error, 3 PR review is off, 4 wait timed out.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need git jq python3

root="$FACTORY_ROOT_DIR"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;; esac

slug="$(factory_active_slug)"
[ -n "$slug" ] || { echo "factory: no active run in this checkout" >&2; exit 1; }
run="$root/.factory/runs/$slug"
spec="docs/specs/$slug"
branch="factory/$slug"
S="$FACTORY_SCRIPTS"

die() { echo "factory: $*" >&2; exit 1; }
G() { git -C "$root" "$@"; }
gh_() { (cd "$root" && gh "$@"); }
pr_num() { state_get '.pr // empty'; }
repo_url() { state_get '.pr_url // empty' | sed -E 's#/pull/[0-9]+$##'; }
round() { state_get '.rounds.prd // 0'; }
GATES="prd evidence"
gate_ok() { case "$1" in prd|evidence) return 0 ;; esac; echo "factory: gates are $GATES (deploy and rollback need no approval)" >&2; exit 2; }
gate_round() { state_get ".rounds.$1 // 0"; }
gate_what() {
  case "$1" in
    prd) echo "the plan: what will be built and how" ;;
    evidence) echo "what was built (evidence)" ;;
  esac
}
gate_next() {
  case "$1" in
    prd) echo "Implementation starts: tests first, then code, following this plan." ;;
    evidence) echo "The PR is marked ready; merge, deploy and the smoke test follow without another approval." ;;
  esac
}
gate_correct() {
  case "$1" in
    prd) echo "Each comment goes to the planner word for word, and factory asks again after the next round." ;;
    evidence) echo "Each comment is routed as a spec gap (back to the PRD), a defect (a failing test, then a fix) or cosmetic (a direct fix), and factory asks again." ;;
  esac
}
need_pr() {
  [ "$(state_get '.review_via // empty')" = "pr" ] && [ -n "$(pr_num)" ] || die "this run isn't tracked on a PR (pr.sh open)"
}
push() { G push -q -u origin "$branch" 2>&1 >/dev/null | grep -v '^remote:' >&2; [ "${PIPESTATUS[0]}" -eq 0 ] || die "git push origin $branch failed"; }
remote_head() { G ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1; }
marker() { printf '<!-- factory2:%s:%s -->' "$slug" "$1"; }
link() { printf '[%s](%s/blob/%s/%s)' "$(basename "$2")" "$(repo_url)" "$1" "$2"; } # <ref> <path>
gate_examples() { # <gate>: example change requests, naming the run's first criterion
  local id; id="$(jq -r '.criteria[0].id // empty' "$root/$spec/contract.json" 2>/dev/null)"; [ -n "$id" ] || id=AC-1
  case "$1" in
    prd) printf '%s: an empty list says "Nothing to review" instead of showing an empty table.\nOut of scope: exporting the list as CSV.\n' "$id" ;;
    evidence) printf '%s does not hold: after closing, the item is still in the list.\nThe button overlaps the title at phone width (the 390x844 screenshot).\n' "$id" ;;
  esac
}
approve_cmd() { cfg '.issues.commands.approve' /approve; }
flow_cfg() { cfg ".issues.flow.$1" "${2:-}"; }
flow_labels() { factory_config_json | jq -r --arg k "$1" '.issues.flow[$k] // [] | if type == "array" then .[] else . end | strings'; }
flow_on() { # the project's own issue flow approves the plan (issues.flow.approved), on the run's issue
  [ -n "$(flow_labels approved)" ] && [ -n "$(issue_ref)" ]
}
fenced() { # stdin: lines, as an indented code block inside a list item
  printf '  ```\n'; sed 's/^/  /'; printf '  ```\n'
}
commit_paths() { # <message> <path>...: commits just these paths when they changed
  local msg="$1"; shift
  G add -- "$@" || return 1
  G diff --cached --quiet -- "$@" && return 0
  G commit -q -m "$msg" -- "$@" >/dev/null || die "commit failed: $msg"
}

post() { # <file>: posts it as a PR comment, prints the comment URL
  gh_ pr comment "$(pr_num)" --body-file "$1" | tail -n 1
}

changes_md() { # <from sha> <to sha>: what changed in the spec directory, as markdown
  local from="$1" to="$2" lines
  [ -n "$from" ] && [ "$from" != "$to" ] || return 0
  lines="$(G diff --name-status "$from" "$to" -- "$spec" 2>/dev/null)"
  [ -n "$lines" ] || return 0
  printf '\n**Changed since the previous update** ([compare](%s/compare/%s...%s)):\n\n' "$(repo_url)" "$(printf %s "$from" | cut -c1-12)" "$(printf %s "$to" | cut -c1-12)"
  printf '%s\n' "$lines" | while IFS="$(printf '\t')" read -r st path rest; do
    [ -n "$rest" ] && path="$rest"
    case "$st" in A*) w=added ;; D*) w=deleted ;; R*) w=renamed ;; *) w=changed ;; esac
    stat="$(G diff --numstat "$from" "$to" -- "$path" | awk '{ printf "+%s −%s", $1, $2 }')"
    if [ "$w" = deleted ]; then printf -- '- %s `%s`\n' "$w" "$path"
    else printf -- '- %s %s (%s)\n' "$w" "$(link "$to" "$path")" "$stat"; fi
  done
}

render_planner() { # stdin: the planner's report
  jq -r '
    "- Criteria: \(.criteria // "?")",
    (if (.addressed // []) | length > 0 then "\n**Addressed**\n", (.addressed[] | "- **\(.finding)**: \(.change)") else empty end),
    (if (.declined // []) | length > 0 then "\n**Declined** (kept as is; reply if you disagree)\n", (.declined[] | "- **\(.finding)**: \(.why)") else empty end),
    (if (.open_questions // []) | length > 0 then "\n**Open questions** (answer in a comment)\n", (.open_questions[] | "- \(.)") else empty end)'
}

render_review() { # stdin: the prd-reviewer's report
  jq -r '
    def f: "- **\(.id)** · \(.rubric // "") · `\(.where // "")`: \(.problem)\n  *Fix:* \(.fix // "")";
    "Verdict: **\(.verdict // "?")**", "",
    ((.summary // "") | split("\n") | map("> " + .) | join("\n")),
    ([.findings // [] | .[] | select(.severity == "blocking")] as $b | if $b | length > 0 then "\n**Blocking (\($b | length))**\n", ($b[] | f) else "\nNo blocking findings." end),
    ([.findings // [] | .[] | select(.severity != "blocking")] as $a | if $a | length > 0 then "\n**Advisory (\($a | length))**\n", ($a[] | f) else empty end)'
}

latest_review() { # the newest prd-review-<n>.json, or nothing
  ls "$root/$spec/reviews"/prd-review-*.json 2>/dev/null | sed -E 's/.*-([0-9]+)\.json$/\1 &/' | sort -n | tail -n 1 | cut -d' ' -f2-
}

demote() { # markdown on stdin with every heading two levels deeper (outside code fences), first H1 dropped
  awk 'BEGIN { fence = 0; h1 = 0 }
    /^[ ]*(```|~~~)/ { fence = !fence; print; next }
    !fence && /^# / && !h1 { h1 = 1; next }
    !fence && /^#+ / { print "##" $0; next }
    { print }'
}

clip() { # <max chars> <link>: stdin, cut at a line boundary when longer
  python3 -c '
import sys
n, link = int(sys.argv[1]), sys.argv[2]
t = sys.stdin.read()
if len(t) > n:
    t = t[:n].rsplit("\n", 1)[0] + "\n\n*… cut here for length; the rest is in " + link + ".*\n"
sys.stdout.write(t)' "$@"
}

plan_md() { # <sha>: what will be built (the criteria) and how (plan.md), for the PR
  local sha="$1" pf
  printf '#### What will be built\n\n'
  if [ -f "$root/$spec/contract.json" ]; then
    jq -r '.criteria // [] | .[] | "- **\(.id)** (\(.level // "?")): \(.text)"' "$root/$spec/contract.json"
  fi
  printf '\nThe problem, scope, flows and non-goals are in %s.\n\n' "$(link "$sha" "$spec/prd.md")"
  printf '#### How the planner proposes to build it\n\n'
  if [ -f "$root/$spec/plan.md" ]; then
    demote < "$root/$spec/plan.md" | clip 40000 "$(link "$sha" "$spec/plan.md")"
  else
    printf '*No plan.md yet.*\n'
  fi
  pf="$root/$spec/reviews/planner-$(round).json"
  if [ -f "$pf" ] && jq -e '(.open_questions // []) | length > 0' "$pf" >/dev/null 2>&1; then
    printf '\n#### Open questions from the planner\n\n'
    jq -r '.open_questions[] | "- \(.)"' "$pf"
  fi
}

STAGES="1:plan 2:prd-review 3:prd-fix 4:implement 5:review 6:evidence 7:ship 8:monitor"
stage_label() { # <n>: factory2:stage-<n>-<name>
  local e; for e in $STAGES; do [ "${e%%:*}" = "$1" ] && { echo "factory2:stage-$1-${e#*:}"; return; }; done
}
stage_what() {
  case "$1" in
    1) echo "planning: PRD, acceptance criteria and plan" ;; 2) echo "the PRD is under review" ;;
    3) echo "the PRD is being revised" ;; 4) echo "tests first, then code and docs" ;;
    5) echo "code review and fixes" ;; 6) echo "evidence for the maintainer's approval" ;;
    7) echo "merging and deploying" ;; 8) echo "shipped; production is monitored" ;;
  esac
}
issue_norm() { # <ref>: a GitHub issue as gh takes it (a number or an issues URL); empty for anything else
  case "$1" in
    ''|*[!0-9#]*) case "$1" in https://*/issues/[0-9]*) echo "$1" ;; esac ;;
    *) echo "${1#\#}" ;;
  esac
}
issue_refs() { # every GitHub issue the run works on: .issue first, then .linked_issues (state.sh link-issue)
  { state_get '.issue // empty'; state_get '.linked_issues // [] | .[]'; } | while IFS= read -r i; do issue_norm "$i"; done | awk 'NF && !seen[$0]++'
}
issue_ref() { issue_refs | head -n 1; }   # the run's own issue; empty for a local incident file
issue_path() { # <ref>: the issue as an API path, repos/<owner>/<repo>/issues/<n>
  case "$1" in
    https://*) printf '%s' "$1" | sed -E 's#^https://[^/]+/([^/]+)/([^/]+)/issues/([0-9]+).*#repos/\1/\2/issues/\3#' ;;
    *) printf 'repos/{owner}/{repo}/issues/%s' "$1" ;;
  esac
}
issue_labels() { gh_ issue view "$1" --json labels --jq '.labels[].name' 2>/dev/null; }
issue_has() { # <ref> <issues.flow key>: the issue carries one of that key's labels
  local have l; have="$(issue_labels "$1")"
  for l in $(flow_labels "$2"); do printf '%s\n' "$have" | grep -qxF -- "$l" && return 0; done
  return 1
}
post_human() { # <file>: a request for a person goes to every issue the run works on (the PR is how, the
  # issue is what), or to the PR when the run has no issue. Prints the first comment's URL.
  local refs r u first=""
  refs="$(issue_refs)"
  if [ -z "$refs" ]; then post "$1"; return; fi
  for r in $refs; do
    u="$(gh_ issue comment "$r" --body-file "$1" | tail -n 1)" || { echo "factory: commenting on issue $r failed" >&2; continue; }
    [ -n "$first" ] || first="$u"
  done
  [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

label_spec() { # name<TAB>color<TAB>description for each label factory uses
  local e
  printf 'factory2\t5319e7\ta factory2 run\n'
  printf 'factory2:awaiting-approval\tfbca04\tfactory2 waits for your approval\n'
  printf 'factory2:awaiting-input\tfbca04\tfactory2 waits for your answer to a question\n'
  for g in $GATES; do
    printf 'factory2:awaiting-%s\tfbca04\tfactory2 waits for your /approve: %s\n' "$g" "$(gate_what "$g")"
    printf 'factory2:approved-%s\t0e8a16\tapproved: %s\n' "$g" "$(gate_what "$g")"
  done
  for e in $STAGES; do printf '%s\t1d76db\tfactory2 stage %s: %s\n' "$(stage_label "${e%%:*}")" "${e%%:*}" "$(stage_what "${e%%:*}")"; done
}

sync_labels() { # <pr|issue> <ref> <wanted> [<managed> [<prefix>]]: among the factory2 labels, the managed
  # ones (newline-separated names) and those starting with the prefix, it keeps exactly the wanted ones;
  # every other label stays
  local kind="$1" ref="$2" want="$3" managed="${4:-}" prefix="${5:-}" have add="" rm="" l
  have="$(gh_ "$kind" view "$ref" --json labels 2>/dev/null | jq -r --arg m "$managed" --arg p "$prefix" '($m | split("\n")) as $ms
    | .labels[]?.name | select(startswith("factory2") or ($p != "" and startswith($p)) or (. as $n | $ms | index($n)))')"
  for l in $want; do printf '%s\n' "$have" | grep -qx -- "$l" || add="$add,$l"; done
  for l in $have; do printf '%s\n' "$want" | grep -qx -- "$l" || rm="$rm,$l"; done
  [ -z "$add$rm" ] && return 0
  gh_ "$kind" edit "$ref" ${add:+--add-label "${add#,}"} ${rm:+--remove-label "${rm#,}"} >/dev/null || echo "factory: updating the $kind's labels failed" >&2
}

# The run's labels live on the issue it was started from: factory2, the stage, and the approvals waiting
# and held, so maintainers follow each feature in the issue list. Its PR is only the change for that
# issue and carries none (any left from before are removed). A run without an issue labels its PR instead.
labels() {
  local pr="" issue stage spec_hash key mapped own run_labels
  [ "$(state_get '.review_via // empty')" = pr ] && pr="$(pr_num)"
  issue="$(issue_ref)"
  [ -n "$pr$issue" ] || die "this run has neither a PR nor a GitHub issue to label"
  if [ -n "$issue" ] && [ -n "$pr" ]; then
    sync_labels pr "$pr" ""   # the PR follows its issue
    pr=""
    [ "$(cfg '.issues.labels' true)" = false ] && return 0
  fi
  if [ "$(cfg '.issues.labels' true)" = false ]; then   # the project's own automation labels its issues
    die "this run's issue is labelled by the project's own automation (issues.labels: false)"
  fi
  spec_hash="$(label_spec | cksum | cut -d' ' -f1)"
  if [ "$(state_get '.labels_ready // empty')" != "$spec_hash" ]; then
    label_spec | while IFS="$(printf '\t')" read -r name color desc; do
      gh_ label create "$name" --color "$color" --description "$desc" --force >/dev/null 2>&1 || true
    done
    state_update '.labels_ready = $h' --arg h "$spec_hash"
  fi
  stage="$(stage_label "$(state_get '.stage // 1')")"
  # the project's own label for this stage (issues.stage_labels), "merged" once the merge is recorded
  key="$(state_get 'if .ship.merged then "merged" else (.stage // 1 | tostring) end')"
  mapped="$(factory_config_json | jq -r '.issues.stage_labels // {} | to_entries[] | .value | strings')"
  own="$(factory_config_json | jq -r --arg k "$key" '.issues.stage_labels // {} | .[$k] // empty')"
  run_labels="$(state_get '.' | jq -r --arg st "$stage" '"factory2", $st,
    (if .approval_request then "factory2:awaiting-approval", "factory2:awaiting-\(.approval_request.gate)" else empty end),
    (if .question then "factory2:awaiting-input" else empty end),
    (.approvals // {} | keys[] | "factory2:approved-\(.)")')"
  [ -n "$pr" ] && sync_labels pr "$pr" "$run_labels"
  # with issues.stage_labels the issue carries only the project's label; a stage the map leaves out keeps
  # the label of the last mapped one
  local i
  for i in $(issue_refs); do
    if [ -n "$mapped" ]; then
      [ -z "$own" ] || sync_labels issue "$i" "$own" "$mapped" "$(cfg '.issues.stage_label_prefix')"
    else sync_labels issue "$i" "$run_labels"; fi
  done
  return 0
}

flow_request() { # <sha>: the plan goes to the project's own issue flow: written into the issue and
  # submitted when the issue takes a plan (issues.flow.ready_for_plan), else the owner is asked to accept
  # the idea first; wait/feedback submits it once they have
  local i c u h7; i="$(issue_ref)"; h7="$(printf %s "$1" | cut -c1-12)"
  if issue_has "$i" ready_for_plan; then
    u="$(flow_submit "$1")"
    state_update '.approval_request = {gate: "prd", sha: $s, url: $u, at: $at, flow: "submitted"}' --arg s "$1" --arg u "$u" --arg at "$(now_utc)"
    return
  fi
  c="$run/.issue-comment.md"
  {
    marker "approval-request:prd:$1"; echo
    printf '### ⏳ factory2 needs you to accept this idea first\n\n'
    printf 'The plan for this issue is ready (run `%s`, commit `%s`%s). This project'"'"'s issue flow takes a plan once the idea is accepted: the issue is labelled %s.\n\n' \
      "$slug" "$h7" "$(state_get '.pr_url // empty' | sed 's/^./, pull request &/')" "$(flow_labels ready_for_plan | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/ or /g')"
    printf '#### What to do\n\n'
    printf -- '- **Accept the idea**: a comment whose first line is\n\n'
    printf '%s\n' "$(flow_cfg accept_idea /approve)" | fenced
    printf '\n  factory then writes the plan into this issue and submits it for your review.\n\n'
    printf -- '- **Decline it**: as this project'"'"'s issue flow says; then stop the run in its Claude Code session.\n'
  } > "$c"
  u="$(gh_ issue comment "$i" --body-file "$c" | tail -n 1)" || die "commenting on issue $i failed"
  state_update '.approval_request = {gate: "prd", sha: $s, url: $u, at: $at, flow: "idea"}' --arg s "$1" --arg u "$u" --arg at "$(now_utc)"
}
flow_submit() { # <sha>: writes docs/specs/<slug>/issue-plan.md into the issue's body and submits it; prints the comment URL
  local i f c sub h7; i="$(issue_ref)"; f="$root/$spec/issue-plan.md"; h7="$(printf %s "$1" | cut -c1-12)"
  [ -s "$f" ] || die "$spec/issue-plan.md is missing: with issues.flow the planner writes the issue's body in the project's format"
  gh_ issue edit "$i" --body-file "$f" >/dev/null || die "writing the plan into issue $i failed"
  sub="$(flow_cfg submit)"; c="$run/.issue-comment.md"
  {
    [ -n "$sub" ] && printf '%s\n\n' "$sub"
    marker "approval-request:prd:$1"; echo
    printf '### ⏳ factory2 needs your review of the plan\n\n'
    printf 'The plan is now this issue'"'"'s body (run `%s`, commit `%s`%s)%s. It is what will be built; how is on the pull request.\n\n' \
      "$slug" "$h7" "$(state_get '.pr_url // empty' | sed 's/^./, pull request &/')" "${sub:+, submitted with \`$sub\`}"
    printf '#### What to do\n\n'
    printf -- '- **Approve the plan**: a comment whose first line is\n\n'
    printf '%s\n' "$(flow_cfg approve /approve)" | fenced
    printf '\n- **Ask for changes**: a comment like\n\n'
    { printf '%s ' "$(flow_cfg changes | awk '{print $1}')"; gate_examples prd; } | sed 's/^ //' | fenced
    printf '\n  factory revises the plan and submits it again.\n\n'
    printf 'factory continues once the issue is labelled %s.\n' "$(flow_labels approved | head -n 1 | sed 's/.*/`&`/')"
  } > "$c"
  gh_ issue comment "$i" --body-file "$c" | tail -n 1 || die "commenting on issue $i failed"
}
all_comments() { # every comment a person could have left: on the PR (comments, inline, reviews) and on each
  # issue the run works on, as one JSON array
  local pr ic rc rv iss="[]" r x
  pr="$(pr_num)"
  fetch() { gh_ api --paginate "$1" 2>/dev/null | jq -s 'map(if type == "array" then . else [] end) | add // []'; }
  ic="$(fetch "repos/{owner}/{repo}/issues/$pr/comments")" && rc="$(fetch "repos/{owner}/{repo}/pulls/$pr/comments")" \
    && rv="$(fetch "repos/{owner}/{repo}/pulls/$pr/reviews")" || return 1
  for r in $(issue_refs); do
    x="$(fetch "$(issue_path "$r")/comments")" || return 1
    iss="$(jq -n --argjson a "$iss" --argjson b "$x" '$a + $b')"
  done
  jq -n --argjson ic "$ic" --argjson rc "$rc" --argjson rv "$rv" --argjson iss "$iss" '
    def mk($k): {key: ($k + "-" + (.id | tostring)), kind: $k, id, author: (.user.login // ""),
      assoc: (.author_association // "NONE"), body: (.body // ""), url: (.html_url // ""),
      at: (.submitted_at // .created_at // ""), path: (.path // null), line: (.line // .original_line // null), state: (.state // null)};
    [$ic[] | mk("comment")] + [$iss[] | mk("issue")] + [$rc[] | mk("inline")]
      + [$rv[] | select(.state != "PENDING") | mk("review") | select(.body != "" or .state == "APPROVED")]'
}
artifact_what() {
  case "$1" in
    request.md) echo "the request as given" ;;
    prd.md) echo "product requirements and acceptance criteria" ;;
    plan.md) echo "how it will be built: approach, decisions, steps, risks, exceptions" ;;
    *) echo "the criteria the tests are tagged with" ;;
  esac
}

body() {
  local f n pr url head kind issue fixes ff any r rf pf kw
  need_pr
  url="$(repo_url)"; n="$(round)"; f="$run/.pr-body.md"
  kind="$(state_get '.kind // "feature"')"; fixes=""
  kw="$(cfg '.issues.link_keyword' Fixes)"
  for i in $(issue_refs); do
    case "$i" in https://*) fixes="$fixes$kw $i"$'\n' ;; *) fixes="$fixes$kw #$i"$'\n' ;; esac
  done
  where="the pull request"; [ -n "$(issue_ref)" ] && where="the issue ($(issue_refs | sed 's/^[0-9]/#&/' | paste -sd, - | sed 's/,/, /g'))"
  {
    marker body; echo
    printf '## factory2 run `%s` (%s)\n\n' "$slug" "$kind"
    [ -n "$fixes" ] && printf '%s\n' "$fixes"
    printf 'This PR is how the change is built: a draft while it is in progress, ready for review once it can merge. factory comments here on every planning step. **Anything that needs you is asked on %s**, with the exact reply to give.\n\n' "$where"
    printf '| Artifact | |\n|---|---|\n'
    for a in request.md prd.md plan.md contract.json; do
      [ -f "$root/$spec/$a" ] && printf '| %s | %s |\n' "$(link "$branch" "$spec/$a")" "$(artifact_what "$a")"
    done
    printf '\n**Stage** %s (%s) · **PRD round** %s\n\n' "$(state_get .stage)" "$(state_get .phase)" "$n"
    state_get '.approval_request // {}' | jq -r 'select(.gate) | "⏳ **Waiting for your approval: \(.gate)** at `\(.sha[0:12])`: see [the request](\(.url)) for what to reply.\n"'
    state_get '.question // {}' | jq -r 'select(.n) | "❓ **Waiting for your answer** to [a question](\(.url)).\n"' 
    state_get '.approvals // {}' | jq -r 'to_entries[] | "- ✅ **\(.key)** approved at `\(.value.sha[0:12])`" + (if .value.by then " by @\(.value.by) ([comment](\(.value.url)))" else "" end)'
    printf '\n### Review ledger\n\n'
    local any=0 r rf pf
    for rf in $(ls "$root/$spec/reviews"/prd-review-*.json 2>/dev/null | sed -E 's/.*-([0-9]+)\.json$/\1 &/' | sort -n | cut -d' ' -f2-); do
      r="$(basename "$rf" .json | sed 's/^prd-review-//')"; pf="$root/$spec/reviews/planner-$r.json"
      [ "$any" = 1 ] || printf '| Finding | Severity | Problem | Resolution |\n|---|---|---|---|\n'
      any=1
      jq -r --arg r "$r" --slurpfile p <( [ -f "$pf" ] && cat "$pf" || echo '{}') '
        ($p[0]) as $pl |
        def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ") | if length > 140 then .[0:137] + "…" else . end;
        def res($id): ([$pl.addressed // [] | .[] | select((.finding | tostring) | startswith($id))][0]) as $a
          | ([$pl.declined // [] | .[] | select((.finding | tostring) | startswith($id))][0]) as $d
          | if $a then "fixed: " + ($a.change | esc) elif $d then "declined: " + ($d.why | esc) else "open" end;
        .findings // [] | .[] | "| R\($r).\(.id) | \(.severity) | \(.problem | esc) | \(res(.id)) |"' "$rf"
    done
    [ "$any" = 1 ] || printf 'No review yet.\n'
    if ls "$root/$spec/feedback"/*.md >/dev/null 2>&1; then
      printf '\n### Your corrections\n\n'
      for ff in "$root/$spec/feedback"/*.md; do printf -- '- %s\n' "$(link "$branch" "$spec/feedback/$(basename "$ff")")"; done
    fi
    printf '\n### How to steer\n\n'
    printf -- '- **Correct**: comment on %s, or here on this PR (inline on the files too). Every comment goes to the run word for word.\n' "$where"
    printf -- '- **Approve**: factory asks on %s twice: for the plan (what will be built) before any code, and for the evidence (what was built) before merge. Each request says exactly what to reply. Deploy and rollback follow without another approval.\n' "$where"
    # the run's labels are on its issues when it has one; with issues.labels: false there are none
    if [ -z "$(issue_ref)" ]; then
      printf -- '- **Find waiting requests**: the `factory2:awaiting-approval` and `factory2:awaiting-input` labels on this PR; approvals held carry `factory2:approved-<gate>`.\n'
    elif [ "$(cfg '.issues.labels' true)" != false ] && [ "$(factory_config_json | jq '.issues.stage_labels // {} | length')" = 0 ]; then
      printf -- '- **Find waiting requests**: the labels are on the issue: `factory2:awaiting-approval` (with `factory2:awaiting-prd` or `factory2:awaiting-evidence`) and `factory2:awaiting-input` for a question. This PR carries none: it is a draft while in progress.\n'
    fi
  } > "$f"
  gh_ pr edit "$(pr_num)" --body-file "$f" >/dev/null || die "gh pr edit failed"
  labels
}

case "$cmd" in
  enabled) [ "$(state_get '.review_via // empty')" = "pr" ] && [ -n "$(pr_num)" ] ;;

  open)
    via="$(cfg '.review.via' pr)"
    if [ "$via" != "pr" ]; then state_update '.review_via = "terminal"'; echo "factory: review.via is $via; gates stay in the terminal" >&2; exit 3; fi
    reason=""
    factory_has gh || reason="gh is not installed"
    [ -z "$reason" ] && { gh_ auth status >/dev/null 2>&1 || reason="gh is not logged in (gh auth login)"; }
    [ -z "$reason" ] && { G remote get-url origin >/dev/null 2>&1 || reason="the repository has no origin remote"; }
    if [ -n "$reason" ]; then
      state_update '.review_via = "terminal"'
      die "no PR for this run: $reason. Gates stay in the terminal; fix it and run pr.sh open again to move them to a PR."
    fi
    [ "$(G symbolic-ref --short -q HEAD)" = "$branch" ] || die "not on $branch (state.sh branch first)"
    req="$(cat)"
    if [ ! -f "$root/$spec/request.md" ]; then
      [ -n "$req" ] || die "open needs the request on stdin"
      mkdir -p "$root/$spec"
      printf '# Request\n\n%s\n' "$req" > "$root/$spec/request.md"
      commit_paths "factory($slug): 0 request" "$spec/request.md"
    fi
    push
    info="$(gh_ pr view "$branch" --json number,url,state 2>/dev/null)"
    if [ "$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null)" != "OPEN" ]; then
      open_cmd="$(cfg '.ship.pr_open' 'gh pr create --draft --fill')"
      (cd "$root" && bash -c "$open_cmd") >/dev/null || die "ship.pr_open failed: $open_cmd"
      info="$(gh_ pr view "$branch" --json number,url,state)" || die "the PR for $branch can't be read after ship.pr_open"
    fi
    n="$(printf '%s' "$info" | jq -r .number)"; u="$(printf '%s' "$info" | jq -r .url)"
    title="$(printf '%s\n' "$req" | grep -m1 . | cut -c1-80)"
    state_update '.pr = ($n | tonumber) | .pr_url = $u | .review_via = "pr" | .pr_published = (.pr_published // $h) | .pr_seen = (.pr_seen // [])' \
      --arg n "$n" --arg u "$u" --arg h "$(G rev-parse HEAD)"
    [ -n "$title" ] && gh_ pr edit "$n" --title "$slug: $title" >/dev/null 2>&1
    body
    echo "factory: run '$slug' is tracked on $u"
    ;;

  publish)
    need_pr
    kind="${1:-}"; n="$(round)"; in="$(cat)"; file=""
    case "$kind" in
      plan)
        printf '%s' "$in" | jq -e 'type == "object"' >/dev/null 2>&1 || die "publish plan: stdin must be the planner's JSON report"
        file="$spec/reviews/planner-$n.json"
        if [ "$n" = 0 ]; then title="Plan written"; else title="Plan revised (round $n): answers to the review and your corrections"; fi
        summary="$(printf '%s' "$in" | render_planner)" ;;
      prd-review)
        printf '%s' "$in" | jq -e 'type == "object" and has("findings")' >/dev/null 2>&1 || die "publish prd-review: stdin must be the prd-reviewer's JSON report"
        file="$spec/reviews/prd-review-$n.json"; title="PRD review, round $n"
        summary="$(printf '%s' "$in" | render_review)" ;;
      note) [ -n "$in" ] || die "publish note: empty stdin"; title=""; summary="$in" ;;
      *) echo "factory: publish plan|prd-review|note" >&2; exit 2 ;;
    esac
    if [ -n "$file" ]; then
      mkdir -p "$root/$spec/reviews"
      printf '%s' "$in" | jq . > "$root/$file"
      commit_paths "factory($slug): $kind $n report" "$file"
    fi
    push
    head="$(G rev-parse HEAD)"; prev="$(state_get '.pr_published // empty')"
    c="$run/.pr-comment.md"
    {
      marker "$kind:$n"; echo
      [ -n "$title" ] && printf '### %s\n\n' "$title"
      printf '%s\n' "$summary"
      changes_md "$prev" "$head"
      if [ "$kind" = plan ]; then
        printf '\n<details><summary>The plan as it stands: what will be built and how</summary>\n\n'
        plan_md "$head"
        printf '\n</details>\n'
      fi
      [ -n "$file" ] && printf '\nFull report: %s\n' "$(link "$head" "$file")"
    } > "$c"
    u="$(post "$c")" || die "gh pr comment failed"
    state_update '.pr_published = $h' --arg h "$head"
    body
    echo "factory: published $kind (round $n): $u"
    ;;

  request-approval)
    need_pr
    gate="${1:-}"; gate_ok "$gate"; shift
    details=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --details) case "${2:-}" in -) details="$(cat)" ;; '') echo "factory: --details <file>|-" >&2; exit 2 ;; *) details="$(cat "$2")" || exit 2 ;; esac; shift 2 ;;
        *) echo "factory: request-approval <gate> [--details <file>|-]" >&2; exit 2 ;;
      esac
    done
    [ -z "$(G status --porcelain --untracked-files=no)" ] || die "uncommitted changes; commit them before asking for approval"
    push
    sha="$(G rev-parse HEAD)"
    h7="$(printf %s "$sha" | cut -c1-12)"
    if [ "$gate" = prd ] && flow_on; then   # the project's own issue flow approves the plan
      flow_request "$sha"
      body
      echo "factory: approval of prd at $h7 requested through the issue's flow: $(state_get '.approval_request.url')"
      exit 0
    fi
    ac="$(approve_cmd)"; pr_url="$(state_get '.pr_url // empty')"
    c="$run/.pr-comment.md"
    {
      marker "approval-request:$gate:$sha"; echo
      printf '### ⏳ factory2 needs your approval: %s\n\n' "$(gate_what "$gate")"
      printf 'Run `%s`%s, commit `%s`.\n\n' "$slug" "${pr_url:+, pull request $pr_url}" "$h7"
      if [ "$gate" = prd ]; then
        printf 'Before any code is written: this is what factory will build and how.\n\n'
        plan_md "$sha"; echo
      fi
      [ -n "$details" ] && printf '%s\n\n' "$details"
      [ "$gate" = evidence ] && printf '**This is the last approval:** once given, factory merges, deploys and runs the smoke test without asking again, and rolls back on its own if the smoke test fails.\n\n'
      if [ "$gate" = prd ]; then
        lr="$(latest_review)"; blocking=""
        [ -n "$lr" ] && blocking="$(jq -r '.findings // [] | .[] | select(.severity == "blocking") | "- **\(.id)**: \(.problem)"' "$lr")"
        [ -n "$blocking" ] && printf '**⚠️ The reviewer still has blocking findings.** Approving overrides them, and the override is recorded:\n\n%s\n\n' "$blocking"
      fi
      printf '#### What to do\n\nReply %s with one of:\n\n' "$([ -n "$(issue_ref)" ] && echo "on this issue" || echo "on this pull request")"
      printf -- '- **Approve**: a comment whose first line is exactly\n\n'
      printf '%s\n' "$ac" | fenced
      printf '\n  Lines after it are kept as notes for the run, for example:\n\n'
      printf '%s\nKeep the reason field optional.\n' "$ac" | fenced
      printf '\n- **Ask for changes**: write each change on its own line, naming the criterion it concerns, for example:\n\n'
      gate_examples "$gate" | fenced
      printf '\n  %s\n\n' "$(gate_correct "$gate")"
      printf -- '- **Stop the run**: say so in the Claude Code session running it.\n\n'
      printf 'The approval holds for `%s` only: a later push asks again. If change requests arrive together with `%s`, the changes win and factory asks again.\n' "$h7" "$ac"
    } > "$c"
    u="$(post_human "$c")" || die "posting the approval request failed"
    state_update '.approval_request = {gate: $g, sha: $s, url: $u, at: $at}' --arg g "$gate" --arg s "$sha" --arg u "$u" --arg at "$(now_utc)"
    body
    echo "factory: approval of $gate at $h7 requested: $u"
    ;;

  feedback|wait)
    need_pr
    gate="${1:-}"; gate_ok "$gate"; shift
    bind=true   # every gate approves the branch as pushed
    timeout=0
    if [ "$cmd" = wait ]; then
      while [ $# -gt 0 ]; do
        case "$1" in --timeout) timeout="${2:-0}"; shift 2 || { echo "factory: $1 needs a value" >&2; exit 2; } ;; *) echo "factory: wait <gate> [--timeout <s>]" >&2; exit 2 ;; esac
      done
    fi
    poll="$(cfg '.review.poll_seconds' 60)"; case "$poll" in ''|*[!0-9]*) poll=60 ;; esac
    reviewers="$(factory_config_json | jq -c '.review.reviewers // [] | if type == "array" then map(tostring) else [] end')"
    started="$(date +%s)"
    while :; do
      flow=""; flow_ok=false; refused=false
      if [ "$gate" = prd ] && flow_on; then
        flow="$(state_get '.approval_request.flow // empty')"
        if [ "$flow" = idea ] && issue_has "$(issue_ref)" ready_for_plan; then   # the owner accepted the idea
          u="$(flow_submit "$(state_get '.approval_request.sha')")"
          state_update '.approval_request.url = $u | .approval_request.at = $at | .approval_request.flow = "submitted"' --arg u "$u" --arg at "$(now_utc)"
          flow=submitted
        fi
        [ "$flow" = submitted ] && issue_has "$(issue_ref)" approved && flow_ok=true
        # still taking a plan after the submit: the flow refused it, and its bot said why
        [ "$flow" = submitted ] && [ "$flow_ok" = false ] && issue_has "$(issue_ref)" ready_for_plan && refused=true
      fi
      all="$(all_comments)" || die "reading the comments failed (gh api)"
      head_remote="$(remote_head)"; head_local="$(G rev-parse HEAD)"
      result="$(jq -n --argjson all "$all" --argjson seen "$(state_get '.pr_seen // []')" \
        --argjson reviewers "$reviewers" --arg slug "$slug" --arg gate "$gate" --arg hr "$head_remote" --arg hl "$head_local" --argjson bind "$bind" \
        --arg ac "$(approve_cmd)" --arg flow "$flow" --argjson flow_ok "$flow_ok" --arg fa "$(flow_cfg approve /approve)" \
        --arg fc "$(flow_cfg changes | awk '{print $1}')" --argjson refused "$refused" --arg iurl "$(gh_ issue view "$(issue_ref)" --json url --jq .url 2>/dev/null)" '
        def first: (.body | split("\n")[0] | gsub("^\\s+|\\s+$"; ""));
        def cmdword: (first | split(" ")[0] | ascii_downcase);
        ($all | map(select(.body | contains("<!-- factory2:")))) as $ours
        | ([$ours[] | select(.kind == "comment" or .kind == "issue")
            | (.body | capture("<!-- factory2:" + $slug + ":approval-request:" + $gate + ":(?<sha>[0-9a-f]{7,64}) -->")? // null) as $m
            | select($m) | {id, at, url, sha: $m.sha}] | max_by(.at)) as $req
        | [$all[] | select((.body | contains("<!-- factory2:")) | not) | select(.key as $k | $seen | index($k) | not)] as $fresh
        | [$fresh[] | select(.author | endswith("[bot]") | not)
            | select(if ($reviewers | length) > 0 then (.author as $a | $reviewers | index($a)) else (.assoc | IN("OWNER", "MEMBER", "COLLABORATOR")) end)] as $new
        | [$fresh[] | select(.key as $k | $new | map(.key) | index($k) | not)] as $ignored
        | def isapprove: if $flow != "" then false
            else .kind != "inline" and ((cmdword == ($ac | ascii_downcase)) or (.kind == "review" and .state == "APPROVED")) end;
          # a command for another automation (the issue flow'"'"'s /approve, /verified, ...) is not a change request;
          # the flow'"'"'s changes command is
          def othercmd: (first | startswith("/")) and (isapprove | not) and (($fc == "") or (cmdword != ($fc | ascii_downcase)));
          [$new[] | select(isapprove)] as $ap0
        | (if $flow_ok then [([$new[] | select(cmdword == ($fa | ascii_downcase))] | max_by(.at))
              // {author: "the issue flow", url: $iurl, at: "", body: "", id: 0}] else $ap0 end) as $ap
        | ([$new[] | select(isapprove | not) | select(othercmd | not)]
          + (if $refused and $req != null then [$fresh[] | select(.kind == "issue" and (.author | endswith("[bot]")) and .at > $req.at)] else [] end)) as $corr
        | (if ($ap | length) == 0 then null
           elif $req == null then "there is no approval request yet"
           elif ($flow_ok | not) and ($ap | all(.at > $req.at) | not) then "the approval came before the approval request"
           elif $bind and $req.sha != $hr then "the approval request is for \($req.sha[0:12]) but the PR head is \($hr[0:12])"
           elif $bind and $hr != $hl then "the PR head \($hr[0:12]) is not this checkout'"'"'s HEAD \($hl[0:12])"
           else "" end) as $why
        | {status: (if ($corr | length) > 0 then "changes" elif ($ap | length) > 0 and $why == "" then "approved" else "none" end),
           corrections: $corr, approvals: $ap, ignored: [$ignored[] | {author, url}],
           approval_invalid: (if ($ap | length) > 0 and ($corr | length) == 0 and $why != "" then $why else null end),
           approval_ignored: (if ($ap | length) > 0 and ($corr | length) > 0 then "change requests arrived with the approval" else null end),
           request: $req, keys: [$fresh[] | .key]}')" || die "couldn't parse the comments"
      status="$(printf '%s' "$result" | jq -r .status)"
      n="$(gate_round "$gate")"; fb="$spec/feedback/$gate-$n.md"
      # everything read is marked seen, so a comment is never applied twice
      state_update '.pr_seen = ((.pr_seen // []) + $k | unique)' --argjson k "$(printf '%s' "$result" | jq -c .keys)"
      inv="$(printf '%s' "$result" | jq -r '.approval_invalid // empty')"
      if [ -n "$inv" ]; then
        c="$run/.pr-comment.md"
        { marker "note:$n"; echo; printf 'The approval was not recorded: %s. Reply `%s` to the latest approval request: %s\n' "$inv" "$(approve_cmd)" "$(state_get '.approval_request.url // empty')"; } > "$c"
        post_human "$c" >/dev/null || true
      fi
      if [ "$status" = changes ] || [ "$status" = approved ]; then
        mkdir -p "$root/$spec/feedback"
        {
          [ -s "$root/$fb" ] && echo
          printf '## From GitHub, %s\n' "$(now_utc)"
          printf '%s' "$result" | jq -r '
            (.corrections[] | "\n### @\(.author) · \(if .path then "`\(.path)`" + (if .line then ":\(.line)" else "" end) else .kind end) · \(.at)\n\(.url)\n\n\(.body)"),
            (if .status == "approved" then (.approvals[] | (.body | sub("^\\s*/[^\n]*\n?"; "")) as $notes
              | select($notes | test("\\S")) | "\n### Approval notes from @\(.author) · \(.at)\n\(.url)\n\n\($notes)") else empty end)'
        } >> "$root/$fb"
        before="$(G rev-parse HEAD)"
        commit_paths "factory($slug): $gate feedback $n from GitHub" "$fb"
        if [ "$(G rev-parse HEAD)" != "$before" ]; then
          push
          state_update '.pr_published = $h' --arg h "$(G rev-parse HEAD)"
        fi
      fi
      if [ "$status" = approved ]; then
        a="$(printf '%s' "$result" | jq -c '.approvals | max_by(.id)')"
        sha="$(printf '%s' "$result" | jq -r .request.sha)"
        bash "$S/state.sh" approve "$gate" "$sha" --via-pr "$(printf '%s' "$a" | jq -r .url)" --by "$(printf '%s' "$a" | jq -r .author)" >/dev/null || die "recording the approval failed"
        lr=""; [ "$gate" = prd ] && lr="$(latest_review)"; open_blocking="[]"
        [ -n "$lr" ] && open_blocking="$(jq -c '[.findings // [] | .[] | select(.severity == "blocking") | .id]' "$lr")"
        result="$(printf '%s' "$result" | jq --argjson b "$open_blocking" '.override = (($b | length) > 0) | .open_blocking = $b')"
        c="$run/.pr-comment.md"
        who="$(printf '%s' "$a" | jq -r .author)"; case "$who" in *' '*) ;; *) who="@$who" ;; esac
        { marker "approved:$gate:$sha"; echo; printf '✅ **Approved: %s** at `%s` by %s. %s\n' "$(gate_what "$gate")" "$(printf %s "$sha" | cut -c1-12)" "$who" "$(gate_next "$gate")"; } > "$c"
        post_human "$c" >/dev/null || true
        state_update 'del(.approval_request)'
        body
      elif [ "$status" = changes ]; then
        c="$run/.pr-comment.md"
        { marker "received:$gate:$n"; echo
          printf 'Received %s comment(s) at the %s gate, saved word for word (%s).\n\n' "$(printf '%s' "$result" | jq '.corrections | length')" "$gate" "$(link "$(G rev-parse HEAD)" "$fb")"
          printf '%s' "$result" | jq -r '.corrections[] | "- [@\(.author)](\(.url))"'
          [ -n "$(printf '%s' "$result" | jq -r '.approval_ignored // empty')" ] && printf '\nThe approval in the same batch was ignored: factory asks again after this round.\n'
          printf '\nNothing is needed from you until factory asks again.\n'
        } > "$c"
        post_human "$c" >/dev/null || true
        # the request is answered: a new one follows the next round
        state_update 'if .approval_request.gate == $g then del(.approval_request) else . end' --arg g "$gate"
        body
      fi
      out="$(printf '%s' "$result" | jq -c --arg fb "$fb" '{status, corrections: (.corrections | length), approvals: (.approvals | length),
        feedback_file: (if .status == "none" then null else $fb end), ignored, approval_invalid, approval_ignored,
        override: (.override // false), open_blocking: (.open_blocking // [])}')"
      if [ "$cmd" = feedback ] || [ "$status" != none ]; then printf '%s\n' "$out"; exit 0; fi
      if [ "$timeout" -gt 0 ] && [ $(( $(date +%s) - started + poll )) -gt "$timeout" ]; then printf '%s\n' "$out"; exit 4; fi
      sleep "$poll"
    done
    ;;

  notify)   # stdin: markdown for the person, nothing to reply: on the run's issues (else the PR)
    need_pr
    m="$(cat)"; [ -n "$m" ] || die "notify: the message comes on stdin"
    c="$run/.pr-comment.md"; { marker "notice:$(date +%s)"; echo; printf '%s\n' "$m"; } > "$c"
    u="$(post_human "$c")" || die "posting the notice failed"
    echo "factory: notified: $u"
    ;;
  ask)
    need_pr
    q="$(cat)"; [ -n "$q" ] || die "ask: the question comes on stdin, with its options and an example reply"
    n=$(( $(state_get '.questions // 0') + 1 )); pr_url="$(state_get '.pr_url // empty')"
    c="$run/.pr-comment.md"
    {
      marker "question:$n"; echo
      printf '### ❓ factory2 needs a decision\n\n'
      printf 'Run `%s`%s.\n\n%s\n\n' "$slug" "${pr_url:+, pull request $pr_url}" "$q"
      printf '#### What to do\n\nReply %s with your answer. The whole comment goes to the run word for word, and the run waits for it.\n' \
        "$([ -n "$(issue_ref)" ] && echo "on this issue" || echo "on this pull request")"
    } > "$c"
    u="$(post_human "$c")" || die "posting the question failed"
    state_update '.questions = $n | .question = {n: $n, url: $u, at: $at}' --argjson n "$n" --arg u "$u" --arg at "$(now_utc)"
    labels
    echo "factory: question $n asked: $u"
    ;;
  answer)
    need_pr
    [ -n "$(state_get '.question // empty')" ] || die "no question is waiting (pr.sh ask)"
    timeout=0
    while [ $# -gt 0 ]; do
      case "$1" in --timeout) timeout="${2:-0}"; shift 2 || { echo "factory: $1 needs a value" >&2; exit 2; } ;; *) echo "factory: answer [--timeout <s>]" >&2; exit 2 ;; esac
    done
    poll="$(cfg '.review.poll_seconds' 60)"; case "$poll" in ''|*[!0-9]*) poll=60 ;; esac
    reviewers="$(factory_config_json | jq -c '.review.reviewers // [] | if type == "array" then map(tostring) else [] end')"
    started="$(date +%s)"; n="$(state_get '.question.n')"; qat="$(state_get '.question.at')"
    while :; do
      all="$(all_comments)" || die "reading the comments failed (gh api)"
      ans="$(jq -n --argjson all "$all" --argjson seen "$(state_get '.pr_seen // []')" --argjson reviewers "$reviewers" --arg qat "$qat" '
        [$all[] | select((.body | contains("<!-- factory2:")) | not) | select(.key as $k | $seen | index($k) | not)
          | select(.at >= $qat) | select(.author | endswith("[bot]") | not)
          | select(if ($reviewers | length) > 0 then (.author as $a | $reviewers | index($a)) else (.assoc | IN("OWNER", "MEMBER", "COLLABORATOR")) end)]')"
      if [ "$(printf '%s' "$ans" | jq length)" -gt 0 ]; then
        fb="$spec/feedback/question-$n.md"; mkdir -p "$root/$spec/feedback"
        printf '%s' "$ans" | jq -r '.[] | "## @\(.author) · \(.at)\n\(.url)\n\n\(.body)\n"' > "$root/$fb"
        commit_paths "factory($slug): answer to question $n" "$fb"; push
        state_update '.pr_seen = ((.pr_seen // []) + $k | unique) | del(.question)' --argjson k "$(printf '%s' "$ans" | jq -c 'map(.key)')"
        c="$run/.pr-comment.md"
        { marker "answered:$n"; echo; printf 'Thanks: the answer is saved word for word (%s) and the run continues. Nothing else is needed from you now.\n' "$(link "$(G rev-parse HEAD)" "$fb")"; } > "$c"
        post_human "$c" >/dev/null || true
        labels
        jq -cn --arg f "$fb" --argjson a "$ans" '{status: "answered", file: $f, authors: [$a[] | .author] | unique}'
        exit 0
      fi
      if [ "$timeout" -gt 0 ] && [ $(( $(date +%s) - started + poll )) -gt "$timeout" ]; then echo '{"status":"none"}'; exit 4; fi
      sleep "$poll"
    done
    ;;
  body) body ;;
  labels) labels ;;
  draft)
    n="$(pr_num)"; [ -n "$n" ] || die "this run has no PR"
    if [ "$(gh_ pr view "$n" --json isDraft --jq .isDraft 2>/dev/null)" = false ]; then
      gh_ pr ready "$n" --undo >/dev/null || die "putting PR #$n back in draft failed"
      echo "factory: PR #$n is a draft again: the change is in progress"
    fi
    ;;
  ready)
    n="$(pr_num)"; [ -n "$n" ] || die "this run has no PR"
    timeout="$(cfg '.ship.checks_timeout' 3600)"
    while [ $# -gt 0 ]; do
      case "$1" in --timeout) timeout="${2:-}"; shift 2 || { echo "factory: $1 needs a value" >&2; exit 2; } ;; *) echo "factory: ready [--timeout <s>]" >&2; exit 2 ;; esac
    done
    case "$timeout" in ''|*[!0-9]*) timeout=3600 ;; esac
    poll="$(cfg '.review.poll_seconds' 60)"; case "$poll" in ''|*[!0-9]*) poll=60 ;; esac
    if [ "$(gh_ pr view "$n" --json isDraft --jq .isDraft 2>/dev/null)" != false ]; then
      rc="$(cfg '.ship.pr_ready' 'gh pr ready')"
      (cd "$root" && bash -c "$rc") >/dev/null || die "ship.pr_ready failed: $rc"
    fi
    started=$(date +%s); seen_none=0
    while :; do
      out="$(gh_ pr checks "$n" --json name,bucket,link 2>"$run/.checks.err")" || true
      if ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
        grep -qi "no checks" "$run/.checks.err" || die "reading the PR's checks failed: $(cat "$run/.checks.err")"
        out='[]'
      fi
      failed="$(printf '%s' "$out" | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | "- \(.name): \(.link // "")"')"
      pending="$(printf '%s' "$out" | jq '[.[] | select(.bucket == "pending")] | length')"
      if [ -n "$failed" ]; then
        gh_ pr ready "$n" --undo >/dev/null 2>&1 || true
        printf 'factory: checks failed on PR #%s; it is a draft again:\n%s\n' "$n" "$failed" >&2
        exit 1
      fi
      if [ "$pending" = 0 ]; then
        # a fresh push may not have registered its checks yet: no checks counts only on a second look
        if [ "$(printf '%s' "$out" | jq length)" -gt 0 ] || [ "$seen_none" = 1 ]; then
          echo "factory: PR #$n is ready for review; checks: $(printf '%s' "$out" | jq -r 'if length == 0 then "none" else (group_by(.bucket) | map("\(length) \(.[0].bucket)") | join(", ")) end')"
          exit 0
        fi
        seen_none=1
      fi
      if [ $(( $(date +%s) - started + poll )) -gt "$timeout" ]; then
        echo "factory: PR #$n: checks still running after ${timeout}s" >&2; exit 4
      fi
      sleep "$poll"
    done
    ;;
  *) echo "factory: unknown pr command '$cmd'" >&2; exit 2 ;;
esac
