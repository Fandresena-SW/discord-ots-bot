# Implementation Prompt for RFC-007: Challonge Schema & Cache Tables

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-007: the Challonge integration's data layer — a
nullable `tournaments.challonge_tournament_id` link column, and two cache
tables (`challonge_participants_cache`, `challonge_matches_cache`) that let the
bot resolve a player's current opponent without ever calling the Challonge API
directly. Refer to:
- `knowledge/FEATURES.md` §"v3.0 — Challonge Integration" for the feature specs
  (F26–F29) and the locked v3.0 architecture decisions
- `knowledge/RFCs/RFCS.md` §"v3.0 — Challonge Integration" for the RFC sequence
  and dependency table
- `.claude/RULES.md` for project guidelines and standards (note: v2.0-era; this
  RFC's own §9 "Applicable rules" section calls out where v3.0 will need
  amendments to RULES.md, but does not make them itself)
- `RFC-007-Challonge-Schema.md` for the specific requirements being implemented
- `schema.sql` (existing, RFC-001) for the conventions and the
  `trim_ingame_name()` function this RFC reuses

Note there is no formal `PRD.md` v3.0 section yet (see RFC-007's own
"Documentation gap" note) — FEATURES.md's v3.0 addendum is the authoritative
spec for this work.

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements and existing codebase (in particular the existing
   `schema.sql` structure and the `trim_ingame_name()` function this RFC reuses)
2. Present a comprehensive implementation plan covering:
   - Exact SQL to append to `schema.sql` (tables, trigger, indexes, RLS, seed data)
   - Proposed implementation sequence
   - Technical decisions and trade-offs (e.g. upsert vs. append semantics for
     the cache tables, the `state` check constraint's fail-loud behavior)
   - Potential impacts on existing functionality (should be none — purely additive)
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined (column → participants cache →
   matches cache → RLS → seed data)
3. Explain your approach for complex sections (in particular the reused trigger
   and the upsert contract RFC-008 will depend on)
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (naming, idempotency idioms,
   English identifiers) except where RFC-007 itself documents a deliberate
   deviation
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — reuse
   `trim_ingame_name()` as specified rather than writing a second trim function
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-007-Challonge-Schema.md` (F26–F29). Do **not**
implement the Edge Function (RFC-008), the `/ots` refactor (RFC-009), or the
runbook/E2E work (RFC-010) — note dependencies on them but leave them
unimplemented. In particular, do not write any Edge Function code or touch
`bot.py` in this RFC.

## Final Deliverables
1. All SQL changes necessary to implement the RFC (appended to `schema.sql`)
2. Verification queries per the project's testing standards (commented, in
   `schema.sql`, mirroring RFC-001's pattern)
3. Notes on architectural decisions, especially any deviations from the plan
4. Potential improvements or scaling considerations for the future
