# Implementation Prompt for RFC-012: Points Engine & Sync Freeze

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-012: the **points engine and the one-way freeze**
— extending RFC-008's `challonge-sync` Edge Function to carry `final_rank`
through from Challonge, compute points from a pure placement table × the event's
tier multiplier, and write `tournament_results` rows with a full snapshot of
every input the points depended on.

This is the highest-risk RFC in v4.0, for one narrow reason: **the freeze is
one-way by default (F56), and the obvious completion check is wrong (F68).**
Deriving "the tournament is over" from "all cached matches are complete" fires
at the **group-stage boundary**, before the final bracket's matches exist in
`matches.json` at all — irreversibly freezing half an event. A conditional third
Challonge call is what closes that hole. Refer to:
- `knowledge/PRD.v4.final.md` §31.4 (the points engine), **§31.5 (the freeze —
  including the seven-step, short-circuiting algorithm you must implement in
  order)**, §37, §40
- `knowledge/FEATURES.md` §O and §P (F51–F57, F68, F72, F74)
- `.claude/RULES.md` §11–§14 (the v3.0 Edge Function stack, architecture and
  cache contract), **§18 (which this RFC must reword)**, §20
- `RFC-012-Points-Engine-And-Sync-Freeze.md` for the specific requirements being
  implemented — in particular §3.5 (the algorithm), §3.6 (the read/write
  sequence and why `completed_at` is set last), §3.7 (the response contract)
- `supabase/functions/challonge-sync/index.ts` and `mapping.ts` (existing) —
  study the handler's step order, `upsertRows`, `resolveTournament`, and the way
  the dual-id trap is commented in `mapping.ts`; F74's `active` trap must be
  commented at the same depth and in the same place
- `RFC-008-Challonge-Sync-Edge-Function.md` for the invariants you must preserve
  (all-or-nothing before any write, upsert-never-append, the secret gate)
- `RFC-011-Ranking-Schema.md` §3.5 for the exact `tournament_results` columns,
  every one of which is `not null` on the snapshot side

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements and existing codebase
2. Present a comprehensive implementation plan covering:
   - Files to create or modify
   - Key components, data structures, and APIs — including the exact pure
     surface of `points.ts` and why `final_rank` does **not** join
     `ParticipantCacheRow`
   - Proposed implementation sequence
   - Technical decisions and trade-offs — in particular: **how you will keep the
     two opposing write semantics separable** (caches are refreshed constantly
     and overwritten; `tournament_results` is written once and never
     overwritten), how `freeze_count` is computed without a transaction, and why
     upsert-then-prune is ordered that way
   - Potential impacts on existing functionality — confirm every v3.0 behavior
     is untouched: the secret gate, both unconditional Challonge calls, the
     all-or-nothing rule, both cache upserts, and the strict `state` enum. State
     explicitly which existing lines you are changing and which you are only
     appending after
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined (pure `points.ts` + its tests →
   `mapping.ts` extension + its tests → `runFreeze()` → handler wiring →
   documentation rewording)
3. Explain your approach for complex sections — specifically the third-call
   arming condition and every path on which it must **not** fire
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (v3.0 Addendum §11–§20 and the
   v4.0 addendum RFC-011 added), except §18's call-count invariant, which **this
   RFC is explicitly chartered to amend** in both `RULES.md` §18 and `PRD.md` §21
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — reuse
   `upsertRows` and `resolveTournament` (widening its `select`) rather than
   adding parallel helpers
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-012-Points-Engine-And-Sync-Freeze.md` (F51–F57,
F68, F72, F74). Do **not** touch `bot.py`, `test_bot.py`, or `schema.sql` — all
v4.0 DDL is RFC-011's, and if you find yourself needing a column, raise it
rather than adding one. Do not implement any Discord command (RFC-013) or read
command (RFC-014). Do not build DQ/forfeit handling or any behavior that assumes
an answer to the two known unknowns in PRD §37 — flag them, as RFC-012 §8 does.
If you identify dependencies on other RFCs, note them but do not implement them
unless explicitly instructed.

## Final Deliverables
1. All code changes necessary to implement the RFC —
   `supabase/functions/challonge-sync/{index.ts,mapping.ts,points.ts}`, plus the
   reworded call-count invariant in `.claude/RULES.md` §18 and
   `knowledge/PRD.md` §21
2. Necessary tests per the project's testing standards — a new `points_test.ts`
   and an extended `mapping_test.ts` joining the existing Deno suite, covering
   every bucket edge, **the tournament-3 real-data fixture (the 14-element rank
   vector totalling 480)**, tie equality, invalid input, and
   `allMatchesComplete([]) === false`; plus a report of the **staged
   group-stage walkthrough** in RFC-012 §10.2 — a real Challonge group-stage
   tournament with fake players, advanced one match at a time, triggered after
   each, **walked through with the user rather than reported afterwards**
   (step 2's boundary exists for one trigger only). Record the observed
   Challonge call counts per trigger (2 normally, 3 when armed), the raw
   `/tournaments/{id}.json` body captured at the boundary, and — opportunistically
   — whether `final_rank` is null before completion
3. Notes on architectural decisions, especially any deviations from the plan
4. Potential improvements or scaling considerations for the future
