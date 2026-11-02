# shellcheck shell=bash disable=SC2034
# Test helpers for factory's bash tests. Each tests/*.test.sh sources this, calls the t_* helpers, and
# ends with t_done. No dependencies beyond bash, git, jq and python3.
set -u
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$TESTS")"
PLUGIN="$REPO/plugins/factory"
S="$PLUGIN/scripts"
FIX="$TESTS/fixtures"
T_PASS=0
T_FAIL=0
T_NAME="$(basename "${0%.test.sh}")"
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX")"
trap 'rm -rf "$T_TMP"' EXIT
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_EFFORT_LEVEL

t_ok() { T_PASS=$((T_PASS + 1)); }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL %s: %s\n' "$T_NAME" "$1"; }
t_eq() { # <actual> <expected> <what>
  if [ "$1" = "$2" ]; then t_ok; else t_fail "$3: expected [$2], got [$1]"; fi
}
t_code() { # <expected exit> <what>  (checks $CODE)
  if [ "$CODE" = "$1" ]; then t_ok; else t_fail "$2: expected exit $1, got $CODE; stderr: $(printf '%s' "$ERR" | head -c 400)"; fi
}
t_has() { # <haystack> <needle> <what>
  case "$1" in *"$2"*) t_ok ;; *) t_fail "$3: [$2] not in [$(printf '%s' "$1" | head -c 600)]" ;; esac
}
t_hasnt() { # <haystack> <needle> <what>
  case "$1" in *"$2"*) t_fail "$3: [$2] unexpectedly in [$(printf '%s' "$1" | head -c 600)]" ;; *) t_ok ;; esac
}

run() { # <command...>: runs it, capturing OUT, ERR and CODE
  local o e
  o="$T_TMP/.out"; e="$T_TMP/.err"
  "$@" > "$o" 2> "$e" < /dev/null
  CODE=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
}
hook() { # <script> <json>: runs a hook script with the JSON on stdin
  local o e
  o="$T_TMP/.out"; e="$T_TMP/.err"
  printf '%s' "$2" | bash "$1" > "$o" 2> "$e"
  CODE=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
}

new_repo() { # prints a fresh git repo path with one commit; FACTORY_ROOT is set to it by the caller
  local d
  d="$(mktemp -d "$T_TMP/repo.XXXXXX")"
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  git -C "$d" config commit.gpgsign false
  printf 'node_modules/\n' > "$d/.gitignore"
  git -C "$d" add -A && git -C "$d" commit -q -m init
  (cd "$d" && pwd -P)
}

write_config() { # <repo> <yaml text>
  mkdir -p "$1/.factory"
  printf '%s\n' "$2" > "$1/.factory/config.yaml"
}

t_done() {
  printf '%s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
