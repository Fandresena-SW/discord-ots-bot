# Implementation Prompt for RFC-014: Ranking Read Commands, Runbook §9 & Release

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-014: **the closing RFC of v4.0** — the two French
ranking read commands (`/standings`, public; `/profile`, ephemeral), both
restricted to one configured channel, plus the documentation, the release gate,
and the sign-off. It mirrors RFC-006's and RFC-010's role exactly.

The one genuinely hard thing is **F70's render contract**. The leaderboard is
only the second place in this project that emits variable-length text into a
Discord embed, and an oversized description is **rejected by Discord outright** —
which presents to a player as the command silently failing. The 4096-character
cap is therefore a correctness requirement, not presentation polish, and F70
belongs in F14's category rather than the "formatting" category it resembles.
Refer to:
- `knowledge/PRD.v4.final.md` §31.8 (the read commands and the render
  contract), §31.9, §32 (non-functional requirements — defer before I/O, render
  safety, fail-soft, a ranking outage never affecting `/ots`), §34, **§41 (all
  36 release-gate scenarios)**
- `knowledge/FEATURES.md` §S, §T, §U (F62–F65, F70, F73, F75)
- `.claude/RULES.md` §5 step 5 (render-safety — F70 is F14's contract on a
  second surface), §7/§17 (fail-soft), §8/§18 (the E2E checklist as the primary
  release gate), §10 (keep the docs in sync), plus the v4.0 addendum
- `RFC-014-Ranking-Read-Commands-And-Release.md` for the specific requirements
  being implemented — in particular §3.2 (the three claimants on the character
  budget and the drop-rows-never-truncate-mid-row algorithm), §3.4 (why the
  channel check must exist at exactly two explicit call sites), §3.6 (the
  named-status table with its French copy), and §7.1 (the documentation
  deliverables, which are co-equal with the code)
- `bot.py` (existing) — study `render_team_text` closely: `render_standings` is
  its sibling and must follow the same budget discipline. Reuse
  `DISCORD_DESC_LIMIT`, the `0x3B4CCA` color, the defer-before-I/O rule and the
  5s bounded read
- `RFC-004-Pure-Logic-Normalization-Render-Safety.md` for the char-accounting
  precedent, and `RFC-011-Ranking-Schema.md` §3.3/§3.7 for the `current_season`
  and `season_standings` views these commands read

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements and existing codebase
2. Present a comprehensive implementation plan covering:
   - Files to create or modify — **including the six documents**, not just the code
   - Key components, data structures, and APIs — the exact PostgREST queries
     (one indexed read each), and the pure signature of `render_standings`
   - Proposed implementation sequence
   - Technical decisions and trade-offs — in particular: how rank numbers are
     assigned from points alone while the four sort keys decide row order only,
     how the footer's budget is reserved before rows are emitted, and how you
     will resolve `discord_user_id` for mentions without a per-row lookup
   - Potential impacts on existing functionality — **confirm explicitly that no
     channel check exists anywhere `/ots` can reach.** A shared decorator or a
     helper `/ots` calls would silently break F75's boundary; two explicit call
     sites, commented
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined (config → `in_ranking_channel` →
   pure `render_standings` + its tests → `/standings` → `/profile` → the
   optional per-tournament filter → French copy → documentation → the release
   gate)
3. Explain your approach for complex sections — specifically the character
   budget and the tie-break/rank-number split
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (§1–§10, the v3.0 Addendum, and
   the v4.0 addendum), and extend the v4.0 addendum with anything this RFC
   decides that the PRD does not already state
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — reuse
   `DISCORD_DESC_LIMIT`, the embed color, the PostgREST header/timeout helpers,
   and RFC-013's profile-resolution helper rather than re-deriving them
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in
`RFC-014-Ranking-Read-Commands-And-Release.md` (F62–F65, F70, F73, F75). Do
**not** touch `schema.sql` (all v4.0 DDL is RFC-011's — if a display requirement
seems to need a view change, raise it rather than adding one), do not touch
`supabase/functions/`, and do not modify `/ots`, `/ots-organizer`,
`/link-organizer` or `/unlink` beyond what registering two more commands
requires. Historical-season browsing, ranking-aware seeding, a web leaderboard
and a dispute flow are explicitly out of scope (PRD §29). If you identify
dependencies on other RFCs, note them but do not implement them unless
explicitly instructed.

## Final Deliverables
1. All code changes necessary to implement the RFC — `bot.py`, `.env.example`,
   plus the documentation this RFC owns: **`knowledge/RUNBOOK.md` §9** (all
   eleven topics in RFC-014 §7.1, in French),
   **`knowledge/E2E-CHECKLIST-v4.md`** (F73 — French, all 36 PRD §41 scenarios
   with a PASS/FAIL column and a sign-off line), `knowledge/DEPLOYMENT.md` (both
   new non-secret env vars), and the `.claude/RULES.md` v4.0 addendum
2. Necessary tests per the project's testing standards — new `unittest` coverage
   for `render_standings` (rank numbering including ties, all four ordering
   keys, mentions vs. bare names, the top-25 cap, a synthetic oversized field
   asserting `len(result) <= DISCORD_DESC_LIMIT`, and degenerate input),
   `in_ranking_channel`, and the extended `validate_config`; plus the executed
   `E2E-CHECKLIST-v4.md` with its result. **Scenarios 11, 25 and 29 cannot be
   waived** — 11 proves the group-stage boundary freezes nothing, and 25 and 29
   together are the measure of the release's security goal
3. Notes on architectural decisions, especially any deviations from the plan —
   and confirmation that the four status trackers (`CLAUDE.md`'s convention) plus
   `FEATURES.md` were updated on sign-off, and that **the `/ots` change was
   announced**, which is a release requirement no other RFC will remind anyone
   about
4. Potential improvements or scaling considerations for the future
