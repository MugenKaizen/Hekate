#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

if ! state_has_adapter cursor "$STATE_FILE" && ! state_has_adapter codex "$STATE_FILE"; then
  exit 0
fi

keep_claude=0
if state_has_adapter claude "$STATE_FILE" \
  || [ -f "$TARGET/CLAUDE.md" ] \
  || [ -f "$TARGET/.claude/commands/init-workflow.md" ]; then
  keep_claude=1
fi

for skill_template in "$RUNNER_ROOT"/templates/skills/*/SKILL.md; do
  [ -f "$skill_template" ] || continue
  skill_name="$(basename "$(dirname "$skill_template")")"
  legacy_rel=".claude/skills/$skill_name/SKILL.md"
  portable_rel=".agents/skills/$skill_name/SKILL.md"
  legacy_file="$TARGET/$legacy_rel"
  portable_file="$TARGET/$portable_rel"

  [ -f "$legacy_file" ] || continue

  if [ ! -e "$portable_file" ]; then
    copy_file "$legacy_file" "$portable_file"
    log "relocated skill: $legacy_file -> $portable_file"
  elif ! cmp -s "$legacy_file" "$portable_file"; then
    warn "portable skill differs; preserving legacy copy: $legacy_file"
    continue
  fi

  [ "$keep_claude" -eq 0 ] || continue
  backup_file "$legacy_rel"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "would remove relocated legacy skill: $legacy_file"
    continue
  fi

  rm "$legacy_file"
  rmdir "$TARGET/.claude/skills/$skill_name" 2>/dev/null || true
  rmdir "$TARGET/.claude/skills" 2>/dev/null || true
  rmdir "$TARGET/.claude" 2>/dev/null || true
  log "removed relocated legacy skill: $legacy_file"
done
