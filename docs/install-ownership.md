# Legacy v0 installation ownership

This document freezes the current `0.x` install and update ownership contract.
It describes shipped behavior, including known limitations. The target v1
manifest and transactional upgrade contract are defined in `docs/roadmap.md`.

## Ownership classes

| Class | Meaning in v0 |
|---|---|
| Template-managed | Hekate may update the file. Local edits normally produce a `.new` review copy; force may replace after backup. |
| Project seed | Created on first install, then edited by the project. Normal update only applies targeted legacy migrations. |
| Local seed | Local policy created once and expected to remain untracked. |
| Shared merge | Hekate adds its entries while preserving unrelated content. |
| Generated | Rebuilt by install or update from installation state. |
| User-owned | Hekate must not claim the file without installation provenance. |

## Asset contract

| Destination | Class | Install | Normal update | Force behavior |
|---|---|---|---|---|
| `AGENTS.md` | Template-managed | Create if absent | Three-way template update | Backup and replace |
| `.workflow/bootstrap.md` | Template-managed | Create if absent | Three-way template update | Backup and replace |
| `.workflow/history-format.md` | Template-managed | Create if absent | Three-way template update | Backup and replace |
| `.workflow/README.md` | Template-managed | Create if absent | Three-way template update | Backup and replace |
| `.workflow/bin/hekate-agent*` | Legacy template-managed | Not installed by default | Service only when already present | Backup and replace |
| `.workflow/delegation.md` | Legacy template-managed | Not installed by default | Service only when already present | Backup and replace |
| `.workflow/subagents.md` | Legacy compatibility data | Not installed by default | Service only when already present | Backup and replace |
| Claude, Cursor, Copilot, Gemini, Aider adapter files | Template-managed when installed by Hekate | Create for selected adapter | Three-way template update | Backup and replace |
| `.claude/skills/*/SKILL.md` | Template-managed | Create for Claude | Three-way template update | Backup and replace |
| `.agents/skills/*/SKILL.md` | Template-managed | Create for portable adapters | Three-way template update | Backup and replace |
| `.workflow/config.yml` | v1 project seed | Create if absent | Preserve pending typed v1 upgrade | Preserve; never replace as a template |
| `.workflow/project.yml` | v1 project seed | Create if absent | Preserve pending typed v1 upgrade | Preserve; never replace as a template |
| `.workflow/stack.yml` | Project seed | Create if absent | Targeted legacy migrations only | Current installer replaces; v1 must migrate instead |
| `.workflow/architecture.yml` | Project seed | Create if absent | Targeted legacy migrations only | Current installer replaces; v1 must migrate instead |
| `.workflow/conventions.yml` | Project seed | Create if absent | Targeted legacy migrations only | Current installer replaces; v1 must migrate instead |
| `.workflow/workflow.yml` | Project seed | Create if absent | Targeted legacy migrations only | Current installer replaces; v1 must migrate instead |
| `.workflow/presets.yml` | Project seed | Create if absent | Targeted legacy migrations only | Current installer replaces; v1 must migrate instead |
| `.workflow/status.yml` | Legacy authored/generated mix | Create if absent | Targeted legacy migrations and state indexing | Current installer replaces; v1 removes this mixed ownership |
| `.workflow/orchestration.yml` | Legacy project seed | Not installed by default | Service only when already present | Current updater may replace; v1 importer must preserve it |
| `.workflow/session.local.yml` | Legacy local seed | Not installed by default | Preserve | v1 must never overwrite it |
| `.workflow/state.yml` | Generated installation state | Generate | Back up and regenerate | Regenerate |
| `.gitignore` | Shared merge | Append missing Hekate entries | Append missing Hekate entries after backup | Never replace wholesale |
| Existing project `README.md` | User-owned unless installed provenance is known | Preserve | Preserve, except legacy `# Hekate` heuristic | Legacy force may replace matching heuristic; v1 removes this inference |
| Existing harness settings and unrelated project files | User-owned | Preserve | Preserve | Never replace |
| `.workflow/history/`, `.workflow/runs/`, `.workflow/backups/` | Local/generated artifacts | Create only as needed | Preserve or append | Never use as authored policy |

## Known v0 limitations

- Installer `--force` can replace project and local seeds. Use it only with a
  verified backup until the typed v1 importer is available.
- Adapter marker-file presence is not proof that Hekate owns an existing
  harness file. Normal updates preserve local content through `.new`, but force
  can overwrite it.
- Root README ownership uses a legacy heading heuristic and is not reliable
  provenance.
- Rollback overlays captured files. It does not remove files created by an
  update and does not detect edits made after the update.
- Backup run IDs have one-second resolution in v0. Do not run concurrent
  installers or updaters against the same project.

These limitations are compatibility facts, not permissions for the v1
implementation. The v1 ownership manifest must classify every destination and
must abort before mutation when provenance or preservation is ambiguous.
