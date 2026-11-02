#!/usr/bin/env bash
# factory guardrail (PreToolUse on Bash). Exit 2 blocks the command and shows stderr to Claude.
# Ported from singularity's guard-bash.sh (MIT); the lexer and the git and rm checks are unchanged. It blocks:
#   - force-pushes to a protected branch (--force, --force-with-lease, -f, +refspec, --mirror, or --all
#     with force), and deleting one (--delete, :branch);
#   - skipping git hooks (--no-verify, `git commit -n`, `-c core.hooksPath=…`, HUSKY=0);
#   - recursive deletes of / or of the home directory;
#   - stopping processes by name (pkill, killall): kill by pid;
#   - the project's deploy and rollback commands (ship.deploy, ship.rollback in .factory/config.yaml)
#     unless the active factory run is in stage 7 with your deploy confirmation recorded, or in stage 7-8
#     with a rollback approval. Deploys go through /factory:run.
# It splits the command the way a shell does (quotes, escapes, here-documents, `;`, `&&`, `|`, subshells,
# `bash -c` and `eval`) and checks the command words, so quoting a branch name doesn't get past it, and a
# commit message, an echo or a here-document that mentions these commands doesn't trigger it.
# It is a seatbelt against mistakes, not a security boundary: protect the default branch on the code host,
# and use Claude Code's sandbox, for that.
# Protected branches: main, master, develop, trunk, production, release, release/* and releases/*, plus
# project.default_branch from .factory/config.yaml.
input="$(cat)"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_has jq || exit 0

command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
dir="${cwd:-$FACTORY_ROOT_DIR}"
current="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)"
default_branch="$(cfg '.project.default_branch')"

deploy_guard() { # blocks ship.deploy / ship.rollback outside an approved stage 7 (or 8 for rollback)
  local norm dep rb slug run stage
  norm="$(printf '%s' "$command" | tr -s ' \t\n' '   ')"
  dep="$(cfg '.ship.deploy' | tr -s ' \t\n' '   ')"
  rb="$(cfg '.ship.rollback' | tr -s ' \t\n' '   ')"
  slug="$(factory_active_slug)"
  run="$FACTORY_ROOT_DIR/.factory/runs/$slug"
  stage=""; [ -n "$slug" ] && stage="$(jq -r '.stage // empty' "$run/state.json" 2>/dev/null)"
  matches() { [ "${#1}" -ge 4 ] && [ "$1" != "..." ] && case "$norm" in *"$1"*) return 0 ;; esac; return 1; }
  if matches "$dep"; then
    if [ "$stage" = "7" ] && [ -n "$(jq -r '.approvals.deploy.sha // empty' "$run/state.json" 2>/dev/null)" ]; then return 0; fi
    echo "Blocked by factory guardrail: this is the project's deploy command (ship.deploy). Deploys run only in stage 7 of /factory:run, after the person confirms (state.sh approve deploy). To deploy by hand, run it yourself outside Claude." >&2
    exit 2
  fi
  if matches "$rb"; then
    case "$stage" in
      7|8) [ -n "$(jq -r '(.approvals.rollback.sha // .approvals.deploy.sha) // empty' "$run/state.json" 2>/dev/null)" ] && return 0 ;;
    esac
    echo "Blocked by factory guardrail: this is the project's rollback command (ship.rollback). Rollbacks run in stage 7-8 of /factory:run after the person approves (state.sh approve rollback)." >&2
    exit 2
  fi
}
deploy_guard

IFS= read -r -d '' program <<'AWK' || true
BEGIN {
  n = split("main master develop trunk production release " extra, names, " ")
  for (k = 1; k <= n; k++) if (names[k] != "") PROTECTED[names[k]] = 1
  SEP = "\001"
}
{ buf = (NR > 1 ? buf "\n" : "") $0 }
END { run(buf, 0) }  # the command arrives already unescaped (jq -r)

function block(reason) { print reason; exit }

function unescape(s,   out, i, n, c, d) { # a JSON string's escapes
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\\" || i == n) { out = out c; continue }
    d = substr(s, ++i, 1)
    if (d == "n") out = out "\n"
    else if (d == "t") out = out "\t"
    else if (d == "u") { out = out "?"; i += 4 }
    else if (d == "r" || d == "b" || d == "f") out = out ""
    else out = out d
  }
  return out
}

# Splits a shell command into words, as tok[0..nt-1], with SEP between simple commands. Quotes and
# escapes are removed; redirection targets, here-strings and here-document bodies are dropped.
function lex(s, tok,   nt, n, i, c, nx, word, inw, skip, j, dl, hd, hdash, hdash_of, nh, hi, line, eol) {
  nt = 0; n = length(s); word = ""; inw = 0; skip = 0; nh = 0; i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx != "\n") { word = word nx; inw = 1 }
      i += 2; continue
    }
    if (c == "'") {
      j = index(substr(s, i + 1), "'")
      if (j == 0) { word = word substr(s, i + 1); inw = 1; i = n + 1; continue }
      word = word substr(s, i + 1, j - 1); inw = 1; i += j + 1; continue
    }
    if (c == "\"") {
      i++; inw = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
          nx = substr(s, i + 1, 1)
          if (nx == "\"" || nx == "\\" || nx == "$" || nx == "`") { word = word nx; i += 2; continue }
          if (nx == "\n") { i += 2; continue }
        }
        if (c == "\"") { i++; break }
        word = word c; i++
      }
      continue
    }
    if (c == " " || c == "\t") {
      if (inw) { if (skip) skip = 0; else tok[nt++] = word; word = ""; inw = 0 }
      i++; continue
    }
    if (c == "#" && !inw) {
      j = index(substr(s, i), "\n")
      if (j == 0) i = n + 1; else i += j - 1
      continue
    }
    if (c == "<" || c == ">") {
      if (inw && word ~ /^[0-9]+$/) { word = ""; inw = 0 }
      else if (inw) { if (skip) skip = 0; else tok[nt++] = word; word = ""; inw = 0 }
      if (substr(s, i, 3) == "<<<") { i += 3; skip = 1; continue }
      if (substr(s, i, 2) == "<<") {
        i += 2; hdash = 0
        if (substr(s, i, 1) == "-") { hdash = 1; i++ }
        while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
        dl = ""
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == "<" || c == ">" || c == "(" || c == ")") break
          if (c != "'" && c != "\"" && c != "\\") dl = dl c
          i++
        }
        hd[nh] = dl; hdash_of[nh] = hdash; nh++
        continue
      }
      i++
      while (substr(s, i, 1) == ">" || substr(s, i, 1) == "|") i++
      if (substr(s, i, 1) == "&") { i++; while (i <= n && substr(s, i, 1) ~ /[0-9-]/) i++; continue }
      skip = 1
      continue
    }
    if (c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "`") {
      if (inw) { if (skip) skip = 0; else tok[nt++] = word; word = ""; inw = 0 }
      skip = 0
      tok[nt++] = SEP
      if (c == "\n" && nh > 0) {
        for (hi = 0; hi < nh; hi++) {
          while (i < n) {
            j = index(substr(s, i + 1), "\n")
            if (j == 0) { line = substr(s, i + 1); eol = n } else { line = substr(s, i + 1, j - 1); eol = i + j }
            if (hdash_of[hi]) sub(/^\t+/, "", line)
            i = eol
            if (line == hd[hi]) break
          }
        }
        nh = 0
      }
      i++; continue
    }
    word = word c; inw = 1; i++
  }
  if (inw && !skip) tok[nt++] = word
  tok[nt++] = SEP
  return nt
}

function run(s, depth,   tok, nt, k, w, nw) {
  nt = lex(s, tok); nw = 0
  for (k = 0; k < nt; k++) {
    if (tok[k] == SEP) { if (nw > 0) check(w, nw, depth); nw = 0 }
    else w[nw++] = tok[k]
  }
}

function check(w, nw, depth,   i, t, prog, j, s, husky) {
  i = 0; husky = 0
  while (i < nw) {
    t = w[i]
    if (t ~ /^(\{|\}|!|if|then|else|elif|do|while|until|time|nohup|command|builtin|exec|stdbuf|caffeinate)$/) { i++; continue }
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { if (t ~ /^HUSKY=0$/ || t ~ /^HUSKY_SKIP_HOOKS=(1|true)$/) husky = 1; i++; continue }
    if (t == "sudo" || t == "doas") { i++; while (i < nw && w[i] ~ /^-/) { if (w[i] ~ /^-[ugCDhpRrTt]$/) i++; i++ } continue }
    if (t == "env") {
      i++
      while (i < nw && (w[i] ~ /^-/ || w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        if (w[i] ~ /^HUSKY=0$/ || w[i] ~ /^HUSKY_SKIP_HOOKS=(1|true)$/) husky = 1
        if (w[i] ~ /^-[uSC]$/) i++
        i++
      }
      continue
    }
    if (t == "nice" || t == "timeout") { i++; while (i < nw && (w[i] ~ /^-/ || w[i] ~ /^[0-9.]+[smhd]?$/)) { if (w[i] ~ /^-[nsk]$/) i++; i++ } continue }
    break
  }
  if (i >= nw) return
  prog = w[i]; sub(/.*\//, "", prog)
  if (prog ~ /^(bash|sh|zsh|dash|ksh)$/) {
    if (depth >= 3) return
    for (j = i + 1; j < nw; j++) if (w[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { if (j + 1 < nw) run(w[j + 1], depth + 1); return }
    return
  }
  if (prog == "eval") {
    if (depth >= 3) return
    s = ""; for (j = i + 1; j < nw; j++) s = s " " w[j]
    run(s, depth + 1); return
  }
  if (prog == "git") check_git(w, nw, i + 1, husky)
  else if (prog == "rm") check_rm(w, nw, i + 1)
  else if (prog == "pkill" || prog == "killall")
    block(prog " stops every process with that name, the user's own included: stop the processes you started by their pid (kill <pid>)")
}

function protected_branch(b) {
  sub(/^refs\/heads\//, "", b)
  if (b == "") return 0
  if (b in PROTECTED) return 1
  return b ~ /^releases?\//
}

function check_git(w, nw, i, husky,   hooksoff, sub_cmd, t, k, c, force, del, all, remote, refs, nr, r, f, p, src, dst) {
  hooksoff = husky
  while (i < nw && w[i] ~ /^-/) {
    t = w[i]
    if (t == "-c" && i + 1 < nw && tolower(w[i + 1]) ~ /^core\.hookspath=/) hooksoff = 1
    if (tolower(t) ~ /^-ccore\.hookspath=/) hooksoff = 1
    if (t == "-C" || t == "-c" || t == "--git-dir" || t == "--work-tree" || t == "--namespace" || t == "--config-env") { i += 2; continue }
    i++
  }
  if (i >= nw) return
  sub_cmd = w[i++]
  if (hooksoff && sub_cmd ~ /^(commit|push|merge|rebase|am|cherry-pick|revert)$/)
    block("skipping git hooks (core.hooksPath or HUSKY=0) skips the project's checks")
  if (sub_cmd == "commit") {
    for (; i < nw; i++) {
      t = w[i]
      if (t == "--") break
      if (t == "--no-verify") block("--no-verify skips the project's checks")
      if (t ~ /^-[mFCct]$/ || t ~ /^--(message|file|reuse-message|reedit-message|template|author|date|cleanup|fixup|squash|trailer|pathspec-from-file)$/) { i++; continue }
      if (t ~ /^-[A-Za-z]+$/) {
        for (k = 2; k <= length(t); k++) {
          c = substr(t, k, 1)
          if (c == "n") block("git commit -n skips the project's checks (it means --no-verify)")
          if (c ~ /[mFCct]/) break
        }
      }
    }
    return
  }
  if (sub_cmd != "push") return
  force = 0; del = 0; all = 0; remote = ""; nr = 0
  for (; i < nw; i++) {
    t = w[i]
    if (t == "--no-verify") block("--no-verify skips the project's checks")
    if (t == "--force" || t ~ /^--force-with-lease/) { force = 1; continue }
    if (t == "--mirror") { force = 1; all = 1; continue }
    if (t == "--delete") { del = 1; continue }
    if (t == "--all" || t == "--branches") { all = 1; continue }
    if (t ~ /^--(repo|receive-pack|exec|push-option)$/ || t == "-o") { i++; continue }
    if (t ~ /^--/) continue
    if (t ~ /^-[A-Za-z0-9]+$/) { if (t ~ /f/) force = 1; if (t ~ /d/) del = 1; continue }
    if (remote == "") { remote = t; continue }
    refs[nr++] = t
  }
  if (force && all) block("force-pushing every branch (--mirror, or --all with force) overwrites protected branches")
  if (nr == 0) {
    if ((force || del) && protected_branch(current)) block("force-push to the protected branch " current)
    return
  }
  for (k = 0; k < nr; k++) {
    r = refs[k]; f = force
    if (substr(r, 1, 1) == "+") { f = 1; r = substr(r, 2) }
    p = index(r, ":")
    if (p) { src = substr(r, 1, p - 1); dst = substr(r, p + 1) } else { src = r; dst = r }
    if (dst == "HEAD" || dst == "@") dst = current
    if (del || (p && src == "")) { if (protected_branch(dst)) block("deleting the protected branch " dst); continue }
    if (f && protected_branch(dst)) block("force-push to the protected branch " dst)
  }
}

function norm(t) { # a path with the home directory written as ~, without trailing /, /. or /*
  if (t ~ /^(\$HOME|\$\{HOME\}|~)(\/|$)/) sub(/^(\$HOME|\$\{HOME\}|~)/, "~", t)
  else if (home != "" && (t == home || index(t, home "/") == 1)) t = "~" substr(t, length(home) + 1)
  while (t != "/" && t ~ /\/(\*|\.)?$/) { sub(/\/(\*|\.)?$/, "", t); if (t == "") { t = "/"; break } }
  return t
}

function check_rm(w, nw, i,   rec, endopt, t, nt, targets, k) {
  rec = 0; endopt = 0; nt = 0
  for (; i < nw; i++) {
    t = w[i]
    if (!endopt && t == "--") { endopt = 1; continue }
    if (!endopt && t ~ /^--/) { if (t == "--recursive") rec = 1; continue }
    if (!endopt && t ~ /^-[A-Za-z]+$/) { if (t ~ /[rR]/) rec = 1; continue }
    targets[nt++] = t
  }
  if (!rec) return
  for (k = 0; k < nt; k++) {
    t = norm(targets[k])
    if (t == "/" || t == "~") block("recursive delete of / or the home directory")
  }
}
AWK

h="${HOME:-}"
h="${h%/}"
reason="$(printf '%s' "$command" | awk -v home="$h" -v current="$current" -v extra="$default_branch" "$program")"
if [ -n "$reason" ]; then
  echo "Blocked by factory guardrail: $reason" >&2
  exit 2
fi
exit 0
