---
name: unslop
description: Revises the agent's own prose for concise, evidence-led technical communication. Removes empty acknowledgements, repeated context, vague claims, stock rhetoric, and ceremonial closings without dropping caveats or failures. Use before substantial user-facing replies, PR/commit/issue text, docs, and on requests like "unslop this", "make it shorter", "stop the fluff", or "перепиши без воды".
---

# unslop

Applies to text the agent produces for a human: chat replies, plan and
summary sections, commit/PR bodies, issue comments, docs. It does not
touch code, identifiers, quoted user text, or literal file contents.

## Method

Rewrite for information density, not for a generic "human" voice. In order:

1. **Answer first.** Start with the result, finding, recommendation, or
   blocker. Add context only when it changes interpretation.
2. **Keep evidence and limits.** Preserve disagreement, unknowns, failed
   checks, skipped scope, assumptions, and platform constraints.
3. **Remove duplicate framing.** Drop flattery, request restatement,
   pre-summary, post-summary, and a closing that adds no next action.
4. **Make claims testable.** Replace evaluations with observed behavior:
   `robust` becomes `retries 5xx up to three times`. Prefer a measurement,
   file, symbol, command, or exact error over a vague magnitude.
5. **Commit once, qualify once.** State the likely conclusion, then its
   boundary: `The retry path races. I have not reproduced it under load.`
6. **Use structure only when it helps retrieval.** Prefer prose for one
   linear argument. Use a table for comparisons and bullets for genuinely
   discrete items.
7. **Read once for residue.** Remove repeated claims, stock transitions,
   mirrored slogans, and unsupported success language.

Length is a consequence, not the goal. Match detail to task size:

| Task | Default shape |
|------|---------------|
| Direct question or tiny change | answer in 1-3 sentences |
| Bounded change | outcome, relevant files, verification; at most 3 bullets |
| Multi-file or risky work | short sections for result, decisions, checks, and remaining risk |

User-requested formats and detail levels override these defaults.

## Cliché → fix

| # | Pattern | Example | Fix | Why it's slop |
|---|---------|---------|-----|---------------|
| 1 | Flattery opener | "Great question! / You're absolutely right!" | delete | Sycophancy signal; often precedes a softened answer |
| 2 | Restating the request | "You want me to refactor the parser." | delete | The user wrote it; zero information |
| 3 | Empty process update | "Let me dive into the codebase and take a look." | report a finding, decision, or blocker | Intent alone gives the user no state |
| 4 | Ceremonial closing | "Let me know if you'd like me to elaborate!" | delete | Chat can already continue |
| 5 | `not just X, it's Y` | "It's not just a cache, it's a coordination layer." | "It also holds lease state." | Rhetorical symmetry with no added fact |
| 6 | Rule-of-three padding | "clean, scalable, maintainable" | keep only properties supported by facts | Rhythm substitutes for evidence |
| 7 | Empty superlatives | "robust, seamless, powerful, elegant" | name the property: "retries on 5xx" | Not falsifiable |
| 8 | Inflated verbs | "leverage, utilize, facilitate, delve into" | use the precise ordinary verb | Formal register adds no meaning here |
| 9 | Metaphor cover | "navigate the complexity / landscape / tapestry" | state the actual difficulty | Metaphor hides that nothing was measured |
| 10 | Double hedging | "this might potentially help in some cases" | "Likely fixes it; unverified on Windows." | Two hedges = no claim |
| 11 | Hollow importance | "It's important/crucial to note that…" | drop the wrapper, keep the noun | Filler before the real sentence |
| 12 | Fake causality | "This is because of how JS handles async." | give the mechanism or say you don't know | Explanation-shaped non-explanation |
| 13 | Vague magnitude | "significantly improves performance" | "p95 420ms → 180ms" | Unmeasurable |
| 14 | Pre-summary | "Here's a summary of what I'll cover:" | delete | Table of contents for four sentences |
| 15 | Post-summary echo | "In summary, as mentioned above…" | delete | Repetition |
| 16 | Bullet reflex | 6 one-line bullets for a linear argument | use a short paragraph | Lists fragment reasoning |
| 17 | Bold-key spray | "**Fix:** … **Impact:** … **Note:** …" for trivia | plain prose | Formatting mimicking rigour |
| 18 | Emoji/section theatre | "✅ Done! 🚀", `## Overview` in a 5-line reply | delete | Ceremony |
| 19 | Success inflation | "Perfect! Everything works now!" | "Tests pass: 41/41." or the actual failure | Claims verification that didn't happen |
| 20 | Apology without repair | "You're right, I apologize for the confusion." | briefly own a real error, then correct it | Repeated apology displaces the fix |
| 21 | Capitulation | reversing a correct answer because the user pushed back | restate the evidence | Preference mirroring over truth |
| 22 | Both-sides ending | "Ultimately, it depends on your needs." | recommend one, name the tradeoff | Refuses the decision the user asked for |
| 23 | Time-setting opener | "In today's fast-paced development world…" | delete | Pure padding |
| 24 | Effort disclaimer | "This is a complex task, but I'll try my best." | do the task | Preemptive excuse |
| 25 | Repeated aside splices | 3+ em-dash asides per paragraph | use sentences or parentheses by meaning | Repeated interruptions obscure the main claim |

These are editing heuristics, not AI-detection signals. No word or
punctuation mark proves authorship. Judge whether repeated patterns lower
information density in this text.

## Self-check before sending

- Does sentence 1 carry the answer?
- Does each evaluative word encode a testable distinction?
- Any claim of success backed by output actually seen?
- Anything the user might dislike (failure, disagreement, skipped scope)
  still stated plainly?
- Is each section easier to scan than the same content as plain prose?

## Do not strip

Technical qualifiers (`only on macOS`, `not tested`, `assumes UTC`),
explicit uncertainty, meaningful progress updates, verbatim errors and
paths, user-quoted text, code and comments, and required confirmation
prompts for destructive actions.
