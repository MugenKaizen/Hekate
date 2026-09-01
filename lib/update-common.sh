#!/usr/bin/env sh

log()  { printf '[hekate] %s\n' "$*"; }
warn() { printf '[hekate] WARN: %s\n' "$*" >&2; }
die()  { printf '[hekate] ERROR: %s\n' "$*" >&2; exit 1; }

read_state_value() {
  state_key="$1"
  state_file_path="$2"

  [ -f "$state_file_path" ] || return 0
  awk -F': ' -v key="$state_key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' "$state_file_path"
}

state_has_adapter() {
  adapter_name="$1"
  adapter_state_file="$2"

  [ -f "$adapter_state_file" ] || return 1
  grep -Eq "^[[:space:]]*-[[:space:]]*${adapter_name}$" "$adapter_state_file" 2>/dev/null
}

# Single reader for the migration ledger (schema.applied_migrations in
# .workflow/state.yml). Prints one migration ID per line, in file order.
#
# The ledger is a YAML block sequence. YAML permits the sequence items to sit
# either deeper than their key or at the *same* indentation as the key, and
# both forms must be read identically:
#
#   applied_migrations:        applied_migrations:
#     - 001-first              - 001-first
#
# List membership is therefore tracked by the indentation of the *items*, not
# by "deeper than the key". The list ends at the first non-comment, non-blank
# line that is either a mapping key (e.g. the `history:` sibling) or a
# sequence item at a different indentation, so entries belonging to any other
# key can never leak into the result. Only bare scalar IDs are emitted;
# anything else (notably the `- {ran_at: ...}` maps written by the historical
# ledger-contamination bug) is skipped without terminating the list.
#
# Keep byte-for-byte behavior in sync with Get-AawAppliedMigrations in
# lib/update-common.ps1: both must accept and reject exactly the same input.
applied_migrations_from_state() {
  migration_state_file="$1"

  [ -f "$migration_state_file" ] || return 0

  awk '
    function indentation(line, prefix) {
      prefix = line
      sub(/[^[:space:]].*$/, "", prefix)
      return length(prefix)
    }

    /^[[:space:]]*applied_migrations:[[:space:]]*\[\][[:space:]]*$/ {
      in_list = 0
      next
    }

    /^[[:space:]]*applied_migrations:[[:space:]]*$/ {
      in_list = 1
      key_indent = indentation($0)
      item_indent = -1
      next
    }

    !in_list { next }

    /^[[:space:]]*($|#)/ { next }

    /^[[:space:]]*-/ {
      line_indent = indentation($0)
      if (item_indent < 0) {
        # A dedented item cannot belong to this key.
        if (line_indent < key_indent) {
          in_list = 0
          next
        }
        item_indent = line_indent
      } else if (line_indent != item_indent) {
        in_list = 0
        next
      }

      entry = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", entry)
      sub(/[[:space:]]+$/, "", entry)
      if (entry ~ /^[[:alnum:]][[:alnum:]_.-]*$/) {
        print entry
      }
      next
    }

    # Any other content (a mapping key such as `history:`) ends the list.
    { in_list = 0 }
  ' "$migration_state_file"
}

state_has_migration() {
  migration_id="$1"
  migration_state_file="$2"

  [ -f "$migration_state_file" ] || return 1
  [ -n "$migration_id" ] || return 1

  applied_migrations_from_state "$migration_state_file" \
    | grep -qxF "$migration_id"
}

seed_applied_migrations_file() {
  migration_state_file="$1"
  migrations_output_file="$2"

  : > "$migrations_output_file"
  [ -f "$migration_state_file" ] || return 0

  applied_migrations_from_state "$migration_state_file" > "$migrations_output_file"
}

append_unique_line() {
  append_file="$1"
  append_value="$2"

  [ -f "$append_file" ] || : > "$append_file"
  if grep -qxF "$append_value" "$append_file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$append_value" >> "$append_file"
}

project_has_claude_adapter() {
  [ -f "$TARGET/CLAUDE.md" ] \
    || [ -f "$TARGET/.claude/commands/init-workflow.md" ] \
    || [ -f "$TARGET/.claude/skills/workflow/SKILL.md" ] \
    || state_has_adapter claude "$STATE_FILE"
}

project_has_cursor_adapter() {
  [ -f "$TARGET/.cursor/rules/workflow.mdc" ] || state_has_adapter cursor "$STATE_FILE"
}

project_has_codex_adapter() {
  state_has_adapter codex "$STATE_FILE"
}

project_has_copilot_adapter() {
  [ -f "$TARGET/.github/copilot-instructions.md" ] || state_has_adapter copilot "$STATE_FILE"
}

project_has_gemini_adapter() {
  [ -f "$TARGET/GEMINI.md" ] || state_has_adapter gemini "$STATE_FILE"
}

project_has_aider_adapter() {
  [ -f "$TARGET/.aider.conf.yml" ] || state_has_adapter aider "$STATE_FILE"
}

already_backed_up() {
  backup_rel="$1"

  [ -n "${BACKED_UP_LIST_FILE:-}" ] || return 1
  [ -f "$BACKED_UP_LIST_FILE" ] || return 1
  grep -qxF "$backup_rel" "$BACKED_UP_LIST_FILE" 2>/dev/null
}

mark_backed_up() {
  backup_rel="$1"

  [ -n "${BACKED_UP_LIST_FILE:-}" ] || return 0
  append_unique_line "$BACKED_UP_LIST_FILE" "$backup_rel"
}

backup_file() {
  backup_rel="$1"
  backup_src="$TARGET/$backup_rel"

  [ -e "$backup_src" ] || return 0
  if already_backed_up "$backup_rel"; then
    return 0
  fi

  # Prefer the current run's timestamped backup directory
  # (.workflow/backups/<UTC-timestamp>/<relative path>) when the calling
  # script has set one up via RUN_BACKUP_DIR. Falls back to the flat legacy
  # layout (.workflow/backups/<relative path>) so direct/standalone
  # invocations (e.g. running a single migration script by hand) still work.
  backup_root_for_run="${RUN_BACKUP_DIR:-$BACKUP_ROOT}"
  backup_dst="$backup_root_for_run/$backup_rel"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would back up: $backup_src -> $backup_dst"
    mark_backed_up "$backup_rel"
    return 0
  fi

  mkdir -p "$(dirname "$backup_dst")"
  cp -R "$backup_src" "$backup_dst"
  mark_backed_up "$backup_rel"
  log "backed up: $backup_dst"
}

# Keep only the most recent $1 (default 5) timestamped backup run
# directories under $BACKUP_ROOT. Directories that don't match the
# UTC-timestamp naming convention (e.g. pre-existing flat-layout backup
# files from older Hekate versions) are left untouched.
prune_old_backups() {
  keep="${1:-5}"

  [ -d "$BACKUP_ROOT" ] || return 0
  [ "${DRY_RUN:-0}" -eq 1 ] && return 0

  kept=0
  # shellcheck disable=SC2012
  for run_dir in $(ls -1 "$BACKUP_ROOT" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r); do
    kept=$((kept + 1))
    if [ "$kept" -gt "$keep" ]; then
      rm -rf "$BACKUP_ROOT/$run_dir"
      log "pruned old backup run: $BACKUP_ROOT/$run_dir"
    fi
  done
}

copy_file() {
  copy_src="$1"
  copy_dst="$2"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would copy: $copy_src -> $copy_dst"
    return 0
  fi

  mkdir -p "$(dirname "$copy_dst")"
  cp "$copy_src" "$copy_dst"
}

write_review_file() {
  review_rel="$1"
  review_src="$2"
  review_dst="$TARGET/$review_rel.new"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would write review copy: $review_dst"
    return 0
  fi

  mkdir -p "$(dirname "$review_dst")"
  cp "$review_src" "$review_dst"
  log "review required: $review_dst"
}

replace_file_if_changed() {
  replace_rel="$1"
  replace_src="$2"
  replace_dst="$TARGET/$replace_rel"

  if [ -f "$replace_dst" ] && cmp -s "$replace_src" "$replace_dst"; then
    return 0
  fi

  if [ -f "$replace_dst" ]; then
    backup_file "$replace_rel"
  fi

  copy_file "$replace_src" "$replace_dst"
  log "updated: $replace_dst"
}

append_gitignore() {
  snippet="$1"
  gi="$TARGET/.gitignore"
  changed=0

  [ -f "$snippet" ] || return 0
  [ -f "$gi" ] || {
    if [ "$DRY_RUN" -eq 1 ]; then
      log "would create: $gi"
    else
      : > "$gi"
      changed=1
    fi
  }

  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    if grep -qxF "$line" "$gi" 2>/dev/null; then
      continue
    fi

    if [ "$changed" -eq 0 ] && [ -f "$gi" ]; then
      backup_file ".gitignore"
      changed=1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "would append to .gitignore: $line"
    else
      printf '%s\n' "$line" >> "$gi"
    fi
  done < "$snippet"

  if [ "$changed" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    log "updated: $gi"
  fi
}

extract_remote_repo() {
  ref="$1"
  repo="$2"
  label="$3"
  dest="$TMP_ROOT/$label"
  tarball="$TMP_ROOT/$label.tgz"
  url="https://codeload.github.com/${repo}/tar.gz/${ref}"

  mkdir -p "$dest"
  log "downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tarball" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tarball" "$url" || return 1
  else
    die "need curl or wget"
  fi

  tar -xzf "$tarball" -C "$dest"
  find "$dest" -maxdepth 1 -mindepth 1 -type d | head -n1
}

extract_local_git_ref() {
  source_root="$1"
  ref="$2"
  label="$3"
  dest="$TMP_ROOT/$label"

  mkdir -p "$dest"
  command -v git >/dev/null 2>&1 || return 1
  [ -d "$source_root/.git" ] || return 1

  git -C "$source_root" archive "$ref" | tar -x -C "$dest" || return 1
  printf '%s\n' "$dest"
}
