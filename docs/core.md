# Deterministic Core

The Phase 2 Node packages provide mechanical validation without changing the
portable static distribution. Projects may continue using Markdown/YAML without
Node; runtime validation and generated locks require Node 20 or newer.

## Authored Inputs

- `.workflow/config.yml`: Hekate enablement, profile, narrow overrides,
  authorization policy, and objective enforcement settings.
- `.workflow/project.yml`: explicit project facts, verification commands,
  architecture references, and confirmation state.

Facts use `known`, `unknown`, or `not_applicable`. Readiness is derived from
validated facts; there is no authored `initialized` or `ready` switch.

## Commands

From this repository:

```sh
node packages/cli/bin/hekate.js check
node packages/cli/bin/hekate.js check --json
node packages/cli/bin/hekate.js compile
node packages/cli/bin/hekate.js compile --check
```

`compile` writes `.workflow/status.lock.json` atomically. Identical inputs and
compiler versions produce byte-identical output. `compile --check` never writes
and fails when the lock is missing, stale, malformed, or the project is not
ready.

## Gate States

The core reports:

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

The lock contains raw-input SHA-256 hashes, resolved policy, normalized
verification commands, stable diagnostic codes, and extension data. It contains
no timestamps or absolute paths.

## Security Boundaries

- YAML 1.2 duplicate keys, aliases, custom tags, non-string keys, unsafe
  numbers, and multiple documents are rejected.
- Schemas reject unknown core properties. Custom data is confined to namespaced
  `extensions`.
- Architecture references must be regular non-symlink files below the project
  root.
- Validation and compilation never execute project commands.

The read-only Phase 3 distribution foundation is documented in
[`distribution.md`](distribution.md).

The Pi adapter and mechanically enforced runtime states are documented in
[`pi.md`](pi.md).
