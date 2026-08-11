#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

status_file="$TARGET/.workflow/status.yml"
[ -f "$status_file" ] || exit 0

needs_block=0
needs_lazy=0
grep -q '^orchestration:' "$status_file" || needs_block=1
grep -q '^  orchestration: \.workflow/orchestration\.yml$' "$status_file" || needs_lazy=1
[ "$needs_block" -eq 1 ] || [ "$needs_lazy" -eq 1 ] || exit 0

config_file="$TARGET/.workflow/orchestration.yml"
enabled=false
default_harness=pi
if [ -f "$config_file" ]; then
  value="$(awk '/^enabled:[[:space:]]*/{print $2;exit}' "$config_file")"
  [ "$value" = true ] || [ "$value" = false ] || value=false
  enabled="$value"
  value="$(awk '/^default_harness:[[:space:]]*/{print $2;exit}' "$config_file")"
  [ -z "$value" ] || default_harness="$value"
fi

backup_file ".workflow/status.yml"
if [ "$DRY_RUN" -eq 1 ]; then
  log "would add orchestration status/lazy-load fields to $status_file"
  exit 0
fi

tmp="$TMP_ROOT/status-orchestration.yml.tmp"
awk -v add_lazy="$needs_lazy" '
  { print }
  add_lazy == 1 && /^  bootstrap: \.workflow\/bootstrap\.md[[:space:]]*$/ {
    print "  orchestration: .workflow/orchestration.yml"
    add_lazy = 0
  }
  END {
    if (add_lazy == 1) {
      print ""
      print "lazy_load:"
      print "  orchestration: .workflow/orchestration.yml"
    }
  }
' "$status_file" > "$tmp"

if [ "$needs_block" -eq 1 ]; then
  cat >> "$tmp" <<EOF

orchestration:
  enabled: $enabled
  default_harness: $default_harness
  config: .workflow/orchestration.yml
  runner: .workflow/bin/hekate-agent
EOF
fi
mv "$tmp" "$status_file"
log "updated: $status_file"

if [ -f "$TARGET/.workflow/bin/hekate-agent" ]; then chmod +x "$TARGET/.workflow/bin/hekate-agent"; fi
