#!/usr/bin/env bash
# issue-flow.sh: one issue per feature; its pull requests follow it. gh is a fake keeping each issue's and
# pull request's labels, body and state in files.
. "$(dirname "$0")/lib.sh"
F="$S/issue-flow.sh"
FAKE="$T_TMP/gh"; mkdir -p "$FAKE/bin" "$FAKE/s"; export FAKE
cat > "$FAKE/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
d="$FAKE/s"
kind="$1"; [ "$kind" = pr ] || [ "$kind" = issue ] || [ "$kind" = label ] || { echo "fake gh: unhandled $*" >&2; exit 1; }
case "$1 $2" in
  "label create") printf '%s\n' "$3" >> "$FAKE/repo_labels" ;;
  "pr view"|"issue view") f="$d/$1-$3"; touch "$f.labels"; [ -f "$f.body" ] || : > "$f.body"
    q=.; for a in "$@"; do [ "${prev:-}" = --jq ] && q="$a"; prev="$a"; done
    jq -n --rawfile b "$f.body" --argjson l "$(jq -R '{name: .}' "$f.labels" | jq -s .)" '{body: $b, labels: $l}' | jq -r "$q" ;;
  "pr edit"|"issue edit") f="$d/$1-$3"; shift 3; touch "$f.labels"
    while [ $# -gt 0 ]; do case "$1" in
      --body-file) cp "$2" "$f.body"; shift 2 ;;
      --add-label) for l in $(printf '%s' "$2" | tr ',' ' '); do grep -qxF "$l" "$FAKE/repo_labels" 2>/dev/null || { echo "label $l not found" >&2; exit 1; }; done
        printf '%s\n' "$2" | tr ',' '\n' >> "$f.labels"; shift 2 ;;
      --remove-label) printf '%s\n' "$2" | tr ',' '\n' > "$FAKE/rm"; grep -vxF -f "$FAKE/rm" "$f.labels" > "$FAKE/l2"; mv "$FAKE/l2" "$f.labels"; shift 2 ;;
      *) shift ;; esac; done ;;
  "pr list") for f in "$d"/pr-*.body; do n="${f##*/pr-}"; n="${n%.body}"; [ "$(cat "$d/pr-$n.state" 2>/dev/null || echo OPEN)" = OPEN ] || continue; touch "$d/pr-$n.labels"
      jq -n --argjson n "$n" --rawfile b "$f" --argjson l "$(jq -R '{name: .}' "$d/pr-$n.labels" | jq -s .)" '{number: $n, body: $b, labels: $l}'; done | jq -s . ;;
  "pr close") echo CLOSED > "$d/pr-$3.state" ;;
  "issue close") echo CLOSED > "$d/issue-$3.state"; printf '%s\n' "$5" >> "$d/issue-$3.comments" ;;
  "issue comment") if [ "$4" = --body-file ]; then cat "$5"; else printf '%s\n' "$5"; fi >> "$d/issue-$3.comments"
    echo "https://github.com/o/r/issues/$3#issuecomment-1" ;;
  *) echo "fake gh: unhandled $*" >&2; exit 1 ;;
esac
GH
chmod +x "$FAKE/bin/gh"; export PATH="$FAKE/bin:$PATH"
L() { sort "$FAKE/s/$1-$2.labels" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; } # <pr|issue> <n>
pr() { printf '%s' "$2" > "$FAKE/s/pr-$1.body"; }                           # <n> <body>

run bash "$F" status 7 nonsense;              t_code 2 "unknown status"
run bash "$F" start x 7;                       t_code 2 "start needs an issue reference"
run bash "$F" bogus;                           t_code 2 "unknown command"

# --- one pull request through every stage
printf 'todo\nbug\n' > "$FAKE/s/issue-43.labels"
pr 7 "## The change"
run bash "$F" start '#43' https://github.com/o/r/pull/7; t_code 0 "start"
t_has "$(cat "$FAKE/repo_labels")" "documenting" "the labels are created when the repository lacks them"
t_eq "$(head -n 2 "$FAKE/s/pr-7.body")" "<!-- issue-flow:issue=43 status=planning -->
Part of #43" "the pull request names its issue"
t_has "$(cat "$FAKE/s/pr-7.body")" "## The change" "and keeps its body"
t_eq "$(L pr 7)" "building" "the pull request is building"
t_eq "$(L issue 43)" "bug planning" "the issue is planning; todo is gone, other labels stay"
run bash "$F" start 43 7;                      t_code 0 "start again"
t_eq "$(grep -c 'issue-flow:issue' "$FAKE/s/pr-7.body")" "1" "one marker"
t_eq "$(grep -c 'Part of #43' "$FAKE/s/pr-7.body")" "1" "one Part of line"
run bash "$F" issue 7;                         t_code 0 "issue"
t_eq "$OUT" "43" "the pull request's issue"
for s in building testing documenting; do
  run bash "$F" status 7 "$s";                 t_code 0 "status $s"
  t_eq "$(L issue 43)" "bug $s" "the issue is $s"
done
run bash "$F" status 7 building;               t_code 0 "back to building"
t_eq "$(L issue 43)" "bug building" "a fix loop moves the issue back"

printf 'PR #7 needs your approval of the plan.\nReply `/approve`.\n' > "$T_TMP/c"
CODE=0; OUT="$(bash "$F" block 7 < "$T_TMP/c" 2>"$T_TMP/e")" || CODE=$?; ERR="$(cat "$T_TMP/e")"
t_code 0 "block"
t_has "$OUT" "issues/43#issuecomment" "prints the comment's URL"
t_has "$(cat "$FAKE/s/issue-43.comments")" "PR #7 needs your approval" "the request is on the issue"
t_eq "$(L pr 7)" "blocked" "the pull request is blocked, not building"
t_eq "$(L issue 43)" "blocked bug building" "the issue is blocked next to its status"
run bash "$F" block 7;                         t_code 2 "block needs the comment"
run bash "$F" show 43;                         t_code 0 "show"
t_has "$OUT" "#7: blocked (building)" "show lists the pull request"
bash "$F" start 43 7 building >/dev/null
t_eq "$(L pr 7)" "blocked" "starting it again (a resumed run) keeps it blocked"
run bash "$F" unblock 7;                       t_code 0 "unblock"
t_eq "$(L pr 7)" "building" "building again"
t_eq "$(L issue 43)" "bug building" "the issue is no longer blocked"

# --- a second pull request on the same issue
pr 8 "the second part"
run bash "$F" start 43 8;                      t_code 0 "a second pull request"
t_eq "$(L issue 43)" "bug planning" "the issue shows the earliest status of its pull requests"
bash "$F" block 8 < "$T_TMP/c" >/dev/null
t_eq "$(L issue 43)" "blocked bug planning" "blocked while any pull request is"
bash "$F" status 7 documenting >/dev/null
t_eq "$(L issue 43)" "blocked bug planning" "the other's progress doesn't hide it"
bash "$F" unblock 8 >/dev/null; bash "$F" status 8 testing >/dev/null
t_eq "$(L issue 43)" "bug testing" "unblocked: the earliest status"
echo MERGED > "$FAKE/s/pr-7.state"
run bash "$F" merged 7;                        t_code 0 "the first pull request merged"
t_has "$OUT" "stays open" "the issue stays open"
t_eq "$(cat "$FAKE/s/issue-43.state" 2>/dev/null || echo OPEN)" "OPEN" "not closed while #8 is open"
t_eq "$(L pr 7)" "" "a merged pull request carries no flow label"
t_eq "$(L issue 43)" "bug testing" "the issue follows #8"
echo MERGED > "$FAKE/s/pr-8.state"
run bash "$F" merged 8;                        t_code 0 "the last pull request merged"
t_eq "$(cat "$FAKE/s/issue-43.state")" "CLOSED" "the issue is done: closed"
t_eq "$(L issue 43)" "bug" "with no flow label"
t_has "$(cat "$FAKE/s/issue-43.comments")" "the last one: #8" "saying why"

# --- stopped before merge
printf 'todo\n' > "$FAKE/s/issue-50.labels"; pr 9 "x"
bash "$F" start 50 9 >/dev/null
run bash "$F" stop 9;                          t_code 0 "stop"
t_eq "$(cat "$FAKE/s/pr-9.state")" "CLOSED" "the pull request is closed"
t_eq "$(L issue 50)" "todo" "the issue is todo again"
t_has "$(cat "$FAKE/s/issue-50.comments")" "todo\` again" "with a comment"

run bash "$F" status 99 building;              t_code 1 "a pull request with no issue"
t_has "$ERR" "names no issue" "says so"
t_done
