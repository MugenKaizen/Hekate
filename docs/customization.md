# Customization

Hekate separates project facts from workflow guidance. Keep harness adapters
thin and make each setting authoritative in one authored location.

## Project Context

Edit these files for project-specific facts:

- `.workflow/stack.yml`: languages, runtimes, frameworks, dependencies, and
  verification commands;
- `.workflow/architecture.yml`: modules, layers, boundaries, and dependency
  constraints;
- `.workflow/conventions.yml`: code, tests, documentation, naming, branches,
  and commit-message conventions.

Unknown extension keys are allowed in legacy `0.x` files and must be preserved
by updates. Fields that should block initialized work belong under
`workflow.yml -> blocking.required_non_empty_fields` until the v1 schemas
replace this legacy structure.

## Workflow Guidance

`.workflow/workflow.yml` is the sole current owner of:

- `hekate.enabled` and the workflow module;
- TDD mode: `off`, `prefer-test-first`, or `require-test-evidence`;
- optional local history;
- commit consent and scope-control policy.

Profiles in `.workflow/presets.yml` tune only those settings. They do not
authorize commits, branch creation, native subagents, or external delegation.

The uninitialized template values match the `medium` profile: prefer test-first
where practical and leave history disabled. No profile is selected until
bootstrap writes `workflow.yml -> meta.profile`. Use `full` when observed test
evidence is required and local resumable notes are useful. Use `custom` to
answer the registry questions directly.

After deliberate legacy config changes, refresh `.workflow/status.yml` as a
validation-result index only. It must not copy enablement, TDD, history,
profile, or commit policy. Do not set `initialized: true` unless required files
and fields were actually validated. Phase 2 replaces this index with generated
`status.lock.json`.

## Optional History

History is local and disabled by default. When enabled, use one concise note
for resumable work. There is no required file for every task and no mandatory
per-stage JSONL event stream. Durable decisions belong in project docs or ADRs.

## Native Subagents

Native subagent discovery, permission, consent, concurrency, cancellation, and
results belong to the active harness. Do not add a portable `off | ask | auto`
authorization layer. If native delegation is unavailable or declined, continue
in the primary session without automatic external fallback.

## Adapters

An adapter should point to root `AGENTS.md` and add only harness-specific
loading instructions. Portable skills live under
`templates/skills/<name>/SKILL.md` and are installed to the harness's standard
skill directory. Do not duplicate the task contract in adapter files.

Existing harness settings are user-owned unless Hekate has installation
provenance for the exact asset. See [`install-ownership.md`](install-ownership.md)
for current `0.x` behavior and known exceptions.

## Legacy External Orchestration

The project-local `hekate-agent` controller is retained for existing
installations but is no longer part of the default payload. It is experimental
legacy compatibility, not a fallback for native delegation. Existing users can
reference [`orchestration.md`](orchestration.md); new development targets the
future Pi wrapper and bounded Pi child processes.

## Versioning

Commit authored project workflow files with the project. Keep history, runs,
backups, migration archives, and local overrides untracked. Hekate release
changes are documented in `CHANGELOG.md`; published installs and updates must
use a full pinned commit SHA.
