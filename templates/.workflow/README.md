# .workflow/

This directory contains portable project facts and workflow guidance.

| File | Purpose |
|---|---|
| `config.yml` | Hekate enablement, selected profile, overrides, and policy |
| `project.yml` | Project identity, stack, verification commands, and architecture |
| `workflow.yml` | Hekate switch, TDD evidence, optional history, and scope policy |
| `status.yml` | Legacy validation-result index pending generated `status.lock.json` |
| `bootstrap.md` | Initialization procedure, loaded only when needed |
| `history-format.md` | Optional concise note format for resumable work |
| `state.yml` | Installation reference and frozen legacy migration ledger |

## Rules

- The workflow is adaptive: Understand, Decide when needed, Plan when needed,
  Execute, Verify.
- Every implementation task needs relevant observed verification evidence.
- History is optional and disabled by default. It is not a per-stage ledger.
- Profile definitions ship with Hekate. A project records only its selection
  and overrides in `config.yml`.
- Profiles only tune TDD/history guidance and never authorize commits, branch
  creation, destructive actions, or delegation.
- Native subagent authorization belongs to the active harness.
- External orchestration is a legacy optional component and is not installed by
  default. Existing legacy files are compatibility data, not portable policy.
- Project and user configuration must be preserved during updates.

See root `AGENTS.md` for the normal task contract and `bootstrap.md` only for
initialization.
