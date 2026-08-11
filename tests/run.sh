#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
sh -n "$ROOT/templates/.workflow/bin/hekate-agent" "$ROOT/tests/test-hekate-agent.sh" "$ROOT/tests/test-install-update.sh"
"$ROOT/tests/test-hekate-agent.sh"
"$ROOT/tests/test-install-update.sh"
