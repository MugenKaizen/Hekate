#!/usr/bin/env sh
# ai_agent_workflow installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MugenKaizen/Hekate/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --target=/path/to/proj --agents=claude,cursor,codex
#   bash install.sh --target=. --agents=claude --dry-run
#
# Flags:
#   --target=<path>     Root of the target project. Defaults to the current directory.
#   --agents=<list>     Which adapters to lay down. Comma-separated: claude,cursor,codex.
#                       Defaults to all.
#   --force             Overwrite existing files.
#   --dry-run           Show what would be done without making changes.
#   --source=<path>     Local copy of the repository (for installer development).
#   --ref=<git-ref>     Branch/tag to download. Defaults to main.
#   --repo=<owner/name> GitHub repository. Defaults to the built-in one.

set -eu

# --- defaults ------------------------------------------------------------
TARGET="$(pwd)"
AGENTS="claude,cursor,codex"
FORCE=0
DRY_RUN=0
SOURCE=""
REF="main"
REPO="${AAW_REPO:-MugenKaizen/Hekate}"

# --- args ----------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --target=*)  TARGET="${arg#--target=}" ;;
    --agents=*)  AGENTS="${arg#--agents=}" ;;
    --source=*)  SOURCE="${arg#--source=}" ;;
    --ref=*)     REF="${arg#--ref=}" ;;
    --repo=*)    REPO="${arg#--repo=}" ;;
    --force)     FORCE=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
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
    printf '  installed_ref: %s\n' "$REF"
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

do_copy() {
  # copy $1 -> $2 unless exists (or --force). Creates parent dirs.
  src="$1"
  dst="$2"
  if [ ! -e "$src" ]; then
    warn "source missing: $src"
    return 0
  fi
  if [ -e "$dst" ] && [ "$FORCE" -eq 0 ]; then
    log "skip (exists): $dst"
    return 0
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

# --- acquire source ------------------------------------------------------
CLEANUP_DIR=""
cleanup() {
  if [ -n "$CLEANUP_DIR" ] && [ -d "$CLEANUP_DIR" ]; then
    rm -rf "$CLEANUP_DIR"
  fi
}
trap cleanup EXIT INT TERM

if [ -n "$SOURCE" ]; then
  SRC_ROOT="$SOURCE"
  [ -d "$SRC_ROOT/templates" ] || die "--source does not look like ai_agent_workflow: $SRC_ROOT"
  log "using local source: $SRC_ROOT"
else
  TMP="$(mktemp -d)"
  CLEANUP_DIR="$TMP"
  TARBALL_URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"
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

log "target: $TARGET"
log "agents: $AGENTS"
[ "$DRY_RUN" -eq 1 ] && log "DRY RUN — no files will be written"

# --- core files ----------------------------------------------------------
do_copy "$TPL/AGENTS.md"             "$TARGET/AGENTS.md"
do_copy "$TPL/.workflow/stack.yml"        "$TARGET/.workflow/stack.yml"
do_copy "$TPL/.workflow/architecture.yml" "$TARGET/.workflow/architecture.yml"
do_copy "$TPL/.workflow/conventions.yml"  "$TARGET/.workflow/conventions.yml"
do_copy "$TPL/.workflow/workflow.yml"     "$TARGET/.workflow/workflow.yml"
do_copy "$TPL/.workflow/presets.yml"      "$TARGET/.workflow/presets.yml"
do_copy "$TPL/.workflow/status.yml"       "$TARGET/.workflow/status.yml"
do_copy "$TPL/.workflow/bootstrap.md"     "$TARGET/.workflow/bootstrap.md"
do_copy "$TPL/.workflow/README.md"        "$TARGET/.workflow/README.md"
do_copy "$TPL/.workflow/history/.gitkeep" "$TARGET/.workflow/history/.gitkeep"

# --- adapters ------------------------------------------------------------
if has_agent claude; then
  do_copy "$TPL/adapters/claude/CLAUDE.md" "$TARGET/CLAUDE.md"
  for f in "$TPL/adapters/claude/commands/"*.md; do
    [ -e "$f" ] || continue
    do_copy "$f" "$TARGET/.claude/commands/$(basename "$f")"
  done
  do_copy "$TPL/adapters/claude/skills/workflow/SKILL.md" \
          "$TARGET/.claude/skills/workflow/SKILL.md"
fi

if has_agent cursor; then
  do_copy "$TPL/adapters/cursor/.cursor/rules/workflow.mdc" \
          "$TARGET/.cursor/rules/workflow.mdc"
fi

if has_agent codex; then
  # Codex reads AGENTS.md directly — nothing needs to be copied.
  # The adapter README is kept only as reference (not copied into the project).
  :
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

  To update an existing installation later:
    curl -fsSL https://raw.githubusercontent.com/MugenKaizen/Hekate/main/update.sh \
      | sh -s -- --target=/path/to/project

 Until the required fields are filled in, the agent will NOT work — this is by design.
─────────────────────────────────────────────────────────
EOF
