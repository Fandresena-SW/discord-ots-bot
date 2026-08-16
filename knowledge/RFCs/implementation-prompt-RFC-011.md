# Implementation Prompt for RFC-011: Ranking Schema — Profiles, Seasons, Tiers & Frozen Results

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-011: the **data layer for v4.0's ranking and
identity system** — the first RFC of the v4.0 series and the one that gates
every other. It adds four tables (`profiles`, `seasons`, `tournament_tiers`,
`tournament_results`), five columns, two views, an auto-link trigger, and RLS
across all of it, as an idempotent addition to `schema.sql`. There is **no
Python and no TypeScript in this RFC.**

Two things make it different in kind from RFC-001 and RFC-007: it introduces the
project's **first non-disposable data** (a lost season of standings cannot be
reconstructed), and its **first genuinely personal data**
(`profiles.discord_user_id`). Refer to:
- `knowledge/PRD.v4.final.md` §31.1–§31.3 (the data model), §37 (the
  locked-decision table), §39 (the migration contract) — and read the ⚠️ box in
  §27 first, so you understand why the binding is an authorization boundary
- `knowledge/FEATURES.md` §L, §M, §N (F38–F50, F66, F67) and its
  "Supersession & amendment notes" table
- `.claude/RULES.md` §4 (the DB contract), §6 (security/RLS posture), §2
  (no new folders), §10 (locked decisions)
- `RFC-011-Ranking-Schema.md` for the specific requirements being implemented —
  in particular §3.1 (the deliberate ordering exception), §3.6 (the auto-link
  trigger's fail-closed/fail-open rules) and §3.8 (the `security_invoker` trap)
- `schema.sql` (existing) — study RFC-001's idempotency idioms, the
  `trim_ingame_name()` function and its two triggers, the RLS block, the guarded
  seed pattern, and the commented verification block you must amend
- `RFC-001-Supabase-Schema.md` and `RFC-007-Challonge-Schema.md` for the
  precedent this RFC follows: append one self-contained section, verify against a
  disposable local Postgres container, never create a second SQL file

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements and existing codebase
2. Present a comprehensive implementation plan covering:
   - Files to create or modify
   - Key components, data structures, and APIs
   - Proposed implementation sequence — **including why the v4.0 block cannot
     follow `schema.sql`'s established tables → function → trigger → indexes →
     RLS → seed order, and what internal order you will use instead** (RFC-011
     §3.1: the `tier_id` not-null backfill depends on seeded tier rows)
   - Technical decisions and trade-offs — in particular: how each object stays
     idempotent (including the one constraint with no `if not exists` form), and
     how you will prove both new **views** are closed to `anon`
   - Potential impacts on existing functionality — confirm that
     `players`/`tournaments` keep every existing column, index, trigger and
     query semantic, that `/ots`'s v3.0 read path is untouched, and state
     explicitly what the `tier_id` backfill writes to pre-existing production rows
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined
3. Explain your approach for complex sections — specifically the F42 exclusion
   constraint, the `tier_id` add → backfill → constrain sequence, and the
   auto-link trigger's two fail-open guards
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` — and **add the v4.0 addendum
   starting at §21** (v3.0's ends at §20) per RFC-011 §7
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — reuse
   `trim_ingame_name()`'s precedent and the existing seed/verification idioms
   rather than inventing parallel ones
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-011-Ranking-Schema.md` (F38–F50, F66, F67, and
the **DDL halves** of F60, F69, F70). Do **not** implement the points formula or
the freeze (RFC-012), any bot command (RFC-013), or any read command (RFC-014).
Do not touch `bot.py`, `test_bot.py`, or `supabase/functions/`. If you identify
dependencies on other RFCs, note them but do not implement them unless
explicitly instructed.

## Final Deliverables
1. All code changes necessary to implement the RFC — `schema.sql` and
   `.claude/RULES.md` only
2. Necessary tests per the project's testing standards — the commented
   verification block extended per RFC-011 §10 (all nine checks), the RFC-007
   "delete the test tournament" step amended in place for F48, and a report of
   an actual two-pass idempotency run plus the F49 anon/service-key check
   against PostgREST (the SQL editor runs as a superuser role and proves nothing
   for RLS)
3. Notes on architectural decisions, especially any deviations from the plan
4. Potential improvements or scaling considerations for the future
