# Distribution Contract

Phase 3 distribution includes a shared ownership model, private transaction
preparation, and delegation from legacy shell and PowerShell forced-upgrade
paths to the transactional CLI.

## Canonical Manifest

`distribution/install-manifest.json` is the authoritative v1 asset inventory.
Every asset has a stable ID, component, source and destination, ownership
class, update and removal strategies, and mode. Components derive from the
selected adapters; unknown adapters and case-insensitive destination collisions
are rejected.

The manifest distinguishes content ownership from filename presence. In
particular, an existing adapter file is not Hekate-owned unless structured
installed state records that asset.

## Installed State

The target ownership ledger is `.workflow/install-state.json`, validated by
`packages/core/schemas/install-state.schema.json`. It records the manifest and
source release, selected components and adapters, and source/destination hashes
for each installed asset.

Legacy `.workflow/state.yml` remains compatibility input. It is not accepted as
v1 ownership proof.

## Planning

`planInstallation()` validates the manifest and optional installed state,
resolves selected components, rejects unsafe managed paths and classifies each
asset without writing files. A modified template with recorded provenance is a
`replace`; the same filename without provenance is only a
`replace-candidate`. Project and local seeds remain `preserve`.

`resolveInstallationOperations()` converts a diagnostic-free plan into a
canonical operation journal, exact staged byte map, and manifest-derived mode
map. Template sources are re-read with symlink protection and must still match
the planned hash. Replacement candidates require an explicit asset approval;
structured merges, typed project-seed migrations, and generated assets require
explicit resolved bytes. Local seeds and user-owned assets cannot be resolved
into mutations.

Adapter selection is desired-state reconciliation. Assets recorded in the
installed state but belonging to a now-unselected component are included in
the plan. `remove-if-unmodified` and `remove-if-generated` become deletes only
when the live bytes still match the recorded destination hash; otherwise they
are preserved. `remove-contribution` requires explicit merged bytes and never
deletes a shared file wholesale. Unrecorded assets are never removal targets.

## Journals

Operation journals use `packages/core/schemas/journal.schema.json` and canonical
JSON. `createOperationJournal()` enforces safe unique paths, operation-specific
hash and backup requirements, and rejects wholesale replacement or deletion of
protected ownership classes.

## Transaction Preparation

For a mutating CLI upgrade, `.workflow/update.lock` is acquired before installed
state discovery and held through planning, confirmation, preparation, apply,
and post-apply verification. This serializes the complete operation rather than
only its write phases. Dry runs remain byte-neutral and do not acquire the lock.
`prepareOperationTransaction()` verifies all live `before_hash` values and
supplied staged `after_hash` values, then prepares an offline transaction without
changing any live operation target. Standalone core callers that do not supply
an existing operation lock still acquire one for this phase. Existing
bytes are stored under `.workflow/backups/<transaction-id>/`; post-operation
bytes, mode metadata, and canonical journals are stored privately under
`.workflow/transactions/<transaction-id>/` on the project filesystem.

The canonical `operation-journal.json` is published last and therefore marks a
fully prepared transaction. Existing transaction IDs cannot be overlaid,
backup paths must belong to their transaction, transaction-owned paths cannot
be operation targets, and user-owned content cannot appear in a mutating
journal. Locks are exclusive and are never guessed stale or stolen.

## Apply And Rollback

`applyPreparedTransaction()` consumes only the validated local journal, stage,
backup, and mode metadata. It rechecks every live and staged hash while holding
the same operation lock, records each directory actually created by the transaction,
atomically replaces individual files, writes the generated lock after authored
files, and writes installation state last. A caller-supplied verification step
must succeed before the journal becomes `committed`; interruption or failure
leaves a rollback-recoverable `applying` or `failed` journal.

`verifyInstalledProject()` is the standard post-apply verifier. It requires a
current compiler check, exact desired adapters and components, a complete
ownership ledger with matching live destination hashes, and required
local-artifact `.gitignore` entries. For imported legacy projects it also
validates the import/report pair, rejects unresolved critical settings, and
compares normalized config and project values with the applied YAML. Apply
retains these structured diagnostics when verification marks a transaction
failed. A validated legacy import may remain mechanically gated as
`needs_configuration` or `needs_confirmation` when the source release did not
contain the missing project facts; stale, invalid, or unsupported locks still
fail verification.

`rollbackPreparedTransaction()` supports a no-write dry run and works without
the source release or network access. It validates every required backup and
all live hashes and modes before the first inverse mutation. Creates are removed
only when still byte-identical, replacements and merges restore complete private
snapshots, deletes are restored, and any user edit produces
`rollback_conflict` without partially rolling back other paths. A durable
`rolling_back` state is resumable.

Unexpected process termination can leave `.workflow/update.lock`. Recovery is
explicit: `recoverProjectUpdateLock()` removes only a well-formed lock for the
requested transaction whose recorded PID no longer exists. A live, malformed,
or differently owned lock is never stolen. Confirmed CLI rollback performs this
matching recovery; dry runs never remove locks.

## Legacy Import

`importLegacyProject()` is the read-only legacy `0.x` importer. It parses the
released workflow, stack, architecture, conventions, preset, status, install
state, orchestration, and local orchestration/session inputs without executing
their contents. It returns schema-valid v1 config/project objects, selected
adapters, a private normalized archive, and a deterministic preservation
report.

Every parsed leaf receives a `preserved`, `transformed`, `deprecated`, or
`unresolved` disposition. Unresolved critical values suppress `import.json`.
Profile-owner conflicts, unsupported future schemas, malformed commands and
typed facts, unknown adapters, and unsafe managed paths fail closed.
Malformed non-critical legacy documents do not block an otherwise safe import:
their exact bytes are base64-encoded only in private `import.json`, while the
redacted report records an unresolved non-critical entry, source hash, and
diagnostic code. Unsafe reads and malformed critical documents still abort.

Exact tagged inputs for `v0.1.0-beta.1` and `v0.2.0-beta.1` and their canonical
import/report outputs are committed under
`packages/core/test/fixtures/historical/`. The fixture generator records the
peeled release commit, and normal tests consume only committed files rather
than relying on a Git checkout or network access.

`import.json` may contain sensitive legacy values and is written with private
permissions by transaction preparation. `report.json` contains no values and
is stored beside it under `.workflow/migration/<transaction-id>/`. Unknown
mapping-key segments are represented by stable truncated
SHA-256 labels so a token used as a YAML key cannot leak into the report; the
exact key remains only in the private archive. Deprecated branch, commit,
delegation, and orchestration authority is archived rather than reactivated.
Upgrade output reports critical and non-critical unresolved counts separately.

## Upgrade CLI

`hekate upgrade --to=<release> --force` now composes discovery, optional legacy
import, planning, deterministic content materialization, journal resolution,
transaction preparation, apply, and full verification through the core APIs.
`--dry-run` resolves and summarizes the exact operation journal without writing
transaction artifacts. Non-interactive mutation requires `--yes`; omitting it
without a terminal fails before preparation. `--adapters` expresses the target
adapter set, while omission preserves the installed or imported selection.
`--components` selects opt-in components that no adapter implies; omission
preserves the recorded opt-in rather than removing it. Today the only such
component is `legacy-workflow-files`, which carries `stack.yml`,
`architecture.yml`, `conventions.yml`, and the `presets.yml` registry copy.
`install.sh --legacy-workflow-files` and `install.ps1 -LegacyWorkflowFiles`
request the same component on the static path.
Failed apply output includes the transaction ID needed for offline recovery.

Before confirmation, `--force` prints the preservation report and the operation
plan: preserved, transformed, archived, and unresolved setting counts, the
template, migrated, created, and deleted file counts, the backup directory, and
one line per file the upgrade would migrate or replace. Files a previous Hekate
installation never recorded are listed individually as `replace unowned`. They
are replaced only after that plan is accepted: an interactive run shows the plan
with the confirmation prompt, and `--yes` refuses with `HKT903` unless
`--replace-unowned` states the approval explicitly. The refusal happens before
transaction preparation, so the project is untouched.

Shell and PowerShell install/update entry points delegate existing-install
`--force` operations to this engine. They require Node 20+ only on that path and
install lockfile-pinned dependencies with lifecycle scripts disabled when running
from a downloaded snapshot. Fresh static installation remains Node-free. Non-force
updates and explicit legacy rollback continue through the frozen implementation
for compatibility. Direct runner `--force` invocations delegate to the same Node
engine and are not alternate forced-upgrade authorities.

Use the recorded transaction ID for user-facing offline rollback:

```sh
hekate rollback --transaction=<id> --dry-run --json
hekate rollback --transaction=<id> --yes
```

Rollback refuses unconfirmed non-interactive mutation and reports user-edit
conflicts without applying a partial inverse. Transaction and backup artifacts
remain available as recovery evidence after rollback.

Transaction bundles are retained indefinitely by default. After accepting a
committed upgrade, or after completing rollback, inspect and remove the entire
exact-ID bundle explicitly:

```sh
hekate cleanup --transaction=<id> --dry-run --json
hekate cleanup --transaction=<id> --yes
```

Cleanup removes matching backup, migration, and transaction trees under one
project update lock. Only `committed`, `rolled_back`, or unpublished bundles
with a durable preparation marker are eligible; recovery states, malformed
journals, and missing journals without orphan provenance are preserved. A
failed removal reports every completed component and converges on retry.
Cleaning a committed bundle permanently removes its offline rollback material.
