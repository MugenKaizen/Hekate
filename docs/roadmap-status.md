# Roadmap Status

## Implemented

Phases 0 through 8 have repository implementations and automated contract
coverage. The implementation includes the deterministic core, transactional
distribution, prompt budgets, Pi adapter, global/inline enforcement package,
SDK-based Hekate wrapper, and bounded wrapper-native subagents.

The wrapper resolves Pi project trust before loading project settings and
resources. Non-interactive sessions fail closed to untrusted, TUI sessions can
record an explicit decision, and the mandatory inline gate is independent of
context-file loading. `/hekate-bootstrap` and `/hekate-settings` restrict their
writes to authored Hekate configuration.

Advisory subagent roles expose no shell or mutation tools. Finite aggregate
budgets serialize dispatch, account for Pi cache tokens and `cost.total`, and
truncate on UTF-8 byte boundaries. Timeout and abort escalate from graceful
process-tree termination to forced termination. Writer authorization requires
a Git-authenticated linked worktree in the parent repository and an atomic
lease.

Every supported historical fixture is exercised through dry-run, apply,
byte-idempotent repeat, and user-facing offline rollback. A CRLF/Unicode
serialized variant is included in the platform-neutral matrix. Derived
customization fixtures cover non-default stack, architecture, conventions,
verification commands, preserved legacy typecheck commands, and locally edited
managed prompts and adapter instructions. Released `fast`, `medium`, and `full`
presets, disabled Hekate, and workflow-module states run through the same
forced-upgrade and offline-rollback protocol. Custom legacy routing profiles
and harness definitions are retained as critical, private, deprecated
configuration without reactivating their authority. A mixed-generation fixture
interrupted halfway through legacy migration 004 verifies ledger archival,
safe normalization, repeat stability, and exact offline rollback. A
malformed non-critical extension fixture verifies private byte preservation,
report and CLI secret redaction, byte-idempotent repeat, and offline rollback.
Installed legacy state is critical when present so malformed adapter inventory
cannot silently degrade to an empty selection; a genuinely missing state file
remains supported. POSIX-created and PowerShell-created installations are
forced-upgraded through the opposite compatibility wrapper when both runtimes
are available. Apply and rollback fault injection covers every operation
boundary, including convergent retry and write-ahead parent cleanup intent.
Exact-ID cleanup removes complete terminal transaction bundles only after
explicit confirmation; no automatic retention policy expires offline rollback.
Cleanup uses durable unpublished-preparation provenance, reports partial
component removal, and converges on retry. Pi readiness is revalidated before
every non-read or unknown tool call so in-session stale or forged locks fail
closed. The publishable CLI assembles and tests a package-local transactional
upgrade payload rather than relying on files outside its npm tarball.

Phase 9 was re-evaluated after wrapper-native children were implemented. No
default external-harness plugin is justified: Pi provider/model support and the
bounded child implementation cover the target contract. Legacy external
orchestration remains optional compatibility code and is not restored to the
default payload.

## Deferred

A dedicated Hekate TUI, desktop UI, or web UI is intentionally deferred. The
current interactive surface remains the upstream Pi TUI loaded through the
SDK-based wrapper. Future interface work starts only after real-use evidence and
a stable renderer-independent session adapter exist; it must not move policy or
transaction authority into UI code. An independently versioned UI package is
preferred, and a Pi fork is not planned.

Explicit compatibility versions:

| Surface | Version |
|---|---|
| Authored config and generated lock | schema v1 |
| Install manifest and operation journal | schema v1 |
| Core, CLI, Pi extension, subagents | 0.3.0-beta.1 |
| Pi runtime | `>=0.84.4 <0.85.0`; CI pin `0.84.4` |
| Deterministic core and transactional CLI | Node 20 or newer |
| Pi runtime and `hekate agent` | Node 22.19 or newer |

## External Validation

The following roadmap statements cannot be completed truthfully by a local
implementation run and remain release/operations evidence:

- Windows PowerShell 5.1 execution on a real Windows runner (configured in CI);
- execution of the shared serialized fixture matrix on both Windows and POSIX;
- compatibility against an unpublished next Pi candidate release;
- several weeks of real-use false-positive and bypass measurements;
- provider/OAuth smoke tests requiring user credentials;
- release publication, package installation from the public registry, and
  signed release artifacts.

These are not replaced by mocks or marked complete based on source inspection.
All deterministic contracts beneath them remain CI-testable.
