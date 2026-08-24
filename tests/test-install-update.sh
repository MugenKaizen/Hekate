#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
PROJECT="$TMP/project"
mkdir -p "$PROJECT"
FULL_COMMIT=0123456789abcdef0123456789abcdef01234567
FAKEBIN="$TMP/fake-bin"
CAPTURE_FILE="$TMP/download-url"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env sh
for arg in "$@"; do
  case "$arg" in https://*) printf '%s\n' "$arg" > "$CAPTURE_FILE" ;; esac
done
exit 1
EOF
chmod +x "$FAKEBIN/curl"

# Network bootstraps require an immutable full commit SHA before any download.
if "$ROOT/install.sh" --target="$PROJECT" >/dev/null 2>&1; then
  printf 'FAIL: remote installer accepted a missing commit\n' >&2
  exit 1
fi
if "$ROOT/install.sh" --target="$PROJECT" --commit=0123456 >/dev/null 2>&1; then
  printf 'FAIL: remote installer accepted a short commit\n' >&2
  exit 1
fi
CAPTURE_FILE="$CAPTURE_FILE" PATH="$FAKEBIN:$PATH" \
  "$ROOT/install.sh" --target="$PROJECT" --commit="$FULL_COMMIT" >/dev/null 2>&1 || true
grep -qxF "https://codeload.github.com/MugenKaizen/Hekate/tar.gz/$FULL_COMMIT" "$CAPTURE_FILE"
rm -f "$CAPTURE_FILE"

# Fresh install contains executable runners, adapters, and migration state.
"$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --agents=claude --commit="$FULL_COMMIT" >/dev/null
[ -x "$PROJECT/.workflow/bin/hekate-agent" ]
[ -f "$PROJECT/.workflow/bin/hekate-agent.ps1" ]
[ -f "$PROJECT/.workflow/session.local.yml" ]
[ -f "$PROJECT/.claude/commands/harness.md" ]
[ -f "$PROJECT/.claude/skills/workflow/SKILL.md" ]
[ -f "$PROJECT/.claude/skills/unslop/SKILL.md" ]
grep -qxF '  mode: ask' "$PROJECT/.workflow/session.local.yml"
grep -qxF '.workflow/session.local.yml' "$PROJECT/.gitignore"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 004-add-routing-profiles' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 005-add-session-subagent-policy' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 006-relocate-agent-skills' "$PROJECT/.workflow/state.yml"
grep -qxF "  installed_ref: $FULL_COMMIT" "$PROJECT/.workflow/state.yml"

# A fresh install lays down the lazily-loaded docs AGENTS.md now references.
[ -f "$PROJECT/.workflow/delegation.md" ]
[ -f "$PROJECT/.workflow/subagents.md" ]
[ -f "$PROJECT/.workflow/history-format.md" ]

if sh "$ROOT/update.sh" --target="$PROJECT" >/dev/null 2>&1; then
  printf 'FAIL: remote updater accepted a missing commit\n' >&2
  exit 1
fi
if sh "$ROOT/update.sh" --target="$PROJECT" --commit=0123456 >/dev/null 2>&1; then
  printf 'FAIL: remote updater accepted a short commit\n' >&2
  exit 1
fi
CAPTURE_FILE="$CAPTURE_FILE" PATH="$FAKEBIN:$PATH" \
  sh "$ROOT/update.sh" --target="$PROJECT" --commit="$FULL_COMMIT" >/dev/null 2>&1 || true
grep -qxF "https://codeload.github.com/MugenKaizen/Hekate/tar.gz/$FULL_COMMIT" "$CAPTURE_FILE"
sh "$ROOT/update.sh" --source="$ROOT" --target="$PROJECT" --commit="$FULL_COMMIT" >/dev/null
grep -qxF "  installed_ref: $FULL_COMMIT" "$PROJECT/.workflow/state.yml"

# Agent Skills use the portable .agents path for non-Claude adapters.
PORTABLE_PROJECT="$TMP/portable-project"
mkdir -p "$PORTABLE_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$PORTABLE_PROJECT" --agents=cursor,codex >/dev/null
[ -f "$PORTABLE_PROJECT/.agents/skills/workflow/SKILL.md" ]
[ -f "$PORTABLE_PROJECT/.agents/skills/unslop/SKILL.md" ]
[ ! -e "$PORTABLE_PROJECT/.claude/skills/workflow/SKILL.md" ]
rm -f "$PORTABLE_PROJECT/.agents/skills/unslop/SKILL.md"
sh "$ROOT/update-runner.sh" --target="$PORTABLE_PROJECT" --ref=HEAD >/dev/null
[ -f "$PORTABLE_PROJECT/.agents/skills/unslop/SKILL.md" ]

# Installing the copilot/gemini/aider adapters lays down real thin-pointer
# files (not just README guidance) and shares portable Agent Skills with them.
NEW_ADAPTERS_PROJECT="$TMP/new-adapters-project"
mkdir -p "$NEW_ADAPTERS_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$NEW_ADAPTERS_PROJECT" --agents=copilot,gemini,aider >/dev/null
[ -f "$NEW_ADAPTERS_PROJECT/.github/copilot-instructions.md" ]
[ -f "$NEW_ADAPTERS_PROJECT/GEMINI.md" ]
[ -f "$NEW_ADAPTERS_PROJECT/.aider.conf.yml" ]
grep -qxF '  - AGENTS.md' "$NEW_ADAPTERS_PROJECT/.aider.conf.yml"
[ -f "$NEW_ADAPTERS_PROJECT/.agents/skills/workflow/SKILL.md" ]
grep -qxF '    - copilot' "$NEW_ADAPTERS_PROJECT/.workflow/state.yml"
grep -qxF '    - gemini' "$NEW_ADAPTERS_PROJECT/.workflow/state.yml"
grep -qxF '    - aider' "$NEW_ADAPTERS_PROJECT/.workflow/state.yml"

# Installer re-entry must not mark skipped migrations as applied.
if "$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --agents=claude >/dev/null 2>&1; then
  printf 'FAIL: installer re-entry was accepted\n' >&2
  exit 1
fi

# Simulate an installation that has migrations 001/002 but not 003/004/005/006.
awk '
  /^(orchestration|native_subagents):$/ { drop=1; next }
  drop && /^  / { next }
  drop { drop=0 }
  /^  orchestration: \.workflow\/orchestration\.yml$/ { next }
  { print }
' "$PROJECT/.workflow/status.yml" > "$PROJECT/.workflow/status.yml.tmp"
mv "$PROJECT/.workflow/status.yml.tmp" "$PROJECT/.workflow/status.yml"
awk '$0 != "    - 003-add-cross-harness-orchestration" && $0 != "    - 004-add-routing-profiles" && $0 != "    - 005-add-session-subagent-policy" && $0 != "    - 006-relocate-agent-skills" { print }' "$PROJECT/.workflow/state.yml" > "$PROJECT/.workflow/state.yml.tmp"
mv "$PROJECT/.workflow/state.yml.tmp" "$PROJECT/.workflow/state.yml"
rm -f "$PROJECT/.workflow/orchestration.yml" "$PROJECT/.workflow/session.local.yml" "$PROJECT/.workflow/bin/hekate-agent" "$PROJECT/.workflow/bin/hekate-agent.ps1" "$PROJECT/.claude/commands/harness.md" "$PROJECT/.claude/agents/harness-orchestrator.md" "$PROJECT/.claude/skills/unslop/SKILL.md"

sh "$ROOT/update-runner.sh" --target="$PROJECT" --ref=HEAD >/dev/null
[ -x "$PROJECT/.workflow/bin/hekate-agent" ]
grep -q '^orchestration:$' "$PROJECT/.workflow/status.yml"
grep -qxF '  orchestration: .workflow/orchestration.yml' "$PROJECT/.workflow/status.yml"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 004-add-routing-profiles' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 005-add-session-subagent-policy' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 006-relocate-agent-skills' "$PROJECT/.workflow/state.yml"
[ -f "$PROJECT/.workflow/session.local.yml" ]
[ -f "$PROJECT/.claude/skills/unslop/SKILL.md" ]
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
[ -f "$MIGRATION_PROJECT/.workflow/backups/.workflow/orchestration.yml" ]
[ -f "$MIGRATION_PROJECT/.workflow/backups/.workflow/status.yml" ]

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
[ -f "$SESSION_PROJECT/.workflow/backups/.workflow/status.yml" ]
sed 's/^  mode: ask$/  mode: auto/' "$SESSION_PROJECT/.workflow/session.local.yml" > "$SESSION_PROJECT/.workflow/session.local.yml.tmp"
mv "$SESSION_PROJECT/.workflow/session.local.yml.tmp" "$SESSION_PROJECT/.workflow/session.local.yml"
TARGET="$SESSION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/session-work" \
  BACKUP_ROOT="$SESSION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/session-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/005-add-session-subagent-policy.sh" >/dev/null
grep -qxF '  mode: auto' "$SESSION_PROJECT/.workflow/session.local.yml"

# Migration 006 moves legacy Hekate skills for portable adapters, including
# user edits, while dry-run remains read-only.
SKILLS_PROJECT="$TMP/skills-project"
mkdir -p "$SKILLS_PROJECT/.workflow/backups" "$SKILLS_PROJECT/.claude/skills/workflow" "$TMP/skills-work"
cp "$ROOT/templates/skills/workflow/SKILL.md" "$SKILLS_PROJECT/.claude/skills/workflow/SKILL.md"
printf 'install:\n  adapters:\n    - cursor\nschema:\n  applied_migrations: []\n' > "$SKILLS_PROJECT/.workflow/state.yml"
: > "$TMP/skills-work/backed.txt"
TARGET="$SKILLS_PROJECT" STATE_FILE="$SKILLS_PROJECT/.workflow/state.yml" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/skills-work" \
  BACKUP_ROOT="$SKILLS_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/skills-work/backed.txt" \
  DRY_RUN=1 sh "$ROOT/migrations/006-relocate-agent-skills.sh" >/dev/null
[ ! -e "$SKILLS_PROJECT/.agents/skills/workflow/SKILL.md" ]
[ -f "$SKILLS_PROJECT/.claude/skills/workflow/SKILL.md" ]
printf '\nUser customization.\n' >> "$SKILLS_PROJECT/.claude/skills/workflow/SKILL.md"
: > "$TMP/skills-work/backed.txt"
TARGET="$SKILLS_PROJECT" STATE_FILE="$SKILLS_PROJECT/.workflow/state.yml" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/skills-work" \
  BACKUP_ROOT="$SKILLS_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/skills-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/006-relocate-agent-skills.sh" >/dev/null
grep -qxF 'User customization.' "$SKILLS_PROJECT/.agents/skills/workflow/SKILL.md"
[ ! -e "$SKILLS_PROJECT/.claude/skills/workflow/SKILL.md" ]
[ -f "$SKILLS_PROJECT/.workflow/backups/.claude/skills/workflow/SKILL.md" ]

# Migration 007 backfills the state.yml adapters ledger for a hand-authored
# adapter marker file that predates this Hekate version, without creating
# any files itself and without touching an adapter already recorded.
ADAPTERS_MIGRATION_PROJECT="$TMP/adapters-migration-project"
mkdir -p "$ADAPTERS_MIGRATION_PROJECT/.workflow/backups" "$ADAPTERS_MIGRATION_PROJECT/.github" "$TMP/adapters-migration-work"
printf 'hand-authored\n' > "$ADAPTERS_MIGRATION_PROJECT/.github/copilot-instructions.md"
printf 'install:\n  adapters:\n    - claude\nschema:\n  applied_migrations: []\n' > "$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml"
: > "$TMP/adapters-migration-work/backed.txt"
TARGET="$ADAPTERS_MIGRATION_PROJECT" STATE_FILE="$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/adapters-migration-work" \
  BACKUP_ROOT="$ADAPTERS_MIGRATION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/adapters-migration-work/backed.txt" \
  DRY_RUN=1 sh "$ROOT/migrations/007-add-portable-adapters.sh" >/dev/null
if grep -qxF '    - copilot' "$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml"; then
  printf 'FAIL: dry-run migration 007 wrote state\n' >&2
  exit 1
fi
: > "$TMP/adapters-migration-work/backed.txt"
TARGET="$ADAPTERS_MIGRATION_PROJECT" STATE_FILE="$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/adapters-migration-work" \
  BACKUP_ROOT="$ADAPTERS_MIGRATION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/adapters-migration-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/007-add-portable-adapters.sh" >/dev/null
grep -qxF '    - claude' "$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml"
grep -qxF '    - copilot' "$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml"
[ ! -e "$ADAPTERS_MIGRATION_PROJECT/GEMINI.md" ]
if grep -qxF '    - gemini' "$ADAPTERS_MIGRATION_PROJECT/.workflow/state.yml"; then
  printf 'FAIL: migration 007 registered an adapter with no marker file\n' >&2
  exit 1
fi

# Migration 008 backfills the lazily-loaded docs for an installation that
# updated in place before this Hekate version existed and is missing them.
DOCS_MIGRATION_PROJECT="$TMP/docs-migration-project"
mkdir -p "$DOCS_MIGRATION_PROJECT/.workflow/backups" "$TMP/docs-migration-work"
: > "$TMP/docs-migration-work/backed.txt"
TARGET="$DOCS_MIGRATION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/docs-migration-work" \
  BACKUP_ROOT="$DOCS_MIGRATION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/docs-migration-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/008-add-lazy-load-docs.sh" >/dev/null
[ -f "$DOCS_MIGRATION_PROJECT/.workflow/delegation.md" ]
[ -f "$DOCS_MIGRATION_PROJECT/.workflow/subagents.md" ]
[ -f "$DOCS_MIGRATION_PROJECT/.workflow/history-format.md" ]
# Never overwrites a copy that's already there.
printf 'custom\n' > "$DOCS_MIGRATION_PROJECT/.workflow/subagents.md"
TARGET="$DOCS_MIGRATION_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/docs-migration-work" \
  BACKUP_ROOT="$DOCS_MIGRATION_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/docs-migration-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/008-add-lazy-load-docs.sh" >/dev/null
grep -qxF 'custom' "$DOCS_MIGRATION_PROJECT/.workflow/subagents.md"

# --force backs up a user-edited stack.yml before overwriting it, warns and
# asks for confirmation, and --dry-run reports the same plan without writing.
FORCE_PROJECT="$TMP/force-project"
mkdir -p "$FORCE_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --agents=claude --commit="$FULL_COMMIT" >/dev/null
printf 'meta:\n  project_name: "my-custom-project"\n' > "$FORCE_PROJECT/.workflow/stack.yml"

FORCE_DRY_OUTPUT="$TMP/force-dry-output.txt"
"$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --agents=claude --commit="$FULL_COMMIT" \
  --force --dry-run > "$FORCE_DRY_OUTPUT" 2>&1
grep -q 'WARN: --force enabled' "$FORCE_DRY_OUTPUT"
grep -q 'would back up:.*stack.yml' "$FORCE_DRY_OUTPUT"
grep -qxF 'meta:' "$FORCE_PROJECT/.workflow/stack.yml"
grep -qxF '  project_name: "my-custom-project"' "$FORCE_PROJECT/.workflow/stack.yml"
[ ! -d "$FORCE_PROJECT/.workflow/backups" ]

# --force without --yes and without a TTY refuses to proceed.
if "$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --agents=claude --commit="$FULL_COMMIT" \
  --force < /dev/null > /dev/null 2>&1; then
  printf 'FAIL: --force proceeded without confirmation or --yes\n' >&2
  exit 1
fi
grep -qxF '  project_name: "my-custom-project"' "$FORCE_PROJECT/.workflow/stack.yml"

# --force --yes proceeds non-interactively, backing up the edited file first.
"$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --agents=claude --commit="$FULL_COMMIT" \
  --force --yes >/dev/null 2>/dev/null
FORCE_BACKUP_DIR=$(find "$FORCE_PROJECT/.workflow/backups" -mindepth 1 -maxdepth 1 -type d | head -n1)
[ -n "$FORCE_BACKUP_DIR" ]
[ -f "$FORCE_BACKUP_DIR/.workflow/stack.yml" ]
grep -qxF '  project_name: "my-custom-project"' "$FORCE_BACKUP_DIR/.workflow/stack.yml"
if grep -qxF '  project_name: "my-custom-project"' "$FORCE_PROJECT/.workflow/stack.yml"; then
  printf 'FAIL: --force --yes did not overwrite the managed file\n' >&2
  exit 1
fi

# prune_old_backups keeps only the 5 most recent timestamped backup run
# directories, leaving non-timestamped/legacy entries untouched.
PRUNE_PROJECT="$TMP/prune-project"
mkdir -p "$PRUNE_PROJECT/.workflow/backups/legacy-file.bak"
n=1
while [ "$n" -le 7 ]; do
  ts=$(printf '202601%02dT000000Z' "$n")
  mkdir -p "$PRUNE_PROJECT/.workflow/backups/$ts"
  n=$((n + 1))
done
(
  TARGET="$PRUNE_PROJECT" BACKUP_ROOT="$PRUNE_PROJECT/.workflow/backups" DRY_RUN=0
  . "$ROOT/lib/update-common.sh"
  prune_old_backups 5
) >/dev/null
[ -d "$PRUNE_PROJECT/.workflow/backups/legacy-file.bak" ]
[ ! -d "$PRUNE_PROJECT/.workflow/backups/20260101T000000Z" ]
[ ! -d "$PRUNE_PROJECT/.workflow/backups/20260102T000000Z" ]
[ -d "$PRUNE_PROJECT/.workflow/backups/20260103T000000Z" ]
[ -d "$PRUNE_PROJECT/.workflow/backups/20260107T000000Z" ]
remaining_runs=$(find "$PRUNE_PROJECT/.workflow/backups" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' | wc -l | tr -d ' ')
[ "$remaining_runs" -eq 5 ]

# --rollback restores the most recent backup run, including a snapshot of
# .workflow/state.yml, which reverts the applied-migrations ledger too.
ROLLBACK_PROJECT="$TMP/rollback-project"
mkdir -p "$ROLLBACK_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$ROLLBACK_PROJECT" --agents=claude --commit="$FULL_COMMIT" >/dev/null

# A project with no backup runs yet refuses to roll back.
if sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback >/dev/null 2>&1; then
  printf 'FAIL: rollback proceeded with no backup runs\n' >&2
  exit 1
fi

cp "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.before-run1"
sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD >/dev/null
cp "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.after-run1"
sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD >/dev/null
cp "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.after-run2"
if cmp -s "$TMP/state.after-run1" "$TMP/state.after-run2"; then
  printf 'FAIL: expected state.yml to change on the second update run\n' >&2
  exit 1
fi

# --rollback --dry-run reports the plan without restoring anything.
sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback --dry-run >/dev/null
cmp -s "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.after-run2"

# A malformed --rollback=<name> is rejected.
if sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback=not-a-timestamp >/dev/null 2>&1; then
  printf 'FAIL: rollback accepted a malformed run name\n' >&2
  exit 1
fi

sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback >/dev/null
cmp -s "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.after-run1"

printf 'ok: install/update smoke tests passed\n'
