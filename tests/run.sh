#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
sh -n "$ROOT/install.sh" "$ROOT/update.sh" "$ROOT/update-runner.sh" \
  "$ROOT/lib/update-common.sh" "$ROOT"/migrations/*.sh \
  "$ROOT/templates/.workflow/bin/hekate-agent" "$ROOT"/tests/*.sh
"$ROOT/tests/test-migration-freeze.sh"
"$ROOT/tests/test-phase1-semantics.sh"
"$ROOT/tests/test-ledger-parser.sh"
"$ROOT/tests/test-hekate-agent.sh"
"$ROOT/tests/test-install-update.sh"

# PowerShell coverage runs when pwsh or Windows PowerShell is available; it is
# not installed on every dev/CI box, so its
# absence is a clearly-labeled skip rather than a failure.
PS_EXE=""
if command -v pwsh >/dev/null 2>&1; then PS_EXE=pwsh
elif command -v powershell >/dev/null 2>&1; then PS_EXE=powershell
fi
if [ -n "$PS_EXE" ]; then
  sh "$ROOT/tests/test-wrapper-interop.sh" "$PS_EXE"
  "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tests/run.ps1"
else
  printf 'SKIPPED: PowerShell tests (tests/run.ps1) - no pwsh or powershell on PATH\n'
fi
