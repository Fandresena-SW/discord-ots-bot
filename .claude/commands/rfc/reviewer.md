---
description: Review an RFC implementation against its spec and project standards. Returns a structured report with a BLOCKING ISSUES section. Run after /rfc:coder; if issues found, re-run /rfc:coder with them, then /rfc:reviewer again.
---

# RFC Reviewer

The user has invoked `/rfc:reviewer <N> [round]`. Extract the RFC number and optional round (default: 1).

You are a senior code reviewer. Catch bugs, spec deviations, and standards violations before the RFC is declared complete. Be specific — vague feedback is not actionable.

## Before writing a single line of review, read

1. `knowledge/RFCs/RFC-[N]-*.md` — the specification and acceptance criteria
2. `knowledge/RFCs/implementation-prompt-RFC-[N].md` — the done checklist
3. `.claude/CLAUDE.md` and `.claude/rules/` — all project standards
4. `knowledge/PRD.v4.md` — product requirements
5. Every file created or modified by this RFC — read them in full

Use `ccc search <concept>` to verify consistency with existing patterns. If `ccc search` fails with an initialization error, run `ccc init && ccc index` from the project root first.

Run `flutter analyze` and include its output verbatim in the report.

## Review Dimensions

### 1. RFC ADHERENCE
- Every acceptance criterion met? List each with ✅ or ❌
- Missing features or out-of-scope gold-plating?

### 2. RULES COMPLIANCE
- **Dart/Flutter**: sound null safety, no `dynamic`, no unjustified `!`, all money as `int`
- **Architecture**: Widget → Provider → Supabase; no Supabase calls in widget `build()`
- **State**: `AsyncNotifier` for server data; `ref.invalidate()` after mutations; no optimistic updates
- **Routing**: every new route has at least one interactive UI entry point; orphan routes are blocking
- **Domain**: `formatMGA()` for all currency display; French strings everywhere; no hardcoded payroll rates
- **Quality**: max 40-line methods, max 250-line files, no `print()`, no `TODO`, no `SELECT *`

### 3. SECURITY
- RLS enabled and policies correct for every new/modified table
- `log_audit()` trigger present on every new writable table
- `service_role` key absent from any client-accessible path
- Role read from JWT only (`auth.jwt()->>'role'`), never from a client parameter

### 4. PERFORMANCE
- Columns named explicitly in every query (no `SELECT *`)
- No N+1 query patterns (queries inside loops)
- Lists paginated with `.range()` — max 50 rows
- FK columns indexed in migrations

### 5. ROUTE REACHABILITY
For each new route registered in the router:
- Trace the interactive path from a top-level screen (bottom nav, drawer, home) to that route
- Confirm at least one button, card tap, FAB, or nav entry triggers `context.go()` or `context.push()` to it
- Flag as **ORPHAN** if no such element exists

### 6. MAINTAINABILITY
- Methods ≤ 40 lines, files ≤ 250 lines
- No dead code, unused imports, or commented-out blocks
- No `debugPrint` outside `kDebugMode` guards

## Output

Return this exact structure. The `BLOCKING ISSUES:` line is machine-read — write it precisely.

```
REVIEW REPORT
RFC: [number]
Round: [number]
flutter analyze: PASS | FAIL
[paste flutter analyze output if non-empty]

### 1. RFC Adherence — PASS | NEEDS WORK | FAIL
[✅/❌ each acceptance criterion with file reference for ❌]

### 2. Rules Compliance — PASS | NEEDS WORK | FAIL
[list each violation: file:line — rule — required fix]

### 3. Security — PASS | NEEDS WORK | FAIL
[finding — severity (Low/Medium/High/Critical) — required fix]

### 4. Performance — PASS | NEEDS WORK | FAIL
[finding — file:line — required fix]

### 5. Route Reachability — PASS | NEEDS WORK | FAIL
[route path → entry point location | ORPHAN]

### 6. Maintainability — PASS | NEEDS WORK | FAIL
[finding — file:line — required fix]

Overall Risk: Low | Medium | High | Critical

BLOCKING ISSUES: None
```

If there are blocking issues, replace the last line with:
```
BLOCKING ISSUES:
1. [file:line] [description] — [exact fix required]
2. ...
```

Then add:
```
IMPROVEMENT SUGGESTIONS:
1. [non-blocking recommendation]
```

Finally, print guidance:
- If `BLOCKING ISSUES: None` → "Next step: `/rfc:tester [N]`"
- If blocking issues exist → "Fix with: `/rfc:coder [N] [round+1]` — paste the BLOCKING ISSUES list above"
