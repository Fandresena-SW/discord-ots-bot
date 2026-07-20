# Implementation Prompt for RFC-010: Runbook, Staleness Backstop & Release

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-010: the final RFC of the v3.0 Challonge
addendum, mirroring the role RFC-006 played for v2.0 — document, harden,
verify, and ship. It is mostly documentation/verification work, but includes
one real code change: the 48h passive cache-staleness warning (F36), folded
into RFC-009's `fetch_current_opponent`. Refer to:
- `knowledge/PRD.md` §17, §18.3 (outcome 7), §19, §20, §21, §22 (v3.0
  addendum) for the requirements this closes out
- `knowledge/FEATURES.md` §"v3.0 — Challonge Integration" §K for F35–F37
- `.claude/RULES.md` v3.0 Addendum §17–20 for this RFC's specific guardrails
  (staleness-as-log-not-gate, the E2E release gate, the deferred §9
  bookkeeping this RFC now performs)
- `RFC-010-Runbook-Staleness-Release.md` for the specific requirements being
  implemented (exact runbook section content, the staleness check's precise
  placement, the deployment doc additions, the E2E checklist shape)
- `knowledge/RUNBOOK.md`, `knowledge/DEPLOYMENT.md`, and
  `knowledge/E2E-CHECKLIST.md` (existing, from RFC-002/RFC-006) for the
  document structure and tone to match — **do not** edit
  `E2E-CHECKLIST.md` itself; RFC-010 creates a separate
  `E2E-CHECKLIST-v3.md`
- `bot.py`'s `fetch_current_opponent` (delivered by RFC-009) — this RFC
  extends it with one additional check, it does not restructure it

Since this RFC depends on RFC-007, RFC-008, and RFC-009 all being complete,
confirm before starting that all three are actually implemented and merged —
if any is still only "Drafted," stop and flag this rather than proceeding
against a moving target.

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the current state of `RUNBOOK.md`, `DEPLOYMENT.md`, and the
   already-implemented RFC-009 code
2. Present a comprehensive implementation plan covering:
   - The exact new `RUNBOOK.md` §8 content (linking, name discipline, the
     curl trigger command with a placeholder secret, the validate-then-trigger
     ordering, forgotten-trigger recovery)
   - The exact placement and logic of the F36 staleness check inside
     `fetch_current_opponent` (which query gains `fetched_at`, the comparison,
     the log line format)
   - The `DEPLOYMENT.md` Edge Function section content
   - The `E2E-CHECKLIST-v3.md` structure and full scenario list
   - The `.claude/RULES.md` §9 amendment wording
   - Proposed implementation sequence
   - Potential impacts on existing functionality (the staleness check must
     provably never change `fetch_current_opponent`'s returned status)
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments: runbook → staleness check → deployment doc
   → E2E checklist authoring → RULES.md amendment
3. Explain your approach for complex sections (in particular confirming the
   staleness check is purely additive/non-blocking)
4. Self-review before finalizing
5. **Execute** the E2E checklist and the deployment verification as this
   RFC's testing strategy requires (RFC-010 §10) — this RFC's own acceptance
   criteria require the checklist to actually be run and recorded, not just
   authored

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (v3.0 Addendum §17–20)
   except where RFC-010 itself documents a deliberate deviation
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — the
   staleness check reuses data RFC-009's query already fetches; do not add a
   second query for it
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-010-Runbook-Staleness-Release.md` (F35, F36,
F37). This is the final RFC of the v3.0 addendum — there is nothing further
to defer, but do not expand scope beyond what F35–F37 specify (e.g. do not
add a timed dry-run gate; RFC-010 §8 explicitly notes v3.0 has no such
requirement).

## Final Deliverables
1. All changes necessary to implement the RFC: `bot.py` (staleness check
   only), `knowledge/RUNBOOK.md` (extended), `knowledge/DEPLOYMENT.md`
   (extended), `knowledge/E2E-CHECKLIST-v3.md` (new), `.claude/RULES.md`
   (small amendment)
2. The E2E checklist actually executed, with results recorded per row, plus
   the pre-release `python -m unittest test_bot` re-run confirmed passing
3. Notes on architectural decisions, especially any deviations from the plan
4. A completion record analogous to RFC-006's, summarizing what was
   delivered and verified, since this RFC closes out the v3.0 addendum
