# Implementation Prompt for RFC-008: Challonge Sync Edge Function (Manual Trigger)

## Role and Mindset
You are a senior software developer. Approach this implementation with:

1. **Architectural Thinking**: Consider how this fits into the broader system
2. **Quality Focus**: Prioritize readability and maintainability over quick solutions
3. **Pragmatism**: Balance best practices with practical considerations
4. **Defensive Programming**: Anticipate edge cases and potential failures

## Context
This implementation covers RFC-008: the Challonge integration's sync layer —
a Supabase Edge Function (TypeScript/Deno) that, on a secret-protected manual
trigger, performs a full refresh (2 Challonge API calls) and upserts the
results into RFC-007's cache tables. This is the **first non-Python runtime**
in this repo. Refer to:
- `knowledge/PRD.md` §16, §18.2, §18.4, §19, §24 (v3.0 addendum) for the
  product-level requirements and locked architecture decisions
- `knowledge/FEATURES.md` §"v3.0 — Challonge Integration" §I for F30–F31
- `.claude/RULES.md` v3.0 Addendum §11–12, §14, §16, §19 for the guardrails
  specific to this RFC (stack, the documented `supabase/functions/` folder
  exception, the upsert/all-or-nothing data contract, secret handling)
- `RFC-008-Challonge-Sync-Edge-Function.md` for the specific requirements
  being implemented (request/response contract, resolution sequence, mapping
  rules)
- `RFC-007-Challonge-Schema.md` and `schema.sql` for the exact shape of the
  two cache tables this function writes into, and their unique keys (the
  upsert `on_conflict` targets)

Note this RFC's own §3.4 flags that the Challonge API v1 Basic-Auth
convention should be verified against Challonge's current docs before being
hardcoded — do not treat the RFC's description of it as unverified gospel.

## Two-Phase Approach

### Phase 1: Planning (No Code)
1. Analyze the requirements: the request/response contract (RFC-008 §3.2–3.3),
   the Challonge API calls and payload shapes (§3.4–3.5), and the upsert
   writes (§3.6)
2. Present a comprehensive implementation plan covering:
   - Files to create (`supabase/functions/challonge-sync/index.ts`,
     `supabase/config.toml` changes)
   - The exact request validation sequence (secret check → body parse →
     tournament/link lookup → Challonge calls → upsert) and its error-code
     mapping (401/400/404/502/500)
   - How the "both Challonge calls must succeed before any write" contract
     will be enforced in code
   - Whether/how the Challonge-payload-to-cache-row mapping will be factored
     into a testable pure function (RFC-008 §10)
   - Technical decisions and trade-offs (e.g. raw `fetch` to PostgREST vs.
     any client library — RFC-008 §3.6 already locks this to raw `fetch`;
     confirm you're following it, don't relitigate)
   - Potential impacts on existing functionality (should be none — `bot.py`,
     `schema.sql`, `requirements.txt` are all untouched by this RFC)
3. Wait for explicit user approval before proceeding
4. Address any feedback or modifications from the user

### Phase 2: Implementation (After Approval Only)
1. Follow the approved plan, noting any necessary deviations
2. Implement in logical segments as outlined (secret/request validation →
   tournament resolution → Challonge fetch → mapping → upsert → response)
3. Explain your approach for complex sections (in particular the
   all-or-nothing write ordering and the upsert `on_conflict` targets)
4. Self-review before finalizing

## Implementation Standards
1. Follow all conventions in `.claude/RULES.md` (v3.0 Addendum §11–20)
   except where RFC-008 itself documents a deliberate deviation
2. Do not create workarounds. If you encounter a challenge:
   a. Explain the challenge clearly
   b. Propose a proper architectural solution
   c. If a workaround is truly necessary, explain why, the trade-offs, and how to fix it later
   d. Flag workarounds with `WORKAROUND: [explanation]` in comments
   e. Never implement a workaround without user approval
3. Improve existing methods/components rather than creating duplicates — this
   is new code, but keep it to the single Edge Function file unless a small
   pure sub-module is clearly warranted for testability
4. Apply SOLID principles and established design patterns where appropriate,
   scaled to a small serverless function — do not over-architect this

## Problem Solving
When making design decisions on complex problems:
1. Explain alternative approaches considered with pros/cons
2. Make recommendations based on best practices, not expediency
3. Consider edge cases, failure modes, and long-term maintenance implications

## Scope Limitation
Only implement features in `RFC-008-Challonge-Sync-Edge-Function.md` (F30,
F31). Do **not** implement the `/ots` refactor (RFC-009) or the
runbook/staleness/release work (RFC-010) — note dependencies on them but
leave them unimplemented. Do not touch `bot.py`, `schema.sql`, or
`requirements.txt` in this RFC.

## Final Deliverables
1. All code changes necessary to implement the RFC (the Edge Function source
   and `supabase/config.toml` change)
2. Necessary tests per the project's testing standards (Deno-side unit tests
   for any extracted pure mapping logic, per RFC-008 §10; manual verification
   steps performed and reported for the network-dependent behavior)
3. Notes on architectural decisions, especially any deviations from the plan
   (e.g. if the Basic-Auth convention verification in §3.4 turned up
   something different from the RFC's description)
4. Potential improvements or scaling considerations for the future
