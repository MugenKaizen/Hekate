#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
PS_EXE=${1:?PowerShell executable required}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

POSIX_PROJECT="$TMP/posix-created"
PS_PROJECT="$TMP/powershell-created"
mkdir -p "$POSIX_PROJECT" "$PS_PROJECT"

"$ROOT/install.sh" --source="$ROOT" --target="$POSIX_PROJECT" --agents=claude --ref=HEAD --legacy-workflow-files >/dev/null
printf 'meta:\n  project_name: posix-created\n  project_kind: cli\n' > "$POSIX_PROJECT/.workflow/stack.yml"
"$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/install.ps1" \
  -Source "$ROOT" -Target "$POSIX_PROJECT" -Agents claude -Ref HEAD -LegacyWorkflowFiles -Force -Yes >/dev/null
grep -qxF '  project_name: posix-created' "$POSIX_PROJECT/.workflow/stack.yml"
[ -f "$POSIX_PROJECT/.workflow/install-state.json" ]

"$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/install.ps1" \
  -Source "$ROOT" -Target "$PS_PROJECT" -Agents claude -Ref HEAD -LegacyWorkflowFiles >/dev/null
printf 'meta:\n  project_name: powershell-created\n  project_kind: cli\n' > "$PS_PROJECT/.workflow/stack.yml"
"$ROOT/install.sh" --source="$ROOT" --target="$PS_PROJECT" --agents=claude --ref=HEAD --legacy-workflow-files \
  --force --yes >/dev/null
grep -qxF '  project_name: powershell-created' "$PS_PROJECT/.workflow/stack.yml"
[ -f "$PS_PROJECT/.workflow/install-state.json" ]

printf 'ok: bidirectional wrapper interoperability tests passed\n'
