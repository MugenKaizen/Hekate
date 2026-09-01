#!/usr/bin/env sh
# Pins the migration-ledger parser (schema.applied_migrations in
# .workflow/state.yml) against real ledger content.
#
# The fixtures under tests/test-ledger-fixtures/ are shared with the
# PowerShell half of this suite (tests/test-update-common.ps1), so the POSIX
# and PowerShell readers are asserted against byte-identical input and the
# same *.expected results. Do not fork the fixtures.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
FIXTURES="$ROOT/tests/test-ledger-fixtures"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

. "$ROOT/lib/update-common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# IDs that must never be reported as applied by any fixture: they live in
# update-history entries, sibling keys, or malformed rows.
FORBIDDEN_IDS='not-a-migration leaked-history-entry deeper-not-an-item history ran_at 003-never-applied 002-add-status-index'

for fixture in \
  indented \
  same-indent \
  empty-list \
  missing-key \
  history-after-list \
  malformed
do
  state="$FIXTURES/$fixture.yml"
  expected="$FIXTURES/$fixture.expected"
  actual="$TMP/$fixture.actual"

  [ -f "$state" ] || fail "missing ledger fixture: $state"
  [ -f "$expected" ] || fail "missing expected output: $expected"

  seed_applied_migrations_file "$state" "$actual"
  cmp -s "$expected" "$actual" || {
    printf 'FAIL: ledger fixture %s parsed incorrectly\n' "$fixture" >&2
    printf '  expected: %s\n' "$(tr '\n' ' ' < "$expected")" >&2
    printf '  actual:   %s\n' "$(tr '\n' ' ' < "$actual")" >&2
    exit 1
  }

  # Every seeded ID must also answer true through the membership check, so an
  # already-recorded migration is never re-run.
  while IFS= read -r migration_id || [ -n "$migration_id" ]; do
    [ -n "$migration_id" ] || continue
    state_has_migration "$migration_id" "$state" \
      || fail "$fixture: state_has_migration did not find seeded ID $migration_id"
  done < "$expected"

  # Nothing outside the applied-migrations list may leak in.
  for forbidden in $FORBIDDEN_IDS; do
    if grep -qxF "$forbidden" "$expected"; then
      continue
    fi
    if state_has_migration "$forbidden" "$state"; then
      fail "$fixture: parser leaked unrelated entry $forbidden"
    fi
  done
done

# Regression guard for the same-indentation block sequence (audit finding G5).
# A ledger written as `  applied_migrations:` followed by `  - 001-...` is
# valid YAML; the previous indentation-sensitive scanner dropped every entry,
# which silently re-ran migrations that had already been applied.
SAME_INDENT_OUT="$TMP/same-indent-guard.txt"
seed_applied_migrations_file "$FIXTURES/same-indent.yml" "$SAME_INDENT_OUT"
[ -s "$SAME_INDENT_OUT" ] \
  || fail 'same-indentation ledger produced no migration IDs'
cmp -s "$FIXTURES/indented.expected" "$SAME_INDENT_OUT" \
  || fail 'same-indentation and indented ledgers disagree'

# A missing state file yields no migrations and no membership.
MISSING_STATE="$TMP/definitely-absent.yml"
MISSING_OUT="$TMP/missing.actual"
printf 'stale\n' > "$MISSING_OUT"
seed_applied_migrations_file "$MISSING_STATE" "$MISSING_OUT"
[ -f "$MISSING_OUT" ] || fail 'missing state file did not truncate the output file'
[ ! -s "$MISSING_OUT" ] || fail 'missing state file produced migration IDs'
if state_has_migration 001-add-three-branch-model "$MISSING_STATE"; then
  fail 'missing state file reported an applied migration'
fi

# An empty ID never matches.
if state_has_migration '' "$FIXTURES/indented.yml"; then
  fail 'empty migration ID matched the ledger'
fi

printf 'ok: migration-ledger parser tests passed\n'
