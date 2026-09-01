# Workflow Bootstrap

Read this file only when preflight fails or initialization is explicitly
requested. Bootstrap configures project context; it does not create branches,
commits, delegation permissions, or external jobs.

## 1. Enable Hekate

Ask whether Hekate workflow guidance is enabled. Write the answer only to
`workflow.yml -> hekate.enabled`.

If disabled, stop. Do not require the remaining project fields.

## 2. Select A Profile

Offer `fast`, `medium`, `full`, or `custom`. Profile definitions ship with
Hekate and are not copied into the project; the project records only its
selection. Profiles control only:

- TDD mode: `off`, `prefer-test-first`, or `require-test-evidence`;
- optional local history notes;

Apply the selected settings to `.workflow/workflow.yml`. Write the profile to
`workflow.yml -> meta.profile`. Profile definitions remain read-only inputs.

For `custom`, ask only for the TDD mode and whether optional history notes are
enabled; both overrides are required. No profile may authorize commits, branch
creation, native subagents, or external harness fallback.

## 3. Discover Project Facts

For an existing project, inspect manifests, source layout, formatter/linter
configuration, test configuration, CI, containers, README, and recent commit
messages. Distinguish observed facts from unknown values. Do not guess.

For a new project, ask concise grouped questions about:

1. name, kind, and purpose;
2. languages, frameworks, runtimes, dependencies, and commands;
3. architecture, modules, layers, and dependency rules;
4. code, test, documentation, naming, and commit-message conventions.

Show authored YAML changes for confirmation. Commit-message conventions
describe messages only; they never grant permission to make a commit.

## 4. Finish

Write or update `config.yml`, `project.yml`, and `workflow.yml`. Then refresh
the legacy `status.yml` index:

- `initialized: true`;
- both required checks set from observed file/field validation;
- `source.workflow: .workflow/workflow.yml`.

Create `.workflow/history/` only when history is enabled. Do not create a
bootstrap history entry automatically. Report unknown fields and verification
performed.
