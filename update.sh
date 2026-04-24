#!/usr/bin/env sh
# ai_agent_workflow update bootstrap
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MugenKaizen/Hekate/main/update.sh | sh
#   curl -fsSL .../update.sh | sh -s -- --target=/path/to/proj --ref=main
#   curl -fsSL .../update.sh | sh -s -- --target=/path/to/proj --commit=<sha>
#   curl -fsSL .../update.sh | sh -s -- --force
#
# Flags:
#   --target=<path>     Root of the target project. Defaults to the current directory.
#   --source=<path>     Local copy of the repository (for updater development).
#   --repo=<owner/name> GitHub repository. Defaults to the built-in one.
#   --ref=<git-ref>     Branch/tag to update to. Defaults to main.
#   --commit=<sha>      Exact commit to update to.
#   --force             Overwrite locally edited managed files after confirmation.
#   --dry-run           Show what would be done without making changes.

set -eu

TARGET="$(pwd)"
SOURCE=""
REPO="${AAW_REPO:-MugenKaizen/Hekate}"
REF="main"
COMMIT=""
DRY_RUN=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#--target=}" ;;
    --source=*) SOURCE="${arg#--source=}" ;;
    --repo=*)   REPO="${arg#--repo=}" ;;
    --ref=*)    REF="${arg#--ref=}" ;;
    --commit=*) COMMIT="${arg#--commit=}" ;;
    --dry-run)  DRY_RUN=1 ;;
    --force)    FORCE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      printf '[aaw] ERROR: unknown arg: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

log()  { printf '[aaw] %s\n' "$*"; }
die()  { printf '[aaw] ERROR: %s\n' "$*" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
cleanup() {
  if [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

REQUESTED_REV="$REF"
if [ -n "$COMMIT" ]; then
  REQUESTED_REV="$COMMIT"
fi

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

set -- "--target=$TARGET" "--repo=$REPO" "--ref=$REF"
if [ -n "$COMMIT" ]; then
  set -- "$@" "--commit=$COMMIT"
fi
if [ "$DRY_RUN" -eq 1 ]; then
  set -- "$@" "--dry-run"
fi
if [ "$FORCE" -eq 1 ]; then
  set -- "$@" "--force"
fi

log "starting update runner from snapshot"
exec sh "$RUNNER" "$@"
