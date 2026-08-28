# Workflow Bootstrap

Read this file only when initialization is required: configs are empty,
missing, `presets.yml → meta.active_preset` is `null`, a required field is
empty, `.workflow/status.yml` is missing or not initialized, or the user
explicitly asks to "initialize the workflow" / "/init-workflow".

## 1. Choose enabled Hekate modules

Read `.workflow/status.yml` and ask which Hekate modules should be active:

- **all** — workflow, task history, native subagents, and cross-harness orchestration;
- **history + subagents** — only task history and native subagents;
- **off** — disable all Hekate behavior;
- **custom** — choose each module independently.

Write the result to `workflow.yml → hekate` and mirror it to
`status.yml → hekate`. `off` sets `hekate.enabled: false`; every other choice
sets it to `true` and writes the module allowlist. If Hekate or its workflow
module is disabled, do not require project initialization or an active preset.
Configure enabled standalone modules only, ensure their local files exist,
then finish. Enabling `native_subagents` does not mean `auto`; its separate
local mode remains `off | ask | auto`, with `ask` as the safe default.

## 2. Choose a workflow preset

Only when the workflow module is enabled, read `.workflow/presets.yml`. Ask the user
**one** question first:

> Which workflow preset do you want?
> - **fast** — minimal process, plan only (no options, no TDD, no granular commits)
> - **medium** — balanced (adds options + granular commits; no TDD) *(recommended default)*
> - **full** — complete workflow (all stages + light TDD strict-lite)
> - **custom** — configure each feature individually

Show each preset's `label` and `description` from `presets.yml` verbatim.

Then:

- If the user picked **fast / medium / full**: load that preset's `features:`
  map from `presets.yml` and apply the values to the corresponding fields in
  `workflow.yml` (see each feature's `controls:` path). **Skip every bootstrap
  question about features that are disabled in the chosen preset** — for
  example, do not ask about light TDD in Fast or Medium.
- If the user picked **custom**: iterate `presets.yml → features:` in order
  and ask the feature's `question` (yes/no) for each entry. Fill
  `workflow.yml` from the answers. When a feature has `when_enabled_mode`,
  apply that mode value whenever the feature is enabled.

Write the chosen preset name to `.workflow/presets.yml → meta.active_preset`
and mirror it to `.workflow/workflow.yml → meta.preset`.

### 2.1 Configure optional cross-harness delegation

Only when the orchestration module is enabled, ask whether the project should enable long-running delegation to external CLI
harnesses. This uses the local `.workflow/bin/hekate-agent` job controller — no
MCP server or daemon.

If disabled, keep `.workflow/orchestration.yml → enabled: false` and do not ask
model questions. If enabled:

1. Read `.workflow/orchestration.yml → harnesses` and run
   `.workflow/bin/hekate-agent doctor` (or the PowerShell counterpart on
   Windows). Treat only `ok` entries as installed choices; `missing` entries
   are normal optional CLIs and `disabled` entries are unavailable by policy.
2. Explain that the primary user-facing harness exclusively owns architecture,
   task decomposition, profile/model choice, subagent/harness orchestration,
   review, and final verification. Delegated children are bounded
   executors/advisors and may not recursively delegate. The runner never infers
   complexity or architecture from prompt text.
3. Explain the advisory-vs-writer split before asking about profiles: most
   harnesses in `orchestration.yml` ship as an unsuffixed advisory/read-only
   entry (research, review, propose — never edits files) and a
   `<name>-write` twin that edits files unattended using that CLI's safest
   available writer flag (never a bypass-everything flag). `pi` has no
   permission gate at all and has no `-write` twin — plain `pi` already
   writes unattended. A `-write` entry, and plain `pi`, must always run in a
   dedicated git worktree, never the primary session's checkout. Write
   access is a property of the task, not the project: a "review" or
   "research" profile should route to an advisory entry; only a profile
   meant to actually change files (e.g. "implement") should route to a
   `-write` entry or `pi`.
4. Ask whether routing should use one default harness or arbitrary named
   profiles. Offer `small`, `medium`, `complex`, and optional `small-deep` as a
   recommended complexity-oriented set, but do not require these names; teams
   may instead define profiles by role, risk, cost, provider, or another
   policy — including an advisory/writer split such as `review`, `research`,
   and `implement` (see step 3).
5. For one default, ask which `ok` harness to use — including whether it
   should be the advisory entry or its `-write` twin, given what the default
   will be used for — then its model and, only when `supports_effort: true`,
   effort. Write `default_profile: null`.
6. For named routing, ask for each profile's name, whether it should write,
   and an `ok` harness (an advisory entry, unless the profile is explicitly
   for writing, in which case its `-write` twin or `pi`). Model and effort
   are optional: omitted values fall back to that harness's defaults. Choose
   `default_profile` — prefer an advisory profile as the default so an
   unqualified run never writes unattended by accident.
7. A valid pi example, only when those models are actually available, is:
   `small = openai-codex/gpt-5.6-terra + high`,
   `small-deep = openai-codex/gpt-5.6-terra + xhigh`,
   `medium = openai-codex/gpt-5.6-sol + medium`, and
   `complex = openai-codex/gpt-5.6-sol + high`. Do not install these as
   universal defaults, and remind the user that plain `pi` always writes.
8. Write `enabled: true`, `default_harness`, `default_profile`, profiles, and
   harness defaults to the committed orchestration config.
9. Explain local selection without committed changes:
   `.workflow/bin/hekate-agent config use-profile <name>` or
   `.workflow/bin/hekate-agent config use <harness> --model <id> --effort <level>`.

CLI flags are version-sensitive. If `doctor` or a smoke test shows that an
installed harness changed its non-interactive flags, update only its declarative
registry entry rather than the runner.

## 3. Identify the project type

- **New** (empty repo / just `git init`) → *interview* mode.
- **Existing** (has sources, manifests) → *analyze + confirm* mode.

## 4. New project: interview

Ask the user questions by groups, one group at a time:

1. **Meta**: name, kind (web-app / cli / library / service / …), a short
   description.
2. **Stack**: languages and versions, frameworks (backend/frontend/testing),
   databases, infrastructure, external services, commands (install/dev/test/lint/build).
3. **Architecture**: style (clean / hexagonal / ddd / mvc / modular-monolith / …),
   layers and their dependencies, major modules, patterns, anti-patterns.
4. **Conventions**: formatter, linter, line length, naming (files,
   directories, variables, classes, constants), test layout, branching
   rules. For commits, do not ask free-form questions — run the
   **Commit convention preset** procedure below.
5. **Workflow rules**: the process features were already decided via the
   chosen preset (or custom answers). Do **not** re-ask about features the
   active preset has disabled. Only confirm settings for features that the
   preset enables and that require extra parameters, such as commit-message
   language. Everything else comes from `presets.yml`.

After each group, show the filled-in YAML and ask the user to confirm or adjust.

## 5. Existing project: analysis

Analyze the repo **on your own**, gathering facts:

- Dependency manifests: `package.json`, `pyproject.toml`, `requirements*.txt`,
  `go.mod`, `Cargo.toml`, `Gemfile`, `composer.json`, `pom.xml`, `build.gradle*`.
- Linter/formatter configs: `.eslintrc*`, `.prettierrc*`, `ruff.toml`,
  `pyproject.toml [tool.*]`, `.golangci.yml`, `rustfmt.toml`.
- Directory structure: presence of `src/`, `app/`, `internal/`, `domain/`,
  `application/`, `infrastructure/`, test directories.
- CI: `.github/workflows/`, `.gitlab-ci.yml`, `circleci/`.
- Containerization: `Dockerfile`, `docker-compose.yml`, `k8s/`.
- Commit history (`git log --oneline -n 100`) for message style.
- `README.md` for the description and run commands.

Based on the facts, fill out drafts of all four YAML files. Then:

1. Show the user the result one file at a time.
2. Explicitly flag fields you are **not sure about** (mark `# TODO: confirm`).
3. Do not fill in a field if there isn't enough evidence — leave it empty.
4. Process features (TDD, granular commits, options, …) were decided via the
   workflow preset. Do not re-ask about them here; the values in
   `workflow.yml` already reflect the preset from `presets.yml`.
5. For the `commits:` block, run the **Commit convention preset** procedure —
   first recommend a preset based on `git log --oneline -n 100`, then still
   show all presets.
6. Ask the user to confirm or correct each file.

## 6. Finishing initialization

- Write all YAML files: `stack.yml`, `architecture.yml`, `conventions.yml`,
  `workflow.yml`, and `presets.yml` (with `meta.active_preset` set).
- Write `.workflow/status.yml` as the fast pre-flight index:
  - `hekate.enabled` and `hekate.modules.*` mirror `workflow.yml → hekate`
  - `initialized: true`
  - `active_preset` equal to `presets.yml → meta.active_preset`
  - `checks.required_files_present: true`
  - `checks.required_fields_filled: true`
  - `features.*` equal to the resolved preset/custom feature map
  - `orchestration.enabled`, `orchestration.default_harness`,
    `orchestration.default_profile`, config path, and runner path mirror
    `.workflow/orchestration.yml`
  - `native_subagents.policy: .workflow/session.local.yml` and
    `native_subagents.missing_or_invalid_mode: ask`
  - `required_files` and `required_non_empty_fields` mirror the blocking rules
    from `workflow.yml`
- Create `.workflow/history/` if the history module is enabled and it does not exist.
- If the native-subagents module is enabled, ensure `.workflow/session.local.yml` exists with `subagents.mode: ask` when no
  local choice exists. Never overwrite an explicit local `off` / `ask` / `auto`
  choice during bootstrap.
- Make sure `.workflow/history/` and `.workflow/session.local.yml` are in
  `.gitignore` (if not, add them).
- Tell the user: "The workflow is initialized. You can now assign tasks."
- If the history module is enabled, create the first history entry for the bootstrap itself:
  `.workflow/history/<date>-bootstrap.md`. Include the chosen preset name
  and the resolved feature map so future sessions know what was applied.
- If `workflow.yml → git.three_branch_model.enabled` is `true`, ensure
  the repo has the three branches listed in
  `git.three_branch_model.branches` (defaults: `main`, `stage`, `dev`).
  For each missing branch, create it locally from the current `HEAD`
  (or from the configured `main` branch if it already exists). Do
  **not** push without asking the user. Record the result in the
  bootstrap history entry. Mirror the resolved branch names into
  `conventions.yml → branches.protected`, and set
  `branches.model: three-branch`,
  `branches.default: <main-branch-name>`, and
  `branches.flow: "feature → dev → stage → main"`.

## 7. Commit convention preset

Do not ask "what commit style do you use?" in the abstract. Instead show the
user the four named presets below, ask which one fits, and fill the whole
`commits:` block in `conventions.yml` from the chosen preset. If none fits,
fall back to `custom` and ask the raw fields by hand.

Presets (language is handled separately, see below — any preset works with
any language):

1. **conventional** — Conventional Commits 1.0.
   Examples: `feat(auth): add OAuth login` / `feat(auth): добавить OAuth-логин`.
2. **gitmoji** — emoji from gitmoji.dev in front of the type.
   Examples: `✨ feat(auth): add OAuth login` / `✨ feat(auth): добавить OAuth-логин`.
3. **emoji-prefix** — short local emoji map in front of the type.
   Map: `✨ feat`, `🐛 fix`, `♻️ refactor`, `📝 docs`, `✅ test`, `🚀 perf`,
   `🔧 chore`, `⏪ revert`. Example: `🐛 fix(api): handle empty body`.
4. **free-form** — no strict template, only the subject length is enforced.
   Example: `Fix empty body handling in API`.

Fifth option — `custom`: if none of the presets fits, ask the user to fill
the raw `commits:` fields manually.

For an existing project, first look at `git log --oneline -n 100`, try to
guess which preset the history already matches, and recommend it — but still
show the full list.

After the user picks a preset, fill `conventions.yml → commits:` exactly from
the template below. The `language` value comes from a separate question (see
next subsection) and is **not** part of the preset.

```yaml
# conventional
commits:
  style: conventional
  preset: conventional
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: [feat, fix, refactor]
  forbid_in_subject: ["ticket numbers without prefix"]

# gitmoji
commits:
  style: gitmoji
  preset: gitmoji
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: [feat, fix, refactor]
  forbid_in_subject: []
  # full map: see https://gitmoji.dev

# emoji-prefix
commits:
  style: conventional
  preset: emoji-prefix
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: [feat, fix, refactor]
  forbid_in_subject: []
  emoji_map:
    feat: "✨"
    fix: "🐛"
    refactor: "♻️"
    docs: "📝"
    test: "✅"
    perf: "🚀"
    chore: "🔧"
    revert: "⏪"

# free-form
commits:
  style: free-form
  preset: free-form
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: []
  forbid_in_subject: []
```

### Commit message language (separate question)

Right after the preset is chosen, ask one extra question:

> In which language should commit subjects and bodies be written?
> `en | ru | de | es | fr | pt | zh | ja | other` — or a free string,
> e.g. `ru-en-mix` for a mixed style.

Write the user's answer verbatim into `commits.language`. For an existing
project, first look at `git log` to estimate the dominant language and offer
it as the default — but accept whatever the user says.

## 8. Extending with new process features

The registry of customizable process features lives in
`.workflow/presets.yml → features:`. To add a new customizable step to the
workflow (e.g., `security_review`, `architecture_diff`, `dependency_audit`):

1. Append one entry to `presets.yml → features:` with a unique `id`,
   a `description`, a `question` (for custom mode), a `controls:` list
   naming the `workflow.yml` paths it writes to, and `defaults:` with a
   boolean for each of `fast`, `medium`, `full`.
2. If needed, add the matching block to `.workflow/workflow.yml` at the
   path named in `controls`.
3. Optionally reference the new feature from `AGENTS.md` task workflow so
    agents know when to run it.
4. Add the feature's resolved boolean to `.workflow/status.yml → features`
   if agents need it during normal pre-flight or task routing.

**Do not** hardcode new features in `AGENTS.md`, `init-workflow.md`, or in
adapter files. The bootstrap procedure is data-driven over `presets.yml` —
a new entry automatically appears in preset application and custom mode.
