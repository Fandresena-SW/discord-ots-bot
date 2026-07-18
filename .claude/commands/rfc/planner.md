---
description: Explore the codebase then write a detailed implementation plan for an RFC. Produces .claude/rfc-plans/RFC-[N]-plan.md. Run before /rfc:coder.
---

# RFC Planner

The user has invoked `/rfc:planner <N>`. Extract the RFC number from the args (e.g. `7` → pad to `007` where needed for filenames).

You will perform two phases sequentially: **Explore**, then **Plan**. Do not spawn sub-agents — execute both phases yourself.

---

## Phase 1 — Explore

You are a codebase scout. Produce a factual map of the existing code relevant to the RFC. No planning, no recommendations, no code changes — facts only.

### Steps

1. Read `knowledge/RFCs/RFC-[N]-*.md` to understand the RFC's full scope.
2. Run `ccc search` queries for each major concept in the RFC (cash register, payroll, etc.). If `ccc search` fails with an initialization error, run `ccc init && ccc index` from the project root first.
3. Run `find lib/ supabase/ test/ -type f | sort` to get the full file tree.
4. Read all existing source files in the impacted feature folder(s).
5. Read `lib/core/router/app_router.dart`.
6. Run `ls supabase/migrations/` and note the highest-numbered file.
7. Read any existing migration files relevant to tables this RFC touches.

### Exploration Output (keep in memory for Phase 2)

Produce internally:

```
EXPLORATION REPORT
RFC: [N]

### 1. Files to create or modify
[path] — [new | NNN lines] — [reason]

### 2. Existing patterns
Providers: [list existing AsyncNotifier/FutureProvider in the feature folder, or none]
Models: [list existing @freezed models, or none]
Routes: [list current routes in app_router.dart relevant to this feature, or none]
DB tables: [list relevant tables with columns, or none]

### 3. Potential conflicts
[file:line — description of conflict risk, or none]

### 4. Migration context
Next migration number: [NNNN]
Relevant existing functions/triggers: [list, or none]
```

---

## Phase 2 — Plan

You are a senior Flutter architect. Using the Exploration Report from Phase 1, design a precise, ordered implementation plan. Every architectural decision and sequencing choice is made here.

### Before writing the plan, also read

1. `knowledge/RFCs/implementation-prompt-RFC-[N].md` — done checklist
2. `.claude/CLAUDE.md` and `.claude/rules/` — all project standards
3. Every file flagged in the Exploration Report as a conflict risk

Use `ccc search <concept>` to verify how similar features were implemented when a pattern in the exploration report is unclear.

### Plan Structure

Write a complete plan covering these sections in order:

#### 1. SCOPE SUMMARY
One paragraph: what this RFC adds/changes. One sentence: what is explicitly out of scope.

#### 2. DATABASE MIGRATIONS
For each migration file to create:
- Exact filename (`NNNN_description.sql`, using the next number from the exploration report)
- Tables/columns/types (with PostgreSQL types)
- RLS policies: table + role + operation + condition expression
- Indexes: every FK column and every column used in `WHERE` or `ORDER BY`
- Triggers: `log_audit()` on every writable table (INSERT/UPDATE/DELETE)
- PostgreSQL functions to create or modify (signature + behavior summary)

#### 3. DART MODELS
For each `@freezed` model to create or modify:
- File path, class name
- All fields with Dart types (money as `int`, no `double`)
- Whether `build_runner` must run after this model

#### 4. PROVIDERS
For each Riverpod provider:
- File path, provider name, type (`AsyncNotifier` / `FutureProvider` / `StreamProvider`)
- Exact columns to query (no `SELECT *`)
- Filters and pagination (`.range()` if list can exceed 20 rows)
- Mutations exposed and which providers to `ref.invalidate()` after each

#### 5. SCREENS & WIDGETS
For each screen/widget to create or modify:
- File path, purpose
- Provider(s) it watches
- All four states: loading → error → empty → data
- Navigation: which widget/button triggers navigation to this screen

#### 6. ROUTING
- Exact route paths to add to `app_router.dart`
- Entry points (file:line of the widget that triggers navigation to each route)

#### 7. EDGE FUNCTIONS (if any)
- Function name and directory under `supabase/functions/`
- Trigger (DB trigger / pg_cron / direct client call)
- Input parameters and output JSON contract

#### 8. IMPLEMENTATION ORDER
Numbered sequence the coder must follow. Migrations always first, models second, providers third, UI last.

#### 9. RISK AREAS
Each conflict identified in the exploration report and the exact strategy to resolve it.

### Output

Write the plan to `.claude/rfc-plans/RFC-[N]-plan.md`, then print:

```
PLAN COMPLETE
RFC: [number]
Plan written to: .claude/rfc-plans/RFC-[N]-plan.md
Sections: [comma-separated list of sections with content]
Risk areas: [count, or none]
Complexity estimate: Low | Medium | High
Next step: /rfc:coder [N]
```
