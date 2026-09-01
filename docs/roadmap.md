# Hekate implementation roadmap

Status: proposed. This roadmap supersedes the earlier Pi-only integration
plan. The immediate goal is to make Hekate a small, deterministic workflow
contract that remains useful in any harness and is safe to enforce in a
future wrapper built on [Pi](https://github.com/earendil-works/pi).

The roadmap is ordered by dependency. A phase starts only after the previous
phase meets its exit criteria.

## 1. Product direction

Hekate currently mixes four concerns:

- portable project and workflow guidance;
- manually synchronized runtime state;
- harness-specific adapters and subagent policy;
- an external CLI job controller.

The target architecture separates them:

```text
Portable workflow files
        |
        v
Deterministic Hekate core
        |
        +-- static adapters for other harnesses
        |
        +-- Pi enforcement extension
                |
                +-- future Hekate wrapper over Pi
                +-- wrapper-native Pi subagents
```

The portable workflow defines policy and project context. The core parses,
resolves, validates, and compiles that policy. Harness integrations enforce
only objective rules that their APIs can actually control.

## 2. Design principles

1. **One owner per datum.** Authored configuration is never mirrored manually.
2. **Generated state is not authored state.** Readiness is derived, not set by
   writing `initialized: true`.
3. **Portable first.** Project policy remains readable without Pi or a custom
   harness.
4. **Objective enforcement only.** Tool gates enforce facts such as readiness,
   paths, capabilities, and explicit destructive operations. Semantic quality
   remains the responsibility of the primary agent and user.
5. **Native orchestration belongs to the harness.** Portable Hekate does not
   wrap native subagents with a weaker prompt-only authorization layer.
6. **Progressive disclosure.** Normal sessions load a compact core. Bootstrap,
   migration, delegation, and detailed references are loaded only when used.
7. **No silent data loss.** Install, update, forced upgrade, and rollback are
   transactional and preserve user-owned configuration.
8. **Evidence is not acceptance.** Passing commands and child results are
   recorded evidence; the primary session still owns final acceptance.

## 3. Target workflow

The portable workflow is adaptive rather than a mandatory five-stage state
machine:

```text
Understand
  -> Decide when a material choice exists
  -> Plan when risk, size, delegation, or the user requires it
  -> Execute
  -> Verify
```

### 3.1 Understand

Always applicable:

- understand the requested outcome;
- inspect the affected code instead of guessing;
- identify scope, constraints, and a verification method;
- avoid unrelated changes.

This is guidance, not a hard gate.

### 3.2 Decide

Compare options only when there is a material design fork, a meaningful
trade-off, difficult rollback, or an explicit user request. Obvious fixes do
not require two artificial alternatives or another approval turn.

### 3.3 Plan

A written plan is required for large, risky, destructive, delegated, or
resumable work, and whenever the user asks for one. Plan approval is required
when the user requested planning before execution or when the proposed plan
changes scope materially.

Plans identify affected paths, steps, verification, and rollback only where
rollback is meaningful. They are not mandatory artifacts for every task.

### 3.4 Execute

Normal execution is not blocked by a model-authored stage label. A harness may
offer an explicit read-only or plan mode that mechanically removes mutation
tools until the user exits that mode.

### 3.5 Verify

Every implementation task ends with relevant verification evidence. Hekate
records observed commands and results but does not claim that a successful
exit code proves product correctness.

### 3.6 Optional TDD

Replace ambiguous TDD combinations with three modes:

```text
off
prefer-test-first
require-test-evidence
```

`prefer-test-first` remains guidance. `require-test-evidence` requires an
observed relevant test result before completion, not a ceremonial claim that a
red-green cycle occurred.

### 3.7 Removed universal requirements

The following do not belong in the workflow core:

- mandatory options for every non-trivial task;
- mandatory plan approval for every non-trivial task;
- automatic commits selected indirectly by a preset;
- automatic creation of `main`, `stage`, and `dev` branches;
- one Markdown history file and JSONL event for every task stage;
- a persistent portable `off | ask | auto` native-subagent policy;
- external harness orchestration in every installation.

## 4. Target configuration contract

### 4.1 Authored files

The initial v1 target is:

```text
.workflow/config.yml      # workflow selection and policy
.workflow/project.yml     # project facts and verification commands
```

Detailed architecture or convention references may remain separate when they
are useful, but every value has exactly one authored owner.

`config.yml` contains:

- contract schema version;
- Hekate enabled state;
- selected workflow profile;
- explicit feature overrides;
- TDD and commit consent policy;
- objective enforcement controls.

`project.yml` contains:

- project identity and kind;
- languages, frameworks, and runtimes;
- formatter, linter, test, build, and validation commands;
- architecture references and project-specific constraints;
- explicit `known`, `unknown`, or `not_applicable` states where required.

Preset definitions ship with the Hekate core. A project stores only its
selection and overrides. It does not carry a mutable copy of the preset
registry.

The portable preflight in `AGENTS.md` runs without Node, so `.workflow/`
additionally carries `workflow.yml` and `status.yml` as part of the default
payload. The legacy project-fact files `stack.yml`, `architecture.yml`, and
`conventions.yml`, together with the `presets.yml` registry copy, are not
installed by default. They remain available as the opt-in
`legacy-workflow-files` component for installations that still author facts in
that layout; `project.yml` owns those facts otherwise.

### 4.2 Generated lock

The compiler emits:

```text
.workflow/status.lock.json
```

It contains:

- lock schema version;
- compiler version;
- hashes of all authored inputs;
- resolved workflow policy;
- gate state and stable diagnostic codes;
- normalized verification commands;
- compatibility metadata.

Valid gate states are:

```text
absent
off
workflow_disabled
needs_configuration
needs_confirmation
ready
stale
invalid
unsupported_schema
```

The lock is generated through an atomic replacement and must be byte-identical
for identical inputs. It contains no timestamps. Agents must not edit it
directly.

### 4.3 Validation and compilation

The core exposes:

```text
hekate check [--json]
hekate compile
hekate compile --check
```

The implementation must:

- parse YAML 1.2 with duplicate keys rejected;
- reject unsafe tags and malformed aliases;
- validate exact schema versions and value types;
- validate cross-file references and profile overrides;
- resolve required fields by exact path, not by textual search;
- calculate input hashes and lock freshness;
- emit stable machine-readable diagnostics;
- fail closed for unsupported future schemas;
- preserve explicit extensions under a documented namespace.

## 5. Runtime and repository boundaries

During contract development, keep packages in one repository so schemas and
consumers can evolve together:

```text
packages/
  core/       # schemas, parser, resolver, validator, compiler
  cli/        # init, check, compile, migrate, upgrade
  pi/         # Pi extension, bootstrap UI, gates, observations
  wrapper/    # future Hekate entry point over Pi
```

The static portable distribution remains usable without Node or Pi. It ships
templates and concise guidance. Mechanical validation and Pi integration use
the packages above.

A repository split may happen after contract v1 is stable and compatibility
ranges no longer change on every release.

## 6. Installation ownership model

The current pre-v1 behavior and its known safety exceptions are frozen in
[`install-ownership.md`](install-ownership.md). That document describes legacy
compatibility; the manifest below is the replacement contract.

Replace procedural file lists in shell and PowerShell with one canonical
install manifest. Each asset records:

```text
asset_id
component
source
destination
ownership
update_strategy
remove_strategy
mode
```

Required ownership classes:

| Ownership | Meaning | Normal update behavior |
|---|---|---|
| `template-managed` | Hekate owns the content | Three-way update or replace after backup |
| `project-seed` | Hekate creates an initial user-editable file | Parse and migrate; never replace wholesale |
| `local-seed` | Local user policy or cache | Create if absent; never overwrite |
| `generated` | Reproducible compiler output | Regenerate from validated inputs |
| `shared-merge` | Shared file such as `.gitignore` | Structured merge preserving unrelated data |
| `user-owned` | Existing harness or project configuration | Never claim or overwrite |

Installed state records, per asset:

- stable asset ID;
- destination and ownership class;
- installed source hash;
- destination hash after installation;
- source release and manifest version;
- selected components and adapters.

Unknown adapter names are rejected. Adapter selection is desired-state
reconciliation rather than a set of hardcoded installer branches.

## 7. Forced upgrade contract

### 7.1 Meaning of `--force`

`--force` means: reconcile an older or locally modified Hekate installation to
the requested target release while preserving critical project and user
configuration.

It does not mean: overwrite every known path with new templates.

`--force` may replace locally edited `template-managed` files after showing the
plan and creating a backup. It must never replace `project-seed`, `local-seed`,
`shared-merge`, or `user-owned` files wholesale.

`--force --yes` skips the confirmation prompt but does not bypass validation,
data-loss checks, schema compatibility, path safety, or backup creation.

The target CLI is:

```text
hekate upgrade --to <version-or-ref> --force [--yes] [--dry-run]
```

Compatibility entry points delegate to the same implementation:

```text
update.sh --force
update.ps1 --force
install.sh --force       # when an existing Hekate installation is detected
install.ps1 --force      # when an existing Hekate installation is detected
```

Re-running an installer with `--force` against an existing installation must
not execute the fresh-install copy path. It enters the version-aware upgrade
transaction. Fresh installation into a non-Hekate directory remains a separate
operation.

The v1 importer supports every publicly released Hekate `0.x` layout. An
installation with missing state is identified from known files and schema
shapes. An unknown or internally inconsistent layout may be inspected and
backed up, but it cannot be upgraded until every critical setting has an
unambiguous preservation disposition.

### 7.2 Critical settings that must survive

The upgrade contract preserves, when present:

- project name, kind, languages, frameworks, runtimes, and dependencies;
- build, test, lint, format, typecheck, and project validation commands;
- architecture descriptions, modules, layers, and dependency constraints;
- naming, testing, documentation, and commit conventions;
- Hekate enabled state and explicit workflow choices;
- selected profile and custom feature overrides;
- destructive-action, dependency, commit, and TDD preferences;
- custom verification commands;
- custom adapter selection;
- custom external harness definitions and routing profiles when the legacy
  orchestration component is installed;
- unrelated `.gitignore` entries;
- unrelated keys in shared harness settings such as `.pi/settings.json`;
- unknown legacy extension keys that can be represented safely.

Deprecated settings are not silently activated in the new version. For
example, old native-subagent and automatic branch/commit settings are preserved
in the migration archive and reported, but they do not regain authority in the
new workflow unless the target contract has an explicit equivalent.

Secrets must never be copied into console output or a human-readable migration
report. Backups and intermediate files use private permissions.

### 7.3 Upgrade pipeline

The forced upgrade runs as a transaction:

```text
discover
  -> snapshot
  -> import legacy state
  -> normalize
  -> validate target state
  -> stage filesystem operations
  -> show plan and preservation report
  -> atomically apply
  -> verify installation
  -> commit operation journal
```

#### Discover

- acquire a project-level update lock;
- detect installed Hekate version from state, schemas, and known legacy files;
- reject symlinked managed paths or parents that could escape the project;
- identify each installed path by ownership, not only by filename presence;
- distinguish a Hekate-managed adapter from a pre-existing user adapter.

#### Snapshot

- create a collision-resistant backup run ID;
- copy every file that may be replaced, transformed, or deleted;
- record hashes, permissions, ownership class, and intended operation;
- back up installation state before changing the migration ledger;
- retain the snapshot until the upgraded installation passes validation.

The backup must be sufficient for offline rollback. Rollback cannot depend on
downloading the old release. A successful forced-upgrade snapshot is not
removed by the normal bounded backup pruning policy. It remains until the user
explicitly accepts the upgrade or runs a dedicated cleanup command.

#### Import legacy state

A version-aware importer parses old project configuration into a normalized
intermediate representation. It does not mutate files in place with regexes.

```text
.workflow/migration/<run-id>/import.json
.workflow/migration/<run-id>/report.json
```

The importer records for every legacy value:

- source file and exact path;
- normalized target path;
- whether it was preserved, transformed, deprecated, or unresolved;
- a stable diagnostic code for any ambiguity.

Unknown values are preserved under a documented extension namespace when safe.
Values with no safe target are retained in the private migration archive and
listed in the report.

#### Validate target state

- target schemas must validate before any live replacement;
- generated lock must compile successfully;
- all critical source settings must have a preservation disposition;
- unresolved critical settings abort the upgrade, even with `--force --yes`;
- unreadable or malformed critical configuration aborts unless a separate,
  explicitly destructive recovery option is provided in a future release.

There is intentionally no generic `--allow-config-loss` shortcut in v1.

#### Stage and apply

- write all target files into a staging directory on the same filesystem;
- produce a create/replace/delete/merge operation journal;
- use atomic rename where supported;
- never modify the generated lock before authored files are valid;
- write installation state last;
- leave the previous installation recoverable if any operation fails.

#### Verify

After apply:

- parse and validate every target config;
- run `hekate compile --check`;
- verify the install manifest and selected adapters;
- verify critical-setting preservation against the normalized import;
- verify local files are ignored where required;
- keep the backup and mark the operation failed if verification fails.

### 7.4 Preservation report

Before confirmation, `--force` prints a concise summary:

```text
preserved: 24 settings
transformed: 7 settings
deprecated and archived: 3 settings
unresolved critical: 0 settings
template files to replace: 5
project files to migrate: 4
files to create: 6
files to delete: 2
backup: .workflow/backups/<run-id>/
```

The complete machine-readable report remains under the migration run directory.
Sensitive values are redacted.

### 7.5 Rollback contract

Every operation journal entry contains:

```text
operation: create | replace | delete | merge
path
before_hash
after_hash
backup_path
ownership
```

Rollback behavior:

- `create`: remove only when current content still matches `after_hash`;
- `replace`: restore the backup only when current content still matches
  `after_hash`;
- `delete`: restore the backed-up file;
- `merge`: restore only Hekate's recorded contribution or the complete backup
  after conflict confirmation;
- conflicting user edits stop rollback and produce a recovery plan;
- installation state and generated lock roll back in the same transaction;
- rollback supports `--dry-run` and works without network access.

## 8. Migration policy

The current paired shell/PowerShell regex migrations are frozen after critical
bug fixes. Contract v1 uses one parsed legacy importer and typed transformations.

Rules:

- released migration behavior is immutable;
- unknown future schemas fail before mutation;
- downgrade is unsupported unless an explicit reverse transformation exists;
- migration IDs are stored in a structured ledger and never parsed by
  indentation-sensitive text scanning;
- state and operation journals are written atomically;
- running the same migration twice produces byte-identical output;
- all supported historical releases have golden input/output fixtures;
- POSIX and Windows invoke the same core migration logic.

The migration-ledger parser reads both block-sequence indentation forms, ends
the list at the first sibling key, and cannot include update-history entries in
`applied_migrations`. POSIX and PowerShell readers are asserted against one
shared fixture set.

## 9. Portable prompt and token budget

The portable prompt is reduced to:

- master enablement and preflight pointer;
- adaptive task-cycle summary;
- scope and destructive-action rules;
- one lazy-load index.

Targets:

| Component | Budget |
|---|---:|
| Root `AGENTS.md` | at most 1,000 tokens |
| Root instructions plus generated status summary | at most 1,500 tokens |
| Adapter-specific overhead | at most 100 tokens |
| Normal ready-state Pi extension injection | 0 tokens |
| Skill metadata | at most 100 tokens per installed skill |
| Full bootstrap/subagent instructions | loaded only on use |

Adapters contain only harness-specific integration. They do not restate the
workflow. The broad always-on workflow skill is removed or converted into an
explicit bootstrap/maintenance skill.

Repository transcripts, run logs, backups, migration archives, and generated
history are excluded from agent indexing as well as Git.

## 10. Pi integration

Pi is currently published as `@earendil-works/pi-coding-agent`. The canonical
repository is `earendil-works/pi`; older `badlogic/pi-mono` links redirect to
the same repository.

The integration uses documented public APIs:

- `createAgentSessionRuntime`;
- `InteractiveMode`, `runPrintMode`, and `runRpcMode`;
- `DefaultResourceLoader` and `SettingsManager`;
- `tool_call`, session, resource, and UI extension events;
- `pi.appendEntry()` for state that does not enter model context;
- strict tool allowlists and `pi.setActiveTools()`;
- inline extension factories for wrapper-mandatory behavior.

Pi has no built-in OS sandbox. Hekate must not describe tool filtering or
project trust as process isolation.

### 10.1 Pi adapter

The static adapter is intentionally thin:

- Pi already loads root `AGENTS.md`;
- Pi already discovers project `.agents/skills`;
- Pi prompt templates use standard Markdown frontmatter and support
  `$ARGUMENTS`;
- Hekate prompts must come from a generic source, not be copied from the Claude
  adapter;
- an existing `.pi/settings.json` remains user-owned and is never overwritten.

Adapter installation uses the canonical manifest, not new hardcoded installer
branches or an adapter-only migration.

### 10.2 Pi enforcement extension

The extension is global or wrapper-inline so project trust and non-interactive
modes cannot silently prevent enforcement.

Session states:

```text
absent       no Hekate project; extension is a no-op
off          Hekate explicitly disabled; extension is a no-op
blocked      invalid or stale project; model receives read-only tools
configuring  bootstrap writes allowed only to declared config paths
ready        normal work; no stage gate
```

In `blocked` state, allow only known read-only tools. Block shell, PowerShell,
edit, write, and unknown tools. In `configuring`, allow writes only to Hekate
authored configuration and the Hekate portion of shared files. In `ready`, do
not inject workflow text every turn.

Mechanically gate:

- mutation before valid preflight;
- direct writes to generated state;
- model writes to user authorization state;
- recognized destructive commands and permission bypass flags;
- write delegation without declared scope or isolation.

Keep advisory:

- architecture quality;
- whether options are genuinely different;
- whether test-first is practical;
- semantic scope and product acceptance;
- whether verification is sufficient beyond configured commands.

### 10.3 Hekate wrapper over Pi

The wrapper depends on Pi instead of forking it. It provides:

- a `hekate` entry point;
- mandatory inline Hekate extension loading;
- Hekate onboarding and bootstrap UI;
- minimal system prompt and controlled resource loading;
- consistent TUI, print, JSON, and RPC behavior;
- Pi session, model, provider, OAuth, compaction, and tree functionality;
- explicit documentation that direct `pi` invocation bypasses wrapper-only
  enforcement.

The first wrapper accepts Pi's `.pi` project namespace and environment names.
Branding is not a reason to fork Pi.

### 10.4 Deferred Hekate interface

A dedicated Hekate TUI or graphical interface is deferred. The stock Pi TUI is
the supported interactive surface for the initial wrapper and is not forked or
vendored.

Reconsider a custom interface only after real use identifies concrete UX gaps
that cannot be addressed through Pi extensions. Before interface work begins:

- define a stable Hekate session adapter over documented Pi SDK, JSON, or RPC
  events;
- keep policy, readiness, trust, and transaction decisions in Hekate core and
  extensions rather than in renderer code;
- preserve print, JSON, and RPC parity and retain the stock Pi TUI as a
  fallback;
- specify terminal, desktop, or web scope from observed workflows rather than
  branding goals;
- prefer an independently versioned `@hekate/pi-ui` package over a Pi fork.

Forking Pi remains a last resort for a demonstrated upstream API limitation,
not a prerequisite for visual customization.

## 11. Subagents

### 11.1 Portable behavior

Portable Hekate does not define a generic native-subagent authorization plane.
Harnesses with native subagents own discovery, permissions, consent,
concurrency, cancellation, and results.

External delegation is never an automatic fallback when native delegation is
missing, disabled, or declined.

### 11.2 Pi wrapper behavior

Pi deliberately has no built-in subagents. Its official example implements
them by spawning isolated `pi --mode json --no-session` child processes.

Hekate's wrapper-native implementation may build on that pattern with:

- single, parallel, and chain modes;
- bounded task count and concurrency;
- strict per-role tool allowlists;
- private prompt files or stdin;
- structured JSON results and usage accounting;
- output, time, token, and cost limits;
- parent session and delegation-depth metadata;
- child removal of the subagent tool to prevent recursion;
- process-tree cancellation;
- canonical cwd validation;
- advisory children by default;
- writer children only in dedicated worktrees with atomic writer leases.

The subagent tool is exposed only when enabled. Agent summaries remain short;
full role instructions load after selection.

### 11.3 External harnesses

The current `hekate-agent` runner becomes a legacy experimental component and
is removed from the default payload. Most cross-model work can be performed by
Pi child processes because Pi already supports multiple providers and models.

If real use cases remain for Claude/OpenCode/Codex/Aider CLI delegation, build
them later as an independently versioned `external-harnesses` plugin.

## 12. Test strategy

### 12.1 Contract and compiler

- strict parsing of every shipped template;
- duplicate-key and wrong-type rejection;
- golden profile and override resolution;
- byte-identical repeat compilation;
- source hash and stale-lock detection;
- every gate-state transition;
- `known`, `unknown`, and `not_applicable` project facts;
- stable JSON diagnostics.

### 12.2 Prompt budgets

- exact normal-session file set;
- size budgets for `AGENTS.md`, adapters, and skills;
- no optional policy loaded in a trivial task;
- no duplicate workflow text in adapters;
- provider-tokenizer reporting where available.

### 12.3 Install and update

- manifest parity on POSIX and Windows;
- every adapter independently and in combination;
- unknown adapter rejection;
- ownership behavior for every class;
- modified template file review and forced replacement;
- preservation of existing `.pi/settings.json` and `.gitignore` content;
- symlink, path escape, concurrent update, and interrupted update cases;
- no-op update changes no files.

### 12.4 Forced upgrade

Maintain fixtures for every supported historical release and representative
customized installations. For every fixture:

1. Capture the expected critical-settings inventory.
2. Run `upgrade --force --dry-run` and validate the operation plan.
3. Run `upgrade --force --yes`.
4. Validate target schemas and generated lock.
5. Compare every critical setting with its preservation disposition.
6. Run the upgrade again and assert byte-identical project state.
7. Roll back offline and compare with the original fixture.

Required cases:

- all released presets and custom settings;
- locally modified managed prompts and adapters;
- custom verification commands;
- custom stack, architecture, and convention values;
- custom orchestration profiles and harnesses;
- disabled Hekate and disabled workflow module;
- missing legacy state file;
- partially applied migrations;
- malformed non-critical extension data;
- malformed critical configuration, which must abort;
- quoted strings, colons, hashes, Unicode, multiline values, and empty arrays;
- settings containing secrets, which must be redacted from reports;
- failure injection after every transaction step;
- user edits after upgrade followed by rollback;
- shell-created fixture upgraded on Windows and the reverse.

### 12.5 Pi extension and wrapper

- non-Hekate projects remain unaffected;
- disabled Hekate and workflow-disabled projects remain usable;
- stale, malformed, or forged locks block mutation;
- bootstrap cannot write source files or invoke arbitrary shell;
- TUI, print, JSON, RPC, trusted, and untrusted modes behave consistently;
- `--no-context-files` does not disable the mechanical gate;
- direct wrapper extension state does not enter LLM context;
- wrapper forwards signals, exit codes, stdin, stdout, and session replacement;
- extension compatibility is tested against a pinned Pi version and the next
  candidate release.

### 12.6 Subagents

- role and tool allowlist enforcement;
- recursion-depth rejection;
- bounded parallelism and budget exhaustion;
- child process-tree cancellation;
- output truncation with complete structured details;
- writer lease and dedicated-worktree enforcement;
- parent review remains pending after child success;
- no external fallback after native denial or unavailability.

## 13. Implementation phases

### Phase 0: Correct current upgrade safety

Deliverables:

- fix migration-ledger parsing;
- run PowerShell install/update/migration tests in CI;
- document managed versus project/user-owned files;
- add regression tests for backups and current rollback behavior;
- freeze new regex-based feature migrations.

Exit criteria:

- migration history cannot contaminate the applied migration list;
- both platform suites run in CI;
- current beta installations have a tested path into the v1 importer.

### Phase 1: Freeze workflow v1 semantics

Deliverables:

- adopt the adaptive workflow in section 3;
- remove automatic commits and branch creation from presets;
- make history artifacts optional;
- remove portable native-subagent authorization;
- mark external orchestration as legacy optional;
- publish the objective enforcement matrix.

Exit criteria:

- no workflow feature requires a second contradictory representation;
- every retained rule is classified as advisory, deterministic, observable, or
  mechanically gated.

### Phase 2: Build core contract

Deliverables:

- v1 authored schemas;
- parser, resolver, validator, and compiler;
- generated `status.lock.json`;
- `check`, `compile`, and `compile --check` commands;
- contract and compiler test suites.

Exit criteria:

- identical inputs produce identical locks;
- readiness cannot be asserted by editing a boolean;
- all gate states and schema failures are covered.

### Phase 3: Transactional distribution and forced upgrade

Deliverables:

- canonical install manifest and ownership ledger;
- transactional operation journal;
- legacy-to-v1 importer;
- preservation report;
- new rollback implementation;
- `upgrade --force`, `--dry-run`, and non-interactive `--yes` behavior;
- historical fixture matrix.

Exit criteria:

- every critical legacy setting is preserved, transformed explicitly, or
  causes a pre-mutation abort;
- rollback is an offline inverse of create, replace, delete, and merge;
- repeated upgrades are byte-idempotent;
- no user-owned harness configuration is overwritten.

### Phase 4: Reduce prompt and installation surface

Deliverables:

- compact `AGENTS.md`;
- pointer-only adapters;
- explicit, narrow skills;
- selective components and adapters;
- context-budget CI;
- agent-index exclusions for generated local artifacts.

Exit criteria:

- normal portable context meets the budgets in section 9;
- optional components add no files or prompt content when unselected.

### Phase 5: Add the Pi adapter

Deliverables:

- generic Pi prompt templates;
- shared skills only where useful;
- manifest-based adapter installation;
- compatibility tests against pinned Pi;
- no ownership of existing `.pi/settings.json`.

Exit criteria:

- Pi can use the portable workflow without a runtime extension;
- installation and update preserve all existing Pi settings.

### Phase 6: Build the Pi enforcement package

Deliverables:

- global Pi package;
- project detection and gate-state resolution;
- preflight and bootstrap mutation gates;
- destructive-operation confirmations;
- generated lock protection;
- verification observation and status UI;
- no normal-turn prompt injection.

Exit criteria:

- ready-state work has zero extension prompt overhead;
- invalid projects are read-only in TUI, print, JSON, and RPC modes;
- several weeks of real use show acceptable false-positive and bypass rates.

### Phase 7: Build the Hekate wrapper

Deliverables:

- `hekate` executable using Pi's documented runtime APIs;
- mandatory inline Hekate extension;
- Hekate bootstrap and settings UI;
- TUI, print, JSON, and RPC modes;
- explicit Pi compatibility range and smoke tests.

Exit criteria:

- no Pi fork or vendored Pi source;
- direct Pi and wrapper behavior are documented clearly;
- wrapper lifecycle, sessions, compaction, providers, and signals are stable.

### Phase 8: Add wrapper-native subagents

Deliverables:

- bounded Pi child-process implementation;
- role/capability registry;
- structured lifecycle, results, and usage;
- recursion and writer isolation;
- dynamic tool exposure;
- subagent integration tests.

Exit criteria:

- children cannot recursively delegate;
- advisory children cannot mutate through exposed tools;
- writer children require isolated worktrees;
- child success is shown as review-pending evidence.

### Phase 9: Re-evaluate external harness plugins

Proceed only if real tasks cannot be covered by Pi's provider/model support and
wrapper-native child processes. Do not restore the current all-harness payload
by default.

## 14. Wrapper readiness checklist

Do not begin Phase 7 until all are true:

- one authored owner exists for every workflow setting;
- the generated lock is deterministic and protected;
- forced upgrades preserve critical settings across all supported releases;
- rollback is transactional and offline;
- no automatic commit or branch authority is hidden in a preset;
- no mandatory per-stage history writes remain;
- portable native-subagent policy is removed;
- the Pi extension behaves consistently in all run modes;
- bootstrap cannot mutate project source;
- prompt and installation budgets pass in CI;
- core, lock, adapter, Pi, and wrapper compatibility versions are explicit.

## 15. Licensing

Hekate and Pi are MIT licensed. A wrapper or package must retain the required
copyright and license notices. Pi remains an upstream dependency, not vendored
or forked source.
