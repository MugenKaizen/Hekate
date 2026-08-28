#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
PROJECT="$TMP/project"
FAKEBIN="$TMP/bin"
mkdir -p "$PROJECT/.workflow/bin" "$FAKEBIN"
cp "$ROOT/templates/.workflow/orchestration.yml" "$PROJECT/.workflow/orchestration.yml"
awk '
  /^default_profile:/ { print "default_profile: medium"; next }
  /^  opencode:[[:space:]]*$/ { in_opencode=1; print; next }
  in_opencode && /^    command:/ {
    print "    command: hekate-test-missing-opencode"
    in_opencode=0
    next
  }
  /^  claude:[[:space:]]*$/ {
    print "  fakeXcli:"
    print "    enabled: true"
    print "    command: claude"
    print "    prompt_delivery: stdin"
    print "    supports_model: true"
    print "    supports_effort: true"
    print "    default_model: fake/alias-harness"
    print "    default_effort: low"
    print "    args:"
    print "  fake.cli:"
    print "    enabled: true"
    print "    command: pi"
    print "    prompt_delivery: argument"
    print "    supports_model: true"
    print "    supports_effort: true"
    print "    default_model: fake/dotted-harness"
    print "    default_effort: high"
    print "    args:"
    print
  }
  /^profiles:[[:space:]]*$/ {
    print
    print "  small:"
    print "    harness: pi"
    print "    model: fake/terra"
    print "    effort: high"
    print "  medium:"
    print "    harness: pi"
    print "    model: fake/sol"
    print "    effort: medium"
    print "  no-effort:"
    print "    harness: gemini"
    print "    effort: high"
    print "  aXb:"
    print "    harness: pi"
    print "    model: fake/alias"
    print "    effort: low"
    print "  a.b:"
    print "    harness: pi"
    print "    model: fake/dotted"
    print "    effort: high"
    print "  quoted:"
    print "    harness: \047pi\047"
    print "    model: \047fake/quoted\047"
    print "    effort: \047high\047"
    print "  none:"
    print "    harness: pi"
    print "    model: fake/reserved"
    print "    effort: high"
    next
  }
  { print }
' "$PROJECT/.workflow/orchestration.yml" > "$PROJECT/.workflow/orchestration.yml.tmp"
mv "$PROJECT/.workflow/orchestration.yml.tmp" "$PROJECT/.workflow/orchestration.yml"
cp "$ROOT/templates/.workflow/bin/hekate-agent" "$PROJECT/.workflow/bin/hekate-agent"
chmod +x "$PROJECT/.workflow/bin/hekate-agent"

cat > "$FAKEBIN/pi" <<'EOF'
#!/usr/bin/env sh
printf 'pi-args:'
code=""
for arg in "$@"; do
  printf '<%s>' "$arg"
  [ "$arg" != SLOW ] || sleep 30
  case "$arg" in FAIL:*) code="${arg#FAIL:}" ;; esac
done
printf '\n'
[ -z "$code" ] || exit "$code"
EOF
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env sh
printf 'claude-args:'
for arg in "$@"; do printf '<%s>' "$arg"; done
printf '\nprompt:'
cat
EOF
cat > "$FAKEBIN/aider" <<'EOF'
#!/usr/bin/env sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --message-file ]; then shift; printf 'file-prompt:'; cat "$1"; exit 0; fi
  shift
done
exit 2
EOF
chmod +x "$FAKEBIN/pi" "$FAKEBIN/claude" "$FAKEBIN/aider"
PATH="$FAKEBIN:$PATH"; export PATH
cd "$PROJECT"
CLI=.workflow/bin/hekate-agent

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected [$2] in [$1]" ;; esac; }

# Disabled by default.
if "$CLI" run --task nope >/dev/null 2>&1; then fail 'disabled orchestration accepted a run'; fi

# A committed, single-quoted default profile resolves without guessing from prompt text.
sed -e 's/^enabled: false$/enabled: true/' -e "s/^default_profile: medium$/default_profile: 'medium'/" .workflow/orchestration.yml > .workflow/orchestration.yml.tmp
mv .workflow/orchestration.yml.tmp .workflow/orchestration.yml
profiles=$($CLI profiles)
assert_contains "$profiles" 'medium'
assert_contains "$profiles" 'fake/sol'
case "$profiles" in *'none'*) fail 'reserved profile was listed' ;; esac
$CLI run --task 'implicit committed profile' --foreground >/dev/null
implicit=$(find .workflow/runs -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ "$(cat "$implicit/profile")" = medium ] || fail 'committed default profile not persisted'
[ "$(cat "$implicit/model")" = fake/sol ] || fail 'committed profile model not resolved'

# A missing module block preserves old behavior, but explicit switches prevent
# new jobs even when orchestration.yml itself is enabled.
cat > .workflow/status.yml <<'EOF'
hekate:
  enabled: true
  modules:
    orchestration: false
EOF
if $CLI run --task nope >/dev/null 2>&1; then fail 'disabled orchestration module accepted a run'; fi
cat > .workflow/status.yml <<'EOF'
hekate:
    enabled: true
    modules:
        orchestration:
EOF
if $CLI run --task nope >/dev/null 2>&1; then fail 'empty orchestration module with four-space indentation accepted a run'; fi
cat > .workflow/status.yml <<'EOF'
hekate:
  enabled: false
EOF
if $CLI run --task nope >/dev/null 2>&1; then fail 'disabled Hekate accepted a run'; fi
rm .workflow/status.yml

# Dotted profile and harness names match exactly; quoted values are unquoted.
harnesses=$($CLI harnesses)
dotted_harness_line=$(printf '%s\n' "$harnesses" | grep '^fake\.cli ')
assert_contains "$dotted_harness_line" 'command=pi'
assert_contains "$dotted_harness_line" 'model=fake/dotted-harness'
$CLI run --profile a.b --task 'dotted exact profile' --foreground >/dev/null
dotted=''
for candidate in .workflow/runs/*; do [ "$(cat "$candidate/task.md")" = 'dotted exact profile' ] && dotted="$candidate"; done
[ "$(cat "$dotted/model")" = fake/dotted ] || fail 'dotted profile aliased another name'
$CLI run --profile quoted --task 'quoted profile values' --foreground >/dev/null
quoted=''
for candidate in .workflow/runs/*; do [ "$(cat "$candidate/task.md")" = 'quoted profile values' ] && quoted="$candidate"; done
[ "$(cat "$quoted/harness")" = pi ] || fail 'single-quoted harness was not unquoted'
[ "$(cat "$quoted/model")" = fake/quoted ] || fail 'single-quoted model was not unquoted'

# Local profile selection and explicit effort override profile values.
profile_config=$($CLI config use-profile small)
assert_contains "$profile_config" 'default_profile: small'
$CLI run --task 'local profile override' --effort xhigh --foreground >/dev/null
local_profile=''
for candidate in .workflow/runs/*; do [ "$(cat "$candidate/task.md")" = 'local profile override' ] && local_profile="$candidate"; done
[ "$(cat "$local_profile/profile")" = small ] || fail 'local profile not persisted'
[ "$(cat "$local_profile/model")" = fake/terra ] || fail 'local profile model not resolved'
[ "$(cat "$local_profile/effort")" = xhigh ] || fail 'explicit effort did not override profile'
assert_contains "$($CLI status "$(basename "$local_profile")")" 'profile: small'

# A developer may define a local-only profile; config updates preserve it.
cat >> .workflow/orchestration.local.yml <<'EOF'

profiles:
  personal:
    harness: pi
    model: fake/personal
    effort: low
EOF
$CLI config use-profile personal >/dev/null
$CLI run --task 'local-only profile' --foreground >/dev/null
personal=''
for candidate in .workflow/runs/*; do [ "$(cat "$candidate/task.md")" = 'local-only profile' ] && personal="$candidate"; done
[ "$(cat "$personal/profile")" = personal ] || fail 'local-only profile not persisted'
[ "$(cat "$personal/model")" = fake/personal ] || fail 'local-only profile not resolved'
grep -q '^  personal:$' .workflow/orchestration.local.yml || fail 'local profile was not preserved'

# Profile validation and conflict rules.
if $CLI run --profile unknown --task nope >/dev/null 2>&1; then fail 'unknown profile accepted'; fi
if $CLI run --profile none --task nope >/dev/null 2>&1; then fail 'reserved none profile accepted'; fi
if $CLI config use-profile null >/dev/null 2>&1; then fail 'reserved null profile accepted'; fi
bad_profile=$(printf 'small\n../../escape')
if $CLI run --profile "$bad_profile" --task nope >/dev/null 2>&1; then fail 'multiline profile accepted'; fi
if $CLI run --profile small --harness pi --task nope >/dev/null 2>&1; then fail 'profile+harness conflict accepted'; fi
if $CLI run --profile no-effort --task nope >/dev/null 2>&1; then fail 'profile capability mismatch accepted'; fi

# Explicit harness bypasses an implicit profile.
$CLI run --harness claude --task 'explicit harness' --foreground >/dev/null
explicit=''
for candidate in .workflow/runs/*; do [ "$(cat "$candidate/task.md")" = 'explicit harness' ] && explicit="$candidate"; done
[ "$(cat "$explicit/profile")" = none ] || fail 'explicit harness did not bypass implicit profile'
[ "$(cat "$explicit/harness")" = claude ] || fail 'explicit harness not selected'

# Runtime harness selection disables inherited project profile safely.
config=$($CLI config use pi --model fake/model --effort low)
assert_contains "$config" 'default_harness: pi'
assert_contains "$config" 'default_profile: none'
assert_contains "$config" 'model=fake/model effort=low'

# Foreground invocation preserves one prompt argument and substitutes argv safely.
$CLI run --task 'implement a long task; do not split me' --foreground
run=''
for candidate in .workflow/runs/*; do [ "$(cat "$candidate/task.md")" = 'implement a long task; do not split me' ] && run="$candidate"; done
[ -n "$run" ] || fail 'foreground job not found'
out=$(cat "$run/stdout.log")
assert_contains "$out" '<fake/model>'
assert_contains "$out" '<low>'
assert_contains "$out" '<implement a long task; do not split me>'
[ "$(cat "$run/status")" = completed ] || fail 'foreground job did not complete'

# Background lifecycle and result retrieval.
job=$($CLI run --harness pi --task 'background task')
$CLI wait "$job"
status=$($CLI status "$job")
assert_contains "$status" 'status: completed'
result=$($CLI result "$job")
assert_contains "$result" '<background task>'

# stdin delivery for Claude.
$CLI config use claude --model sonnet --effort high >/dev/null
$CLI run --task 'stdin task body' --foreground
latest=''
for candidate in .workflow/runs/*; do
  [ "$(cat "$candidate/harness")" = claude ] && latest="$candidate"
done
[ -n "$latest" ] || fail 'Claude job not found'
claude_out=$(cat "$latest/stdout.log")
assert_contains "$claude_out" '<sonnet>'
assert_contains "$claude_out" '<high>'
assert_contains "$claude_out" 'prompt:stdin task body'

# File delivery works for harnesses such as Aider.
$CLI run --harness aider --task 'task from file' --foreground >/dev/null
for candidate in .workflow/runs/*; do
  [ "$(cat "$candidate/harness")" = aider ] && aider_run="$candidate"
done
assert_contains "$(cat "$aider_run/stdout.log")" 'file-prompt:task from file'

# Doctor treats missing optional CLIs as scan results, with targeted/strict modes.
doctor=$($CLI doctor)
assert_contains "$doctor" 'ok       enabled  pi'
assert_contains "$doctor" 'missing  enabled  opencode'
if $CLI doctor opencode >/dev/null 2>&1; then fail 'targeted missing doctor returned success'; fi
if $CLI doctor --strict >/dev/null 2>&1; then fail 'strict doctor returned success with missing harnesses'; fi
$CLI doctor pi >/dev/null || fail 'targeted available doctor failed'
awk '
  /^  aider:[[:space:]]*$/ { in_aider=1; print; next }
  in_aider && /^    enabled:/ { print "    enabled: false"; in_aider=0; next }
  { print }
' .workflow/orchestration.yml > .workflow/orchestration.yml.tmp
mv .workflow/orchestration.yml.tmp .workflow/orchestration.yml
assert_contains "$($CLI doctor)" 'disabled disabled aider'
if $CLI doctor aider >/dev/null 2>&1; then fail 'targeted disabled doctor returned success'; fi

# Reject shell metacharacters, multiline path traversal, and cwd escape.
if $CLI config use pi --model 'x;touch-pwned' >/dev/null 2>&1; then fail 'unsafe model accepted'; fi
bad_name=$(printf 'safe\n../../escaped')
if $CLI run --name "$bad_name" --task escape >/dev/null 2>&1; then fail 'multiline name accepted'; fi
if $CLI run --harness pi --cwd "$TMP" --task escape >/dev/null 2>&1; then fail 'outside cwd accepted'; fi
[ ! -e "$PROJECT/touch-pwned" ] || fail 'shell injection occurred'
[ ! -e "$PROJECT/.workflow/escaped" ] || fail 'job path traversal occurred'

# Unified job-directory field names (must match hekate-agent.ps1 exactly).
field_job=$($CLI run --harness pi --task 'field name check')
$CLI wait "$field_job" || fail 'field name check job did not complete'
[ -f ".workflow/runs/$field_job/task.md" ] || fail 'unified field: task.md missing'
[ -f ".workflow/runs/$field_job/exit-code" ] || fail 'unified field: exit-code missing'
[ -f ".workflow/runs/$field_job/started-at" ] || fail 'unified field: started-at missing'
[ -f ".workflow/runs/$field_job/finished-at" ] || fail 'unified field: finished-at missing'
[ -f ".workflow/runs/$field_job/child-pid" ] || fail 'unified field: child-pid missing'
[ -f ".workflow/runs/$field_job/worker-token" ] || fail 'unified field: worker-token missing'
[ ! -e ".workflow/runs/$field_job/pid" ] || fail 'legacy field: pid should not exist (renamed to child-pid)'
[ ! -e ".workflow/runs/$field_job/prompt.md" ] || fail 'legacy field: prompt.md should not exist (renamed to task.md)'

# `wait` returns the harness's actual exit code, not a hardcoded 0/1.
fail_job=$($CLI run --harness pi --task 'FAIL:7')
wait_rc=0; $CLI wait "$fail_job" || wait_rc=$?
[ "$wait_rc" -ne 0 ] || fail 'wait on a failing job returned success'
[ "$wait_rc" -eq 7 ] || fail "wait did not propagate the harness exit code (got $wait_rc, expected 7)"
[ "$(cat ".workflow/runs/$fail_job/exit-code")" = 7 ] || fail 'exit-code field did not record 7'

ok_job=$($CLI run --harness pi --task 'wait success')
$CLI wait "$ok_job" || fail 'wait on a successful job did not return 0'

# stop only acts on an active, verified worker and updates lifecycle state.
slow_job=$($CLI run --harness pi --task SLOW)
i=0
while [ "$(cat ".workflow/runs/$slow_job/status")" != running ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s ".workflow/runs/$slow_job/worker-token" ] || fail 'worker-token was not written at worker start'
$CLI stop "$slow_job"
[ "$(cat ".workflow/runs/$slow_job/status")" = stopped ] || fail 'stop did not persist state'
if $CLI stop "$slow_job" >/dev/null 2>&1; then fail 'completed stop was accepted twice'; fi

# A worker-token whose recorded start-time does not match the live process's
# actual start time (a spoofed/foreign token) must not be treated as
# verified: stop must refuse to signal.
spoof=.workflow/runs/manual-spoof
mkdir -p "$spoof"
printf 'running\n' > "$spoof/status"; printf '%s\n' "$$" > "$spoof/worker-pid"
printf '%s:not-a-real-start-time\n' "$$" > "$spoof/worker-token"
printf 'pi\n' > "$spoof/harness"; printf 'fake/model\n' > "$spoof/model"; printf 'low\n' > "$spoof/effort"; printf '%s\n' "$PROJECT" > "$spoof/cwd"
if $CLI stop manual-spoof >/dev/null 2>&1; then fail 'stop signaled a PID whose worker-token start-time did not match'; fi

# Orphan detection is persisted and wait returns instead of hanging.
orphan=.workflow/runs/manual-orphan
mkdir -p "$orphan"
printf 'running\n' > "$orphan/status"; printf '999999\n' > "$orphan/worker-pid"
printf 'pi\n' > "$orphan/harness"; printf 'fake/model\n' > "$orphan/model"; printf 'low\n' > "$orphan/effort"; printf '%s\n' "$PROJECT" > "$orphan/cwd"
assert_contains "$($CLI status manual-orphan)" 'status: orphaned'
[ "$(cat "$orphan/status")" = orphaned ] || fail 'orphan status not persisted'
if $CLI wait manual-orphan; then fail 'orphan wait returned success'; fi

printf 'ok: hekate-agent integration tests passed\n'
