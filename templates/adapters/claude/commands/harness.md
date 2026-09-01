---
description: Manage the legacy experimental external-harness controller when already installed
allowed-tools: Bash(.workflow/bin/hekate-agent *)
---

This command is legacy compatibility for an existing `0.x` installation. It is
not part of bootstrap, portable authorization, or automatic fallback.

Before use:

1. Require existing `.workflow/orchestration.yml` and
   `.workflow/bin/hekate-agent` files.
2. Require `.workflow/orchestration.yml -> enabled: true`.
3. Read `.workflow/delegation.md` and the legacy component documentation.
4. Keep architecture, decomposition, routing, review, and acceptance in the
   primary session.

Use `--task` for a short contract or an arbitrary private `--task-file` for a
larger one. Do not require optional workflow history to store delegation input.
Never invoke this command because native delegation was unavailable or denied.

$ARGUMENTS
