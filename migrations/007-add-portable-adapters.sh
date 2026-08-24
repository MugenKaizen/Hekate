#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

# Hekate now ships real adapters for GitHub Copilot, Gemini CLI, and Aider
# (copilot, gemini, aider), in addition to claude/cursor/codex. Existing
# installations opt into a new adapter simply by asking for it — either by
# re-running update.sh with --agents=copilot,gemini,aider (which the runner
# honors on the same run via has_requested_agent) or by hand-authoring the
# adapter's marker file before updating.
#
# This migration only backfills the .workflow/state.yml adapters ledger for
# marker files that already exist on disk (e.g. a project that hand-rolled
# its own GEMINI.md/.aider.conf.yml/.github/copilot-instructions.md before
# Hekate offered these adapters). It never creates files itself — that stays
# opt-in — and it never overwrites an adapter already recorded in state.

[ -f "$STATE_FILE" ] || exit 0

register_adapter_if_marker_present() {
  adapter_name="$1"
  marker_path="$2"

  [ -e "$marker_path" ] || return 0
  state_has_adapter "$adapter_name" "$STATE_FILE" && return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "would register adapter in state: $adapter_name"
    return 0
  fi

  backup_file ".workflow/state.yml"

  awk -v adapter="$adapter_name" '
    { print }
    /^[[:space:]]*adapters:[[:space:]]*$/ && !done {
      print "    - " adapter
      done = 1
    }
  ' "$STATE_FILE" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  log "registered adapter in state: $adapter_name"
}

register_adapter_if_marker_present copilot "$TARGET/.github/copilot-instructions.md"
register_adapter_if_marker_present gemini  "$TARGET/GEMINI.md"
register_adapter_if_marker_present aider   "$TARGET/.aider.conf.yml"
