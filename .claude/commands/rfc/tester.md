---
description: Write and run tests for an RFC implementation. Covers static analysis, unit tests, widget tests, integration tests (RLS), and an E2E checklist. Run after /rfc:reviewer passes.
---

# RFC Tester

The user has invoked `/rfc:tester <N>`. Extract the RFC number.

You are a Flutter QA engineer. Write practical, executable tests that give the team confidence in the implementation. Every test must be tied to a concrete acceptance criterion or business rule.

## Before writing tests, read

1. `knowledge/RFCs/RFC-[N]-*.md` — specification and acceptance criteria
2. `knowledge/RFCs/implementation-prompt-RFC-[N].md` — done checklist
3. `.claude/rules/testing.md` — coverage targets and test patterns
4. All implementation files created or modified by this RFC

Use `ccc search <concept>` to find existing test patterns before writing new tests (e.g. `ccc search "unit test AsyncNotifier mock"`, `ccc search "RLS integration test ChefProd"`). If `ccc search` fails, run `ccc init && ccc index` first.

## Process

### 1. STATIC ANALYSIS

Run and report:
```bash
flutter analyze
```

Search for forbidden patterns in `lib/`:
```bash
grep -rn "print(" lib/ | grep -v "debugPrint"
grep -rn "TODO\|FIXME" lib/
grep -rn ": dynamic" lib/
```

### 2. UNIT TESTS

Write unit tests in `test/unit/` for:
- Every new calculation function (`calculateMargin`, `formatMGA`, payroll helpers)
- Each test must cover: happy path, zero values, boundary values, invalid inputs
- Provider logic testable without a live Supabase connection

File naming: `test/unit/[feature]_test.dart`

Run: `flutter test test/unit/`

### 3. WIDGET TESTS

For each new screen in the RFC:
- Verify loading state shows a `CircularProgressIndicator` or skeleton
- Verify error state shows an error message in French
- Verify empty state shows an appropriate empty message
- Verify data state renders the expected widgets

File naming: `test/unit/[feature]_screen_test.dart`

Run: `flutter test test/unit/`

### 4. INTEGRATION TESTS (RLS)

Write integration tests in `test/integration/` verifying for each new table:
- `ChefProd` can read all rows (if applicable)
- `ChefDept` can only read own department rows (if applicable)
- `DG` can read aggregate/summary views
- Unauthorized INSERT/UPDATE/DELETE raises an RLS violation, not a silent empty result

These tests connect to a local Supabase instance (`supabase start`). If no local instance is running, skip with a clear note.

File naming: `test/integration/rls_[feature]_test.dart`

### 5. E2E CHECKLIST (manual)

For each user journey touched by this RFC, produce a step-by-step checklist:

```
ID: T-[RFC]-[NNN]
Journey: [name from PRD §8]
Account: [ChefProd | ChefDept | DG]
Precondition: [DB state required]
Steps:
  1. [exact tap / fill / action]
  2. ...
Expected: [exact UI outcome]
DB check: [optional SQL to verify DB state after]
```

## Output

End with this exact block:

```
TEST REPORT
RFC: [number]
flutter analyze: PASS | FAIL
Unit tests: [N passed] / [N total] | FAIL ([list failing tests])
Widget tests: [N passed] / [N total] | FAIL ([list failing tests])
Integration tests: [N passed] / [N total] | SKIPPED (no local Supabase) | FAIL
Files created: [path per line]
Coverage gaps: [untested scenarios worth noting, or none]
E2E checklist: [N test cases] — see above
```

If all of the following are true:
- `flutter analyze: PASS`
- All unit and widget tests pass
- No coverage gaps for calculation functions

Then print:
```
RFC-[N] is COMPLETE. All gates passed.
Recommended next step: open a PR from branch rfc-[N] into main.
```

Otherwise print which gates are still open.
