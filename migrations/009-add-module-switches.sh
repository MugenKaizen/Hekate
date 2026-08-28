#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

workflow_file="$TARGET/.workflow/workflow.yml"
status_file="$TARGET/.workflow/status.yml"
needs_workflow=0
needs_status=0

if [ -f "$workflow_file" ] && ! grep -q '^hekate:[[:space:]]*$' "$workflow_file"; then needs_workflow=1; fi
if [ -f "$status_file" ] && ! grep -q '^hekate:[[:space:]]*$' "$status_file"; then needs_status=1; fi
[ "$needs_workflow" -eq 1 ] || [ "$needs_status" -eq 1 ] || exit 0

[ "$needs_workflow" -eq 0 ] || backup_file ".workflow/workflow.yml"
[ "$needs_status" -eq 0 ] || backup_file ".workflow/status.yml"

if [ "$DRY_RUN" -eq 1 ]; then
  [ "$needs_workflow" -eq 0 ] || log "would add Hekate module switches to $workflow_file"
  [ "$needs_status" -eq 0 ] || log "would add Hekate module switches to $status_file"
  exit 0
fi

add_switches_before() {
  source_file="$1"
  anchor="$2"
  output_file="$3"
  awk -v anchor="$anchor" '
    $0 == anchor && !inserted {
      print "hekate:"
      print "  enabled: true"
      print "  modules:"
      print "    workflow: true"
      print "    history: true"
      print "    native_subagents: true"
      print "    orchestration: true"
      print ""
      inserted=1
    }
    { print }
    END {
      if (!inserted) {
        print ""
        print "hekate:"
        print "  enabled: true"
        print "  modules:"
        print "    workflow: true"
        print "    history: true"
        print "    native_subagents: true"
        print "    orchestration: true"
      }
    }
  ' "$source_file" > "$output_file"
  mv "$output_file" "$source_file"
}

if [ "$needs_workflow" -eq 1 ]; then
  add_switches_before "$workflow_file" "meta:" "$TMP_ROOT/workflow-module-switches.yml.tmp"
  log "updated: $workflow_file"
fi

if [ "$needs_status" -eq 1 ]; then
  add_switches_before "$status_file" "features:" "$TMP_ROOT/status-module-switches.yml.tmp"
  log "updated: $status_file"
fi
