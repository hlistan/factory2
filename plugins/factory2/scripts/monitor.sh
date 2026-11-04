#!/usr/bin/env bash
# factory stage 8: watch production after a deploy. Self-contained: /factory2:init copies it, with
# yaml2json.py, to .factory/bin/ so CI (GitHub Actions) and launchd run the committed copy without the
# plugin. Needs bash, git, jq and python3; gh for GitHub issues.
#   monitor.sh --once [slug]   runs every monitor.checks command. A check that fails, and didn't fail at the
#                       deploy baseline, is an anomaly: the incident is FILED FIRST (monitor.report:
#                       github-issue, the default, labelled factory-incident; command: monitor.issue_cmd with
#                       the title as $1 and the markdown body on stdin, printing the reference; file:
#                       .factory/incidents/I-<n>.md), then ship.rollback runs only if monitor.auto_rollback
#                       is true. A check that already has an open incident gets no second one.
#   monitor.sh baseline [slug]  runs the checks and records which pass, as the run's deploy baseline
#                       (ship.sh mark calls it). Without a baseline, any failing check is an anomaly.
#   monitor.sh issue --source <smoke|monitor|...> --output <file> [--title <text>]
#                       files an incident the same way, with the file's tail as evidence (stage 7 smoke).
# The slug defaults to the active run (.factory/runs/active); without one (CI), checks still run and
# incidents name the repository instead of a run.
# Output: one line per check, then `issue: <ref>` per incident filed.
# Exit status: 0 healthy (or window over), 1 an anomaly was filed, 2 config error, 3 failing checks that
# all have an open incident already (nothing new filed).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="${FACTORY_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$root" ] || root="$PWD"
root="$(cd "$root" && pwd -P)"
for t in jq python3; do command -v "$t" >/dev/null 2>&1 || { echo "factory: monitor needs $t" >&2; exit 2; }; done
y2j=""
for c in "$here/lib/yaml2json.py" "$here/yaml2json.py"; do [ -f "$c" ] && { y2j="$c"; break; }; done
[ -n "$y2j" ] || { echo "factory: yaml2json.py not found next to monitor.sh (/factory2:init copies it)" >&2; exit 2; }
[ -f "$root/.factory/config.yaml" ] || { echo "factory: no .factory/config.yaml in $root" >&2; exit 2; }
CFG="$(python3 -I "$y2j" "$root/.factory/config.yaml")" || { echo "factory: .factory/config.yaml doesn't parse" >&2; exit 2; }
cfg() { local v; v="$(printf '%s' "$CFG" | jq -r "($1) | if . == null or . == \"\" then empty else tostring end" 2>/dev/null)"; printf '%s' "${v:-${2:-}}"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in --once|once) cmd=once ;; baseline|issue) ;; ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;;
  *) echo "factory: monitor.sh --once|baseline|issue" >&2; exit 2 ;; esac

slug=""
if [ "$cmd" != issue ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then slug="$1"; shift; fi
[ -n "$slug" ] || slug="$(head -n 1 "$root/.factory/runs/active" 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
state="$root/.factory/runs/$slug/state.json"; [ -n "$slug" ] && [ -f "$state" ] || state=""
sget() { [ -n "$state" ] && jq -r "($1) // empty" "$state" 2>/dev/null; }
report="$(cfg '.monitor.report' github-issue)"
repo="$(basename "$root")"
deploy_sha="$(sget '.deploy.sha')"
pr_url="$(sget '.pr_url')"

ncheck() { printf '%s' "$CFG" | jq -r '.monitor.checks // [] | length'; }
check_field() { printf '%s' "$CFG" | jq -r --argjson i "$1" ".monitor.checks[\$i].$2 // empty"; }

run_checks() { # writes <dir>/<i>.out, prints "<i>\t<name>\t<exit>" per check
  local dir="$1" i n name c rc
  n="$(ncheck)"
  [ "${n:-0}" -gt 0 ] || { echo "factory: monitor.checks is empty" >&2; return 2; }
  i=0
  while [ "$i" -lt "$n" ]; do
    name="$(check_field "$i" name)"; c="$(check_field "$i" cmd)"
    [ -n "$name" ] || name="check-$i"
    if [ -z "$c" ]; then echo "factory: monitor.checks[$i] has no cmd" >&2; return 2; fi
    rc=0; (cd "$root" && CI=true bash -c "$c" </dev/null) > "$dir/$i.out" 2>&1 || rc=$?
    printf '%s\t%s\t%s\n' "$i" "$name" "$rc"
    i=$((i + 1))
  done
}

open_incident() { # <check name>: prints the reference of an open incident for it, if any
  local name="$1" f
  case "$report" in
    github-issue)
      command -v gh >/dev/null 2>&1 || return 0
      (cd "$root" && gh issue list --label factory-incident --state open --limit 100 --json number,title </dev/null 2>/dev/null) |
        jq -r --arg n "[$name]" '.[] | select(.title | contains($n)) | "#\(.number)"' | head -n 1 ;;
    file)
      for f in "$root"/.factory/incidents/I-*.md; do
        [ -f "$f" ] || continue
        grep -q '^status: open' "$f" && grep -qxF "check: $name" "$f" && { printf '%s\n' "${f#"$root"/}"; return 0; }
      done ;;
  esac
  return 0
}

file_incident() { # <title> <body file> <check name or ""> : prints the reference
  local title="$1" body="$2" check="$3" ref n f
  case "$report" in
    github-issue)
      command -v gh >/dev/null 2>&1 || { echo "factory: monitor.report is github-issue but gh is not installed" >&2; return 2; }
      (cd "$root" && gh label create factory-incident --color d73a4a --description "filed by factory2 monitoring" --force >/dev/null 2>&1) || true
      ref="$(cd "$root" && gh issue create --label factory-incident --title "$title" --body-file "$body" | tail -n 1)" || return 1 ;;
    command)
      local ic; ic="$(cfg '.monitor.issue_cmd')"
      [ -n "$ic" ] || { echo "factory: monitor.report is command but monitor.issue_cmd is empty" >&2; return 2; }
      ref="$(cd "$root" && bash -c "$ic" _ "$title" < "$body" | grep -v '^[[:space:]]*$' | tail -n 1)" || return 1 ;;
    file)
      mkdir -p "$root/.factory/incidents"
      n=1; while [ -e "$root/.factory/incidents/I-$n.md" ]; do n=$((n + 1)); done
      f="$root/.factory/incidents/I-$n.md"
      { printf -- '---\nstatus: open\ncreated: %s\n' "$(now)"; [ -n "$check" ] && printf 'check: %s\n' "$check"
        printf 'run: %s\ndeploy_sha: %s\n---\n\n# %s\n\n' "${slug:-}" "${deploy_sha:-}" "$title"; cat "$body"; } > "$f"
      ref=".factory/incidents/I-$n.md" ;;
    *) echo "factory: monitor.report must be github-issue, command or file (got '$report')" >&2; return 2 ;;
  esac
  [ -n "$ref" ] || return 1
  printf '%s\n' "$ref"
}

note_incident() { # <ref> <text>: adds a note to an incident
  case "$report" in
    github-issue) (cd "$root" && gh issue comment "${1#\#}" --body "$2" >/dev/null 2>&1) || true ;;
    file) printf '\n%s\n' "$2" >> "$root/$1" ;;
  esac
}

body_header() {
  printf '**Filed by factory2 monitoring** at %s.\n\n' "$(now)"
  printf -- '- Run: `%s`\n- Deployed commit: `%s`\n' "${slug:-none}" "${deploy_sha:-unknown}"
  [ -n "$pr_url" ] && printf -- '- PR: %s\n' "$pr_url"
  printf '\nThe fix goes through a bugfix run: `/factory2:run --issue <this issue>`.\n\n'
}

case "$cmd" in
  baseline)
    [ -n "$state" ] || { echo "factory: baseline needs a run (slug or active run)" >&2; exit 2; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    res="$(run_checks "$tmp")" || exit 2
    b="$(printf '%s\n' "$res" | jq -R 'split("\t") | {key: .[1], value: (.[2] == "0")}' | jq -s 'from_entries')"
    jq --argjson b "$b" --arg at "$(now)" '.deploy = ((.deploy // {}) + {baseline: $b, baseline_at: $at})' "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
    printf '%s\n' "$res" | while IFS="$(printf '\t')" read -r _ name rc; do
      if [ "$rc" = 0 ]; then echo "baseline: $name passes"; else echo "baseline: $name FAILS (not an anomaly while it keeps failing)"; fi
    done
    ;;

  once)
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    win="$(cfg '.monitor.window_hours' 24)"; at="$(sget '.deploy.at')"
    if [ -n "$at" ] && python3 -c 'import sys,datetime as d; t=d.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ"); sys.exit(0 if (d.datetime.now(d.timezone.utc).replace(tzinfo=None)-t).total_seconds() > float(sys.argv[2])*3600 else 1)' "$at" "$win" 2>/dev/null; then
      echo "factory: the ${win} h monitoring window since the deploy at $at is over"
    fi
    res="$(run_checks "$tmp")" || exit 2
    new=""; known=""; filed=0
    while IFS="$(printf '\t')" read -r i name rc; do
      [ -n "$name" ] || continue
      if [ "$rc" = 0 ]; then echo "ok: $name"; continue; fi
      # not sget: jq's // drops false, and false is exactly the value that matters here
      if [ -n "$state" ] && [ "$(jq -r --arg n "$name" '.deploy.baseline[$n] | if . == null then "" else tostring end' "$state" 2>/dev/null)" = "false" ]; then echo "failing (as at the deploy baseline): $name"; continue; fi
      echo "FAIL: $name (exit $rc)"
      ref="$(open_incident "$name")"
      if [ -n "$ref" ]; then echo "still failing; open incident $ref"; known="$known $name"; continue; fi
      new="$new $i"
    done <<EOF
$res
EOF
    for i in $new; do
      name="$(check_field "$i" name)"; [ -n "$name" ] || name="check-$i"
      c="$(check_field "$i" cmd)"
      body="$tmp/body-$i.md"
      { body_header
        printf '## Failing check: `%s`\n\n```sh\n%s\n```\n\n**Output (last 60 lines):**\n\n```\n' "$name" "$c"
        tail -n 60 "$tmp/$i.out"; printf '\n```\n'; } > "$body"
      ref="$(file_incident "[$name] failing after deploy (${slug:-$repo})" "$body" "$name")" || { echo "factory: filing the incident for $name failed" >&2; exit 2; }
      echo "issue: $ref"; filed=$((filed + 1))
      if [ "$(cfg '.monitor.auto_rollback' false)" = "true" ]; then
        rb="$(cfg '.ship.rollback')"
        if [ -n "$rb" ] && [ "$rb" != "..." ]; then
          if (cd "$root" && CI=true FACTORY_DEPLOY_SHA="$deploy_sha" bash -c "$rb" </dev/null) > "$tmp/rollback.out" 2>&1; then
            echo "rolled back (monitor.auto_rollback)"; note_incident "$ref" "factory2 rolled back automatically (monitor.auto_rollback) at $(now)."
          else
            echo "factory: auto rollback failed" >&2; note_incident "$ref" "factory2 tried to roll back automatically and it failed: $(tail -n 5 "$tmp/rollback.out")"
          fi
        fi
      fi
    done
    [ "$filed" -gt 0 ] && exit 1
    [ -n "$known" ] && exit 3
    exit 0
    ;;

  issue)
    src="monitor"; out=""; title=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --source) src="${2:-}"; shift 2 ;;
        --output) out="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        *) echo "factory: issue --source <name> --output <file> [--title <text>]" >&2; exit 2 ;;
      esac
    done
    [ -f "$out" ] || { echo "factory: --output must be a file" >&2; exit 2; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    [ -n "$title" ] || title="[$src] failing after deploy (${slug:-$repo})"
    { body_header; printf '## Source: %s\n\n**Output (last 80 lines):**\n\n```\n' "$src"; tail -n 80 "$out"; printf '\n```\n'; } > "$tmp/body.md"
    ref="$(file_incident "$title" "$tmp/body.md" "$src")" || exit 2
    echo "issue: $ref"
    ;;
esac
