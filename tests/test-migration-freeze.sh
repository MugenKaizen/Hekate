#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
EXPECTED='001-add-three-branch-model
002-add-status-index
003-add-cross-harness-orchestration
004-add-routing-profiles
005-add-session-subagent-policy
006-relocate-agent-skills
007-add-portable-adapters
008-add-lazy-load-docs
009-add-module-switches'

for extension in sh ps1; do
  actual="$(
    for migration in "$ROOT"/migrations/*."$extension"; do
      [ -e "$migration" ] || continue
      basename "$migration" ".$extension"
    done | sort
  )"
  if [ "$actual" != "$EXPECTED" ]; then
    printf 'FAIL: migrations/*.%s differs from the frozen legacy 001-009 set\n' "$extension" >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$EXPECTED" "$actual" >&2
    exit 1
  fi
done

# Released migration behavior is immutable, so the frozen set is pinned by
# content and not only by file name.
EXPECTED_DIGESTS='e4a8910cdd9e8bcdd7924b37ab2f9bbb5ba68a7e964a703ac658d7fc4e2c2dcb  001-add-three-branch-model.ps1
ce36c21e0b1ce2b45f91cfaae60cfbb2229df2ec640be9b72bb0ca60f820be8a  001-add-three-branch-model.sh
67aea4412a8f60bae3d34fc130ff1a0141a7a971cdb889d82733d95c2a54ac02  002-add-status-index.ps1
9cedb986bef0d6bc04cd8e2d786fb3effa9b5e6ad692f60c27716815885199b5  002-add-status-index.sh
8ad3f9f3dc2208268bfdc57c3dc29cba4b79979260dc36e6e79a744a36b6aea5  003-add-cross-harness-orchestration.ps1
53bf4452379eddc8a5f853e3e23a8f50bd77e9f104dc763b0ea6442a55ee19f8  003-add-cross-harness-orchestration.sh
bd973a8caa9df849c1cf0c05304f2ad460d883ae4804e975c6178b230ee1e56c  004-add-routing-profiles.ps1
f5b42bf8bbdace5194a537dbd611d9cdbc088445dc1b5282036bac9e4931f8b1  004-add-routing-profiles.sh
1afad28f956b425e1cfaf6910115f77657fb4605d1dee3a66cdf607a0c77caaa  005-add-session-subagent-policy.ps1
72bbe97b56aa59e3bda5948f2341ce0d9548063f35db2e37b546504a890c6e1c  005-add-session-subagent-policy.sh
e4234d13041d31937193544aaa46cbba5e62dc446669ddca61577b9198f27b50  006-relocate-agent-skills.ps1
26199424a8a88610ba095870cdc07f2293a1aad2349716b6945af90935957da6  006-relocate-agent-skills.sh
2dcc8a3f317d7437e1379802c3ab06e0011b8bb0c944367aa91ea740d5b67a59  007-add-portable-adapters.ps1
2c0969795bb0096044c4187be3aa0dc54ce50fd823fd235a44f290e6253861b2  007-add-portable-adapters.sh
9d098031d7b2dc93fc82318cb2df96dbd419e431014cb3522e604da4c74832be  008-add-lazy-load-docs.ps1
f47378fd5451394aeec750a115f9f98e14ce4149ec8011dddf2716fa8670e492  008-add-lazy-load-docs.sh
9ace8d5b160974c80a7791dac78920c7881850da5ddfd991499a9d4692a19b8f  009-add-module-switches.ps1
19b901c84c4274b67d6319e1640a143c6f389e91e63f89ecf576b8696dd4241e  009-add-module-switches.sh'

if command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1" | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1" | cut -d' ' -f1; }
else
  printf 'FAIL: no sha256 utility available to verify the frozen migrations\n' >&2
  exit 1
fi

ACTUAL_DIGESTS="$(
  for migration in "$ROOT"/migrations/*.sh "$ROOT"/migrations/*.ps1; do
    [ -e "$migration" ] || continue
    printf '%s  %s\n' "$(hash_file "$migration")" "$(basename "$migration")"
  done | sort -k2
)"

if [ "$ACTUAL_DIGESTS" != "$EXPECTED_DIGESTS" ]; then
  printf 'FAIL: frozen migration content changed\n' >&2
  printf 'Expected:\n%s\nActual:\n%s\n' "$EXPECTED_DIGESTS" "$ACTUAL_DIGESTS" >&2
  exit 1
fi

printf 'ok: legacy migration set is frozen\n'
