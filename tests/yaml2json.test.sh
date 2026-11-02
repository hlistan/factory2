#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
Y="$S/lib/yaml2json.py"
f="$T_TMP/c.yaml"

y() { printf '%s\n' "$1" > "$f"; run python3 -I "$Y" "$f"; }

y 'a: 1
b: "x # not a comment"   # a comment
c: plain text with: colon-free? no
d:
  e: [1, "two", {k: v, n: [true, null]}]
  f: false
list:
  - one
  - "two: quoted"
  - name: health
    cmd: "curl -fsS http://x/health"
  - {name: inline, cmd: y}
empty:
lit: |
  line one
  line two
fold: >-
  folded
  text
q: '"'"'it'"''"'s'"'"'
url: http://localhost:3000
neg: -5
flt: 1.5
yes: yes'
t_code 0 "parses a mixed document"
t_eq "$(printf '%s' "$OUT" | jq -c .a)" '1' "integer"
t_eq "$(printf '%s' "$OUT" | jq -r .b)" 'x # not a comment' "quoted # is not a comment"
t_eq "$(printf '%s' "$OUT" | jq -c .d.e)" '[1,"two",{"k":"v","n":[true,null]}]' "nested flow"
t_eq "$(printf '%s' "$OUT" | jq -c .d.f)" 'false' "false stays false"
t_eq "$(printf '%s' "$OUT" | jq -c '.list')" '["one","two: quoted",{"name":"health","cmd":"curl -fsS http://x/health"},{"name":"inline","cmd":"y"}]' "block list of scalars and maps"
t_eq "$(printf '%s' "$OUT" | jq -c .empty)" 'null' "empty value is null"
t_eq "$(printf '%s' "$OUT" | jq -r .lit)" "$(printf 'line one\nline two')" "literal block"
t_eq "$(printf '%s' "$OUT" | jq -r .fold)" 'folded text' "folded block, stripped"
t_eq "$(printf '%s' "$OUT" | jq -r .q)" "it's" "single-quote escape"
t_eq "$(printf '%s' "$OUT" | jq -r .url)" 'http://localhost:3000' "url plain scalar"
t_eq "$(printf '%s' "$OUT" | jq -c .neg)" '-5' "negative int"
t_eq "$(printf '%s' "$OUT" | jq -c .flt)" '1.5' "float"
t_eq "$(printf '%s' "$OUT" | jq -c .yes)" '"yes"' "no YAML 1.1 yes-boolean"

y 'a: 1
	b: 2'
t_code 2 "tab indentation is rejected"
t_has "$ERR" ":2:" "error names the line"

y 'a: 1
a: 2'
t_code 2 "duplicate key is rejected"

y 'a:
  b: 1
   c: 2'
t_code 2 "bad indentation is rejected"

y 'a: [1, 2'
t_code 2 "unterminated flow is rejected"

run python3 -I "$Y" "$PLUGIN/templates/factory.config.yaml"
t_code 0 "the shipped template parses"
t_eq "$(printf '%s' "$OUT" | jq -r '.checks.fast.unit')" 'npx vitest run --reporter=junit --outputFile=$FACTORY_REPORTS/unit.xml' "template unit command"
t_eq "$(printf '%s' "$OUT" | jq -r '.monitor.checks[0].name')" 'health' "template monitor checks"
t_done
