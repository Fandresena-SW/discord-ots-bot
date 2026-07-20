# Implementation Prompt for RFC-009: `/ots` Opponent-Resolution Refactor

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-009: the highest-complexity RFC in the v3.0
addendum. It changes `/ots`'s argument meaning from "the player to look up"
to "your own username," and adds a new resolution path
(`fetch_current_opponent`) that finds the caller's current opponent via
RFC-007's Challonge cache tables before reusing v2.0's existing
`fetch_active_player` verbatim for the final team_text lookup. Refer to:
- `knowledge/PRD.md` §17, §18.3, §20, §24 (v3.0 addendum) for the product
  requirements, the seven-outcome model, and the locked "no fallback to
  v2.0 arbitrary-lookup" decision
- `knowledge/FEATURES.md` §"v3.0 — Challonge Integration" §J for F32–F34
- `.claude/RULES.md` v3.0 Addendum §13–15, §17, §20 for this RFC's specific
  guardrails (the opponent-resolution contract, expanded fail-soft, the
  confirmed behavior-change posture)
- `RFC-009-OTS-Opponent-Resolution.md` for the specific requirements being
  implemented (the exact resolution sequence, the six-outcome status model,
  the title-echo deviation from RFC-005, French copy)
- `bot.py` (existing) — study `fetch_active_player`, `normalize_name`,
  `_escape_ilike`, and the current `ots` command body closely; this RFC reuses
  all of them and adds a sibling read path alongside, without modifying them
- `RFC-007-Challonge-Schema.md` for the cache tables' exact columns/keys this
  RFC's new queries read from

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements and the existing `bot.py` structure in detail —
   in particular, confirm your understanding of exactly which existing
   functions are reused unmodified vs. which are new
2. Present a comprehensive implementation plan covering:
   - The exact shape and query sequence of the new `fetch_current_opponent`
     helper (RFC-009 §3.1–3.2), including its six-status return contract
   - Whether/how the "pick the current match, resolve the other side's id"
     logic will be factored into a pure, unit-testable function (RFC-009 §7)
   - The rewritten `ots` command handler's branching, including the
     title-echo deviation (opponent's stored name, not the caller's raw
     input) and why
   - The updated command/argument description text
   - Proposed implementation sequence
   - Technical decisions and trade-offs (e.g. the accepted double
     active-tournament-query inefficiency noted in RFC-009 §7 — confirm you
     understand why `fetch_active_player` is not being refactored)
   - Potential impacts on existing functionality — confirm `fetch_active_player`,
     `normalize_name`, `_escape_ilike`, `render_team_text` remain byte-for-byte
     unchanged
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined (new helper → command handler
   rewrite → French copy → command metadata)
3. Explain your approach for complex sections (in particular the multi-step
   resolution chain and its defensive handling of malformed/degenerate cache
   data)
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (v3.0 Addendum §13–20)
   except where RFC-009 itself documents a deliberate deviation (e.g. the
   title-echo change)
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — but
   see RFC-009 §3.2/§7 for the specific, deliberate exception where a
   near-duplicate active-tournament query is preferred over widening a v2.0
   function's contract
4. Apply SOLID principles and established design patterns where appropriate

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-009-OTS-Opponent-Resolution.md` (F32, F33,
F34). Do **not** implement the 48h staleness backstop (F36, explicitly
RFC-010's scope per RFC-009 §8) or the runbook/E2E/release work (RFC-010) —
note the forward-compatibility consideration (making `fetched_at` trivially
addable to the existing query later) but do not add the staleness check
itself. Do not touch `schema.sql` or the Edge Function.

## Final Deliverables
1. All code changes necessary to implement the RFC (`bot.py` only)
2. Necessary tests per the project's testing standards — unit tests added to
   the existing `test_bot.py` for any extracted pure logic (RFC-009 §7/§10),
   plus a report of manual verification against RFC-007's seed fixtures for
   the network-dependent branches
3. Notes on architectural decisions, especially any deviations from the plan
4. Potential improvements or scaling considerations for the future
