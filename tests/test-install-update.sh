#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
PROJECT="$TMP/project"
mkdir -p "$PROJECT"

# Fresh install contains executable runners, adapters, and migration state.
"$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --agents=claude >/dev/null
[ -x "$PROJECT/.workflow/bin/hekate-agent" ]
[ -f "$PROJECT/.workflow/bin/hekate-agent.ps1" ]
[ -f "$PROJECT/.claude/commands/harness.md" ]
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"

# Installer re-entry must not mark skipped migrations as applied.
if "$ROOT/install.sh" --source="$ROOT" --target="$PROJECT" --agents=claude >/dev/null 2>&1; then
  printf 'FAIL: installer re-entry was accepted\n' >&2
  exit 1
fi

# Simulate an installation that has migrations 001/002 but not 003.
awk '
  /^orchestration:$/ { drop=1; next }
  drop && /^  / { next }
  drop { drop=0 }
  /^  orchestration: \.workflow\/orchestration\.yml$/ { next }
  { print }
' "$PROJECT/.workflow/status.yml" > "$PROJECT/.workflow/status.yml.tmp"
mv "$PROJECT/.workflow/status.yml.tmp" "$PROJECT/.workflow/status.yml"
awk '$0 != "    - 003-add-cross-harness-orchestration" { print }' "$PROJECT/.workflow/state.yml" > "$PROJECT/.workflow/state.yml.tmp"
mv "$PROJECT/.workflow/state.yml.tmp" "$PROJECT/.workflow/state.yml"
rm -f "$PROJECT/.workflow/orchestration.yml" "$PROJECT/.workflow/bin/hekate-agent" "$PROJECT/.workflow/bin/hekate-agent.ps1" "$PROJECT/.claude/commands/harness.md" "$PROJECT/.claude/agents/harness-orchestrator.md"

sh "$ROOT/update-runner.sh" --target="$PROJECT" --ref=HEAD >/dev/null
[ -x "$PROJECT/.workflow/bin/hekate-agent" ]
grep -q '^orchestration:$' "$PROJECT/.workflow/status.yml"
grep -qxF '  orchestration: .workflow/orchestration.yml' "$PROJECT/.workflow/status.yml"
grep -qxF '    - 003-add-cross-harness-orchestration' "$PROJECT/.workflow/state.yml"

printf 'ok: install/update smoke tests passed\n'
