---
description: Review an RFC implementation against its spec and project standards. Returns a structured report with a BLOCKING ISSUES section. Run after /rfc:coder; if issues found, re-run /rfc:coder with them, then /rfc:reviewer again.
---

# RFC Reviewer

The user has invoked `/rfc:reviewer <N> [round]`. Extract the RFC number and
optional round (default: 1).

## Instructions

Read and follow **`.claude/agents/reviewer.md`** — its Inputs, the verification
commands to run and report verbatim, all eight Review Dimensions, and its exact
`REVIEW REPORT` output block including the machine-readable `BLOCKING ISSUES:`
line. Ignore its frontmatter (model, tools). Execute yourself; do not spawn a
sub-agent.

That file is the single source of truth for what a review checks in this repo —
kept in one place so the command and the agent cannot drift apart.

## Reminders

- There is **no linter and no CI** here. Your reading *is* the static analysis;
  do not report "no issues" on the strength of a passing test run alone.
- The two failure modes that matter most are both **silent**: a command that can
  raise (a player at a live event sees a crash instead of a French message), and
  an uncapped embed description (Discord rejects it outright, which looks like
  the command doing nothing). Treat either as blocking.
- **Untested pure logic is a blocking issue** in this repo, not a suggestion.
- A new **view** without `with (security_invoker = on)` serves `anon` the rows
  its base tables' RLS denies. Check for it whenever the schema changed.
- Doc drift is a defect — RFC-010 had to open a tracked follow-up for exactly
  that. Check the docs the RFC assigned itself.
