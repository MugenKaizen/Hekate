#!/usr/bin/env sh
# ai_agent_workflow update runner
#
# Flags:
#   --target=<path>     Root of the target project. Defaults to the current directory.
#   --repo=<owner/name> GitHub repository. Defaults to the built-in one.
#   --ref=<git-ref>     Branch/tag to update to. Defaults to main.
#   --commit=<sha>      Exact commit to update to.
#   --force             Overwrite locally edited managed files after confirmation.
#   --dry-run           Show what would be done without making changes.

set -eu

TARGET="$(pwd)"
REPO="${AAW_REPO:-MugenKaizen/Hekate}"
REF="main"
COMMIT=""
DRY_RUN=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#--target=}" ;;
    --repo=*)   REPO="${arg#--repo=}" ;;
    --ref=*)    REF="${arg#--ref=}" ;;
    --commit=*) COMMIT="${arg#--commit=}" ;;
    --dry-run)  DRY_RUN=1 ;;
    --force)    FORCE=1 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      printf '[aaw] ERROR: unknown arg: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

RUNNER_ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
TMP_ROOT="$(mktemp -d)"
STATE_FILE="$TARGET/.workflow/state.yml"
BACKUP_ROOT="$TARGET/.workflow/backups"
BACKED_UP_LIST_FILE="$TMP_ROOT/backed-up-files.txt"
APPLIED_MIGRATIONS_FILE="$TMP_ROOT/applied-migrations.txt"
LEGACY_MODE=0
STATE_REPO=""
STATE_REF=""

cleanup() {
  if [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

. "$RUNNER_ROOT/lib/update-common.sh"

update_template_file() {
  target_rel="$1"
  template_rel="$2"
  new_src="$RUNNER_ROOT/templates/$template_rel"
  old_src=""
  target_path="$TARGET/$target_rel"

  if [ -n "$OLD_TPL" ]; then
    old_src="$OLD_TPL/$template_rel"
  fi

  [ -f "$new_src" ] || return 0

  if [ ! -e "$target_path" ]; then
    copy_file "$new_src" "$target_path"
    log "added: $target_path"
    return 0
  fi

  if cmp -s "$target_path" "$new_src"; then
    return 0
  fi

  if [ "$LEGACY_MODE" -eq 0 ] && [ -n "$old_src" ] && [ -f "$old_src" ] && cmp -s "$target_path" "$old_src"; then
    backup_file "$target_rel"
    copy_file "$new_src" "$target_path"
    log "updated: $target_path"
    return 0
  fi

  if [ "$FORCE" -eq 1 ]; then
    backup_file "$target_rel"
    copy_file "$new_src" "$target_path"
    log "updated: $target_path"
    return 0
  fi

  write_review_file "$target_rel" "$new_src"
}

confirm_force_update() {
  if [ "$FORCE" -eq 0 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  warn "--force enabled; locally edited template-managed files will be overwritten after backup."
  if [ ! -r /dev/tty ]; then
    die "--force requires an interactive terminal for confirmation"
  fi

  printf '[aaw] Continue? Type "yes" to proceed: ' > /dev/tty
  IFS= read -r answer < /dev/tty
  if [ "$answer" != "yes" ]; then
    die "update cancelled"
  fi
}

update_root_readme() {
  new_src="$RUNNER_ROOT/README.md"
  old_src=""
  target_path="$TARGET/README.md"

  [ -f "$new_src" ] || return 0
  [ -f "$target_path" ] || return 0

  if cmp -s "$target_path" "$new_src"; then
    return 0
  fi

  if [ -n "${OLD_SRC_ROOT:-}" ]; then
    old_src="$OLD_SRC_ROOT/README.md"
  fi

  if [ "$LEGACY_MODE" -eq 0 ] && [ -n "$old_src" ] && [ -f "$old_src" ] && cmp -s "$target_path" "$old_src"; then
    backup_file "README.md"
    copy_file "$new_src" "$target_path"
    log "updated: $target_path"
    return 0
  fi

  if grep -qxF "# Hekate" "$target_path" 2>/dev/null; then
    if [ "$FORCE" -eq 1 ]; then
      backup_file "README.md"
      copy_file "$new_src" "$target_path"
      log "updated: $target_path"
      return 0
    fi

    write_review_file "README.md" "$new_src"
  fi
}

write_state_file() {
  state_file="$TARGET/.workflow/state.yml"
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  install_ref="$REF"
  has_claude=0
  has_cursor=0
  has_codex=0

  if [ -n "$COMMIT" ]; then
    install_ref="$COMMIT"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would write install state: $state_file"
    return 0
  fi

  if [ -f "$state_file" ]; then
    backup_file ".workflow/state.yml"
  fi

  if project_has_claude_adapter; then
    has_claude=1
  fi
  if project_has_cursor_adapter; then
    has_cursor=1
  fi
  if project_has_codex_adapter; then
    has_codex=1
  fi

  mkdir -p "$(dirname "$state_file")"
  {
    printf 'install:\n'
    printf '  tool: hekate\n'
    printf '  installed_repo: %s\n' "$REPO"
    printf '  installed_ref: %s\n' "$install_ref"
    printf '  installed_at: %s\n' "$timestamp"
    printf '  adapters:\n'

    if [ "$has_claude" -eq 1 ]; then
      printf '    - claude\n'
    fi
    if [ "$has_cursor" -eq 1 ]; then
      printf '    - cursor\n'
    fi
    if [ "$has_codex" -eq 1 ]; then
      printf '    - codex\n'
    fi

    printf 'schema:\n'
    printf '  state_version: 2\n'
    if [ -s "$APPLIED_MIGRATIONS_FILE" ]; then
      printf '  applied_migrations:\n'
      while IFS= read -r migration_id || [ -n "$migration_id" ]; do
        [ -n "$migration_id" ] || continue
        printf '    - %s\n' "$migration_id"
      done < "$APPLIED_MIGRATIONS_FILE"
    else
      printf '  applied_migrations: []\n'
    fi
  } > "$state_file"

  log "updated: $state_file"
}

acquire_old_source() {
  if [ "$LEGACY_MODE" -eq 1 ]; then
    return 1
  fi

  if [ "$STATE_REPO" = "$REPO" ] && old_local_root="$(extract_local_git_ref "$RUNNER_ROOT" "$STATE_REF" old 2>/dev/null)"; then
    printf '%s\n' "$old_local_root"
    return 0
  fi

  extract_remote_repo "$STATE_REF" "$STATE_REPO" old
}

run_migrations() {
  for migration_script in "$RUNNER_ROOT"/migrations/*.sh; do
    [ -e "$migration_script" ] || continue

    migration_id="$(basename "$migration_script" .sh)"
    if grep -qxF "$migration_id" "$APPLIED_MIGRATIONS_FILE" 2>/dev/null; then
      log "skip migration: $migration_id"
      continue
    fi

    log "running migration: $migration_id"
    sh "$migration_script"
    append_unique_line "$APPLIED_MIGRATIONS_FILE" "$migration_id"
    log "applied migration: $migration_id"
  done
}

[ -d "$TARGET" ] || die "target dir does not exist: $TARGET"
[ -f "$TARGET/AGENTS.md" ] || die "target does not look like a workflow installation: $TARGET/AGENTS.md missing"
[ -f "$TARGET/.workflow/workflow.yml" ] || die "target does not look like a workflow installation: .workflow/workflow.yml missing"
[ -f "$TARGET/.workflow/presets.yml" ] || die "target does not look like a workflow installation: .workflow/presets.yml missing"
[ -d "$RUNNER_ROOT/templates" ] || die "runner source is incomplete: templates/ missing"

export TARGET REPO REF COMMIT DRY_RUN FORCE RUNNER_ROOT TMP_ROOT STATE_FILE BACKUP_ROOT BACKED_UP_LIST_FILE APPLIED_MIGRATIONS_FILE
: > "$BACKED_UP_LIST_FILE"
seed_applied_migrations_file "$STATE_FILE" "$APPLIED_MIGRATIONS_FILE"

if [ -f "$STATE_FILE" ]; then
  STATE_REPO="$(read_state_value installed_repo "$STATE_FILE")"
  STATE_REF="$(read_state_value installed_ref "$STATE_FILE")"
fi

if [ -z "$STATE_REPO" ]; then
  STATE_REPO="$REPO"
fi

if [ -z "$STATE_REF" ]; then
  LEGACY_MODE=1
  warn "state file missing or incomplete; running in legacy safe mode"
fi

OLD_TPL=""
if [ "$LEGACY_MODE" -eq 0 ]; then
  if OLD_SRC_ROOT="$(acquire_old_source)"; then
    OLD_TPL="$OLD_SRC_ROOT/templates"
  else
    LEGACY_MODE=1
    warn "could not load previously installed templates; falling back to legacy safe mode"
  fi
fi

log "target: $TARGET"
if [ -n "$COMMIT" ]; then
  log "updating to commit: $COMMIT"
else
  log "updating to ref: $REF"
fi
[ "$DRY_RUN" -eq 1 ] && log "DRY RUN — no files will be written"
confirm_force_update

append_gitignore "$RUNNER_ROOT/templates/gitignore.snippet"
run_migrations

update_template_file "AGENTS.md" "AGENTS.md"
update_root_readme
update_template_file ".workflow/bootstrap.md" ".workflow/bootstrap.md"
update_template_file ".workflow/README.md" ".workflow/README.md"
update_template_file ".workflow/orchestration.yml" ".workflow/orchestration.yml"
update_template_file ".workflow/bin/hekate-agent" ".workflow/bin/hekate-agent"
update_template_file ".workflow/bin/hekate-agent.ps1" ".workflow/bin/hekate-agent.ps1"
if [ "$DRY_RUN" -eq 0 ] && [ -f "$TARGET/.workflow/bin/hekate-agent" ]; then
  chmod +x "$TARGET/.workflow/bin/hekate-agent"
fi

if project_has_claude_adapter; then
  update_template_file "CLAUDE.md" "adapters/claude/CLAUDE.md"

  for command_file in "$RUNNER_ROOT"/templates/adapters/claude/commands/*.md; do
    [ -e "$command_file" ] || continue
    update_template_file ".claude/commands/$(basename "$command_file")" "adapters/claude/commands/$(basename "$command_file")"
  done
  for agent_file in "$RUNNER_ROOT"/templates/adapters/claude/agents/*.md; do
    [ -e "$agent_file" ] || continue
    update_template_file ".claude/agents/$(basename "$agent_file")" "adapters/claude/agents/$(basename "$agent_file")"
  done

  update_template_file ".claude/skills/workflow/SKILL.md" "adapters/claude/skills/workflow/SKILL.md"
fi

if project_has_cursor_adapter; then
  update_template_file ".cursor/rules/workflow.mdc" "adapters/cursor/.cursor/rules/workflow.mdc"
fi

write_state_file

cat <<EOF

─────────────────────────────────────────────────────────
 ai_agent_workflow update finished.

 Notes:
   - Pending migrations from the downloaded snapshot were applied in order.
   - Existing .workflow/*.yml values were preserved; migrations only changed known managed paths.
   - Local edits in template-managed files were left in place and, if needed, mirrored to <file>.new.
   - Backups of changed files are stored in .workflow/backups/.
─────────────────────────────────────────────────────────
EOF
