#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
AGENTS="$ROOT/templates/AGENTS.md"

for required in \
  '**Understand** every task' \
  '**Decide** only when' \
  '**Plan** when work is large' \
  '**Execute** without model-authored stage gates' \
  '**Verify** every implementation task' \
  'Never fall back automatically to an external harness'; do
  grep -qF "$required" "$AGENTS" || {
    printf 'FAIL: adaptive workflow contract is missing: %s\n' "$required" >&2
    exit 1
  }
done

NORMATIVE_FILES="
$ROOT/templates/AGENTS.md
$ROOT/templates/.workflow/workflow.yml
$ROOT/templates/.workflow/presets.yml
$ROOT/templates/.workflow/status.yml
$ROOT/templates/.workflow/bootstrap.md
$ROOT/templates/.workflow/README.md
$ROOT/templates/skills/workflow/SKILL.md
$ROOT/templates/adapters/claude/CLAUDE.md
$ROOT/templates/adapters/claude/commands/analyze.md
$ROOT/templates/adapters/claude/commands/plan.md
$ROOT/templates/adapters/claude/commands/init-workflow.md
$ROOT/templates/adapters/cursor/.cursor/rules/workflow.mdc
$ROOT/templates/adapters/copilot/.github/copilot-instructions.md
$ROOT/templates/adapters/gemini/GEMINI.md
"

for forbidden in \
  granular_commits \
  three_branch_model \
  create_during_bootstrap \
  require_options \
  require_plan \
  'mode: auto' \
  'events.jsonl'; do
  for file in $NORMATIVE_FILES; do
    if grep -qF "$forbidden" "$file"; then
      printf 'FAIL: active Phase 1 contract still contains %s in %s\n' "$forbidden" "$file" >&2
      exit 1
    fi
  done
done

grep -qxF '    mode: prefer-test-first # off | prefer-test-first | require-test-evidence' \
  "$ROOT/templates/.workflow/workflow.yml"
grep -qxF '    enabled: false' "$ROOT/templates/.workflow/workflow.yml"
grep -qxF '    consent: explicit-request-only' "$ROOT/templates/.workflow/workflow.yml"
if grep -qE '^(hekate:|policy:|active_preset:)' "$ROOT/templates/.workflow/status.yml"; then
  printf 'FAIL: status.yml contains duplicated authored policy\n' >&2
  exit 1
fi
grep -qF '| Advisory |' "$ROOT/docs/philosophy.md"
grep -qF 'Observable evidence' "$ROOT/docs/philosophy.md"
grep -qF 'Mechanically gated only by a supporting runtime' "$ROOT/docs/philosophy.md"

printf 'ok: Phase 1 adaptive semantics are consistent\n'
