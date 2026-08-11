#!/usr/bin/env sh
set -eu

RUNNER_ROOT="${RUNNER_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$RUNNER_ROOT/lib/update-common.sh"

config_file="$TARGET/.workflow/orchestration.yml"
status_file="$TARGET/.workflow/status.yml"
config_exists=0
needs_schema=0
needs_default=0
needs_profiles=0
needs_status=0
if [ -f "$config_file" ]; then
  config_exists=1
  schema_value="$(awk '/^schema_version:[[:space:]]*/{v=$0;sub(/^schema_version:[[:space:]]*/,"",v);sub(/[[:space:]]+#.*/,"",v);sub(/[[:space:]]+$/, "", v);print v;exit}' "$config_file")"
  case "$schema_value" in ''|0|1) needs_schema=1 ;; *) : ;; esac
  grep -q '^default_profile:' "$config_file" || needs_default=1
  grep -q '^profiles:[[:space:]]*$' "$config_file" || needs_profiles=1
fi
if [ -f "$status_file" ] && ! awk '
  /^orchestration:[[:space:]]*$/ { inside=1; next }
  inside && /^[^[:space:]]/ { exit }
  inside && /^  default_profile:/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$status_file"; then needs_status=1; fi

[ "$needs_schema" -eq 1 ] || [ "$needs_default" -eq 1 ] || [ "$needs_profiles" -eq 1 ] || [ "$needs_status" -eq 1 ] || exit 0

[ "$config_exists" -eq 0 ] || backup_file ".workflow/orchestration.yml"
[ "$needs_status" -eq 0 ] || backup_file ".workflow/status.yml"
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$needs_schema" -eq 1 ] || [ "$needs_default" -eq 1 ] || [ "$needs_profiles" -eq 1 ]; then log "would add schema v2 routing-profile fields to $config_file"; fi
  [ "$needs_status" -eq 0 ] || log "would mirror default_profile into $status_file"
  exit 0
fi

if [ "$needs_schema" -eq 1 ] || [ "$needs_default" -eq 1 ] || [ "$needs_profiles" -eq 1 ]; then
  tmp="$TMP_ROOT/orchestration-profiles.yml.tmp"
  awk -v add_schema="$needs_schema" -v add_default="$needs_default" -v add_profiles="$needs_profiles" '
    BEGIN { schema_done=0; default_done=0; profiles_done=0 }
    /^schema_version:[[:space:]]*/ && add_schema == 1 && schema_done == 0 {
      print "schema_version: 2"; schema_done=1; next
    }
    {
      if (/^harnesses:[[:space:]]*$/ && add_profiles == 1 && profiles_done == 0) {
        print "profiles:"
        print ""
        profiles_done=1
      }
      print
      if (/^default_harness:/ && add_default == 1 && default_done == 0) {
        print "default_profile: null"
        default_done=1
      }
    }
    END {
      if (add_schema == 1 && schema_done == 0) print "schema_version: 2"
      if (add_default == 1 && default_done == 0) print "default_profile: null"
      if (add_profiles == 1 && profiles_done == 0) print "profiles:"
    }
  ' "$config_file" > "$tmp"
  mv "$tmp" "$config_file"
  log "updated: $config_file"
fi

if [ "$needs_status" -eq 1 ]; then
  profile=null
  if [ -f "$config_file" ]; then
    value="$(awk '/^default_profile:[[:space:]]*/{print $2;exit}' "$config_file")"
    [ -z "$value" ] || profile="$value"
  fi
  tmp="$TMP_ROOT/status-profile.yml.tmp"
  awk -v profile="$profile" '
    /^orchestration:[[:space:]]*$/ { inside=1; print; next }
    inside && /^[^[:space:]]/ {
      if (!inserted) { print "  default_profile: " profile; inserted=1 }
      inside=0
    }
    { print }
    inside && !inserted && /^  default_harness:/ { print "  default_profile: " profile; inserted=1 }
    END { if (inside && !inserted) print "  default_profile: " profile }
  ' "$status_file" > "$tmp"
  mv "$tmp" "$status_file"
  log "updated: $status_file"
fi
