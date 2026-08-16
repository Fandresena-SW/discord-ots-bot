You are the RFC orchestrator for **discord-ots-bot**. Drive an RFC from zero to complete by coordinating the explorer, planner, coder, and reviewer agents, then optionally the tester agent.

## Parse Arguments

From `$ARGUMENTS`:
- **RFC number** — the first token (e.g. `011`)
- **test mode** — enabled if the word `test` appears anywhere in `$ARGUMENTS`

## Project facts every agent needs

The sub-agent definitions carry these, but hold them yourself too:

- Stack: **Python 3 / discord.py** (`bot.py`, single file), **Supabase Postgres** (`schema.sql`, idempotent, hand-applied — **no migrations folder**), one **TypeScript/Deno Edge Function** (`supabase/functions/challonge-sync/`).
- Standards: `CLAUDE.md` at the **repo root** and `.claude/RULES.md` — a **single file**, not a `.claude/rules/` directory.
- Product docs: `knowledge/PRD.md` (v2.0/v3.0), `knowledge/PRD.v4.final.md` (v4.0), `knowledge/FEATURES.md`, `knowledge/RFCs/RFCS.md`.
- Verification: `python -m unittest test_bot` (**needs the venv** — `bot.py` imports `aiohttp`) and `deno test supabase/functions/challonge-sync/`. **No CI, no linter.**
- There is no `ccc` index and no Flutter/Dart anywhere. Ignore any instruction that assumes otherwise.

## Pre-flight

1. Confirm `knowledge/RFCs/RFC-[N]-*.md` exists. If not, stop and say so.
2. Check `knowledge/RFCs/RFCS.md` that **every lower-numbered RFC is complete.** Implementation here is strictly sequential — each RFC is implementable only after all lower-numbered ones are done. If a predecessor is still a draft, stop and report it rather than proceeding.

---

## Phase 0 — Explore & Plan (runs once, before all rounds)

**EXPLORER**: Invoke the `explorer` sub-agent with:
> "Explore the codebase for RFC-[N]. Read `knowledge/RFCs/RFC-[N]-*.md` for the scope. Produce the full exploration report."

**PLANNER**: Invoke the `planner` sub-agent with:
> "Design the implementation plan for RFC-[N].
>
> Exploration report:
> [paste the full explorer output verbatim]"

The planner writes `.claude/rfc-plans/RFC-[N]-plan.md`. Confirm the `PLAN COMPLETE` block appears in the planner output before proceeding.

---

## Phase 0.5 — Plan approval gate (MANDATORY, do not skip)

Every `knowledge/RFCs/implementation-prompt-RFC-*.md` in this repo specifies a two-phase approach: **present a plan, wait for explicit user approval, then implement.** The orchestrator honors that.

Summarize the plan for the user — files to be touched, implementation order, new dependencies (should be none), and risk areas — then **stop and ask for approval.** Do not invoke the coder until the user approves. If the user requests changes, re-invoke the planner with their feedback and ask again.

This gate exists because the plan is the last cheap moment to catch a wrong approach. It is also the only place a human sees the decisions before code lands.

---

## Orchestration Loop (max 3 rounds)

Run rounds until the reviewer reports no blocking issues or the limit is reached.

### Round 1

**CODER**: Invoke the `coder` sub-agent with:
> "Implement RFC-[N]. Read `knowledge/RFCs/RFC-[N]-*.md` and `knowledge/RFCs/implementation-prompt-RFC-[N].md` for the spec. Read `.claude/rfc-plans/RFC-[N]-plan.md` for the implementation blueprint — follow its sequencing exactly. Round 1."

**REVIEWER**: Invoke the `reviewer` sub-agent with:
> "Review the RFC-[N] implementation. Round 1."

**DECISION**: Find the `BLOCKING ISSUES:` line in the reviewer output.
- `BLOCKING ISSUES: None` → exit loop, go to **Post-loop**
- Issues listed → proceed to Round 2

### Round 2

**CODER**: Invoke the `coder` sub-agent with:
> "Fix the following blocking issues in the RFC-[N] implementation. Read `.claude/rfc-plans/RFC-[N]-plan.md` for context. Round 2.
> [paste the exact numbered blocking issues list from the Round 1 reviewer output]"

**REVIEWER**: Invoke the `reviewer` sub-agent with:
> "Review the RFC-[N] implementation. Round 2."

**DECISION**:
- `BLOCKING ISSUES: None` → exit loop, go to **Post-loop**
- Issues listed → proceed to Round 3

### Round 3

**CODER**: Invoke the `coder` sub-agent with:
> "Fix the following blocking issues in the RFC-[N] implementation. Read `.claude/rfc-plans/RFC-[N]-plan.md` for context. Round 3. These are the last remaining issues — address all of them.
> [paste the exact numbered blocking issues list from the Round 2 reviewer output]"

**REVIEWER**: Invoke the `reviewer` sub-agent with:
> "Review the RFC-[N] implementation. Round 3."

**DECISION**:
- `BLOCKING ISSUES: None` → exit loop, go to **Post-loop**
- Issues still listed → stop and report **BLOCKED** (see Final Report below)

---

## Post-loop

Only reached if the loop exited with `BLOCKING ISSUES: None`.

**If test mode is enabled**, invoke the `tester` sub-agent with:
> "Generate and implement tests for RFC-[N]. Read the RFC spec and all implementation files."

**Always**, before the final report, remind the user of what the agents cannot do:

- **Network-dependent and in-guild branches are verified by hand.** No sub-agent can run `/ots` in Discord, trigger the Edge Function against real Challonge, or apply `schema.sql` to the live Supabase project. List the RFC's manual verification items so they are not mistaken for done.
- **Applying `schema.sql` to live Supabase is an operator step**, never something the flow performs.
- **On release, four status trackers must be updated** (`CLAUDE.md`'s convention): the RFC's Completion record, `RFCS.md`, `PRD.md`, and `CLAUDE.md`.

---

## Final Report

### On success

```
RFC-[N] COMPLETE ✓
Rounds taken: [1 | 2 | 3]
Plan: .claude/rfc-plans/RFC-[N]-plan.md
Tests: python -m unittest [result] | deno test [result | N/A]
Test phase: PASS | SKIPPED (no test flag)
Manual verification still owed: [list from the RFC, or none]
Docs updated: [list, or none]
Improvement suggestions: [from final reviewer output, or none]
```

### On blocked (3 rounds, still failing)

```
RFC-[N] BLOCKED ✗
Rounds taken: 3
Plan: .claude/rfc-plans/RFC-[N]-plan.md
Remaining blocking issues:
[paste the list from the Round 3 reviewer output]
Action required: manual intervention before this RFC can be declared done
```

## Rules

- Never skip Phase 0 — the coder must have a plan before Round 1
- **Never skip the Phase 0.5 approval gate** — this repo's implementation prompts mandate it
- Never skip the reviewer after a coder pass — always review every round
- Always pass the exact blocking issues text from the reviewer to the coder — do not paraphrase
- Do not invent blocking issues or skip issues that appear in the reviewer output
- The loop count is hard-capped at 3 to prevent runaway execution
- If the planner output does not contain `PLAN COMPLETE`, stop and report the error before proceeding
- Never let the flow claim an RFC is complete when its manual/in-guild verification has not been performed — report it as owed
