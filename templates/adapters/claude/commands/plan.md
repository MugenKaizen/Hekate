---
description: Produce a self-contained task plan following AGENTS.md rules (stage 3.3)
---

Produce a plan for the task (use the analysis that was already done and
the option that was agreed on):

$ARGUMENTS

First verify that neither `status.yml → hekate.enabled` nor
`hekate.modules.workflow` is explicitly false. If either is false, explain that the workflow module is
disabled and suggest `/init-workflow` to change the module selection.

Plan requirements — from `AGENTS.md` section 3.3. When the history module is
enabled, the plan is written to `.workflow/history/YYYY-MM-DD-<slug>.md`;
otherwise return it in the conversation. It must be **self-contained** —
it can be opened in a new session without context and executed.

Required sections:

1. **Context** — why this task exists, what problem it solves.
2. **Affected files** — full paths of files to be created or modified
   with a description of the changes.
3. **Steps** — atomic step-by-step actions.
4. **Verification** — commands and scenarios for checking.
5. **Rollback notes** — what to do if something goes wrong (for risky
   changes; may be omitted for simple ones).
6. **Checkpoint checklist** — for large tasks when
   `status.yml → features.granular_commits` is `true`. Each checkpoint
   must include its verification and the commit message to use after it passes.

If `status.yml → features.light_tdd` applies, reflect it in the steps:
add or update a focused test first, run the narrowest relevant check if
practical to see it fail, then implement the minimum code needed to make
it pass. If test-first is impractical, state why in the plan and add the
test immediately after implementation.

If `status.yml → features.granular_commits` applies, break the work into
checkpoint-sized slices that can be verified and committed independently.

If solution options haven't been discussed yet, first go back to the
**Options** stage (at least 2 options with pros/cons), get agreement on
an option, and only then write the plan.

When the history module is enabled, after the plan is written append a `planned` event to
`.workflow/history/events.jsonl`.
