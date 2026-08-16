---
description: Write and run tests for an RFC implementation. Covers stdlib unittest for pure Python logic, Deno tests for the Edge Function, SQL verification statements, and a French E2E checklist. Run after /rfc:reviewer passes.
---

# RFC Tester

The user has invoked `/rfc:tester <N>`. Extract the RFC number.

## Instructions

Read and follow **`.claude/agents/tester.md`** — its Role, Inputs, the four Test
Scope sections, its Process, and its exact `TEST REPORT` output block. Ignore its
frontmatter (tools). Execute yourself; do not spawn a sub-agent.

That file is the single source of truth for how this repo tests — kept in one
place so the command and the agent cannot drift apart.

## The philosophy, restated because it is easy to over-build

> **Test the pure logic exhaustively; verify everything else by hand.**
> Network paths are kept thin around pure functions precisely so the pure
> functions can carry the coverage.

Do **not** add a mocking framework, a fixtures directory, a `tests/` package,
`pytest`, or any new dependency. Python tests append to the single root-level
`test_bot.py` using stdlib `unittest`; Deno tests sit beside the code they
cover.

## Reminders

- `python -m unittest test_bot` **needs the venv** — `bot.py` imports `aiohttp`.
  If import fails, report `BLOCKED (venv/import)`, not a test failure.
- Schema invariants are verified by **commented statements in `schema.sql`'s
  verification block**, executed against a disposable
  `postgres:16-alpine` container — the RFC-001/007 precedent.
- **RLS must be checked against PostgREST with the anon key**, not in the SQL
  editor, which runs as a superuser role and proves nothing.
- The E2E checklist is **French**, matches `knowledge/E2E-CHECKLIST-v3.md`'s
  format, and — where the RFC has a release-gate section — matches its scenarios
  one for one without renumbering or merging them.
