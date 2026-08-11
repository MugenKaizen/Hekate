#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
PROJECT="$TMP/project"
mkdir -p "$PROJECT"

# Fresh install contains executable runners, adapters, and migration state.
"$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --agents=claude >/dev/null
[ -x "$PROJECT/.workflow/bin/hekate-agent" ]
[ -f "$PROJECT/.workflow/bin/hekate-agent.ps1" ]
[ -f "$PROJECT/.workflow/session.local.yml" ]
[ -f "$PROJECT/.claude/commands/harness.md" ]
grep -qxF '  mode: ask' "$PROJECT/.workflow/session.local.yml"
grep -qxF '.workflow/session.local.yml' "$PROJECT/.gitignore"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 004-add-routing-profiles' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 005-add-session-subagent-policy' "$PROJECT/.workflow/state.yml"

# Installer re-entry must not mark skipped migrations as applied.
if "$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --agents=claude >/dev/null 2>&1; then
  printf 'FAIL: installer re-entry was accepted\n' >&2
  exit 1
fi

# Simulate an installation that has migrations 001/002 but not 003/004/005.
awk '
  /^(orchestration|native_subagents):$/ { drop=1; next }
  drop && /^  / { next }
  drop { drop=0 }
  /^  orchestration: \.workflow\/orchestration\.yml$/ { next }
  { print }
' "$PROJECT/.workflow/status.yml" > "$PROJECT/.workflow/status.yml.tmp"
mv "$PROJECT/.workflow/status.yml.tmp" "$PROJECT/.workflow/status.yml"
awk '$0 != "    - 003-add-cross-harness-orchestration" && $0 != "    - 004-add-routing-profiles" && $0 != "    - 005-add-session-subagent-policy" { print }' "$PROJECT/.workflow/state.yml" > "$PROJECT/.workflow/state.yml.tmp"
mv "$PROJECT/.workflow/state.yml.tmp" "$PROJECT/.workflow/state.yml"
rm -f "$PROJECT/.workflow/orchestration.yml" "$PROJECT/.workflow/session.local.yml" "$PROJECT/.workflow/bin/hekate-agent" "$PROJECT/.workflow/bin/hekate-agent.ps1" "$PROJECT/.claude/commands/harness.md" "$PROJECT/.claude/agents/harness-orchestrator.md"

sh "$ROOT/update-runner.sh" --target="$PROJECT" --ref=HEAD >/dev/null
[ -x "$PROJECT/.workflow/bin/hekate-agent" ]
grep -q '^orchestration:$' "$PROJECT/.workflow/status.yml"
grep -qxF '  orchestration: .workflow/orchestration.yml' "$PROJECT/.workflow/status.yml"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 004-add-routing-profiles' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 005-add-session-subagent-policy' "$PROJECT/.workflow/state.yml"
[ -f "$PROJECT/.workflow/session.local.yml" ]
grep -qxF '  mode: ask' "$PROJECT/.workflow/session.local.yml"
grep -qxF 'native_subagents:' "$PROJECT/.workflow/status.yml"
grep -qxF '  policy: .workflow/session.local.yml' "$PROJECT/.workflow/status.yml"
grep -qxF 'schema_version: 2' "$PROJECT/.workflow/orchestration.yml"
grep -qxF 'default_profile: null' "$PROJECT/.workflow/orchestration.yml"
grep -qxF 'profiles:' "$PROJECT/.workflow/orchestration.yml"
grep -qxF '  default_profile: null' "$PROJECT/.workflow/status.yml"

# Migration 004 preserves custom config, supports dry-run, and creates backups.
MIGRATION_PROJECT="$TMP/migration-project"
mkdir -p "$MIGRATION_PROJECT/.workflow" "$TMP/migration-work" "$MIGRATION_PROJECT/.workflow/backups"
awk '
  /^schema_version:/ { print "schema_version: 1 # legacy schema"; next }
  /^default_profile:/ { next }
  /^profiles:[[:space:]]*$/ { drop=1; next }
  drop && /^harnesses:[[:space:]]*$/ { drop=0; print; next }
  drop { next }
  { print }
  END { print "custom_extension: preserve-me" }
' "$ROOT/templates/.workflow/orchestration.yml" > "$MIGRATION_PROJECT/.workflow/orchestration.yml"
# Remove both the target field and its usual insertion anchor to exercise the
# migration's conservative end-of-block fallback.
awk '$0 !~ /^  default_(harness|profile):/' "$ROOT/templates/.workflow/status.yml" > "$MIGRATION_PROJECT/.workflow/status.yml"
cp "$MIGRATION_PROJECT/.workflow/orchestration.yml" "$TMP/config.before"
cp "$MIGRATION_PROJECT/.workflow/status.yml" "$TMP/status.before"
: > "$TMP/migration-work/backed.txt"
TARGET="$MIGRATION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/migration-work" \
  BACKUP_ROOT="$MIGRATION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/migration-work/backed.txt" \
  DRY_RUN=1 sh "$ROOT/migrations/004-add-routing-profiles.sh" >/dev/null
cmp -s "$TMP/config.before" "$MIGRATION_PROJECT/.workflow/orchestration.yml"
cmp -s "$TMP/status.before" "$MIGRATION_PROJECT/.workflow/status.yml"
: > "$TMP/migration-work/backed.txt"
TARGET="$MIGRATION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/migration-work" \
  BACKUP_ROOT="$MIGRATION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/migration-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/004-add-routing-profiles.sh" >/dev/null
grep -qxF 'schema_version: 2' "$MIGRATION_PROJECT/.workflow/orchestration.yml"
grep -qxF 'default_profile: null' "$MIGRATION_PROJECT/.workflow/orchestration.yml"
grep -qxF 'profiles:' "$MIGRATION_PROJECT/.workflow/orchestration.yml"
grep -qxF 'custom_extension: preserve-me' "$MIGRATION_PROJECT/.workflow/orchestration.yml"
grep -qxF '  default_profile: null' "$MIGRATION_PROJECT/.workflow/status.yml"
[ -f "$MIGRATION_PROJECT/.workflow/backups/.workflow/orchestration.yml.bak" ]
[ -f "$MIGRATION_PROJECT/.workflow/backups/.workflow/status.yml.bak" ]

# Forward schema versions are never downgraded, while missing v2-compatible
# routing fields can still be added conservatively.
FORWARD_PROJECT="$TMP/forward-project"
mkdir -p "$FORWARD_PROJECT/.workflow/backups" "$TMP/forward-work"
awk '
  /^schema_version:/ { print "schema_version: 3"; next }
  /^default_profile:/ { next }
  /^profiles:[[:space:]]*$/ { drop=1; next }
  drop && /^harnesses:[[:space:]]*$/ { drop=0; print; next }
  drop { next }
  { print }
' "$ROOT/templates/.workflow/orchestration.yml" > "$FORWARD_PROJECT/.workflow/orchestration.yml"
: > "$TMP/forward-work/backed.txt"
TARGET="$FORWARD_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/forward-work" \
  BACKUP_ROOT="$FORWARD_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/forward-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/004-add-routing-profiles.sh" >/dev/null
grep -qxF 'schema_version: 3' "$FORWARD_PROJECT/.workflow/orchestration.yml"
grep -qxF 'default_profile: null' "$FORWARD_PROJECT/.workflow/orchestration.yml"
grep -qxF 'profiles:' "$FORWARD_PROJECT/.workflow/orchestration.yml"

# Migration 005 creates a safe local default, updates the status pointer, and
# never overwrites an existing user choice.
SESSION_PROJECT="$TMP/session-project"
mkdir -p "$SESSION_PROJECT/.workflow/backups" "$TMP/session-work"
awk '
  /^native_subagents:[[:space:]]*$/ { drop=1; next }
  drop && /^  / { next }
  drop { drop=0 }
  { print }
' "$ROOT/templates/.workflow/status.yml" > "$SESSION_PROJECT/.workflow/status.yml"
cp "$SESSION_PROJECT/.workflow/status.yml" "$TMP/session-status.before"
: > "$TMP/session-work/backed.txt"
TARGET="$SESSION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/session-work" \
  BACKUP_ROOT="$SESSION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/session-work/backed.txt" \
  DRY_RUN=1 sh "$ROOT/migrations/005-add-session-subagent-policy.sh" >/dev/null
[ ! -e "$SESSION_PROJECT/.workflow/session.local.yml" ]
cmp -s "$TMP/session-status.before" "$SESSION_PROJECT/.workflow/status.yml"
: > "$TMP/session-work/backed.txt"
TARGET="$SESSION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/session-work" \
  BACKUP_ROOT="$SESSION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/session-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/005-add-session-subagent-policy.sh" >/dev/null
grep -qxF '  mode: ask' "$SESSION_PROJECT/.workflow/session.local.yml"
grep -qxF 'native_subagents:' "$SESSION_PROJECT/.workflow/status.yml"
[ -f "$SESSION_PROJECT/.workflow/backups/.workflow/status.yml.bak" ]
sed 's/^  mode: ask$/  mode: auto/' "$SESSION_PROJECT/.workflow/session.local.yml" > "$SESSION_PROJECT/.workflow/session.local.yml.tmp"
mv "$SESSION_PROJECT/.workflow/session.local.yml.tmp" "$SESSION_PROJECT/.workflow/session.local.yml"
TARGET="$SESSION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/session-work" \
  BACKUP_ROOT="$SESSION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/session-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/005-add-session-subagent-policy.sh" >/dev/null
grep -qxF '  mode: auto' "$SESSION_PROJECT/.workflow/session.local.yml"

printf 'ok: install/update smoke tests passed\n'
