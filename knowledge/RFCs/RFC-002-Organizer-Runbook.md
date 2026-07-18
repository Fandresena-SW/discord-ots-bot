# RFC-002 — Organizer Runbook (Supabase Studio Workflows)

- **Status:** Ready for implementation
- **Implementation order:** 2 of 6
- **Complexity:** Low–Medium
- **Features covered:** F7, F8, F9, F10
- **PRD refs:** §5.2, §7 (Journey A & B), §8 (G2), §9 (Day 2/Day 6)
- **Builds upon:** RFC-001 (schema, constraints, Studio column setup)
- **Built upon by:** RFC-006 (pre-flight ritual & timed dry-run extend this runbook); provides the seeded data RFC-003/005 test against.

---

## 1. Summary

Document and validate the **organizer-facing workflows** in Supabase Studio: create
and activate a tournament, perform the deliberate two-step activation switch, and
do full player CRUD (add/edit/delete) — all with **zero code changes or redeploys**
(the core value proposition, PRD G1). The deliverable is an organizer **runbook**
(`knowledge/RUNBOOK.md`) plus a validated fast-setup flow that supports pasting ~20
players in under 5 minutes (G2). This RFC is primarily operational/documentation; it
adds **no bot code**, but it is release-gating because G1/G2 are measured against it.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F7** | Organizer creates a tournament row and marks it active; the bot then reads it. |
| **F8** | Two-step activation switch (deactivate current → activate new); the DB rejects two active rows **by design** — documented as expected, not a bug. |
| **F9** | Full player CRUD (name, team text, optional URL) for the active tournament, all in Studio; changes take effect on the next `/ots` with no redeploy. |
| **F10** | Studio workflow supports pasting ~20 players from a notes app in **< 5 min** (validated by the Day-6 timed dry-run, executed in RFC-006). |

## 3. Technical approach

No application code. Produce **`knowledge/RUNBOOK.md`** (per RULES §2 — docs live in
`knowledge/`) documenting each workflow as a numbered procedure with the exact
Studio clicks, the expected constraint behavior, and a copy-paste recipe for bulk
player entry. Validate each procedure by executing it against the RFC-001 database.

The runbook is the single source of truth the organizer follows before and during an
event; RFC-006 appends the pre-flight and contingency sections to this same file.

### 3.1 Runbook contents

0. **First-time Supabase setup — apply `schema.sql` (one-time bootstrap):**
   This is the prerequisite for every workflow below; RFC-001 delivers `schema.sql`
   but this runbook owns *applying* it. Do it once per environment.
   - Create a Supabase project (supabase.com → **New project**): choose an org, name,
     region, and DB password (store the password in the organizer's password manager,
     never in the repo).
   - Open **Studio → SQL Editor → New query**, paste the entire contents of
     `schema.sql` (repo root), and **Run**. It is idempotent — safe to re-run; a
     second run is a no-op (`NOTICE: ... already exists, skipping`).
   - Confirm objects exist: **Table Editor** shows `tournaments` and `players`; the
     seed data (1 active tournament + 3 sample players, one with a null
     `pokepaste_url`) is present. Optionally run the commented verification queries at
     the bottom of `schema.sql` (F3/F4/F6 self-checks).
   - Grab the two values that feed the worker's `.env` (`SUPABASE_URL`,
     `SUPABASE_SERVICE_KEY`) in RFC-003:
     - **Project Settings → API** → **Project URL**.
     - **Project Settings → API Keys** → the **secret** key (`sb_secret_…`; on
       unmigrated projects, the legacy `service_role` JWT). **Not** the publishable
       key (`sb_publishable_…` / legacy `anon`) — that one respects RLS and would read
       nothing once RLS is enabled deny-by-default (the RFC-003 follow-up). The secret
       key bypasses RLS and is worker-only — never commit it or expose it client-side
       (RULES §3, PRD §11.2).

1. **Create & activate a tournament (F7):**
   - New row in `tournaments`: set `name`; leave `is_active = false` initially.
   - Set `is_active = true` (only when no other tournament is active).
   - Confirm: `/ots <known player>` in the guild now resolves against this tournament.

2. **Two-step activation switch (F8):**
   - Step 1: set the currently-active tournament `is_active = false`.
   - Step 2: set the new tournament `is_active = true`.
   - **Expected constraint error:** if you try to activate the new one *before*
     deactivating the old, Studio shows a unique-violation on
     `tournaments_one_active_idx`. **This is correct behavior, not a bug** (RULES §4,
     PRD §11.1). Document the exact error text so the organizer recognizes it.

3. **Player CRUD without redeploy (F9):**
   - Add: new row in `players`, set `tournament_id` to the active tournament, paste
     `ingame_name` + `team_text`, optionally `pokepaste_url`.
   - Edit: change `team_text` (Journey B) — visible on the **next** `/ots`, live.
   - Delete: remove the row — no longer resolvable.
   - Note the trim trigger (RFC-001 F4): pasted names with stray spaces store clean.

4. **20-player fast setup (F10):**
   - Recipe: with F5 column ordering (`ingame_name`, `team_text`, `pokepaste_url`
     first), paste rows sequentially. Document whether the maintainer's notes app
     format pastes cleanly into the Studio grid, and any transform needed (e.g.
     spreadsheet paste vs. one-row-at-a-time). Capture the observed setup time.

## 4. Data models / schema changes

None. Consumes RFC-001's schema and Studio configuration.

## 5. Interfaces exposed

- **`knowledge/RUNBOOK.md`** — organizer operating procedures (extended by RFC-006).
- **A seeded, active test tournament** with a representative roster — the fixture
  RFC-003 (PostgREST read smoke test) and RFC-005 (E2E) rely on.

## 6. Acceptance criteria

- [ ] **Bootstrap:** The runbook documents first-time Supabase project creation and applying `schema.sql` via the Studio SQL Editor; following it produces the two tables, trigger, indexes, and seed data on a fresh project.
- [ ] **F7:** Following the runbook, a newly created + activated tournament becomes the one the bot reads.
- [ ] **F8:** The runbook documents the two-step switch; a one-step attempt reproduces the documented constraint error, described as expected behavior with its exact message.
- [ ] **F9:** Add/edit/delete via Studio each take effect on the next `/ots` with no redeploy; a mid-event `team_text` edit (Journey B) is shown as supported.
- [ ] **F10:** The fast-setup recipe is documented; a realistic ~20-row paste is feasible. *(The timed < 5-min proof is the Day-6 dry-run in RFC-006.)*
- [ ] `knowledge/RUNBOOK.md` exists and is self-contained for the workflows above.
- [ ] An active test tournament + sample players are in place for downstream RFCs.

## 7. Implementation details

- **File:** `knowledge/RUNBOOK.md`. Structure: First-time Supabase setup (apply
  `schema.sql`) → Create & activate → Two-step switch → Player CRUD → Fast bulk entry.
  Leave clearly-marked placeholders that RFC-006 will fill: "Pre-event pre-flight" and
  "Contingency / break-glass."
- **Screens/UX spec:** describe Studio table-editor interactions in words (no web UI
  to build). Reference column ordering from RFC-001 F5.
- **Validation:** actually perform create/activate/switch/CRUD against the RFC-001 DB
  and record real observed behavior (especially the F8 error text).

## 8. Edge cases & risks

- **Two-step switch mistake** (activating before deactivating) — the constraint
  protects data integrity; the runbook must reassure the organizer this is expected.
- **Bulk-paste formatting** differences from the notes app — capture any required
  transform so the Day-6 dry-run isn't the first time it's discovered.
- **Editing the wrong tournament's players** — remind the organizer to filter by the
  active `tournament_id`.

## 9. Applicable rules (RULES.md)

- §2 (docs in `knowledge/`; no new code). §4 (two-step activation constraint is
  expected, never "fixed"). §5 (behavioral contract the workflows must produce).
- §10 (keep docs in sync).

## 10. Testing strategy

Manual execution of every documented procedure against the RFC-001 database,
recording real outcomes. The timed 20-player dry-run (F10 quantitative gate) is
performed and signed off in RFC-006 (Day 6).
