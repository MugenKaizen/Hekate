---
description: Analyze a task following AGENTS.md rules (stage 3.1)
---

Perform the **Analyze stage** from `AGENTS.md` (section 3.1) for the task:

$ARGUMENTS

What to do:

1. Make sure the fast pre-flight check in `.workflow/status.yml` has passed.
   If not, stop and run `/init-workflow`.
2. Understand the goal of the task. If it is unclear, ask clarifying
   questions **before** the analysis.
3. Find and **read** every affected file. Don't guess from names.
4. Lazy-load `.workflow/architecture.yml` and `.workflow/conventions.yml` only
   when their invariants apply.
5. Decide whether `status.yml → features.light_tdd` applies. For a
   behavior change, identify the test that should be added or updated first.
6. If `status.yml → features.granular_commits` is enabled, decide whether the
   task is large enough for checkpoint commits and identify likely checkpoint
   boundaries.
7. Produce a brief report: what was understood, which files were studied,
   which constraints apply.

At this stage **do not propose solutions and do not write code** — only
the analysis.
