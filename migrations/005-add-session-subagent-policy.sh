#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

policy_file="$TARGET/.workflow/session.local.yml"
status_file="$TARGET/.workflow/status.yml"
needs_policy=0
needs_status=0
[ -e "$policy_file" ] || needs_policy=1
if [ -f "$status_file" ] && ! grep -q '^native_subagents:[[:space:]]*$' "$status_file"; then needs_status=1; fi
[ "$needs_policy" -eq 1 ] || [ "$needs_status" -eq 1 ] || exit 0

[ "$needs_status" -eq 0 ] || backup_file ".workflow/status.yml"
if [ "$DRY_RUN" -eq 1 ]; then
  [ "$needs_policy" -eq 0 ] || log "would create local native-subagent policy: $policy_file"
  [ "$needs_status" -eq 0 ] || log "would add native-subagent policy pointer to $status_file"
  exit 0
fi

if [ "$needs_policy" -eq 1 ]; then
  mkdir -p "$TARGET/.workflow"
  tmp="$TMP_ROOT/session-subagent-policy.yml.tmp"
  cat > "$tmp" <<'EOF'
# Local policy for native subagents in the current user-facing harness session.
# This file is gitignored. The user may change the mode at any time.
# Missing/invalid mode is treated as `ask`.

schema_version: 1

subagents:
  # off  — never launch native subagents
  # ask  — ask once before each exact delegation wave (safe default)
  # auto — the primary harness may launch native subagents at its discretion
  mode: ask
EOF
  mv "$tmp" "$policy_file"
  log "created: $policy_file"
fi

if [ "$needs_status" -eq 1 ]; then
  tmp="$TMP_ROOT/status-native-subagents.yml.tmp"
  awk '
    /^lazy_load:[[:space:]]*$/ && !inserted {
      print "native_subagents:"
      print "  policy: .workflow/session.local.yml"
      print "  missing_or_invalid_mode: ask"
      print ""
      inserted=1
    }
    { print }
    END {
      if (!inserted) {
        print ""
        print "native_subagents:"
        print "  policy: .workflow/session.local.yml"
        print "  missing_or_invalid_mode: ask"
      }
    }
  ' "$status_file" > "$tmp"
  mv "$tmp" "$status_file"
  log "updated: $status_file"
fi
