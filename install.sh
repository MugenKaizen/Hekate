#!/usr/bin/env sh
# ai_agent_workflow installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MugenKaizen/Hekate/<full-sha>/install.sh \
#     | sh -s -- --commit=<full-sha>
#   sh install.sh --source=. --target=/path/to/proj --agents=claude,cursor,codex
#   sh install.sh --source=. --target=. --agents=claude --dry-run
#
# Flags:
#   --target=<path>     Root of the target project. Defaults to the current directory.
#   --agents=<list>     Which adapters to lay down. Comma-separated:
#                       claude,cursor,codex,copilot,gemini,aider.
#                       Defaults to all.
#   --force             Overwrite existing files. Any pre-existing managed file
#                       is backed up first into .workflow/backups/<UTC-timestamp>/
#                       (same convention update-runner.sh uses). Prints a warning
#                       listing what will be overwritten and, on a TTY, asks for
#                       confirmation before writing anything.
#   --yes                Skip the --force confirmation prompt (required for
#                       non-interactive/piped invocations combined with --force).
#   --dry-run           Show what would be done (including what --force would
#                       back up/overwrite) without making changes.
#   --source=<path>     Local copy of the repository (for installer development).
#   --commit=<sha>      Full 40-character commit SHA. Required for downloads.
#   --ref=<git-ref>     Source revision metadata for local --source development.
#   --repo=<owner/name> GitHub repository. Defaults to the built-in one.

set -eu

# --- defaults ------------------------------------------------------------
TARGET="$(pwd)"
AGENTS="claude,cursor,codex,copilot,gemini,aider"
FORCE=0
YES=0
DRY_RUN=0
SOURCE=""
REF=""
COMMIT=""
REPO="${AAW_REPO:-MugenKaizen/Hekate}"

# --- args ----------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --target=*)  TARGET="${arg#--target=}" ;;
    --agents=*)  AGENTS="${arg#--agents=}" ;;
    --source=*)  SOURCE="${arg#--source=}" ;;
    --ref=*)     REF="${arg#--ref=}" ;;
    --commit=*)  COMMIT="${arg#--commit=}" ;;
    --repo=*)    REPO="${arg#--repo=}" ;;
    --force)     FORCE=1 ;;
    --yes)       YES=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# --- helpers -------------------------------------------------------------
log()  { printf '[aaw] %s\n' "$*"; }
warn() { printf '[aaw] WARN: %s\n' "$*" >&2; }
die()  { printf '[aaw] ERROR: %s\n' "$*" >&2; exit 1; }

write_state_file() {
  state_file="$TARGET/.workflow/state.yml"
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would write install state: $state_file"
    return 0
  fi

  mkdir -p "$(dirname "$state_file")"
  {
    printf 'install:\n'
    printf '  tool: hekate\n'
    printf '  installed_repo: %s\n' "$REPO"
    printf '  installed_ref: %s\n' "$INSTALLED_REV"
    printf '  installed_at: %s\n' "$timestamp"
    printf '  adapters:\n'

    old_ifs="$IFS"
    IFS=','
    set -- $AGENTS
    IFS="$old_ifs"

    for agent in "$@"; do
      [ -n "$agent" ] || continue
      printf '    - %s\n' "$agent"
    done

    printf 'schema:\n'
    printf '  state_version: 2\n'
    if [ -d "$SRC_ROOT/migrations" ] && ls "$SRC_ROOT/migrations/"*.sh >/dev/null 2>&1; then
      printf '  applied_migrations:\n'
      for migration_file in "$SRC_ROOT"/migrations/*.sh; do
        [ -e "$migration_file" ] || continue
        printf '    - %s\n' "$(basename "$migration_file" .sh)"
      done
    else
      printf '  applied_migrations: []\n'
    fi
  } > "$state_file"

  log "updated: $state_file"
}

# PLAN_MODE=1 makes do_copy only record its destination path (for a
# pre-flight --force overwrite/backup report) instead of touching anything.
PLAN_MODE=0
PLAN_FILE=""

do_copy() {
  # copy $1 -> $2 unless exists (or --force). Creates parent dirs. Existing
  # files are backed up first when --force is in effect (see backup_file in
  # lib/update-common.sh, sourced below — same convention update-runner.sh
  # uses: .workflow/backups/<UTC-timestamp>/<relative-path>).
  src="$1"
  dst="$2"

  if [ "$PLAN_MODE" -eq 1 ]; then
    [ -z "$PLAN_FILE" ] || printf '%s\n' "$dst" >> "$PLAN_FILE"
    return 0
  fi

  if [ ! -e "$src" ]; then
    warn "source missing: $src"
    return 0
  fi
  if [ -e "$dst" ]; then
    if [ "$FORCE" -eq 0 ]; then
      log "skip (exists): $dst"
      return 0
    fi
    dst_rel="$dst"
    case "$dst_rel" in
      "$TARGET"/*) dst_rel="${dst_rel#"$TARGET"/}" ;;
    esac
    backup_file "$dst_rel"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would copy: $src -> $dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
  log "copied: $dst"
}

append_gitignore() {
  snippet="$1"
  gi="$TARGET/.gitignore"
  [ -f "$snippet" ] || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would ensure .gitignore contains entries from $snippet"
    return 0
  fi

  [ -f "$gi" ] || : > "$gi"

  # append each line from snippet if not already present
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      \#*) # comment — add it if the snippet is not in the file at all
        grep -qF "# ai_agent_workflow" "$gi" || printf '\n%s\n' "$line" >> "$gi"
        ;;
      *)
        grep -qxF "$line" "$gi" || printf '%s\n' "$line" >> "$gi"
        ;;
    esac
  done < "$snippet"
  log "updated: $gi"
}

has_agent() {
  case ",$AGENTS," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

copy_skills_to() {
  skills_target="$1"
  for skill_dir in "$TPL/skills/"*/; do
    [ -e "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    do_copy "$skill_dir/SKILL.md" "$skills_target/$skill_name/SKILL.md"
  done
}

# --- acquire source ------------------------------------------------------
CLEANUP_DIR=""
INSTALL_TMP="$(mktemp -d)"
cleanup() {
  if [ -n "$CLEANUP_DIR" ] && [ -d "$CLEANUP_DIR" ]; then
    rm -rf "$CLEANUP_DIR"
  fi
  if [ -n "$INSTALL_TMP" ] && [ -d "$INSTALL_TMP" ]; then
    rm -rf "$INSTALL_TMP"
  fi
}
trap cleanup EXIT INT TERM

[ -z "$REF" ] || [ -z "$COMMIT" ] || die "use either --ref or --commit"
if [ -n "$COMMIT" ]; then
  printf '%s' "$COMMIT" | grep -Eq '^[0-9a-fA-F]{40}$' || die "--commit must be a full 40-character hexadecimal SHA"
fi

if [ -n "$SOURCE" ]; then
  INSTALLED_REV="${COMMIT:-${REF:-HEAD}}"
  SRC_ROOT="$SOURCE"
  [ -d "$SRC_ROOT/templates" ] || die "--source does not look like ai_agent_workflow: $SRC_ROOT"
  log "using local source: $SRC_ROOT"
else
  [ -n "$COMMIT" ] || die "remote installation requires --commit=<full-40-character-sha>"
  INSTALLED_REV="$COMMIT"
  TMP="$(mktemp -d)"
  CLEANUP_DIR="$TMP"
  TARBALL_URL="https://codeload.github.com/${REPO}/tar.gz/${COMMIT}"
  log "downloading $TARBALL_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$TARBALL_URL" -o "$TMP/src.tgz" || die "download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP/src.tgz" "$TARBALL_URL" || die "download failed"
  else
    die "need curl or wget"
  fi
  tar -xzf "$TMP/src.tgz" -C "$TMP"
  SRC_ROOT="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  [ -n "$SRC_ROOT" ] || die "could not locate extracted repo in $TMP"
fi

TPL="$SRC_ROOT/templates"
[ -d "$TPL" ] || die "templates dir missing: $TPL"
[ -d "$TARGET" ] || die "target dir does not exist: $TARGET"
if [ -f "$TARGET/.workflow/workflow.yml" ] && [ "$FORCE" -eq 0 ]; then
  die "Hekate is already installed in $TARGET; use update.sh (or rerun with --force to replace managed files)"
fi

# lib/update-common.sh provides backup_file/prune_old_backups so --force
# backs up pre-existing files the same way update-runner.sh does.
. "$SRC_ROOT/lib/update-common.sh"

BACKUP_ROOT="$TARGET/.workflow/backups"
RUN_TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_BACKUP_DIR="$BACKUP_ROOT/$RUN_TIMESTAMP"
BACKED_UP_LIST_FILE="$INSTALL_TMP/backed-up-files.txt"
PLAN_FILE="$INSTALL_TMP/planned-files.txt"
: > "$BACKED_UP_LIST_FILE"
: > "$PLAN_FILE"

log "target: $TARGET"
log "agents: $AGENTS"
[ "$DRY_RUN" -eq 1 ] && log "DRY RUN — no files will be written"

lay_down_files() {
  # --- core files ----------------------------------------------------------
  do_copy "$TPL/AGENTS.md"             "$TARGET/AGENTS.md"
  do_copy "$TPL/.workflow/stack.yml"        "$TARGET/.workflow/stack.yml"
  do_copy "$TPL/.workflow/architecture.yml" "$TARGET/.workflow/architecture.yml"
  do_copy "$TPL/.workflow/conventions.yml"  "$TARGET/.workflow/conventions.yml"
  do_copy "$TPL/.workflow/workflow.yml"     "$TARGET/.workflow/workflow.yml"
  do_copy "$TPL/.workflow/presets.yml"      "$TARGET/.workflow/presets.yml"
  do_copy "$TPL/.workflow/status.yml"       "$TARGET/.workflow/status.yml"
  do_copy "$TPL/.workflow/orchestration.yml" "$TARGET/.workflow/orchestration.yml"
  do_copy "$TPL/.workflow/session.local.yml" "$TARGET/.workflow/session.local.yml"
  do_copy "$TPL/.workflow/bootstrap.md"     "$TARGET/.workflow/bootstrap.md"
  do_copy "$TPL/.workflow/delegation.md"    "$TARGET/.workflow/delegation.md"
  do_copy "$TPL/.workflow/subagents.md"     "$TARGET/.workflow/subagents.md"
  do_copy "$TPL/.workflow/history-format.md" "$TARGET/.workflow/history-format.md"
  do_copy "$TPL/.workflow/README.md"        "$TARGET/.workflow/README.md"
  do_copy "$TPL/.workflow/bin/hekate-agent" "$TARGET/.workflow/bin/hekate-agent"
  do_copy "$TPL/.workflow/bin/hekate-agent.ps1" "$TARGET/.workflow/bin/hekate-agent.ps1"
  do_copy "$TPL/.workflow/history/.gitkeep" "$TARGET/.workflow/history/.gitkeep"

  # --- adapters ------------------------------------------------------------
  if has_agent claude; then
    do_copy "$TPL/adapters/claude/CLAUDE.md" "$TARGET/CLAUDE.md"
    for f in "$TPL/adapters/claude/commands/"*.md; do
      [ -e "$f" ] || continue
      do_copy "$f" "$TARGET/.claude/commands/$(basename "$f")"
    done
    for f in "$TPL/adapters/claude/agents/"*.md; do
      [ -e "$f" ] || continue
      do_copy "$f" "$TARGET/.claude/agents/$(basename "$f")"
    done
    copy_skills_to "$TARGET/.claude/skills"
  fi

  if has_agent cursor; then
    do_copy "$TPL/adapters/cursor/.cursor/rules/workflow.mdc" \
            "$TARGET/.cursor/rules/workflow.mdc"
  fi

  if has_agent codex; then
    # Codex reads AGENTS.md directly; shared skills are copied below.
    :
  fi

  if has_agent copilot; then
    do_copy "$TPL/adapters/copilot/.github/copilot-instructions.md" \
            "$TARGET/.github/copilot-instructions.md"
  fi

  if has_agent gemini; then
    do_copy "$TPL/adapters/gemini/GEMINI.md" "$TARGET/GEMINI.md"
  fi

  if has_agent aider; then
    do_copy "$TPL/adapters/aider/.aider.conf.yml" "$TARGET/.aider.conf.yml"
  fi

  if has_agent cursor || has_agent codex || has_agent copilot || has_agent gemini || has_agent aider; then
    copy_skills_to "$TARGET/.agents/skills"
  fi
}

if [ "$FORCE" -eq 1 ]; then
  PLAN_MODE=1
  lay_down_files
  PLAN_MODE=0

  OVERWRITE_COUNT=0
  OVERWRITE_LIST="$INSTALL_TMP/would-overwrite.txt"
  : > "$OVERWRITE_LIST"
  while IFS= read -r planned_dst; do
    [ -n "$planned_dst" ] || continue
    if [ -e "$planned_dst" ]; then
      printf '%s\n' "$planned_dst" >> "$OVERWRITE_LIST"
      OVERWRITE_COUNT=$((OVERWRITE_COUNT + 1))
    fi
  done < "$PLAN_FILE"

  if [ "$OVERWRITE_COUNT" -gt 0 ]; then
    warn "--force enabled; $OVERWRITE_COUNT existing file(s) will be overwritten (backed up first into $BACKUP_ROOT/$RUN_TIMESTAMP/):"
    while IFS= read -r overwrite_path; do
      printf '[aaw]   - %s\n' "$overwrite_path" >&2
    done < "$OVERWRITE_LIST"

    if [ "$DRY_RUN" -eq 0 ] && [ "$YES" -eq 0 ]; then
      # `[ -r /dev/tty ]` is not sufficient: the device node can be readable
      # while the process has no controlling terminal, in which case opening
      # it fails at redirect time with a raw shell error. Probe by opening.
      if ! { : < /dev/tty; } 2>/dev/null; then
        die "--force requires an interactive terminal for confirmation; pass --yes to skip the prompt in non-interactive invocations"
      fi
      printf '[aaw] Continue? Type "yes" to proceed: ' > /dev/tty
      IFS= read -r force_answer < /dev/tty
      if [ "$force_answer" != "yes" ]; then
        die "install cancelled"
      fi
    fi
  fi
fi

lay_down_files

if [ "$DRY_RUN" -eq 0 ]; then
  prune_old_backups 5
fi

if [ "$DRY_RUN" -eq 0 ] && [ -f "$TARGET/.workflow/bin/hekate-agent" ]; then
  chmod +x "$TARGET/.workflow/bin/hekate-agent"
fi

# --- gitignore -----------------------------------------------------------
append_gitignore "$TPL/gitignore.snippet"
write_state_file

# --- final message -------------------------------------------------------
cat <<EOF

─────────────────────────────────────────────────────────
 ai_agent_workflow installed.

 Next step:
    1. Open the project in your AI agent (Claude Code / Cursor / Codex / …).
    2. Ask: "initialize the workflow" (or /init-workflow in Claude).
    3. The agent will analyze the project, fill out .workflow/*.yml,
       and write .workflow/status.yml.

  To update later, choose a trusted full commit SHA and use the commit-pinned
  command from the Hekate README. Branches, tags, and short SHAs are rejected.

  On Windows PowerShell 5.1+:
    Use the matching commit-pinned update.ps1 command from the Hekate README.

 Until the required fields are filled in, the agent will NOT work — this is by design.
─────────────────────────────────────────────────────────
EOF
