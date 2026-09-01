# Philosophy

## Problem

Agents need project context, but that context is often scattered and every
harness has a different instruction format. Hekate provides one portable
project contract without pretending that Markdown can enforce runtime facts.

## Principles

1. **Portable first.** Project policy is readable YAML and Markdown, not a
   harness-specific API.
2. **One entry point.** `AGENTS.md` contains a compact adaptive contract;
   adapters point to it instead of copying rules.
3. **One owner per datum.** Authored values are not mirrored manually in the v1
   contract. Legacy `status.yml` remains only until the deterministic compiler
   emits `status.lock.json`.
4. **Adaptive process.** Understand every task, decide and plan only when
   needed, execute narrowly, and always verify implementation work.
5. **No hidden authority.** Profiles never authorize commits, branches,
   destructive actions, native subagents, or external harnesses.
6. **Progressive disclosure.** Load stack, architecture, conventions,
   bootstrap, history, and legacy components only when relevant.
7. **Evidence is not acceptance.** Commands and child results are observed
   evidence. The primary session owns review and final acceptance.
8. **No silent data loss.** Installation and upgrades preserve user-owned and
   project-owned configuration or abort before mutation.

## Enforcement Matrix

| Rule | Classification |
|---|---|
| Understand the request, inspect affected code, avoid unrelated work | Advisory |
| Compare alternatives only for material choices | Advisory |
| Evaluate whether a written plan is warranted | Advisory |
| Portable preflight refusal before initialization | Advisory; mechanically gated only by a supporting runtime |
| Plan approval after an explicit plan-first request or material scope change | Deterministic from the conversation; advisory without a runtime gate |
| TDD mode and required test evidence | Deterministic authored policy plus observable evidence |
| Verification before completion | Observable evidence; semantic sufficiency remains advisory |
| Commit and branch creation | Deterministic `explicit-request-only` consent |
| Dependency additions and destructive actions | Deterministic explicit user consent; mechanically gated where supported |
| External fallback after native denial or unavailability | Deterministically forbidden by portable policy; mechanically gated where supported |
| Passing checks or child success implies acceptance | Forbidden; primary review and acceptance remain advisory responsibilities |
| Optional history note | Observable artifact, never mandatory |
| Native-subagent authorization | Harness-owned, outside portable enforcement |
| External delegation availability | Explicit legacy component capability |
| Readiness, path safety, capabilities, and generated-state protection | Mechanically gated only by a supporting runtime |

Portable Markdown states expectations but does not claim to enforce tool calls.
The future core and Pi extension mechanically gate only objective conditions.
