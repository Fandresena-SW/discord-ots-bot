---
description: Explore the codebase then write a detailed implementation plan for an RFC. Produces .claude/rfc-plans/RFC-[N]-plan.md. Run before /rfc:coder.
---

# RFC Planner

The user has invoked `/rfc:planner <N>`. Extract the RFC number from the args
(e.g. `11` → pad to `011` where needed for filenames).

You will perform two phases sequentially: **Explore**, then **Plan**. Do not
spawn sub-agents — execute both phases yourself.

## Instructions

The full instructions for both phases are the sub-agent definitions, which are
the single source of truth for this project. Read and follow them:

1. **`.claude/agents/explorer.md`** — Phase 1. Follow its Process and produce
   its `EXPLORATION REPORT` output block. Ignore its frontmatter (model, tools).
2. **`.claude/agents/planner.md`** — Phase 2. Feed it your own exploration
   report, follow its Plan Structure, write
   `.claude/rfc-plans/RFC-[N]-plan.md`, and emit its `PLAN COMPLETE` block.

They are kept in one place deliberately: this repo has been bitten before by two
copies of the same instructions drifting apart.

## Pre-flight

- Confirm `knowledge/RFCs/RFC-[N]-*.md` exists. If not, stop and say so.
- Check `knowledge/RFCs/RFCS.md` that **every lower-numbered RFC is complete.**
  Implementation is strictly sequential here. If a predecessor is still a draft,
  say so before planning — the plan may be built on something that does not
  exist yet.

## After the plan

Summarize it for the user — files to be touched, implementation order, new
dependencies (should be **none**), and risk areas — and **stop there.** Every
`implementation-prompt-RFC-*.md` in this repo mandates explicit user approval of
the plan before any code is written. Do not start implementing; tell the user to
run `/rfc:coder [N]` once they approve.
