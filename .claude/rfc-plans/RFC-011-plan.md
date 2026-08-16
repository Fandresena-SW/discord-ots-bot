# RFC-011 Implementation Plan — Ranking Schema: Profiles, Seasons, Tiers & Frozen Results

**Planner output. The coder executes this; it does not redesign it.**
Deliverables are exactly two files: `schema.sql` and `.claude/RULES.md`.
Anything not named here is out of scope for RFC-011.

---

## 1. SCOPE SUMMARY

RFC-011 adds the **durable data layer for v4.0** as one self-contained,
idempotent block appended to `schema.sql`: four new tables (`profiles` F38,
`seasons` F41, `tournament_tiers` F45, `tournament_results` F47/F67), five new
columns (`players.profile_id` F39; `tournaments.event_date` F43, `.season_id`
F44, `.tier_id` F45, `.completed_at` F46), the F40 one-slot-per-person index,
the F42 non-overlapping-seasons exclusion constraint, F48's deliberate
`on delete restrict`, F50's `frozen_at`/`freeze_count` audit columns, F49's RLS
deny-by-default across all four tables, plus the **DDL halves** of F60 (the
`players` auto-link trigger), F69 (`on delete set null` on both `profile_id`
FKs) and F70 (the `season_standings` view), and F66's `current_season` view.
It also adds a v4.0 addendum to `.claude/RULES.md` starting at **§21**.

**Explicitly out of scope** (per the RFC's Scope Limitation): the points formula
and the freeze (RFC-012), every bot command including `/link-organizer`,
`/unlink`, the `/ots` refactor and `/ots-organisateur` (RFC-013), the ranking
read commands, RUNBOOK §9, `E2E-CHECKLIST-v4.md`, `DEPLOYMENT.md` and the new
env vars (RFC-014). **Do not touch `bot.py`, `test_bot.py`, or
`supabase/functions/`.**

---

## 2. LOCKED DECISIONS THIS RFC MUST HONOR

| Locked decision | Source | How this plan honors it |
|---|---|---|
| **Hand-applied, idempotent `schema.sql`; no migrations folder, no second SQL file** | RULES §2, RFC-001/007 precedent, CLAUDE.md Conventions | Every object uses an idempotency idiom (§3.1 below). One appended section in the existing file. |
| **No new folders/packages** | RULES §2 | Nothing is created outside `schema.sql` and `.claude/RULES.md`. |
| **Invariants live in the database, not application code** | RULES §4 | F40 (partial unique index), F42 (exclusion constraint), F45 (not-null FK), F60 (trigger) are all DB-enforced — no bot-side checking is planned or permitted. |
| **trim+lower identity contract, single implementation** | RULES §4/§13/§14 | `resolve_profile_for_ingame_name()` applies `lower(btrim(...))` on *both* sides of its comparison — the same normalization `players_tournament_name_idx` and `normalize_name()` already use. `trim_ingame_name()` is **reused, never re-implemented**, and is not modified. |
| **RLS deny-by-default, no policies; service key bypasses and is worker-only** | RULES §6, RFC-003 | `enable row level security` on all four new tables, zero policies. Extended to views via `security_invoker = on` + explicit `revoke`. |
| **Single active tournament (`tournaments_one_active_idx`)** | RULES §4 | Untouched. `completed_at` is deliberately **not** a status enum and has **no** constraint tying it to `is_active` (F46). |
| **`bot.py` never talks to Challonge; the Edge Function owns Challonge I/O** | RULES §12 | N/A here — no runtime code in this RFC. |
| **Cache tables are disposable** | RULES §14 | Preserved, and **contrasted**: the RULES §21 addendum states that `profiles`/`tournament_results` are *not* disposable and must never be treated as re-derivable. |
| **Points = placement table × tier multiplier; frozen results snapshot the resolved multiplier, never `tier_id`** | PRD §37 | `tournament_results.multiplier numeric(4,2) not null` — a value, not an FK. Codified in the RULES addendum. |
| **The freeze lives in the Edge Function** | PRD §37 | RFC-011 ships schema only; no freeze logic, no `completed_at` writer. |
| **Season date bounds use `daterange(..., '[]')`; no `btree_gist`** | PRD §37 | Verified in a container: core range types carry a native GiST opclass; `select extname from pg_extension` returns `plpgsql` only, after the constraint is created. |
| **Identity binding is organizer-only, one-time, forward auto-link by normalized name; no self-service** | PRD §37 | The trigger only ever *fills a null*; it never overwrites an explicitly supplied `profile_id`, and re-pointing is impossible through it (`before insert` only). |

**Deliberate amendments this RFC carries (name them as such in the code
comments, do not smuggle them in):**

1. **RFC-011 takes all v4.0 DDL**, including F60's trigger and F70's view that
   PRD §40 nominally assigns to RFC-013/014 (RFC-011 §2). Rationale: neither can
   live in Python, and `schema.sql` should be touched exactly once this release.
2. **F48 breaks `schema.sql`'s uniform `on delete cascade` pattern** with
   `on delete restrict` on `tournament_results.tournament_id` (and on
   `tournament_results.season_id`, and on `tournaments.tier_id`). This is the
   file's first non-cascading FK and **must carry an explicit comment saying so.**
3. **F25(b)** ("persistent cross-tournament player identities", a v2.0
   Won't-have) is reopened. **Already annotated in place** in
   `knowledge/FEATURES.md` (the F25(b) bullet and the Supersession table) —
   verify, do not re-annotate.
4. **The v4.0 block does not follow the file's tables → function → trigger →
   indexes → RLS → seed order** (see §3.2/§9). Documented exception with a
   header comment.

---

## 3. SCHEMA CHANGES (`schema.sql`)

### 3.0 Placement in the file

One new section, **`8. v4.0 — RANKING & IDENTITY (RFC-011)`**, inserted **after
the RFC-007 seed data (current line 293) and before the commented verification
block (current line 296)**. The verification block keeps its content and is
amended in place; renumber its heading from `7.` to `9.` when the new section
takes `8.`.

Also extend the **top-of-file comment block** (lines 1-22) with an RFC-011
paragraph, matching how RFC-003 and RFC-007 each added one. It must state:
(a) what RFC-011 adds, (b) that the v4.0 block runs in its own internal order
and why, (c) that the file's uniform-cascade pattern no longer holds (F48).

### 3.1 Idempotency idiom per object (acceptance-critical)

| Object | Idiom | Verified behavior on re-run |
|---|---|---|
| `profiles`, `seasons`, `tournament_tiers`, `tournament_results` | `create table if not exists` | skipped |
| `players.profile_id`, the four `tournaments` columns | `alter table ... add column if not exists` (inline `references` clause) | Whole subcommand skipped, so the FK is **not** duplicated — confirmed in-container: `pg_constraint` count stays at 1 after two passes. Emits a `NOTICE ... skipping`, which is not an error. |
| all 8 indexes | `create [unique] index if not exists` | skipped |
| `seasons_bounds_ck` | inline `constraint ... check` inside `create table if not exists` | skipped with the table |
| **`seasons_no_overlap_excl`** — *the one constraint with no `if not exists` form* | `do $$ begin if not exists (select 1 from pg_constraint where conname = 'seasons_no_overlap_excl') then alter table seasons add constraint ... exclude using gist (...); end if; end $$;` | skipped |
| tier seed (3 rows) | `insert ... select from (values ...) as seed(...) where not exists (select 1 from tournament_tiers t where lower(t.name) = lower(seed.name))` | Confirmed in-container: 3 rows after two passes, `INSERT 0 0` on the second. |
| `tier_id` backfill | `update ... where tier_id is null` then `alter column ... set not null` | Second pass: `UPDATE 0`, and `set not null` on an already-not-null column is a no-op `ALTER TABLE`. Confirmed in-container. |
| season seed + test-tournament amendment | `insert ... where not exists (...)` / `update ... where <col> is null` | no second write |
| `resolve_profile_for_ingame_name()`, `autolink_player_profile()` | `create or replace function` | replaced in place |
| `current_season`, `season_standings` | `create or replace view ... with (security_invoker = on)` | replaced in place; privileges survive, and the revoke below re-runs anyway |
| `players_autolink_profile` | `drop trigger if exists` + `create trigger` (the file's existing idiom, lines 125-136) | recreated |
| RLS | `alter table ... enable row level security` | safe to re-run |
| grants | `revoke all on current_season, season_standings from anon, authenticated;` | idempotent — but **errors if the roles do not exist** (see §7 and §10-R6) |

### 3.2 Internal order of the v4.0 block (the deliberate exception)

The header comment must reproduce this list and say "do not reorder — the
backfill will fail":

```
tables (profiles, seasons, tournament_tiers)
  -> tier seed
  -> tournaments columns + players.profile_id + tier backfill + set not null
  -> tournament_results
  -> functions + trigger (auto-link)
  -> indexes + constraints
  -> views
  -> RLS + grants
  -> v4.0 seed (test season + test-tournament amendment)
  -> (amendments to the existing verification block)
```

Reason, stated in the comment: `tournaments.tier_id` is a **not-null FK added to
a table that already has rows**, so the tier rows must exist before the backfill
that precedes `set not null`. RFC-001's global order cannot express that.

### 3.3 DDL to add — verbatim from RFC-011 §3.2-§3.8

Take the SQL exactly as written in the RFC (§3.2 identity, §3.3 seasons +
`current_season`, §3.4 tiers/event metadata + backfill, §3.5
`tournament_results` + its four indexes, §3.6 the two functions + trigger, §3.7
`season_standings`, §3.8 RLS + revoke). **Do not paraphrase, re-order columns,
or "tidy" the comments** — the comments are as much the deliverable as the DDL.
Specifically preserve:

- the `discord_user_id text` rationale (snowflakes exceed 2^53; a JSON
  round-trip in the Edge Function would silently lose precision) — F38;
- the `display_name` "snapshot for Studio readability ONLY ... never resolve
  identity through it" comment **at the column** — F38, RFC §8;
- the F42 comment explaining `'[]'` vs the default `'[)'` **and** why no
  `btree_gist` is installed;
- the F48 block comment in full, unabridged — it is the one comment a future
  reader must not miss;
- the F67 comment on why `multiplier` is a snapshotted value and not `tier_id`;
- the F46 comment that `completed_at` is independent of `is_active`;
- §3.6's two notes: trigger **name ordering** (`players_autolink_profile` sorts
  before `players_trim_ingame_name`, which is why the resolver applies
  `btrim`/`lower` itself) and **`before insert` only, never `or update`**.

Additions the coder must make on top of the RFC's literal SQL:

- **`current_season`**: a one-line comment "zero or one row; zero is a normal
  state, not an error (F66)", plus a note that `current_date` is evaluated in
  the **database's** timezone (UTC on Supabase) — RFC §8.
- **`season_standings`**: a one-line comment that `ingame_name` is the
  most-recently-frozen spelling and is **not** trimmed on write (F47/§3.5), so
  RFC-012's freeze writer should store an already-trimmed snapshot. Verified
  behavior: grouping is safe regardless (the key normalizes with
  `lower(btrim(...))`); only the displayed spelling could carry whitespace.
  **Do not add `btrim()` to the view's output** — that is RFC-012's write-side
  concern, and changing the view's output expression is a deviation from spec
  for no read benefit.
- **`tournament_results.season_id`** also carries `on delete restrict` — call it
  out next to F48 so the two non-cascading FKs read as one decision.

### 3.4 Indexes, constraints, RLS

Nine new index/constraint objects, exactly as enumerated in RFC §4:
`profiles_discord_user_id_idx` (unique), `players_tournament_profile_idx`
(unique partial `where profile_id is not null`), `seasons_bounds_ck`,
`seasons_no_overlap_excl`, `tournament_tiers_name_idx` (unique on `lower(name)`),
`tournament_results_participant_idx` (unique), `tournament_results_season_idx`,
`tournament_results_profile_idx` (partial), `tournament_results_season_name_idx`.

RLS: `alter table ... enable row level security` on `profiles`, `seasons`,
`tournament_tiers`, `tournament_results`. **No policies.** Views:
`with (security_invoker = on)` **and**
`revoke all on current_season, season_standings from anon, authenticated;`.
Both halves are required — the revoke alone would not survive a future re-grant,
and `security_invoker` alone leaves the view *readable* (but empty) to `anon`.

### 3.5 Seed fixtures (v4.0)

Per RFC §10 "Seed fixtures", guarded exactly like the RFC-001/007 seeds:

1. **One `seasons` row** — `'RFC-011 Test Season'`, `2026-01-01` -> `2026-12-31`,
   guarded `insert ... where not exists (select 1 from seasons where name = ...)`.
   Comment that the range is deliberately fake and wide.
2. **Amend the `RFC-001 Test Tournament` row in place** — set `event_date`,
   `season_id` (that season) and `tier_id` (Hebdo) with
   `update tournaments set ... where name = 'RFC-001 Test Tournament' and <col> is null`.
   `tier_id` will already be Hebdo from the backfill; keep the update idempotent
   and harmless either way.
   Leave **`completed_at` null** and add **no `tournament_results` rows**, so
   RFC-012 can exercise a genuine first freeze.
3. **No `profiles` seed row** — a fake `discord_user_id` is the one seed in this
   file that cannot be exercised, and it would sit in the personal-data table.
   State this in the comment so a later reader does not "fix the gap".
4. A warning comment on the season assignment: it makes the test tournament
   **freezable, and therefore undeletable under F48** — deliberate, and exactly
   what RUNBOOK §9 (RFC-014) has to teach.

### 3.6 Verification-block amendments

**(a) Amend in place** the RFC-007 cleanup step at current lines 376-381
(`delete from tournaments where name = 'RFC-001 Test Tournament'`): keep the
statement, and prepend a comment stating that under F48 this **fails once
anything is frozen for that tournament**, with the purge-first alternative
spelled out:

```
-- delete from tournament_results where tournament_id = (select id from tournaments where name = 'RFC-001 Test Tournament');
-- delete from tournaments where name = 'RFC-001 Test Tournament';
```

**(b) Append nine new commented checks**, one per RFC §10 item, each with its
expected result next to it (the file's existing `-- expected: ...` convention):

1. **Idempotency** — re-apply the whole file; `select count(*) from
   tournament_tiers` -> 3, not 6; `select count(*) from tournaments where
   tier_id is null` -> 0.
2. **F42** — same-boundary-day overlap -> `ERROR ... exclusion constraint
   "seasons_no_overlap_excl"`; adjacent (`...-12-31` then `...-01-01`) ->
   succeeds. Plus `select count(*) from pg_extension where extname =
   'btree_gist'` -> 0.
3. **F40** — two roster rows in one tournament sharing a `profile_id` ->
   `ERROR ... "players_tournament_profile_idx"`; the same across two
   tournaments -> succeeds.
4. **F48** — insert a fixture `tournament_results` row, then
   `delete from tournaments where id = ...` -> FK violation naming
   `tournament_results`.
5. **F67** — insert a `tournament_results` row omitting `multiplier` ->
   `ERROR ... null value in column "multiplier"`.
6. **F60** — the four trigger paths (clean link / ambiguous name / profile
   already slotted in that tournament / explicit `profile_id` supplied), plus an
   `update` to `ingame_name` proving **no re-link**, plus an insert of
   `'  Zou  '` proving the trim-order note in §10-R5. State that paths 2 and 3
   emit a `WARNING` and the insert **still succeeds** with `profile_id` null.
7. **F69** — delete a `profiles` row that has both `players` and
   `tournament_results` references -> succeeds; both go null; the frozen
   `ingame_name` survives.
8. **F70** — a small hand-computed fixture (one bound player across two events,
   one unbound across one) with the expected `total_points` / `events_played` /
   `best_rank` written into the comment.
9. **F49** — the anon/service-key check, marked **"run against PostgREST, not
   the SQL editor"**, listing all six objects (four tables + both views), and
   restating that the SQL editor runs as a superuser role and proves nothing.
   Mirror the wording of the existing RFC-003 RLS comment (lines 348-358), and
   include the `notify pgrst, 'reload schema';` note from §10-R12.

Each fixture-creating check ends with its own commented cleanup, and the
F48/F69 checks must note that their fixture rows make the test tournament
undeletable until purged.

---

## 4. `bot.py` CHANGES

**N/A.** RFC-011 produces no Python.

**Impact on existing functionality — explicit confirmation.** `/ots`'s v3.0 read
path (`fetch_current_opponent` -> `fetch_active_player`) is untouched: every
query it issues selects **named** columns from `tournaments`, `players`,
`challonge_participants_cache` and `challonge_matches_cache` — there is no
`select *` in `bot.py`, so no read broadens implicitly. All four tables keep
every existing column, index, trigger and query semantic:
`tournaments_one_active_idx`, `players_tournament_name_idx`, the three
`challonge_participants_cache` indexes, the two `challonge_matches_cache`
indexes, `trim_ingame_name()` and both of its triggers are unmodified. The only
structural change is **added columns**: four nullable ones
(`players.profile_id`, `tournaments.event_date`/`season_id`/`completed_at`) plus
`tournaments.tier_id`, which is not-null *with every pre-existing row backfilled
before the constraint is applied*. One new `before insert` trigger is added to
`players`; it only ever fills a null `profile_id` and can never reject an insert.

**What the `tier_id` backfill writes to pre-existing production rows:** exactly
one `update` — `tournaments.tier_id = <id of the 'Hebdo' tier>` for every row
where it is null, i.e. every tournament that exists today, including historical
ones. Nothing else about those rows changes. It is harmless (they have
`season_id null` and can never freeze, F55) but it is a real write against live
data and must be stated in the apply notes handed to the operator.

---

## 5. COMMANDS

**N/A.** No `@tree.command` is added, modified, or removed. `/link-organizer`,
`/unlink`, the `/ots` refactor and `/ots-organisateur` are RFC-013;
`/standings` and `/profile` are RFC-014. No user-facing French strings are
introduced by this RFC.

---

## 6. EDGE FUNCTION CHANGES

**N/A.** `supabase/functions/challonge-sync/` is not touched. The Challonge API
call-count invariant (2 per invocation) is unchanged by this RFC; F68's
amendment to it belongs to RFC-012 (`RULES.md` §18 and `PRD.md` §21) — **do not
pre-empt that edit here.**

---

## 7. TESTS

There is no pure Python or TypeScript logic in this RFC, so **no `unittest` and
no `Deno.test` cases are added**. Verification is DB-level, in two tiers.

### 7.1 Tier 1 — disposable local Postgres container (mandatory, run by the coder)

Docker and `psql` are available in this environment. `postgres:16-alpine` is the
right image: I confirmed here that the F42 exclusion constraint creates
successfully with **no extension installed** (`pg_extension` contains only
`plpgsql` afterwards), and that `create or replace view ... with
(security_invoker = on)` parses (a PG 15+ feature; the probe ran PG 16.14).

Harness sequence:

```
docker run -d --name ots-schema-check -e POSTGRES_PASSWORD=pw -p 55432:5432 postgres:16-alpine
# wait: docker exec ots-schema-check pg_isready -U postgres
# PRELUDE (harness only, never in schema.sql) — Supabase's PostgREST roles do
# not exist in a stock image, and the revoke statements would abort the apply:
#   create role anon nologin;
#   create role authenticated nologin;
#   grant usage on schema public to anon, authenticated;
#   grant select on all tables in schema public to anon, authenticated;
# PASS 1: psql -v ON_ERROR_STOP=1 -f schema.sql   -> must exit 0
# PASS 2: psql -v ON_ERROR_STOP=1 -f schema.sql   -> must exit 0
docker rm -f ots-schema-check
```

Then run, as scripted `psql` statements (uncommented copies of §3.6's checks):

- two-pass idempotency assertions: tier count = 3; zero null `tier_id`; exactly
  one FK on `players.profile_id` and one on `tournaments.tier_id`; one row in
  `seasons` named `'RFC-011 Test Season'`;
- F42 overlap / same-boundary / adjacent, plus the `btree_gist`-absent assertion;
- F40, F48, F67, F50 (`freeze_count >= 1`), F41 (`ends_on < starts_on` rejected);
- F60's four trigger paths, the no-re-link `update`, and the untrimmed-name
  insert;
- F69's profile delete;
- F70's hand-computed standings fixture.

**Both halves of the idempotency criterion must be exercised:** a fresh database
*and* a database already carrying v2.0/v3.0 data. For the second, check out the
pre-RFC-011 `schema.sql` (`git show HEAD:schema.sql`), apply it first, then
apply the new file twice. This is the only path that exercises the `tier_id`
backfill against a non-empty `tournaments`.

### 7.2 Tier 1b — the part of F49 that *can* be proven locally

This is the highest-risk item in the RFC and it is **partially** provable
without Supabase. I verified the exact experiment in this environment:

```
set role anon;
select count(*) from seasons;             -- 0   (RLS on the base table)
select count(*) from current_season;      -- 0   (security_invoker honors it)
-- control: the same view WITHOUT security_invoker returned 2 rows to anon
reset role;
-- after the schema's revoke:
set role anon; select * from current_season;  -- ERROR: permission denied for view
```

The coder must run, in the container: (a) `set role anon` reads of all four
tables and both views -> 0 rows / permission denied, and (b) **the control
case** — temporarily create a copy of one view *without* `security_invoker`,
grant it to `anon`, and show that it leaks — so the mechanism is proven, not
assumed. Drop the control view afterwards; it never enters `schema.sql`.

### 7.3 Tier 2 — what only the operator can do, against live Supabase

The container has no PostgREST and no `service_role`/JWT plumbing, so the
following is **operator-run and must be reported, not simulated**:

- `GET {SUPABASE_URL}/rest/v1/{profiles,seasons,tournament_tiers,tournament_results,current_season,season_standings}?select=*&limit=1`
  with the **anon** key in both `apikey` and `Authorization: Bearer` -> HTTP 200
  and an **empty array** for all six.
- The same six with `SUPABASE_SERVICE_KEY` -> rows (or `[]` where genuinely
  empty), proving the bot's path is unaffected.
- `select version()` on the live project **before** applying, to confirm PG >= 15
  for `security_invoker`. On PG 14 the `create view` fails loudly at apply
  time — which is correct behavior, not something to work around.
- A `/ots` smoke test in the guild after applying, confirming the v3.0 read path
  is unchanged.

### 7.4 Existing tests that must still pass unchanged

`python -m unittest test_bot` (30 tests, in the venv where `requirements.txt`
is installed) and `deno test supabase/functions/challonge-sync/mapping_test.ts`
(7 tests). Neither touches the schema, so both must pass **without
modification** — running them is the regression check that no stray edit reached
`bot.py` or the Edge Function.

---

## 8. DOCUMENTATION

Only what RFC-011 itself assigns:

1. **`schema.sql` header block** — an RFC-011 paragraph (§3.0).
2. **`.claude/RULES.md` — a v4.0 addendum starting at §21** (v3.0's ends at
   §20), in the same voice as the v3.0 addendum and opening with the same
   "sections above remain fully binding" framing. Content, per RFC §7:
   - **§21 — Durable data (v4.0).** `profiles` and `tournament_results` are the
     project's first **non-disposable** data — the explicit contrast with §14's
     disposable cache tables. F48's `on delete restrict` on
     `tournament_results.tournament_id` (and `.season_id`) breaks the file's
     uniform cascade pattern on purpose; do not soften it to make
     test-tournament cleanup convenient. `profiles.discord_user_id` is the first
     personal data stored, so the erasure path must stay possible by
     construction.
   - **§22 — Frozen history.** Snapshot the **resolved multiplier**, never
     `tier_id`; standings sum over `tournament_results.season_id`, never a join
     to `tournaments`; corrections are deliberate only (F50/F72), never a side
     effect of a routine sync.
   - **§23 — Security posture extended to views.** Every new view is
     `with (security_invoker = on)` **and** revoked from `anon`/`authenticated`.
     State the failure mode (a superuser-owned view serves `anon` exactly the
     rows RLS denies) and that verification must go through PostgREST with the
     anon key, never the SQL editor.
   - **§24 — Auto-link rules.** Fail-**closed** on ambiguity (null + warning,
     never guess — binding is an authorization boundary); fail-**open** on the
     F40 slot conflict (warn, leave null, never reject the organizer's insert);
     `before insert` only, never `or update`; trigger-name ordering is
     load-bearing. Also: the schema now depends on the organizer's name
     discipline and cannot enforce it.
   - Keep each section to roughly the length of the v3.0 addendum's entries. Do
     **not** pre-write RFC-012/013/014's rules; they extend the addendum
     themselves.
3. **RFC-011's own Completion record** — status, deliverables shipped,
   verification performed (both passes, the anon experiment, the operator's
   PostgREST results), deviations, tracked follow-ups.
4. **`knowledge/RFCs/RFCS.md`** — flip the RFC-011 row (line 145) from
   `📝 Draft` to the shipped marker used for RFC-001-010, per the per-RFC
   convention.
5. **`knowledge/FEATURES.md` — verify only.** F25(b) and the Supersession table
   are **already annotated**; do not duplicate the annotation.

**Explicitly NOT this RFC:** `CLAUDE.md`, `knowledge/PRD.md` status, RUNBOOK §9,
`DEPLOYMENT.md`, `E2E-CHECKLIST-v4.md`, `.env.example` — all RFC-013/014.
(`CLAUDE.md` and `PRD.md` are updated on *release* sign-off, which is RFC-014's
job under the four-status-trackers convention.)

---

## 9. IMPLEMENTATION ORDER

Schema first, then verification, then docs. Within the schema, the internal
order is the documented exception from §3.2.

1. **Start the container and apply the *current* `schema.sql` unchanged**
   (twice), including the role prelude — this proves the harness before any new
   DDL can be blamed for a failure.
2. **Extend the `schema.sql` header block** with the RFC-011 paragraph.
3. **Open section `8. v4.0 — RANKING & IDENTITY (RFC-011)`** after the RFC-007
   seed (line 293), renumber the verification block to `9.`, and write the
   ordering-exception header comment (§3.2) *first*, before any DDL.
4. **Tables:** `profiles`, `seasons` (with `seasons_bounds_ck` inline),
   `tournament_tiers`.
5. **Tier seed** (guarded insert of Hebdo 1.0 / Mensuel 2.0 / Majeur 3.0).
6. **`tournaments` columns** (`event_date`, `season_id`, `tier_id`,
   `completed_at`) and **`players.profile_id`**, then the **`tier_id`
   backfill**, then `alter column tier_id set not null`. *This step order is
   load-bearing; apply and test it in isolation before moving on.*
7. **`tournament_results`** (all F47/F67/F50 columns, both `restrict` FKs, the
   F48 comment).
8. **Functions + trigger:** `resolve_profile_for_ingame_name()`, then
   `autolink_player_profile()`, then `drop trigger if exists` + `create trigger
   players_autolink_profile`. The pure resolver lands and is exercised before
   the trigger that calls it — the same de-risking sequence RFC-004 used ahead
   of RFC-005.
9. **Indexes + constraints:** the eight `if not exists` indexes, then the
   `pg_constraint`-guarded `do $$` block for `seasons_no_overlap_excl`.
10. **Views:** `current_season`, then `season_standings` — both with
    `security_invoker = on`.
11. **RLS + grants:** four `enable row level security`, then the single
    `revoke all on ... from anon, authenticated`.
12. **v4.0 seed:** the test season, then the guarded test-tournament amendment,
    with the undeletability warning comment.
13. **Verification-block amendments:** the F48 in-place amendment first (it
    changes an existing step), then the nine appended checks.
14. **Run the full two-pass idempotency check** in the container, plus every
    scripted invariant test in §7.1 and the anon/control experiment in §7.2 —
    from a *fresh* container **and** from one already carrying v2.0/v3.0 data.
    Fix and re-run until both passes are clean.
15. **Run `python -m unittest test_bot` and `deno test`** — regression check
    that nothing outside `schema.sql` moved. Confirm `git status` shows only
    `schema.sql` and `.claude/RULES.md` (plus the RFC/RFCS doc updates).
16. **Write `.claude/RULES.md` §21-§24.**
17. **Fill RFC-011's Completion record and flip the `RFCS.md` status row**;
    verify FEATURES.md F25(b) is already annotated.
18. **Hand the operator the Tier-2 script** (§7.3): apply notes stating the
    `tier_id` write to production rows, the six anon `GET`s, the six
    service-key `GET`s, the PG-version pre-check, and the `/ots` smoke test.

---

## 10. RISK AREAS

**R1 — `security_invoker` (highest risk in this RFC).** A view without it, owned
by a superuser, serves `anon` exactly the rows RLS denies. *Strategy:* both
views declare it **and** are revoked; the coder runs the §7.2 control experiment
(a deliberately non-invoker copy that leaks) so the mechanism is proven, not
assumed; the operator repeats through PostgREST because the SQL editor runs as a
superuser role and proves nothing. Codified in RULES §23 so future views inherit
the rule.

**R2 — the `tier_id` not-null backfill is a one-way write to live rows.** It
sets every existing tournament, including historical ones, to Hebdo.
*Strategy:* stated explicitly in §4 and in the operator apply notes; harmless
because those rows have `season_id null` and can never freeze; and the
add -> backfill -> constrain sequence is tested against a container that already
holds v2.0/v3.0 data (step 14), not only a fresh one.

**R3 — F48 breaks an operational procedure silently, later.** Nothing fails at
apply time; the "delete the test tournament" step stops working the first time
something is frozen. *Strategy:* amend that verification step **in place** with
the purge-first alternative (§3.6a); flag it in the v4.0 seed comment; RULES §21
forbids softening the constraint. RUNBOOK §9 is the operator-facing mitigation
and belongs to RFC-014 — do not write it here.

**R4 — F42 rejects same-boundary-day seasons and the organizer will hit it.**
Confirmed in-container: `2026-01-01 -> 2026-06-30` followed by
`2026-06-30 -> 2026-12-31` is rejected with
`conflicting key value violates exclusion constraint "seasons_no_overlap_excl"`;
`2026-07-01 -> 2026-12-31` is accepted. *Strategy:* intentional; the
verification block shows both cases side by side with the adjacent-bounds
pattern spelled out. Do not switch to `'[)'` to make it "nicer" — that
contradicts `ends_on`'s name.

**R5 — trigger firing order.** `players_autolink_profile` sorts before
`players_trim_ingame_name`, so the resolver sees an untrimmed
`NEW.ingame_name`. *Strategy:* `resolve_profile_for_ingame_name` applies
`lower(btrim(...))` to both sides itself; a comment forbids renaming either
trigger without re-checking the order; and a verification check inserts
`'  Zou  '` and confirms it still auto-links.

**R6 — `revoke ... from anon, authenticated` aborts on a stock Postgres image.**
Confirmed: revoking from a non-existent role is a hard `ERROR: role "..." does
not exist`, and Supabase's PostgREST roles are cluster-wide but absent from
`postgres:16-alpine`. *Strategy:* keep the plain `revoke` in `schema.sql` (its
only real target is Supabase, where both roles always exist, and the RFC
specifies it literally); create the two roles in the **container harness
prelude**, which the anon experiment needs anyway; and add a one-line comment
above the revoke saying so, so the next person running a local container is not
puzzled. *Alternative considered and rejected:* wrapping the revoke in a
`pg_roles`-guarded `do $$ ... execute ... $$` block — it works (verified), but
adds a plpgsql block to defend against a condition that cannot occur in the
target environment, against the prime directive. If the reviewer prefers
portability over minimalism, that is the one-line swap.

**R7 — `create or replace view` is not a free lunch.** It fails if a later
change renames or retypes an output column. *Strategy:* not a problem on first
landing; note in the view comment that RFC-014 must not need to change the view,
and that any future output-column change requires `drop view ... cascade` first.

**R8 — ambiguous auto-link is a real, silent state.** Two people who used the
same in-game name in different seasons yield a null link and a `WARNING` nobody
reads. *Strategy:* the trigger's job is only to never guess; pre-flight (G16,
RFC-014) is the operational catch. The verification block must demonstrate the
warning path explicitly so the behavior is discoverable.

**R9 — the F40 fail-open guard is easy to "fix" into a fail-closed one.** A
future reader may argue the insert should be rejected. *Strategy:* the comment
states the trade (a null link costs one `/link-organizer`; a rejected insert
costs the roster) and RULES §24 locks it.

**R10 — `current_season` is timezone-dependent** (`current_date`, UTC on
Supabase). *Strategy:* accepted and documented at the view; season boundaries
are months apart. Do not build timezone handling.

**R11 — `tournament_results.ingame_name` is deliberately un-trimmed.** Verified:
`season_standings` groups correctly regardless (the key normalizes), but the
displayed spelling can carry whitespace. *Strategy:* comment it at the view as
an interface note to RFC-012's freeze writer; do **not** change the view
expression, and do **not** add a third table to `trim_ingame_name()`'s
dependency set.

**R12 — PostgREST schema cache.** New tables and views are invisible to
PostgREST until it reloads, and a `404`/`PGRST205` on the anon check would look
like a pass. *Strategy:* the F49 verification comment includes
`notify pgrst, 'reload schema';` and states that a 404 is a cache artifact, not
a passing RLS result.

**R13 — scope creep into RFC-012/013/014.** The RFC hands over three DDL halves,
which invites writing "just the small bit" of the freeze or the binding.
*Strategy:* the Scope Limitation is absolute — if `bot.py`, `test_bot.py`,
`supabase/functions/`, `RUNBOOK.md`, `DEPLOYMENT.md`, `.env.example` or
`CLAUDE.md` appears in `git status`, the change is out of scope and must be
reverted.

**R14 — no split is proposed.** Everything lands in the existing `schema.sql`
and the existing `.claude/RULES.md`; no new file, folder, module or dependency
is introduced, and none is warranted.
