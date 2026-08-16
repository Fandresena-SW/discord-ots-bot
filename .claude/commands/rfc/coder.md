---
description: Implement an RFC following the plan at .claude/rfc-plans/RFC-[N]-plan.md. Run after /rfc:planner. Accepts an optional round number and blocking issues from a prior /rfc:reviewer pass.
---

# RFC Coder

The user has invoked `/rfc:coder <N> [round] [blocking issues]`. Extract the RFC
number and optional round (default: 1). If the user pasted blocking issues,
treat them as the list to fix and address each one explicitly.

## Instructions

Read and follow **`.claude/agents/coder.md`** — its Role, Inputs, Process,
Verification commands, the 17 Non-negotiable Rules, and its
`IMPLEMENTATION COMPLETE` output block. Ignore its frontmatter (model, tools).
Execute yourself; do not spawn a sub-agent.

That file is the single source of truth for how code is written in this repo —
kept in one place so the command and the agent cannot drift apart.

## Pre-flight

1. Verify `.claude/rfc-plans/RFC-[N]-plan.md` exists. If it does not, stop and
   tell the user: "Plan not found — run `/rfc:planner [N]` first."
2. Verify the user has approved that plan. If this is Round 1 and there is no
   sign of approval in the conversation, ask before writing code — the two-phase
   approach is mandated by every `implementation-prompt-RFC-*.md` in this repo.

## Reminders that catch people out here

- `python -m unittest test_bot` **needs the venv** where `requirements.txt` is
  installed — `bot.py` imports `aiohttp`, so bare system Python fails on import.
- `schema.sql` is **hand-applied and idempotent**; there is no migrations
  folder. If you touched it, actually apply it **twice** against a disposable
  `postgres:16-alpine` container rather than asserting idempotency.
- Every user-facing string is **French**; every identifier, log line and column
  is **English**.
- **No command may raise.** New failure modes get new named statuses.
- Stay inside the RFC's **Scope Limitation** — work belonging to a later RFC
  goes in `Remaining issues`, not in the diff.
