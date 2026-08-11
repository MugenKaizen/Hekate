#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
PROJECT="$TMP/project"
FAKEBIN="$TMP/bin"
mkdir -p "$PROJECT/.workflow/bin" "$FAKEBIN"
cp "$ROOT/templates/.workflow/orchestration.yml" "$PROJECT/.workflow/orchestration.yml"
cp "$ROOT/templates/.workflow/bin/hekate-agent" "$PROJECT/.workflow/bin/hekate-agent"
chmod +x "$PROJECT/.workflow/bin/hekate-agent"

cat > "$FAKEBIN/pi" <<'EOF'
#!/usr/bin/env sh
printf 'pi-args:'
for arg in "$@"; do printf '<%s>' "$arg"; [ "$arg" != SLOW ] || sleep 30; done
printf '\n'
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

# Runtime selection is local and supports model/effort overrides.
config=$($CLI config use pi --model fake/model --effort low)
assert_contains "$config" 'default_harness: pi'
assert_contains "$config" 'model=fake/model effort=low'

# Foreground invocation preserves one prompt argument and substitutes argv safely.
$CLI run --task 'implement a long task; do not split me' --foreground
run=$(find .workflow/runs -mindepth 1 -maxdepth 1 -type d | head -n 1)
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

# Reject shell metacharacters, multiline path traversal, and cwd escape.
if $CLI config use pi --model 'x;touch-pwned' >/dev/null 2>&1; then fail 'unsafe model accepted'; fi
bad_name=$(printf 'safe\n../../escaped')
if $CLI run --name "$bad_name" --task escape >/dev/null 2>&1; then fail 'multiline name accepted'; fi
if $CLI run --harness pi --cwd "$TMP" --task escape >/dev/null 2>&1; then fail 'outside cwd accepted'; fi
[ ! -e "$PROJECT/touch-pwned" ] || fail 'shell injection occurred'
[ ! -e "$PROJECT/.workflow/escaped" ] || fail 'job path traversal occurred'

# stop only acts on an active, verified worker and updates lifecycle state.
slow_job=$($CLI run --harness pi --task SLOW)
i=0
while [ "$(cat ".workflow/runs/$slow_job/status")" != running ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
$CLI stop "$slow_job"
[ "$(cat ".workflow/runs/$slow_job/status")" = stopped ] || fail 'stop did not persist state'
if $CLI stop "$slow_job" >/dev/null 2>&1; then fail 'completed stop was accepted twice'; fi

# Orphan detection is persisted and wait returns instead of hanging.
orphan=.workflow/runs/manual-orphan
mkdir -p "$orphan"
printf 'running\n' > "$orphan/status"; printf '999999\n' > "$orphan/worker-pid"
printf 'pi\n' > "$orphan/harness"; printf 'fake/model\n' > "$orphan/model"; printf 'low\n' > "$orphan/effort"; printf '%s\n' "$PROJECT" > "$orphan/cwd"
assert_contains "$($CLI status manual-orphan)" 'status: orphaned'
[ "$(cat "$orphan/status")" = orphaned ] || fail 'orphan status not persisted'
if $CLI wait manual-orphan; then fail 'orphan wait returned success'; fi

printf 'ok: hekate-agent integration tests passed\n'
