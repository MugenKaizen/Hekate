# Workflow Bootstrap

Read this file only when initialization is required: configs are empty,
missing, `presets.yml → meta.active_preset` is `null`, a required field is
empty, or the user explicitly asks to "initialize the workflow" /
"/init-workflow".

## 1. Choose a workflow preset

Before interviewing or analyzing, read `.workflow/presets.yml`. Ask the user
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

## 2. Identify the project type

- **New** (empty repo / just `git init`) → *interview* mode.
- **Existing** (has sources, manifests) → *analyze + confirm* mode.

## 3. New project: interview

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

## 4. Existing project: analysis

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

## 5. Finishing initialization

- Write all YAML files: `stack.yml`, `architecture.yml`, `conventions.yml`,
  `workflow.yml`, and `presets.yml` (with `meta.active_preset` set).
- Create `.workflow/history/` if it does not exist.
- Make sure `.workflow/history/` is in `.gitignore` (if not, add it).
- Tell the user: "The workflow is initialized. You can now assign tasks."
- Create the first history entry for the bootstrap itself:
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

## 6. Commit convention preset

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

## 7. Extending with new process features

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

**Do not** hardcode new features in `AGENTS.md`, `init-workflow.md`, or in
adapter files. The bootstrap procedure is data-driven over `presets.yml` —
a new entry automatically appears in preset application and custom mode.
