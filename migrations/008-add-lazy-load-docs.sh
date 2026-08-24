#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

# AGENTS.md was restructured to lazy-load detail out of three new files:
# .workflow/delegation.md, .workflow/subagents.md, .workflow/history-format.md.
# Existing installations updated in place would otherwise end up with a new
# AGENTS.md that references files they don't have yet. Add them if missing;
# never overwrite a file that's already there (a later ordinary update run
# will keep it in sync via update_template_file once it exists).

add_if_missing() {
  rel="$1"
  src="$RUNNER_ROOT/templates/$rel"
  dst="$TARGET/$rel"

  [ -f "$src" ] || return 0
  [ -e "$dst" ] && return 0

  copy_file "$src" "$dst"
  log "added: $dst"
}

add_if_missing ".workflow/delegation.md"
add_if_missing ".workflow/subagents.md"
add_if_missing ".workflow/history-format.md"
