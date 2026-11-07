#!/usr/bin/env bash
# issue-flow: one GitHub issue per feature is the only source of truth; its pull requests follow it.
#
#   Issue  todo → planning → building → testing → documenting → closed (done)
#          plus blocked while any of its pull requests waits for a person
#   PR     building (work in progress) or blocked (a person must act)
#
# People file an issue and label it todo. Everything else is set by this script; nobody else sets these
# labels. A pull request contributes to exactly one issue, named in its body:
#   <!-- issue-flow:issue=<n> status=<status> -->
#   Part of #<n>
# (no closing keyword: the issue closes only when its last pull request merges). An issue with several
# open pull requests shows the earliest status among them, and blocked while any of them is blocked.
# When a pull request needs a person, the request is a comment on the issue that names the pull request;
# the details stay on the pull request. The top of the issue's body says, for each pull request, what is
# happening now, what the person must do (or that nothing is needed), and what happened so far.
#
#   issue-flow.sh setup                      creates the labels (idempotent)
#   issue-flow.sh start <issue> <pr> [status] the pull request works on the issue (status: planning)
#   issue-flow.sh status <pr> <status>       planning | building | testing | documenting
#   issue-flow.sh block <pr>                 stdin: the comment for the issue (what is needed, the exact
#                                            reply). Labels the pull request and the issue blocked, posts
#                                            the comment on the issue, prints its URL.
#   issue-flow.sh unblock <pr>               the person answered: building again
#   issue-flow.sh merged <pr>                the pull request merged: the issue closes when no other of its
#                                            pull requests is open
#   issue-flow.sh stop <pr>                  the work stopped unmerged: closes the pull request; the issue
#                                            goes back to todo when no other of its pull requests is open
#   issue-flow.sh note <pr> [--now-file <f>] [--event <text>]
#                                            the status block at the top of the issue's body, one per pull
#                                            request: what is happening now and what the person must do
#                                            (--now-file: markdown; without it the block keeps its text),
#                                            and its history, newest first (--event adds a line). Every other
#                                            command keeps it up to date too.
#   issue-flow.sh show <issue>               the issue's status and its open pull requests
#   issue-flow.sh issue <pr>                 prints the issue a pull request works on
# References are numbers, #n, or URLs in the current repository (gh's, or GH_REPO).
# Exit status: 0 ok, 1 GitHub refused or a precondition isn't met, 2 usage error.
set -u

STAGES="todo planning building testing documenting"
WORK="planning building testing documenting"
FLOW="todo planning building testing documenting blocked"
die() { echo "issue-flow: $*" >&2; exit 1; }
usage() { echo "issue-flow: $*" >&2; exit 2; }
for t in gh jq; do command -v "$t" >/dev/null 2>&1 || { echo "issue-flow: $t is required" >&2; exit 2; }; done

label_spec() { # name<TAB>color<TAB>description
  printf 'todo\tededed\tReady to be built: a person wants it\n'
  printf 'planning\tc5def5\tBeing planned: what will be built and how\n'
  printf 'building\t1d76db\tBeing built (on a pull request: work in progress)\n'
  printf 'testing\t5319e7\tBeing reviewed and tested\n'
  printf 'documenting\t0e8a16\tDocs and evidence before merge\n'
  printf 'blocked\td93f0b\tWaiting for a person: see the latest comment on the issue\n'
}
setup() {
  label_spec | while IFS="$(printf '\t')" read -r n c d; do
    gh label create "$n" --color "$c" --description "$d" --force >/dev/null || exit 1
  done
}

num() { # <ref>: the number of an issue or pull request reference
  case "$1" in
    https://*/issues/[0-9]*|https://*/pull/[0-9]*) printf '%s' "$1" | sed -E 's#.*/(issues|pull)/([0-9]+).*#\2#' ;;
    '#'[0-9]*|[0-9]*) local n="${1#\#}"; case "$n" in *[!0-9]*) return 1 ;; esac; printf '%s' "$n" ;;
    *) return 1 ;;
  esac
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

labels_of() { gh "$1" view "$2" --json labels --jq '.labels[].name'; } # <issue|pr> <n>
set_labels() { # <issue|pr> <n> <wanted, space-separated>: among the flow labels, exactly the wanted ones
  local kind="$1" n="$2" want="$3" have add="" rm="" l
  have="$(labels_of "$kind" "$n")" || die "reading $kind #$n failed"
  for l in $want; do printf '%s\n' "$have" | grep -qxF -- "$l" || add="$add,$l"; done
  for l in $FLOW; do in_list "$l" "$want" && continue; printf '%s\n' "$have" | grep -qxF -- "$l" && rm="$rm,$l"; done
  [ -z "$add$rm" ] && return 0
  edit() { gh "$kind" edit "$n" ${add:+--add-label "${add#,}"} ${rm:+--remove-label "${rm#,}"} >/dev/null 2>&1; }
  edit && return 0
  setup && edit || die "labelling $kind #$n failed"   # a label the repository doesn't have yet
}

pr_body() { gh pr view "$1" --json body --jq '.body // ""'; }
marker_of() { # stdin: a body; prints "<issue> <status>"
  sed -nE 's/.*<!-- issue-flow:issue=([0-9]+) status=([a-z]+) -->.*/\1 \2/p' | head -n 1
}
pr_issue() { local m; m="$(pr_body "$1" | marker_of)"; [ -n "$m" ] || die "pull request #$1 names no issue (issue-flow.sh start)"; echo "${m%% *}"; }
set_marker() { # <pr> <issue> <status>: the marker and "Part of #<issue>" lead the body
  local f; f="$(mktemp)"
  { printf '<!-- issue-flow:issue=%s status=%s -->\nPart of #%s\n\n' "$2" "$3" "$2"
    pr_body "$1" | grep -vE '<!-- issue-flow:issue=[0-9]+ status=[a-z]+ -->' | grep -vxE 'Part of #[0-9]+' | sed '/./,$!d'
  } > "$f"
  gh pr edit "$1" --body-file "$f" >/dev/null || { rm -f "$f"; die "editing pull request #$1 failed"; }
  rm -f "$f"
}

open_prs() { # <issue> [<pr to leave out>]: JSON [{number, status, blocked}] of its open pull requests
  gh pr list --state open --limit 500 --json number,body,labels | jq -c --arg i "$1" --arg x "${2:-}" '
    [.[] | (.body // "" | capture("<!-- issue-flow:issue=(?<issue>[0-9]+) status=(?<status>[a-z]+) -->")? // null) as $m
      | select($m != null and $m.issue == $i and (.number | tostring) != $x)
      | {number, status: $m.status, blocked: ([.labels[]?.name] | index("blocked") != null)}]'
}
sync_issue() { # <issue> [<pr to leave out>]: the issue follows its open pull requests; exit 1 when it has none
  local prs st="" s blocked=""
  prs="$(open_prs "$1" "${2:-}")" || die "listing pull requests failed"
  [ "$(printf '%s' "$prs" | jq length)" -gt 0 ] || return 1
  for s in $WORK; do printf '%s' "$prs" | jq -e --arg s "$s" 'any(.status == $s)' >/dev/null && { st="$s"; break; }; done
  [ -n "$st" ] || st=building
  printf '%s' "$prs" | jq -e 'any(.blocked)' >/dev/null && blocked=blocked
  set_labels issue "$1" "$st $blocked"
}


# --- the status block in the issue's body: <!-- issue-flow:status pr=N --> ... <!-- /issue-flow:status pr=N -->
NOTE_EVENTS=15
now_utc() { date -u +%Y-%m-%dT%H:%MZ; }
note() { # <issue> <pr> <now markdown file or ""> <event or "">
  local i="$1" p="$2" nowf="$3" ev="$4" body old f nb
  body="$(gh issue view "$i" --json body --jq '.body // ""')" || { echo "issue-flow: reading issue #$i failed" >&2; return 1; }
  old="$(printf '%s\n' "$body" | awk -v s="<!-- issue-flow:status pr=$p -->" -v e="<!-- /issue-flow:status pr=$p -->" '$0 == s {on = 1; next} $0 == e {on = 0} on')"
  f="$(mktemp)"; nb="$(mktemp)"
  {
    printf '<!-- issue-flow:status pr=%s -->\n' "$p"
    if [ -n "$nowf" ]; then cat "$nowf"; else printf '%s\n' "$old" | awk '/^<!-- issue-flow:history -->$/ {exit} {print}'; fi
    printf '<!-- issue-flow:history -->\n<details><summary>History of PR #%s</summary>\n\n' "$p"
    { [ -z "$ev" ] || printf -- '- %s · %s\n' "$(now_utc)" "$(printf '%s' "$ev" | tr '\n' ' ')"
      printf '%s\n' "$old" | awk '/^<!-- issue-flow:history -->$/ {on = 1; next} on && /^- / {print}'
    } | head -n "$NOTE_EVENTS"
    printf '\n</details>\n<!-- /issue-flow:status pr=%s -->\n' "$p"
  } > "$f"
  # in place when the block exists, else at the top (above the request), followed by a rule
  if printf '%s\n' "$body" | grep -qxF "<!-- issue-flow:status pr=$p -->"; then
    printf '%s\n' "$body" | awk -v s="<!-- issue-flow:status pr=$p -->" -v e="<!-- /issue-flow:status pr=$p -->" -v f="$f" '
      $0 == s {while ((getline l < f) > 0) print l; skip = 1; next} skip && $0 == e {skip = 0; next} !skip' > "$nb"
  else
    { cat "$f"; printf '\n'
      printf '%s\n' "$body" | grep -q '^<!-- issue-flow:status pr=' || printf -- '---\n\n'
      printf '%s\n' "$body"; } > "$nb"
  fi
  gh issue edit "$i" --body-file "$nb" >/dev/null || { rm -f "$f" "$nb"; echo "issue-flow: editing issue #$i failed" >&2; return 1; }
  rm -f "$f" "$nb"
}
nowtext() { # <file> <markdown>: a short "now" for a block nobody else writes
  printf '%s\n' "$2" > "$1"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
  setup) setup || die "creating the labels failed" ;;
  start)
    i="$(num "${1:-}")" && p="$(num "${2:-}")" || usage "start <issue> <pr> [status]"
    st="${3:-planning}"; in_list "$st" "$WORK" || usage "status is one of: $WORK"
    set_marker "$p" "$i" "$st"
    # a pull request waiting for a person stays blocked when it is started again (a resumed run)
    if labels_of pr "$p" | grep -qx blocked; then set_labels pr "$p" blocked; else set_labels pr "$p" building; fi
    sync_issue "$i" || true
    note "$i" "$p" "" "PR #$p works on this issue ($st)" || true
    echo "issue-flow: #$p works on #$i ($st)" ;;
  status)
    p="$(num "${1:-}")" || usage "status <pr> <status>"
    st="${2:-}"; in_list "$st" "$WORK" || usage "status is one of: $WORK"
    i="$(pr_issue "$p")" || exit 1
    set_marker "$p" "$i" "$st"
    sync_issue "$i" || true
    echo "issue-flow: #$i is $(labels_of issue "$i" | grep -xE "$(echo "$FLOW" | tr ' ' '|')" | paste -sd' ' -)" ;;
  block)
    p="$(num "${1:-}")" || usage "block <pr> (the comment on stdin)"
    body="$(cat)"; [ -n "$body" ] || usage "block: the comment for the issue comes on stdin"
    i="$(pr_issue "$p")" || exit 1
    set_labels pr "$p" blocked
    sync_issue "$i" || true
    f="$(mktemp)"; printf '%s\n' "$body" > "$f"
    u="$(gh issue comment "$i" --body-file "$f" | tail -n 1)" || { rm -f "$f"; die "commenting on issue #$i failed"; }
    rm -f "$f"
    t="$(printf '%s\n' "$body" | grep -v '^<!--' | grep -m1 . | sed -E 's/^#+ *//; s/^🛑 *//')"
    nf="$(mktemp)"; nowtext "$nf" "### 🛑 Waiting for you: PR #$p
**You:** $t. [Open the request]($u): it says exactly what to reply."
    note "$i" "$p" "$nf" "🛑 Asked: $t ([request]($u))" || true; rm -f "$nf"
    printf '%s\n' "$u" ;;
  unblock)
    p="$(num "${1:-}")" || usage "unblock <pr>"
    i="$(pr_issue "$p")" || exit 1
    set_labels pr "$p" building
    sync_issue "$i" || true
    nf="$(mktemp)"; nowtext "$nf" "### ▶️ Working on PR #$p
**You:** nothing to do now: your reply was received."
    note "$i" "$p" "$nf" "Your reply was received; working again" || true; rm -f "$nf" ;;
  merged)
    p="$(num "${1:-}")" || usage "merged <pr>"
    i="$(pr_issue "$p")" || exit 1
    set_labels pr "$p" ""
    nf="$(mktemp)"; nowtext "$nf" "### ✅ PR #$p is merged
**You:** nothing to do."
    note "$i" "$p" "$nf" "✅ PR #$p merged" || true; rm -f "$nf"
    if sync_issue "$i" "$p"; then
      echo "issue-flow: #$p merged; #$i stays open for its other pull requests"
    else
      set_labels issue "$i" ""
      gh issue close "$i" --comment "Done: every pull request for this issue is merged (the last one: #$p)." >/dev/null || die "closing issue #$i failed"
      echo "issue-flow: #$p merged; #$i is done and closed"
    fi ;;
  stop)
    p="$(num "${1:-}")" || usage "stop <pr>"
    i="$(pr_issue "$p")" || exit 1
    set_labels pr "$p" ""
    gh pr close "$p" --comment "Stopped before merge; issue #$i keeps the request." >/dev/null || die "closing pull request #$p failed"
    nf="$(mktemp)"; nowtext "$nf" "### ⏹ PR #$p was stopped before merge
**You:** nothing to do for this PR."
    note "$i" "$p" "$nf" "⏹ PR #$p stopped before merge" || true; rm -f "$nf"
    if ! sync_issue "$i" "$p"; then
      set_labels issue "$i" todo
      gh issue comment "$i" --body "The work on #$p stopped before merge. This issue is \`todo\` again: it is built when someone starts it." >/dev/null || true
    fi
    echo "issue-flow: #$p stopped" ;;
  note)
    p="$(num "${1:-}")" || usage "note <pr> [--now-file <f>] [--event <text>]"; shift
    nowf=""; ev=""
    while [ $# -gt 0 ]; do case "$1" in
      --now-file) nowf="${2:-}"; [ -f "$nowf" ] || usage "note: --now-file needs a file"; shift 2 ;;
      --event) ev="${2:-}"; shift 2 || usage "note: --event needs a text" ;;
      *) usage "note <pr> [--now-file <f>] [--event <text>]" ;; esac; done
    i="$(pr_issue "$p")" || exit 1
    note "$i" "$p" "$nowf" "$ev" || exit 1 ;;
  show)
    i="$(num "${1:-}")" || usage "show <issue>"
    printf '#%s: %s\n' "$i" "$(labels_of issue "$i" | grep -xE "$(echo "$FLOW" | tr ' ' '|')" | paste -sd' ' -)"
    open_prs "$i" | jq -r '.[] | "  #\(.number): \(if .blocked then "blocked" else "building" end) (\(.status))"' ;;
  issue) p="$(num "${1:-}")" || usage "issue <pr>"; pr_issue "$p" ;;
  *) usage "unknown command '$cmd' (setup, start, status, block, unblock, merged, stop, note, show, issue)" ;;
esac
