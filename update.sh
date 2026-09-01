#!/usr/bin/env sh
# ai_agent_workflow update bootstrap
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MugenKaizen/Hekate/<full-sha>/update.sh \
#     | sh -s -- --target=/path/to/proj --commit=<full-sha>
#   sh update.sh --source=. --target=/path/to/proj
#
# Flags:
#   --target=<path>     Root of the target project. Defaults to the current directory.
#   --source=<path>     Local copy of the repository (for updater development).
#   --repo=<owner/name> GitHub repository. Defaults to the built-in one.
#   --ref=<git-ref>     Source revision metadata for local --source development.
#   --commit=<sha>      Full 40-character commit SHA. Required for downloads.
#   --agents=<list>     Comma-separated adapters to opt into on this update:
#                       claude,cursor,codex,copilot,gemini,aider.
#   --force             Overwrite locally edited managed files after confirmation.
#   --yes               Skip the --force confirmation prompt for non-interactive use.
#   --replace-unowned  Explicitly approve replacing unowned files during upgrade.
#   --dry-run           Show what would be done without making changes.
#   --rollback[=<run>]  Restore the most recent (or a named) backup run instead
#                       of updating. See update-runner.sh --help for details.

set -eu

TARGET="$(pwd)"
SOURCE=""
REPO="${HEKATE_REPO:-MugenKaizen/Hekate}"
REF=""
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
    --source=*) SOURCE="${arg#--source=}" ;;
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

log()  { printf '[hekate] %s\n' "$*"; }
die()  { printf '[hekate] ERROR: %s\n' "$*" >&2; exit 1; }

[ -z "$REF" ] || [ -z "$COMMIT" ] || die "use either --ref or --commit"
if [ -n "$COMMIT" ]; then
  printf '%s' "$COMMIT" | grep -Eq '^[0-9a-fA-F]{40}$' || die "--commit must be a full 40-character hexadecimal SHA"
fi
if [ -z "$SOURCE" ]; then
  [ -n "$COMMIT" ] || die "remote update requires --commit=<full-40-character-sha>"
fi

TMP_ROOT="$(mktemp -d)"
cleanup() {
  if [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

REQUESTED_REV="${COMMIT:-${REF:-HEAD}}"

if [ -n "$SOURCE" ]; then
  SNAPSHOT_ROOT="$SOURCE"
  [ -f "$SNAPSHOT_ROOT/update-runner.sh" ] || die "--source does not look like ai_agent_workflow: missing update-runner.sh"
  log "using local source: $SNAPSHOT_ROOT"
else
  SNAPSHOT_DIR="$TMP_ROOT/snapshot"
  SNAPSHOT_TARBALL="$TMP_ROOT/snapshot.tgz"
  SNAPSHOT_URL="https://codeload.github.com/${REPO}/tar.gz/${REQUESTED_REV}"

  mkdir -p "$SNAPSHOT_DIR"
  log "downloading $SNAPSHOT_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SNAPSHOT_URL" -o "$SNAPSHOT_TARBALL" || die "download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$SNAPSHOT_TARBALL" "$SNAPSHOT_URL" || die "download failed"
  else
    die "need curl or wget"
  fi

  tar -xzf "$SNAPSHOT_TARBALL" -C "$SNAPSHOT_DIR"
  SNAPSHOT_ROOT="$(find "$SNAPSHOT_DIR" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  [ -n "$SNAPSHOT_ROOT" ] || die "could not locate extracted repo in $SNAPSHOT_DIR"
fi

RUNNER="$SNAPSHOT_ROOT/update-runner.sh"
[ -f "$RUNNER" ] || die "update runner missing in downloaded snapshot"

if [ "$FORCE" -eq 1 ] && [ "$ROLLBACK" -eq 0 ]; then
  command -v node >/dev/null 2>&1 || die "transactional upgrade requires Node 20 or newer"
  node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' || die "transactional upgrade requires Node 20 or newer"
  runtime_root="$SNAPSHOT_ROOT/distribution/runtime"
  [ -f "$runtime_root/src/hekate-cli.mjs" ] || die "standalone transactional runtime is missing from the source snapshot"
  set -- upgrade "--to=$REQUESTED_REV" --force "--target=$TARGET" "--source=$SNAPSHOT_ROOT"
  [ -z "$AGENTS" ] || set -- "$@" "--adapters=$AGENTS"
  [ "$YES" -eq 0 ] || set -- "$@" --yes
  [ "$REPLACE_UNOWNED" -eq 0 ] || set -- "$@" --replace-unowned
  [ "$DRY_RUN" -eq 0 ] || set -- "$@" --dry-run
  log "starting transactional upgrade from snapshot"
  HEKATE_RECOVERY_RUNTIME_ROOT="$runtime_root" exec node "$runtime_root/src/hekate-cli.mjs" "$@"
fi

set -- "--target=$TARGET" "--repo=$REPO" "--ref=$REQUESTED_REV"
if [ -n "$COMMIT" ]; then
  set -- "$@" "--commit=$COMMIT"
fi
if [ -n "$AGENTS" ]; then
  set -- "$@" "--agents=$AGENTS"
fi
if [ "$DRY_RUN" -eq 1 ]; then
  set -- "$@" "--dry-run"
fi
if [ "$FORCE" -eq 1 ]; then
  set -- "$@" "--force"
fi
if [ "$REPLACE_UNOWNED" -eq 1 ]; then
  set -- "$@" "--replace-unowned"
fi
if [ "$ROLLBACK" -eq 1 ]; then
  if [ -n "$ROLLBACK_NAME" ]; then
    set -- "$@" "--rollback=$ROLLBACK_NAME"
  else
    set -- "$@" "--rollback"
  fi
fi

log "starting update runner from snapshot"
exec sh "$RUNNER" "$@"
