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
if "$ROOT/install.sh" --target="$PROJECT" --legacy-workflow-files >/dev/null 2>&1; then
  printf 'FAIL: remote installer accepted a missing commit\n' >&2
  exit 1
fi
if "$ROOT/install.sh" --target="$PROJECT" --legacy-workflow-files --commit=0123456 >/dev/null 2>&1; then
  printf 'FAIL: remote installer accepted a short commit\n' >&2
  exit 1
fi
CAPTURE_FILE="$CAPTURE_FILE" PATH="$FAKEBIN:$PATH" \
  "$ROOT/install.sh" --target="$PROJECT" --legacy-workflow-files --commit="$FULL_COMMIT" >/dev/null 2>&1 || true
grep -qxF "https://codeload.github.com/MugenKaizen/Hekate/tar.gz/$FULL_COMMIT" "$CAPTURE_FILE"
rm -f "$CAPTURE_FILE"

# Fresh install contains portable workflow files and no legacy orchestration or
# portable native-subagent authorization plane.
"$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --legacy-workflow-files --agents=claude --commit="$FULL_COMMIT" >/dev/null
[ ! -e "$PROJECT/.workflow/bin/hekate-agent" ]
[ ! -e "$PROJECT/.workflow/bin/hekate-agent.ps1" ]
[ ! -e "$PROJECT/.workflow/session.local.yml" ]
[ ! -e "$PROJECT/.workflow/orchestration.yml" ]
[ ! -e "$PROJECT/.workflow/delegation.md" ]
[ ! -e "$PROJECT/.workflow/subagents.md" ]
[ ! -e "$PROJECT/.claude/commands/harness.md" ]
[ ! -e "$PROJECT/.claude/agents/harness-orchestrator.md" ]
[ -f "$PROJECT/.claude/skills/workflow/SKILL.md" ]
[ ! -e "$PROJECT/.claude/skills/unslop/SKILL.md" ]
[ -f "$PROJECT/.workflow/config.yml" ]
[ -f "$PROJECT/.workflow/project.yml" ]
grep -qxF '.workflow/session.local.yml' "$PROJECT/.gitignore"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 004-add-routing-profiles' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 005-add-session-subagent-policy' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 006-relocate-agent-skills' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 009-add-module-switches' "$PROJECT/.workflow/state.yml"
grep -qxF "  installed_ref: $FULL_COMMIT" "$PROJECT/.workflow/state.yml"
grep -qxF 'source:' "$PROJECT/.workflow/status.yml"
grep -qxF '  workflow: .workflow/workflow.yml' "$PROJECT/.workflow/status.yml"
grep -qxF '    mode: prefer-test-first # off | prefer-test-first | require-test-evidence' "$PROJECT/.workflow/workflow.yml"
grep -qxF '    consent: explicit-request-only' "$PROJECT/.workflow/workflow.yml"

# A fresh install lays down the optional history reference.
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
"$ROOT/install.sh" --source="$ROOT" --target="$PORTABLE_PROJECT" --legacy-workflow-files --agents=cursor,codex >/dev/null
[ -f "$PORTABLE_PROJECT/.agents/skills/workflow/SKILL.md" ]
[ ! -e "$PORTABLE_PROJECT/.agents/skills/unslop/SKILL.md" ]
[ ! -e "$PORTABLE_PROJECT/.claude/skills/workflow/SKILL.md" ]
rm -f "$PORTABLE_PROJECT/.agents/skills/workflow/SKILL.md"
sh "$ROOT/update-runner.sh" --target="$PORTABLE_PROJECT" --ref=HEAD >/dev/null
[ -f "$PORTABLE_PROJECT/.agents/skills/workflow/SKILL.md" ]

# Pi uses generic project prompts and never owns an existing settings file.
PI_PROJECT="$TMP/pi-project"
mkdir -p "$PI_PROJECT/.pi"
printf '{"theme":"user-owned"}\n' > "$PI_PROJECT/.pi/settings.json"
cp "$PI_PROJECT/.pi/settings.json" "$TMP/pi-settings.before"
"$ROOT/install.sh" --source="$ROOT" --target="$PI_PROJECT" --agents=pi >/dev/null
[ -f "$PI_PROJECT/.pi/prompts/analyze.md" ]
[ -f "$PI_PROJECT/.pi/prompts/init-workflow.md" ]
[ -f "$PI_PROJECT/.pi/prompts/plan.md" ]
[ -f "$PI_PROJECT/.agents/skills/workflow/SKILL.md" ]
cmp -s "$ROOT/templates/prompts/analyze.md" "$PI_PROJECT/.pi/prompts/analyze.md"
cmp -s "$TMP/pi-settings.before" "$PI_PROJECT/.pi/settings.json"
"$ROOT/install.sh" --source="$ROOT" --target="$PI_PROJECT" --agents=pi --force --yes >/dev/null
cmp -s "$TMP/pi-settings.before" "$PI_PROJECT/.pi/settings.json"

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

# Applied-migration parsing stops at the next schema sibling and ignores
# collection entries left by the historical ledger contamination bug.
LEDGER_STATE="$TMP/ledger-state.yml"
LEDGER_OUTPUT="$TMP/ledger-output.txt"
cat > "$LEDGER_STATE" <<'EOF'
schema:
  state_version: 2
  applied_migrations:
    - 001-first
    - 002_second.test
    - {ran_at: "legacy-pollution"}

    # A comment inside the list does not terminate it.
  history:
    - {ran_at: "2026-08-30T00:00:00Z"}
other:
  items:
    - not-a-migration
EOF
(
  . "$ROOT/lib/update-common.sh"
  seed_applied_migrations_file "$LEDGER_STATE" "$LEDGER_OUTPUT"
  state_has_migration 001-first "$LEDGER_STATE"
  if state_has_migration not-a-migration "$LEDGER_STATE"; then
    printf 'FAIL: migration parser consumed a sibling list\n' >&2
    exit 1
  fi
)
printf '001-first\n002_second.test\n' > "$TMP/expected-ledger.txt"
cmp -s "$TMP/expected-ledger.txt" "$LEDGER_OUTPUT"

# Installer re-entry must not mark skipped migrations as applied.
if "$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --legacy-workflow-files --agents=claude >/dev/null 2>&1; then
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
rm -f "$PROJECT/.workflow/orchestration.yml" "$PROJECT/.workflow/session.local.yml" "$PROJECT/.workflow/bin/hekate-agent" "$PROJECT/.workflow/bin/hekate-agent.ps1" "$PROJECT/.claude/commands/harness.md" "$PROJECT/.claude/agents/harness-orchestrator.md" "$PROJECT/.claude/skills/workflow/SKILL.md"

sh "$ROOT/update-runner.sh" --target="$PROJECT" --ref=HEAD >/dev/null
[ ! -e "$PROJECT/.workflow/bin/hekate-agent" ]
[ ! -e "$PROJECT/.claude/commands/harness.md" ]
grep -q '^orchestration:$' "$PROJECT/.workflow/status.yml"
grep -qxF '  orchestration: .workflow/orchestration.yml' "$PROJECT/.workflow/status.yml"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 004-add-routing-profiles' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 005-add-session-subagent-policy' "$PROJECT/.workflow/state.yml"
grep -qxF '    - 006-relocate-agent-skills' "$PROJECT/.workflow/state.yml"
[ -f "$PROJECT/.workflow/session.local.yml" ]
[ -f "$PROJECT/.claude/skills/workflow/SKILL.md" ]
grep -qxF '  mode: ask' "$PROJECT/.workflow/session.local.yml"
grep -qxF 'native_subagents:' "$PROJECT/.workflow/status.yml"
grep -qxF '  policy: .workflow/session.local.yml' "$PROJECT/.workflow/status.yml"
[ ! -e "$PROJECT/.workflow/orchestration.yml" ]
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
# Use a historical status shape: frozen migrations are compatibility inputs,
# not the current portable contract.
cat > "$MIGRATION_PROJECT/.workflow/status.yml" <<'EOF'
schema_version: 1
orchestration:
  enabled: false
  config: .workflow/orchestration.yml
lazy_load:
  stack: .workflow/stack.yml
EOF
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

# Migration 009 adds all-enabled defaults without changing existing settings,
# supports dry-run, and backs up both committed config files.
MODULE_PROJECT="$TMP/module-project"
mkdir -p "$MODULE_PROJECT/.workflow/backups" "$TMP/module-work"
awk '
  /^hekate:[[:space:]]*$/ { drop=1; next }
  drop && /^  / { next }
  drop { drop=0 }
  { print }
' "$ROOT/templates/.workflow/workflow.yml" > "$MODULE_PROJECT/.workflow/workflow.yml"
awk '
  /^hekate:[[:space:]]*$/ { drop=1; next }
  drop && /^  / { next }
  drop { drop=0 }
  { print }
' "$ROOT/templates/.workflow/status.yml" > "$MODULE_PROJECT/.workflow/status.yml"
printf '\ncustom_setting: preserve-me\n' >> "$MODULE_PROJECT/.workflow/workflow.yml"
cp "$MODULE_PROJECT/.workflow/workflow.yml" "$TMP/module-workflow.before"
cp "$MODULE_PROJECT/.workflow/status.yml" "$TMP/module-status.before"
: > "$TMP/module-work/backed.txt"
TARGET="$MODULE_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/module-work" \
  BACKUP_ROOT="$MODULE_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/module-work/backed.txt" \
  DRY_RUN=1 sh "$ROOT/migrations/009-add-module-switches.sh" >/dev/null
cmp -s "$TMP/module-workflow.before" "$MODULE_PROJECT/.workflow/workflow.yml"
cmp -s "$TMP/module-status.before" "$MODULE_PROJECT/.workflow/status.yml"
: > "$TMP/module-work/backed.txt"
TARGET="$MODULE_PROJECT" RUNNER_ROOT="$ROOT" TMP_ROOT="$TMP/module-work" \
  BACKUP_ROOT="$MODULE_PROJECT/.workflow/backups" BACKED_UP_LIST_FILE="$TMP/module-work/backed.txt" \
  DRY_RUN=0 sh "$ROOT/migrations/009-add-module-switches.sh" >/dev/null
grep -qxF 'hekate:' "$MODULE_PROJECT/.workflow/workflow.yml"
grep -qxF 'hekate:' "$MODULE_PROJECT/.workflow/status.yml"
grep -qxF '    workflow: true' "$MODULE_PROJECT/.workflow/workflow.yml"
grep -qxF 'custom_setting: preserve-me' "$MODULE_PROJECT/.workflow/workflow.yml"
[ -f "$MODULE_PROJECT/.workflow/backups/.workflow/workflow.yml" ]
[ -f "$MODULE_PROJECT/.workflow/backups/.workflow/status.yml" ]

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

# Existing-install --force delegates to the ownership-aware transaction engine.
FORCE_PROJECT="$TMP/force-project"
mkdir -p "$FORCE_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --legacy-workflow-files --agents=claude --commit="$FULL_COMMIT" >/dev/null
printf 'meta:\n  project_name: "my-custom-project"\n' > "$FORCE_PROJECT/.workflow/stack.yml"
printf '\n# project-owned\n' >> "$FORCE_PROJECT/.workflow/config.yml"
printf '\n# project-facts-owned\n' >> "$FORCE_PROJECT/.workflow/project.yml"
cp "$FORCE_PROJECT/.workflow/stack.yml" "$TMP/stack.before-force"
cp "$FORCE_PROJECT/.workflow/config.yml" "$TMP/config.before-force"
cp "$FORCE_PROJECT/.workflow/project.yml" "$TMP/project.before-force"

FORCE_DRY_OUTPUT="$TMP/force-dry-output.txt"
"$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --legacy-workflow-files --agents=claude --commit="$FULL_COMMIT" \
  --force --replace-unowned --dry-run > "$FORCE_DRY_OUTPUT" 2>&1
grep -q 'transaction:' "$FORCE_DRY_OUTPUT"
grep -q 'dry run; no files changed' "$FORCE_DRY_OUTPUT"
grep -qxF 'meta:' "$FORCE_PROJECT/.workflow/stack.yml"
grep -qxF '  project_name: "my-custom-project"' "$FORCE_PROJECT/.workflow/stack.yml"
cmp -s "$TMP/config.before-force" "$FORCE_PROJECT/.workflow/config.yml"
cmp -s "$TMP/project.before-force" "$FORCE_PROJECT/.workflow/project.yml"
[ ! -d "$FORCE_PROJECT/.workflow/transactions" ]

# --force without --yes and without a TTY refuses to proceed.
if "$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --legacy-workflow-files --agents=claude --commit="$FULL_COMMIT" \
  --force < /dev/null > /dev/null 2>&1; then
  printf 'FAIL: --force proceeded without confirmation or --yes\n' >&2
  exit 1
fi
grep -qxF '  project_name: "my-custom-project"' "$FORCE_PROJECT/.workflow/stack.yml"

# --force --yes proceeds non-interactively and commits a recoverable journal.
NO_NPM_BIN="$TMP/no-npm-bin"
mkdir -p "$NO_NPM_BIN"
printf '#!/usr/bin/env sh\nexit 97\n' > "$NO_NPM_BIN/npm"
chmod +x "$NO_NPM_BIN/npm"
PATH="$NO_NPM_BIN:$PATH" "$ROOT/install.sh" --source="$ROOT" --target="$FORCE_PROJECT" --legacy-workflow-files --agents=claude --commit="$FULL_COMMIT" \
  --force --yes >/dev/null 2>/dev/null
cmp -s "$TMP/stack.before-force" "$FORCE_PROJECT/.workflow/stack.yml"
cmp -s "$TMP/config.before-force" "$FORCE_PROJECT/.workflow/config.yml"
cmp -s "$TMP/project.before-force" "$FORCE_PROJECT/.workflow/project.yml"
[ -f "$FORCE_PROJECT/.workflow/install-state.json" ]
FORCE_JOURNAL=$(find "$FORCE_PROJECT/.workflow/transactions" -mindepth 2 -maxdepth 2 -name operation-journal.json | head -n1)
[ -n "$FORCE_JOURNAL" ]
grep -q '"status":"committed"' "$FORCE_JOURNAL"
FORCE_TRANSACTION_ID=$(basename "$(dirname "$FORCE_JOURNAL")")
FORCE_RECOVERY_RUNTIME="$FORCE_PROJECT/.workflow/transactions/$FORCE_TRANSACTION_ID/runtime/src/hekate-cli.mjs"
[ -x "$FORCE_RECOVERY_RUNTIME" ]
node "$FORCE_RECOVERY_RUNTIME" rollback --transaction="$FORCE_TRANSACTION_ID" --dry-run --json --target="$FORCE_PROJECT" >/dev/null

# The update bootstrap delegates --force to the same transaction engine.
UPDATE_FORCE_DRY_OUTPUT="$TMP/update-force-dry-output.txt"
if ! sh "$ROOT/update.sh" --source="$ROOT" --target="$FORCE_PROJECT" --agents=claude --commit="$FULL_COMMIT" \
  --force --dry-run > "$UPDATE_FORCE_DRY_OUTPUT" 2>&1; then
  cat "$UPDATE_FORCE_DRY_OUTPUT" >&2
  exit 1
fi
grep -q 'transaction:' "$UPDATE_FORCE_DRY_OUTPUT"
RUNNER_FORCE_DRY_OUTPUT="$TMP/runner-force-dry-output.txt"
sh "$ROOT/update-runner.sh" --target="$FORCE_PROJECT" --agents=claude --ref=HEAD \
  --force --replace-unowned --dry-run > "$RUNNER_FORCE_DRY_OUTPUT" 2>&1
grep -q 'transaction:' "$RUNNER_FORCE_DRY_OUTPUT"

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
"$ROOT/install.sh" --source="$ROOT" --target="$ROLLBACK_PROJECT" --legacy-workflow-files --agents=claude --commit="$FULL_COMMIT" >/dev/null

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
awk '
  /^  applied_migrations:$/ { in_list=1; next }
  in_list && /^  [^ ]/ { in_list=0 }
  in_list && /\{ran_at:/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$ROLLBACK_PROJECT/.workflow/state.yml" && {
  printf 'FAIL: update history contaminated applied migrations\n' >&2
  exit 1
}

# Rollback restores every captured path, not only installation state.
LATEST_ROLLBACK_BACKUP=$(find "$ROLLBACK_PROJECT/.workflow/backups" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' | sort -r | head -n1)
printf 'AGENTS backup sentinel\n' > "$LATEST_ROLLBACK_BACKUP/AGENTS.md"
printf 'AGENTS live sentinel\n' > "$ROLLBACK_PROJECT/AGENTS.md"

# --rollback --dry-run reports the plan without restoring anything.
sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback --dry-run >/dev/null
cmp -s "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.after-run2"
grep -qxF 'AGENTS live sentinel' "$ROLLBACK_PROJECT/AGENTS.md"

# A malformed --rollback=<name> is rejected.
if sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback=not-a-timestamp >/dev/null 2>&1; then
  printf 'FAIL: rollback accepted a malformed run name\n' >&2
  exit 1
fi

sh "$ROOT/update-runner.sh" --target="$ROLLBACK_PROJECT" --ref=HEAD --rollback >/dev/null
cmp -s "$ROLLBACK_PROJECT/.workflow/state.yml" "$TMP/state.after-run1"
grep -qxF 'AGENTS backup sentinel' "$ROLLBACK_PROJECT/AGENTS.md"

# An unknown adapter name is rejected instead of silently installing core only.
UNKNOWN_PROJECT="$TMP/unknown-adapter"
mkdir -p "$UNKNOWN_PROJECT"
if "$ROOT/install.sh" --source="$ROOT" --target="$UNKNOWN_PROJECT" --agents=clod --commit="$FULL_COMMIT" >/dev/null 2>&1; then
  printf 'FAIL: installer accepted an unknown adapter\n' >&2
  exit 1
fi
[ ! -e "$UNKNOWN_PROJECT/AGENTS.md" ]

# A v1 contract installation carries no legacy workflow.yml. It must still be
# recognized as an existing installation rather than overwritten by the
# fresh-install copy path.
V1_PROJECT="$TMP/v1-layout"
mkdir -p "$V1_PROJECT/.workflow"
cp "$ROOT/templates/.workflow/config.yml" "$V1_PROJECT/.workflow/config.yml"
cp "$ROOT/templates/.workflow/project.yml" "$V1_PROJECT/.workflow/project.yml"
printf 'authored by the project\n' > "$V1_PROJECT/AGENTS.md"
cp "$V1_PROJECT/AGENTS.md" "$TMP/v1-agents.expected"
if "$ROOT/install.sh" --source="$ROOT" --target="$V1_PROJECT" --agents=claude --commit="$FULL_COMMIT" >/dev/null 2>&1; then
  printf 'FAIL: installer treated a v1 installation as a fresh target\n' >&2
  exit 1
fi
cmp -s "$V1_PROJECT/AGENTS.md" "$TMP/v1-agents.expected"
[ ! -e "$V1_PROJECT/.workflow/workflow.yml" ]

# The frozen legacy update path must refuse a v1 layout instead of failing with
# a missing-file error, and must not modify it.
if sh "$ROOT/update-runner.sh" --target="$V1_PROJECT" --ref=HEAD >/dev/null 2>&1; then
  printf 'FAIL: legacy update runner accepted a v1 installation\n' >&2
  exit 1
fi
sh "$ROOT/update-runner.sh" --target="$V1_PROJECT" --ref=HEAD 2>&1 | grep -q 'rerun with --force'
cmp -s "$V1_PROJECT/AGENTS.md" "$TMP/v1-agents.expected"

# The legacy project-fact files and the preset registry are opt-in: a default
# installation records its profile selection in config.yml and its facts in
# project.yml instead of carrying duplicates.
DEFAULT_PROJECT="$TMP/default-payload"
mkdir -p "$DEFAULT_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$DEFAULT_PROJECT" --agents=claude --commit="$FULL_COMMIT" >/dev/null
[ -f "$DEFAULT_PROJECT/.workflow/config.yml" ]
[ -f "$DEFAULT_PROJECT/.workflow/project.yml" ]
[ -f "$DEFAULT_PROJECT/.workflow/workflow.yml" ]
[ -f "$DEFAULT_PROJECT/.workflow/status.yml" ]
[ ! -e "$DEFAULT_PROJECT/.workflow/stack.yml" ]
[ ! -e "$DEFAULT_PROJECT/.workflow/architecture.yml" ]
[ ! -e "$DEFAULT_PROJECT/.workflow/conventions.yml" ]
[ ! -e "$DEFAULT_PROJECT/.workflow/presets.yml" ]

OPTIN_PROJECT="$TMP/optin-payload"
mkdir -p "$OPTIN_PROJECT"
"$ROOT/install.sh" --source="$ROOT" --target="$OPTIN_PROJECT" --agents=claude --legacy-workflow-files --commit="$FULL_COMMIT" >/dev/null
[ -f "$OPTIN_PROJECT/.workflow/stack.yml" ]
[ -f "$OPTIN_PROJECT/.workflow/presets.yml" ]

printf 'ok: install/update smoke tests passed\n'
