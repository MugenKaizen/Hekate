#!/usr/bin/env sh
# ai_agent_workflow update runner
#
# Flags:
#   --target=<path>     Root of the target project. Defaults to the current directory.
#   --repo=<owner/name> GitHub repository. Defaults to the built-in one.
#   --ref=<git-ref>     Source revision metadata. Defaults to HEAD.
#   --commit=<sha>      Exact commit to update to.
#   --agents=<list>     Comma-separated adapters to opt into on this update, in
#                       addition to any already detected in the project:
#                       claude,cursor,codex,copilot,gemini,aider. Lets an
#                       existing installation pick up a newly supported
#                       adapter without a full reinstall.
#   --force             Overwrite locally edited managed files after confirmation.
#   --yes               Skip the --force confirmation prompt for non-interactive use.
#   --replace-unowned  Explicitly approve replacing unowned files during upgrade.
#   --dry-run           Show what would be done without making changes.
#   --rollback           Restore the most recent backup run (.workflow/backups/<ts>/)
#                        over the current files. Refuses to act if no backup
#                        runs exist or the chosen run is empty.
#   --rollback=<run>     Restore a specific backup run by its timestamp
#                        directory name (e.g. 20260825T120000Z).
#
# Backups: every run that overwrites or removes a managed file first copies
# the original into .workflow/backups/<UTC-timestamp>/<relative-path>. Only
# the 5 most recent backup runs are retained; older ones are pruned
# automatically. Use --rollback to restore the most recent (or a named) run.

set -eu

TARGET="$(pwd)"
REPO="${HEKATE_REPO:-MugenKaizen/Hekate}"
REF="HEAD"
COMMIT=""
AGENTS=""
DRY_RUN=0
FORCE=0
YES=0
REPLACE_UNOWNED=0
ROLLBACK=0
ROLLBACK_NAME=""

for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#--target=}" ;;
    --repo=*)   REPO="${arg#--repo=}" ;;
    --ref=*)    REF="${arg#--ref=}" ;;
    --commit=*) COMMIT="${arg#--commit=}" ;;
    --agents=*) AGENTS="${arg#--agents=}" ;;
    --dry-run)  DRY_RUN=1 ;;
    --force)    FORCE=1 ;;
    --yes)      YES=1 ;;
    --replace-unowned) REPLACE_UNOWNED=1 ;;
    --rollback=*) ROLLBACK=1; ROLLBACK_NAME="${arg#--rollback=}" ;;
    --rollback) ROLLBACK=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      printf '[hekate] ERROR: unknown arg: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

RUNNER_ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
TMP_ROOT="$(mktemp -d)"
STATE_FILE="$TARGET/.workflow/state.yml"
BACKUP_ROOT="$TARGET/.workflow/backups"
RUN_TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_BACKUP_DIR="$BACKUP_ROOT/$RUN_TIMESTAMP"
BACKED_UP_LIST_FILE="$TMP_ROOT/backed-up-files.txt"
APPLIED_MIGRATIONS_FILE="$TMP_ROOT/applied-migrations.txt"
NEW_MIGRATIONS_FILE="$TMP_ROOT/newly-applied-migrations.txt"
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

has_requested_agent() {
  [ -n "$AGENTS" ] || return 1
  case ",$AGENTS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

do_rollback() {
  [ -d "$TARGET" ] || die "target dir does not exist: $TARGET"
  [ -d "$BACKUP_ROOT" ] || die "no backups available to roll back: $BACKUP_ROOT missing"

  if [ -n "$ROLLBACK_NAME" ]; then
    printf '%s' "$ROLLBACK_NAME" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' \
      || die "--rollback name must be a backup run timestamp like 20260825T120000Z"
    chosen="$ROLLBACK_NAME"
  else
    # shellcheck disable=SC2012
    chosen="$(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r | head -n1)"
  fi
  [ -n "$chosen" ] || die "no backup runs found under $BACKUP_ROOT"

  chosen_dir="$BACKUP_ROOT/$chosen"
  [ -d "$chosen_dir" ] || die "backup run not found: $chosen_dir"

  file_count="$(find "$chosen_dir" -type f | wc -l | tr -d ' ')"
  [ "$file_count" -gt 0 ] || die "backup run is empty; nothing to restore: $chosen_dir"

  log "rolling back using backup run: $chosen ($file_count file(s))"
  [ "$DRY_RUN" -eq 1 ] && log "DRY RUN — no files will be restored"

  find "$chosen_dir" -type f > "$TMP_ROOT/rollback-files.txt"
  while IFS= read -r backed_up_file; do
    [ -n "$backed_up_file" ] || continue
    rel="${backed_up_file#"$chosen_dir"/}"
    dest="$TARGET/$rel"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "would restore: $dest"
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    cp -R "$backed_up_file" "$dest"
    log "restored: $dest"
  done < "$TMP_ROOT/rollback-files.txt"

  if [ "$DRY_RUN" -eq 0 ]; then
    log "rollback complete using backup run: $chosen"
    log "note: this restores files captured in that run, including .workflow/state.yml if it was backed up, which reverts the applied-migrations ledger and installed_ref to their prior values."
  fi
}

update_template_file() {
  target_rel="$1"
  template_rel="$2"
  old_template_rel="${3:-$template_rel}"
  new_src="$RUNNER_ROOT/templates/$template_rel"
  old_src=""
  target_path="$TARGET/$target_rel"

  if [ -n "$OLD_TPL" ]; then
    old_src="$OLD_TPL/$old_template_rel"
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

update_skills_to() {
  skills_target="$1"
  for skill_file in "$RUNNER_ROOT"/templates/skills/*/SKILL.md; do
    [ -e "$skill_file" ] || continue
    skill_name="$(basename "$(dirname "$skill_file")")"
    [ "$skill_name" = "workflow" ] || continue
    update_template_file "$skills_target/$skill_name/SKILL.md" "skills/$skill_name/SKILL.md" "adapters/claude/skills/$skill_name/SKILL.md"
  done
}

confirm_force_update() {
  if [ "$FORCE" -eq 0 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  warn "--force enabled; locally edited template-managed files will be overwritten after backup."
  if [ ! -r /dev/tty ]; then
    die "--force requires an interactive terminal for confirmation"
  fi

  printf '[hekate] Continue? Type "yes" to proceed: ' > /dev/tty
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
  has_copilot=0
  has_gemini=0
  has_aider=0
  from_ref="${STATE_REF:-unknown}"

  if [ -n "$COMMIT" ]; then
    install_ref="$COMMIT"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would write install state: $state_file"
    return 0
  fi

  # Preserve up to the 4 most recent prior history entries (single-line flow
  # mappings) so this run's entry keeps a bounded rolling window of 5.
  old_history_lines=""
  if [ -f "$state_file" ]; then
    old_history_lines="$(grep '^    - {' "$state_file" 2>/dev/null | tail -n 4 || true)"
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
  if project_has_copilot_adapter; then
    has_copilot=1
  fi
  if project_has_gemini_adapter; then
    has_gemini=1
  fi
  if project_has_aider_adapter; then
    has_aider=1
  fi

  backup_dir_field="null"
  if [ -d "$RUN_BACKUP_DIR" ]; then
    backup_dir_field="\".workflow/backups/$RUN_TIMESTAMP\""
  fi

  migrations_applied_field="[]"
  if [ -s "$NEW_MIGRATIONS_FILE" ]; then
    migrations_applied_field="$(awk '{ printf "%s%s", sep, $0; sep = ", " } END { print "" }' "$NEW_MIGRATIONS_FILE")"
    migrations_applied_field="[$migrations_applied_field]"
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
    if [ "$has_copilot" -eq 1 ]; then
      printf '    - copilot\n'
    fi
    if [ "$has_gemini" -eq 1 ]; then
      printf '    - gemini\n'
    fi
    if [ "$has_aider" -eq 1 ]; then
      printf '    - aider\n'
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

    printf '  history:\n'
    if [ -n "$old_history_lines" ]; then
      printf '%s\n' "$old_history_lines"
    fi
    printf '    - {ran_at: "%s", from_ref: "%s", to_ref: "%s", backup_dir: %s, migrations_applied: %s}\n' \
      "$timestamp" "$from_ref" "$install_ref" "$backup_dir_field" "$migrations_applied_field"
  } > "$state_file.tmp.$$"
  # An interrupted in-place write truncates the ledger and loses both the
  # applied migration list and installed_ref, so the file is replaced atomically.
  mv -f "$state_file.tmp.$$" "$state_file"

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
    append_unique_line "$NEW_MIGRATIONS_FILE" "$migration_id"
    log "applied migration: $migration_id"
  done
}

[ -d "$TARGET" ] || die "target dir does not exist: $TARGET"

export TARGET REPO REF COMMIT DRY_RUN FORCE AGENTS RUNNER_ROOT TMP_ROOT STATE_FILE BACKUP_ROOT \
  RUN_TIMESTAMP RUN_BACKUP_DIR BACKED_UP_LIST_FILE APPLIED_MIGRATIONS_FILE NEW_MIGRATIONS_FILE
: > "$BACKED_UP_LIST_FILE"
: > "$NEW_MIGRATIONS_FILE"

if [ "$ROLLBACK" -eq 1 ]; then
  do_rollback
  exit 0
fi

# The frozen legacy path operates on the legacy managed files; the transactional
# --force path reconciles either contract layout and must not demand them.
if [ "$FORCE" -eq 1 ]; then
  if [ ! -f "$TARGET/.workflow/install-state.json" ] && [ ! -f "$TARGET/.workflow/config.yml" ] \
    && [ ! -f "$TARGET/.workflow/workflow.yml" ] && [ ! -f "$TARGET/.workflow/presets.yml" ]; then
    die "target does not look like a Hekate installation: no .workflow/install-state.json, config.yml, workflow.yml, or presets.yml"
  fi
else
  if [ -f "$TARGET/.workflow/install-state.json" ] || [ -f "$TARGET/.workflow/config.yml" ]; then
    if [ ! -f "$TARGET/.workflow/workflow.yml" ] || [ ! -f "$TARGET/.workflow/presets.yml" ]; then
      die "target uses the v1 contract layout; rerun with --force to update it transactionally"
    fi
  fi
  [ -f "$TARGET/AGENTS.md" ] || die "target does not look like a workflow installation: $TARGET/AGENTS.md missing"
  [ -f "$TARGET/.workflow/workflow.yml" ] || die "target does not look like a workflow installation: .workflow/workflow.yml missing"
  [ -f "$TARGET/.workflow/presets.yml" ] || die "target does not look like a workflow installation: .workflow/presets.yml missing"
fi
[ -d "$RUNNER_ROOT/templates" ] || die "runner source is incomplete: templates/ missing"

if [ "$FORCE" -eq 1 ]; then
  command -v node >/dev/null 2>&1 || die "transactional upgrade requires Node 20 or newer"
  node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' || die "transactional upgrade requires Node 20 or newer"
  runtime_root="$RUNNER_ROOT/distribution/runtime"
  [ -f "$runtime_root/src/hekate-cli.mjs" ] || die "standalone transactional runtime is missing from the source snapshot"
  TARGET_RELEASE="${COMMIT:-$REF}"
  set -- upgrade "--to=$TARGET_RELEASE" --force "--target=$TARGET" "--source=$RUNNER_ROOT"
  [ -z "$AGENTS" ] || set -- "$@" "--adapters=$AGENTS"
  [ "$YES" -eq 0 ] || set -- "$@" --yes
  [ "$REPLACE_UNOWNED" -eq 0 ] || set -- "$@" --replace-unowned
  [ "$DRY_RUN" -eq 0 ] || set -- "$@" --dry-run
  rm -rf "$TMP_ROOT"
  HEKATE_RECOVERY_RUNTIME_ROOT="$runtime_root" exec node "$runtime_root/src/hekate-cli.mjs" "$@"
fi

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
update_template_file ".workflow/history-format.md" ".workflow/history-format.md"
update_template_file ".workflow/README.md" ".workflow/README.md"
[ ! -e "$TARGET/.workflow/delegation.md" ] || update_template_file ".workflow/delegation.md" ".workflow/delegation.md"
[ ! -e "$TARGET/.workflow/subagents.md" ] || update_template_file ".workflow/subagents.md" ".workflow/subagents.md"
[ ! -e "$TARGET/.workflow/orchestration.yml" ] || update_template_file ".workflow/orchestration.yml" ".workflow/orchestration.yml"
[ ! -e "$TARGET/.workflow/bin/hekate-agent" ] || update_template_file ".workflow/bin/hekate-agent" ".workflow/bin/hekate-agent"
[ ! -e "$TARGET/.workflow/bin/hekate-agent.ps1" ] || update_template_file ".workflow/bin/hekate-agent.ps1" ".workflow/bin/hekate-agent.ps1"
if [ "$DRY_RUN" -eq 0 ] && [ -f "$TARGET/.workflow/bin/hekate-agent" ]; then
  chmod +x "$TARGET/.workflow/bin/hekate-agent"
fi

if project_has_claude_adapter; then
  update_template_file "CLAUDE.md" "adapters/claude/CLAUDE.md"

  for command_file in "$RUNNER_ROOT"/templates/adapters/claude/commands/*.md; do
    [ -e "$command_file" ] || continue
    if [ "$(basename "$command_file")" = "harness.md" ] \
      && [ ! -e "$TARGET/.claude/commands/harness.md" ]; then
      continue
    fi
    update_template_file ".claude/commands/$(basename "$command_file")" "adapters/claude/commands/$(basename "$command_file")"
  done
  for agent_file in "$RUNNER_ROOT"/templates/adapters/claude/agents/*.md; do
    [ -e "$agent_file" ] || continue
    [ -e "$TARGET/.claude/agents/$(basename "$agent_file")" ] || continue
    update_template_file ".claude/agents/$(basename "$agent_file")" "adapters/claude/agents/$(basename "$agent_file")"
  done

  update_skills_to ".claude/skills"
fi

if project_has_cursor_adapter; then
  update_template_file ".cursor/rules/workflow.mdc" "adapters/cursor/.cursor/rules/workflow.mdc"
fi

if project_has_copilot_adapter || has_requested_agent copilot; then
  update_template_file ".github/copilot-instructions.md" "adapters/copilot/.github/copilot-instructions.md"
fi

if project_has_gemini_adapter || has_requested_agent gemini; then
  update_template_file "GEMINI.md" "adapters/gemini/GEMINI.md"
fi

if project_has_aider_adapter || has_requested_agent aider; then
  update_template_file ".aider.conf.yml" "adapters/aider/.aider.conf.yml"
fi

if project_has_cursor_adapter || project_has_codex_adapter \
  || project_has_copilot_adapter || project_has_gemini_adapter || project_has_aider_adapter \
  || has_requested_agent copilot || has_requested_agent gemini || has_requested_agent aider; then
  update_skills_to ".agents/skills"
fi

write_state_file
prune_old_backups 5

cat <<EOF

─────────────────────────────────────────────────────────
 ai_agent_workflow update finished.

 Notes:
   - Pending migrations from the downloaded snapshot were applied in order.
   - Existing .workflow/*.yml values were preserved; migrations only changed known managed paths.
   - Local edits in template-managed files were left in place and, if needed, mirrored to <file>.new.
   - Backups of changed files are stored in .workflow/backups/<UTC-timestamp>/ (last 5 runs kept).
   - Use --rollback (optionally --rollback=<timestamp>) to restore a backup run.
─────────────────────────────────────────────────────────
EOF
