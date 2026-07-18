---
description: Implement an RFC following the plan at .claude/rfc-plans/RFC-[N]-plan.md. Run after /rfc:planner. Accepts an optional round number and blocking issues from a prior /rfc:reviewer pass.
---

# RFC Coder

The user has invoked `/rfc:coder <N> [round] [blocking issues]`. Extract the RFC number and optional round (default: 1). If the user pasted blocking issues, treat them as the list to fix.

You are a senior Flutter developer. Read every spec file before writing a single line of code.

## Pre-flight check

Verify `.claude/rfc-plans/RFC-[N]-plan.md` exists. If it does not, stop and tell the user: "Plan not found — run `/rfc:planner [N]` first."

## Before writing code, read

1. `.claude/rfc-plans/RFC-[N]-plan.md` — the implementation blueprint; follow its sequencing exactly
2. `knowledge/RFCs/RFC-[N]-*.md` — the full specification
3. `knowledge/RFCs/implementation-prompt-RFC-[N].md` — acceptance criteria and done checklist
4. `.claude/CLAUDE.md` and `.claude/rules/` — all project standards
5. `knowledge/PRD.v4.md` — product requirements
6. All existing source files relevant to this RFC (read them before touching them)

Use `ccc search <concept>` to find existing implementations of similar patterns before writing new code (e.g. `ccc search "AsyncNotifier mutation"`, `ccc search "RLS policy insert"`, `ccc search "formatMGA currency display"`). If `ccc search` fails with an initialization error, run `ccc init && ccc index` from the project root first.

## Process

1. **Understand** — read every file listed above; do not skip
2. **Implement** — write Dart code, SQL migrations, Edge Functions (Deno TS) as required, following the plan's implementation order
3. **Code-generate** — if any `freezed` or `riverpod_annotation` model was added or modified, run:
   ```
   dart run build_runner build --delete-conflicting-outputs
   ```
4. **Verify** — run `flutter analyze`; fix every warning and error before declaring done
5. **Self-review** — check every rule below before writing the output block

If blocking issues were provided, address each one explicitly and mark it resolved in the output.

## Non-negotiable Rules

1. **Sound null safety** — no `dynamic`, no `!` force-unwrap without a justification comment, no unwarranted `late`
2. **Screen → Provider → Supabase** — widgets never call `Supabase.instance.client` directly
3. **`AsyncNotifier` for server data** — call `ref.invalidate()` after every mutation
4. **No optimistic updates** — wait for server confirmation before updating UI
5. **RLS on every new table** — add a migration with policies; never bypass
6. **Audit trigger on every writable table** — `log_audit()` trigger in the migration
7. **4 mandatory UI states** on every async section: loading → error → empty → data
8. **French** for all user-facing strings — zero English in the UI
9. **`formatMGA()`** for every currency display — no inline formatting, no `double` for money
10. **No `SELECT *`** — always name columns explicitly
11. **Every new route reachable via UI** — navbar, button, card tap, or FAB; no orphan routes
12. **Zero `print()`, `TODO`, or `dynamic`** in delivered code
13. **Max 40 lines/method, 250 lines/file** — extract if longer

## Output

End with this exact block:

```
IMPLEMENTATION COMPLETE
RFC: [number]
Round: [1 | 2 | 3]
flutter analyze: PASS | FAIL ([error count] errors, [warning count] warnings)
build_runner: RAN | SKIPPED
Files created: [path per line, or none]
Files modified: [path per line, or none]
Migrations created: [filename per line, or none]
Edge Functions created: [name per line, or none]
Blocking issues fixed: [numbered list matching input issues, or N/A]
Remaining issues: [list, or none]
Next step: /rfc:reviewer [N] [round]
```
