#!/usr/bin/env bash
# evidence.sh: capture (playwright, command and none drivers) and the review pack. The Playwright run is a
# fake command (evidence.playwright) that writes the JSON reporter's results.json and media files.
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"; export FACTORY_ROOT="$R"
E="$PLUGIN/scripts/evidence.sh"
FAKE="$T_TMP/fakepw"; mkdir -p "$FAKE"
cat > "$FAKE/pw" <<'PW'
#!/usr/bin/env bash
# fake `playwright test`: records its arguments and environment, writes results.json and media
printf '%s\n' "$*" > "$FAKE_LOG/args"; printf '%s|%s\n' "$FACTORY_VIEWPORTS" "${FACTORY_PORT:-}" > "$FAKE_LOG/env"
[ "${FAKE_MODE:-}" = noresults ] && exit 1
out="$FACTORY_EVIDENCE/tests"
for t in ac1-1440 ac2-1440 other; do mkdir -p "$out/$t"; done
if [ "${FAKE_MODE:-}" != nomedia ]; then
  printf 'png' > "$out/ac1-1440/test-finished-1.png"; printf 'webm' > "$out/ac1-1440/video.webm"
  printf 'png' > "$out/ac2-1440/test-finished-1.png"; printf 'png' > "$out/other/test-finished-1.png"
fi
# container: the demo ran in a container that mounts the project at /workspace, and reports those paths
rep="$out"; [ "${FAKE_MODE:-}" = container ] && rep="/workspace/.factory/runs/demo/evidence/tests"
att() { [ "${FAKE_MODE:-}" = nomedia ] && { echo '[]'; return; }
  printf '[{"name":"screenshot","contentType":"image/png","path":"%s/%s/test-finished-1.png"}%s]' "$rep" "$1" "$2"; }
cat > "$FACTORY_EVIDENCE/results.json" <<JSON
{"suites":[{"title":"dark.spec.ts","file":"dark.spec.ts","specs":[
  {"title":"@AC-1 toggles","tags":[],"tests":[{"projectName":"1440x900","results":[{"status":"passed","attachments":$(att ac1-1440 ",{\"name\":\"video\",\"contentType\":\"video/webm\",\"path\":\"$rep/ac1-1440/video.webm\"}")}]}]},
  {"title":"returns to light","tags":["AC-2"],"tests":[{"projectName":"1440x900","results":[{"status":"failed","attachments":$(att ac2-1440 "")}]}]},
  {"title":"helper screen","tags":[],"tests":[{"projectName":"1440x900","results":[{"status":"passed","attachments":$(att other "")}]}]},
  {"title":"the wizard opens @AC-1","tags":[],"tests":[{"projectName":"1440x900","results":[{"status":"passed","attachments":$(att other "")}]}]}
]}]}
JSON
[ "${FAKE_MODE:-}" = fail ] && exit 1
exit 0
PW
chmod +x "$FAKE/pw"; export FAKE_LOG="$FAKE"
write_config "$R" "evidence:
  playwright: \"bash $FAKE/pw\"
  viewports: [1440x900, 390x844]"
# an earlier feature's test, at the base, that reused the tag AC-1
printf 'test("the wizard opens @AC-1", () => {})\n' > "$R/wizard.spec.ts"
git -C "$R" add -A && git -C "$R" commit -q -m "an earlier feature"
bash "$S/state.sh" start demo >/dev/null
SP="$R/docs/specs/demo"; RUN="$R/.factory/runs/demo"; mkdir -p "$SP"
printf '{"criteria":[{"id":"AC-1","text":"WHEN clicked THE SYSTEM SHALL go dark","level":"e2e","test_ids":["x"],"passes":true},{"id":"AC-2","text":"Back to <light>","level":"e2e","test_ids":[],"passes":false},{"id":"AC-10","text":"unit only","level":"unit","test_ids":[],"passes":true}]}' > "$SP/contract.json"

run bash "$E" pack;                              t_code 1 "pack before capture"
run bash "$E" capture;                           t_code 0 "capture"
t_has "$(cat "$FAKE/args")" "--grep @AC-(1|2|10)\\b" "greps every criterion, AC-1 not matching AC-10"
t_eq "$(cat "$FAKE/env")" "1440x900,390x844|$(bash "$S/state.sh" get .port)" "viewports and port passed"
M="$RUN/evidence/manifest.json"
t_eq "$(jq -r '[.tests[] | .ac | join(",")] | join(" ")' "$M")" "AC-1 AC-2 " "criteria from titles and tags"
t_eq "$(jq -r '.pre_existing | join(",")' "$M")" "the wizard opens @AC-1" "an earlier feature's test with a reused tag is left out"
t_has "$ERR" "PRE-EXISTING" "and listed"
t_eq "$(jq -r '.tests[0].media | map(.kind) | join(",")' "$M")" "image,video" "screenshot and video recorded"
t_eq "$(jq -r '.tests[1].status' "$M")" "failed" "a failing test still counts as evidence"
t_eq "$(bash "$S/state.sh" get .evidence.driver)" "playwright" "capture recorded in state"
run bash "$E" capture --ac AC-2;                 t_code 0 "one criterion"
t_has "$(cat "$FAKE/args")" "--grep @AC-2\\b" "--ac greps that criterion only"
run bash "$E" capture --ac 2;                    t_code 2 "--ac takes an id"
FAKE_MODE=fail run bash "$E" capture;            t_code 0 "failing demo tests still capture"
t_has "$ERR" "some criteria failed on camera" "and say so"
FAKE_MODE=noresults run bash "$E" capture;       t_code 1 "no results.json"
FAKE_MODE=nomedia run bash "$E" capture;         t_code 1 "nothing recorded"
t_has "$ERR" "recorded no video or screenshot" "explains an empty capture"
FAKE_MODE=container run bash "$E" capture;       t_code 0 "a demo run in a container"
t_eq "$(jq -r '.tests[0].media | map(.path | sub("\\.mp4$"; ".webm")) | join(",")' "$M")" "tests/ac1-1440/test-finished-1.png,tests/ac1-1440/video.webm" "its paths are found under the evidence dir"

run bash "$E" capture
printf '{"findings":[{"id":"M1","lens":"maintainability","severity":"advisory","where":"a.ts:3","problem":"<b>dup</b>","fix":"extract"}]}' > "$RUN/advisory.json"
run bash "$E" pack;                              t_code 0 "pack"
H="$RUN/review-pack/index.html"
t_has "$OUT" "pack: $H" "prints the pack path"
c="$(cat "$H")"
t_has "$c" 'id="AC-1"' "a section per criterion"
t_has "$c" "Back to &lt;light&gt;" "criterion text escaped"
t_has "$c" "&lt;b&gt;dup&lt;/b&gt;" "findings escaped"
t_has "$c" "not passing" "a failing criterion is marked"
t_has "$c" "No demo media for this criterion" "a unit-level criterion without media"
t_has "$c" "Other captures" "untagged captures listed"
t_has "$c" "<b>2 / 3</b>" "summary counts passing criteria"
ls "$RUN/review-pack/media/tests/ac1-1440/" > "$T_TMP/ls"
t_has "$(cat "$T_TMP/ls")" "test-finished-1.png" "media copied into the pack"
t_hasnt "$c" "$RUN/evidence" "pack uses relative paths only"

write_config "$R" "evidence:
  playwright: \"bash $FAKE/pw\"
  publish: \"echo uploading >&2; echo https://packs.example.com/\$(basename \$FACTORY_PACK)\""
run bash "$E" pack;                              t_code 0 "pack with publish"
t_has "$OUT" "url: https://packs.example.com/review-pack" "publish prints the URL"
t_eq "$(bash "$S/state.sh" get .evidence.url)" "https://packs.example.com/review-pack" "URL recorded"

# the default command needs the demo config in the project
write_config "$R" 'evidence: {driver: playwright}'
run bash "$E" capture;                           t_code 2 "default command without playwright.demo.config.ts"
t_has "$ERR" "playwright.demo.config.ts is missing" "says what to do"
# a project's own command (Playwright in a subdirectory or a container) names its config's place itself
write_config "$R" "evidence:
  playwright: \"bash $FAKE/pw -c playwright.demo.config.ts\""
run bash "$E" capture;                           t_code 0 "own command naming the demo config elsewhere"

# driver command: files naming a criterion are shown under it
write_config "$R" 'evidence:
  driver: command
  capture: "mkdir -p $FACTORY_EVIDENCE/sim && printf x > $FACTORY_EVIDENCE/sim/AC_1-home.png && printf x > $FACTORY_EVIDENCE/sim/extra.png"'
run bash "$E" capture;                           t_code 0 "command driver"
t_eq "$(jq -r '[.tests[] | select(.ac == ["AC-1"]) | .media[0].path] | join(",")' "$RUN/evidence/manifest.json")" "sim/AC_1-home.png" "AC_n in a file name maps to the criterion"
run bash "$E" pack;                              t_code 0 "pack from command evidence"
write_config "$R" 'evidence: {driver: command}'
run bash "$E" capture;                           t_code 2 "command driver needs evidence.capture"
write_config "$R" 'evidence: {driver: command, capture: "exit 3"}'
run bash "$E" capture;                           t_code 1 "a failing capture command"

# driver none
write_config "$R" 'evidence: {driver: none}'
run bash "$E" capture;                           t_code 0 "driver none"
run bash "$E" pack;                              t_code 0 "pack with test results only"
t_has "$(cat "$H")" "test results only" "pack says there is no media"
write_config "$R" 'evidence: {driver: vhs}'
run bash "$E" capture;                           t_code 2 "unknown driver"
t_done
