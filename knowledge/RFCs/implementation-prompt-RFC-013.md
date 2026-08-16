# Implementation Prompt for RFC-013: Identity Binding, `/ots` Refactor & Organizer Debug Lookup

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-013: **the release's only breaking change and its
entire security goal.** `/ots` loses its argument and infers the caller from a
Discord account the organizer bound once, so it can only ever reveal that
caller's own opponent. This closes a real leak found during v3.0 — because
`/ots <name>` returns *that person's opponent's* team sheet, any player could
walk the roster and scout the whole field before being paired.

Everything else in the RFC exists to make that possible or survivable:
`/link-organizer` (organizer-only binding, once per human), propagation and
backfill, `/unlink` (the player's erasure path, which also revokes their
`/ots`), and `/ots-organizer` (typed-name lookup surviving **only** as an
organizer-gated debug command).

**The binding is an authorization boundary, not leaderboard bookkeeping.** A
false binding buys silent, instant access to a team sheet the holder is not
entitled to, and no after-the-fact correction can un-see it. Refer to:
- `knowledge/PRD.v4.final.md` **§31.7 (read this first)**, §31.6 (binding and
  its conflict rules), §31.9 (configuration), §37, §38 (contingency — including
  the fact that break-glass restores the leak), §41 scenarios 2–9 and 24–32
- `knowledge/FEATURES.md` §Q and §R (F58–F61, F69, F71, F76, F77, F78)
- `.claude/RULES.md` §5 (the `/ots` behavioral contract), §7 and §17 (fail-soft,
  seven outcomes becoming nine), **§15 (the v3.0 opponent-resolution contract,
  which this RFC amends rather than discards)**, §6, §20
- `RFC-013-Identity-Binding-And-OTS-Refactor.md` for the specific requirements
  being implemented — in particular §3.1 (`bot.py` gains its first write path
  and why the freeze still belongs in TypeScript), §3.2 (extract the core, add
  two thin entry points), §3.3's nine-status table with its exact French copy,
  §3.6's F59 conflict matrix, and §3.7's mandatory propagation log
- `bot.py` (existing) — study `fetch_current_opponent`, `fetch_active_player`,
  `normalize_name`, `_escape_ilike`, `participant_candidate_ids`,
  `pick_opponent_id`, `_warn_if_stale`, `render_team_text` and the current `ots`
  handler closely. **Everything from `participant_candidate_ids()` downward is
  reused verbatim**; `fetch_current_opponent()` keeps its exact public shape and
  becomes `/ots-organizer`'s entry point
- `RFC-009-OTS-Opponent-Resolution.md` for the resolution chain you are
  wrapping, and `RFC-011-Ranking-Schema.md` §3.2/§3.6 for `profiles`,
  `players.profile_id` and the auto-link trigger this RFC verifies but does not
  implement

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements and the existing `bot.py` structure in detail — in
   particular, confirm your understanding of exactly which existing functions
   are reused unmodified, which are extracted, and which are new
2. Present a comprehensive implementation plan covering:
   - Files to create or modify
   - Key components, data structures, and APIs — including the exact shape of
     the extracted resolution core and its two entry points, and the single
     write seam every `POST`/`PATCH`/`DELETE` goes through
   - Which decision logic you will factor into **pure, unit-testable** functions
     (at minimum F59's conflict table and the organizer check), following
     RFC-004's precedent
   - Proposed implementation sequence
   - Technical decisions and trade-offs — in particular: why `/ots-organizer`
     is a separate command and **never** an optional argument on `/ots`
     (fail-direction), how the backfill is bounded to the current season and
     filtered so it can never steal an already-attributed row, and how
     `/unlink`'s confirmation is implemented without introducing UI components
   - Potential impacts on existing functionality — confirm `fetch_active_player`,
     `normalize_name`, `_escape_ilike`, `render_team_text`,
     `participant_candidate_ids`, `pick_opponent_id`, `is_cache_stale` and the
     embed/DM-delivery path remain byte-for-byte unchanged, and that the 30
     existing tests still pass
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined (config + authorization → write
   seam → resolution-core extraction → `/ots` rewrite → `/ots-organizer` →
   `/link-organizer` + backfill → `/unlink` → French copy → tests → the
   `E2E-CHECKLIST-v3.md` strike)
3. Explain your approach for complex sections — specifically the F59 conflict
   matrix, the F71 two-stage roster search, and the propagation log
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (§1–§10, the v3.0 Addendum
   §11–§20, and the v4.0 addendum), except where RFC-013 documents a deliberate
   amendment — §15's entry point, and §2's read-only data seam gaining a write
   twin, both of which must be **recorded in the RULES v4.0 addendum**, not left
   as silent drift
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — reuse
   `_escape_ilike` for **every** name filter (in this RFC it guards a write that
   grants team-sheet access, not just a read), and reuse `normalize_name` rather
   than normalizing inline
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-013-Identity-Binding-And-OTS-Refactor.md` (F58,
F59, F60's command half, F61, F69's command half, F71, F76, F77, F78). Do **not**
implement `/standings`, `/profile`, `RANKING_CHANNEL_ID`, the runbook §9, or
`E2E-CHECKLIST-v4.md` (all RFC-014). Do **not** touch `schema.sql` — the
auto-link trigger is RFC-011's and this RFC only verifies it — and do not touch
`supabase/functions/`. Do not add a self-service claim command, and do not add
an optional name argument to `/ots` under any justification. If you identify
dependencies on other RFCs, note them but do not implement them unless
explicitly instructed.

## Final Deliverables
1. All code changes necessary to implement the RFC — `bot.py`, `.env.example`,
   the `.claude/RULES.md` amendments, and the struck scenarios in
   `knowledge/E2E-CHECKLIST-v3.md`
2. Necessary tests per the project's testing standards — new `unittest` coverage
   in `test_bot.py` for the extracted pure logic (the F59 conflict table, the
   organizer check, the extended `validate_config`, and a table test asserting
   **all nine** `/ots` statuses map to distinct French messages with none
   falling through), with the 30 existing tests still green; plus a report of
   in-guild verification of the network-dependent branches, including the two
   that constitute the release's security gate: **`/ots` accepts no argument at
   all** (not "rejects one"), and `/ots-organizer` is refused for *and absent
   from the command list of* a non-organizer
3. Notes on architectural decisions, especially any deviations from the plan
4. Potential improvements or scaling considerations for the future
