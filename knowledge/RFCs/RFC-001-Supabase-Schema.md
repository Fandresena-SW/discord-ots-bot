# RFC-001 — Supabase Schema, Constraints, Indexes & Trigger

- **Status:** ✅ Complete (2026-07-18, 1 review round — see [§ Completion record](#completion-record))
- **Implementation order:** 1 of 6 (foundation — nothing precedes it)
- **Complexity:** Medium
- **Features covered:** F1, F2, F3, F4, F5, F6
- **PRD refs:** §5.1, §11.1, §11.6, §11.8, §9 (Day 1)
- **Builds upon:** — (first RFC)
- **Built upon by:** RFC-002 (Studio workflows), RFC-003 (read helper), RFC-005 (command read path)

---

## 1. Summary

Establish the entire **data layer** for the v2.0 backoffice in Supabase (Postgres):
the `tournaments` and `players` tables, the DB-level invariants that make the
bot's read path safe and unambiguous (single active tournament; case-insensitive,
whitespace-trimmed, unique player name per tournament), and the indexes that serve
the read path. This RFC produces **no Python changes** — its deliverable is a
single idempotent SQL script applied via the Supabase Studio SQL editor, plus the
Studio column configuration for fast data entry.

All downstream RFCs depend on these invariants being enforced **in the database**,
not merely in code (RULES §4).

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F1** | `tournaments` table: `id`, `name`, `is_active` (bool, default `false`), `created_at` (auto). |
| **F2** | `players` table: `id`, `tournament_id` (FK → tournaments, `ON DELETE CASCADE`), `ingame_name` (text), `team_text` (text), `pokepaste_url` (text, nullable), `created_at` (auto). |
| **F3** | Single-active-tournament enforced by a **partial unique index** on `is_active` where `is_active = true`. |
| **F4** | `ingame_name` trimmed on write via `BEFORE INSERT OR UPDATE` trigger; unique index on `(tournament_id, lower(ingame_name))`; empty-after-trim rejected. |
| **F5** | Studio-friendly defaults + column ordering so a row fills fast (name + team text, optional URL). |
| **F6** | The active-tournament + name lookup is served by an index; verified with `EXPLAIN`. |

## 3. Technical approach

Deliver **one idempotent SQL script**, `schema.sql`, applied in the Studio SQL
editor. Idempotent so the organizer (or a re-provision) can re-run it safely
(`CREATE TABLE IF NOT EXISTS`, `CREATE ... IF NOT EXISTS` for indexes, `CREATE OR
REPLACE FUNCTION`, `DROP TRIGGER IF EXISTS` then `CREATE TRIGGER`).

### 3.1 File location decision

`schema.sql` is placed at the **repo root** (alongside `bot.py`, `Procfile`,
`requirements.txt`). Rationale: it is an executable operational asset applied once
per environment, not a design/planning doc. RULES §2 forbids new **Python**
folders/packages/modules; a single root-level SQL file introduces neither. The
organizer runbook (RFC-002) references it. *(If the maintainer prefers it under
`knowledge/`, that is a trivial move — flagged, not blocking.)*

### 3.2 Schema (data model)

```
tournaments
  id          bigint  generated always as identity  primary key
  name        text    not null
  is_active   boolean not null  default false
  created_at  timestamptz       not null  default now()

players
  id             bigint  generated always as identity  primary key
  tournament_id  bigint  not null  references tournaments(id) on delete cascade
  ingame_name    text    not null
  team_text      text    not null
  pokepaste_url  text    null
  created_at     timestamptz  not null  default now()
```

Notes:
- Use `generated always as identity` (standard Postgres identity) for `id`.
- `team_text` is `NOT NULL` — a player row without a team is meaningless. Content
  is otherwise **trusted as-is** (no validation/normalization — locked §11.4).
- `pokepaste_url` is nullable and is a **first-class case** (drives RFC-005 optional
  link). Do not default it to an empty string.

### 3.3 Invariants (enforced in DB)

1. **Single active tournament (F3):**
   ```sql
   create unique index if not exists tournaments_one_active_idx
     on tournaments (is_active)
     where is_active = true;
   ```
   At most one row may have `is_active = true`. A one-step "activate second"
   attempt raises a unique-violation — this is **expected**, documented in RFC-002,
   and must never be "fixed" by dropping the index (RULES §4, F8).

2. **Name normalization + uniqueness (F4):**
   - Trim trigger (write side):
     ```sql
     create or replace function trim_ingame_name() returns trigger as $$
     begin
       new.ingame_name := btrim(new.ingame_name);
       if new.ingame_name = '' then
         raise exception 'ingame_name must not be empty after trimming';
       end if;
       return new;
     end;
     $$ language plpgsql;

     drop trigger if exists players_trim_ingame_name on players;
     create trigger players_trim_ingame_name
       before insert or update on players
       for each row execute function trim_ingame_name();
     ```
   - Case-insensitive uniqueness (read side matches this exactly):
     ```sql
     create unique index if not exists players_tournament_name_idx
       on players (tournament_id, lower(ingame_name));
     ```
   - The bot (RFC-004/RFC-005) applies **`trim()` then `lower()`** to user input.
     Because stored names are already trimmed, `lower()` on the stored value is
     sufficient. **If you change one side, change both** (RULES §4).
   - **Decision — `citext` vs. functional index:** use the **functional index on
     `lower(ingame_name)`** (not `citext`). Rationale: no extension enablement
     step, and it makes the required read-side normalization explicit and matchable.
     Locked per PRD §11.6 (either is acceptable; this RFC picks the functional
     index).

### 3.4 Read-path index verification (F6)

The read path (RFC-005) is effectively:
```sql
select ingame_name, team_text, pokepaste_url
from players p
join tournaments t on t.id = p.tournament_id
where t.is_active = true
  and lower(p.ingame_name) = lower($1);   -- $1 already trim()+lower() client-side
```
`players_tournament_name_idx` serves the `lower(ingame_name)` predicate;
`tournaments_one_active_idx` serves the single active-row resolution. Run `EXPLAIN`
on a representative query and confirm index usage (dataset is tiny, so this is a
cheap correctness check, not a perf tuning exercise).

> **PostgREST note (for RFC-003):** the bot reads via PostgREST, not raw SQL. The
> equivalent is two calls or an embedded resource: resolve the active tournament
> (`tournaments?is_active=eq.true`) then filter players. The `lower()` match is
> done by sending an already-normalized value and filtering on a generated/lower
> comparison. RFC-003 owns the exact PostgREST query shape; RFC-001 only guarantees
> the indexes and normalization contract exist.

### 3.5 Studio configuration (F5)

- Column order in the `players` table editor: `ingame_name`, `team_text`,
  `pokepaste_url` first (the fields entered per player), then `tournament_id`,
  system columns last.
- Defaults so a valid row needs only name + team text (+ optional URL):
  `is_active` defaults `false`; `created_at` auto; `id` identity.
- Seed **one test tournament** with 2–3 sample players (reuse still-relevant
  `USERNAME_URLS` entries) so RFC-002/003/005 have data to test against.

## 4. Data models / schema changes

Creates `tournaments`, `players`, `trim_ingame_name()`, trigger
`players_trim_ingame_name`, indexes `tournaments_one_active_idx` and
`players_tournament_name_idx`. No existing objects modified (greenfield DB).

## 5. Interfaces exposed

- **`schema.sql`** (repo root) — the canonical, idempotent DDL. Downstream RFCs and
  the runbook reference it.
- **The DB contract** consumed by RFC-003/005: "the active tournament is the sole
  `is_active = true` row; a player is uniquely identified within it by
  `lower(trim(ingame_name))`."

## 6. Acceptance criteria

- [ ] **F1:** `tournaments` exists with the four columns; `created_at` auto-populates; `is_active` defaults `false`.
- [ ] **F2:** `players` exists with all six columns; FK cascades on tournament delete; `pokepaste_url` accepts NULL; a normal insert populates the rest.
- [ ] **F3:** With one active tournament, setting a second `is_active = true` fails with a unique-violation. Zero active tournaments is a valid state.
- [ ] **F4:** Two names differing only by case → rejected in the same tournament. Two names differing only by leading/trailing whitespace → rejected (both stored trimmed). Same name in **different** tournaments → allowed. Stored `ingame_name` has no leading/trailing whitespace after a padded paste. Internal whitespace preserved. Empty-after-trim → rejected.
- [ ] **F5:** A valid player row can be created by filling only `ingame_name` + `team_text`.
- [ ] **F6:** `EXPLAIN` on the read-path query shows `players_tournament_name_idx` in use.
- [ ] `schema.sql` is idempotent (re-running produces no error and no duplicate objects).
- [ ] A test tournament with sample players is seeded and marked active.

## 7. Implementation details

- **File:** create `schema.sql` at repo root. Single script, ordered: tables →
  function → trigger → indexes → (commented) verification queries.
- **Idempotency:** `create table if not exists`, `create unique index if not
  exists`, `create or replace function`, `drop trigger if exists` + `create
  trigger`.
- **Verification block:** include (commented) sample `insert`s and the `EXPLAIN`
  query so the maintainer can self-check.
- **No Python touched** in this RFC.

## 8. Edge cases & risks

- **Empty-after-trim name** → trigger raises; surfaces in Studio as a clear error.
- **Zero active tournaments** is legal and must be handled downstream as "no active
  tournament" (RFC-005 F15b) — not an error here.
- **Internal whitespace** (e.g. `"my name"`) must be preserved; only leading/trailing
  trimmed (`btrim`, not `regexp_replace` of all spaces).
- **Risk:** read-side normalization drifting from the index. Mitigation: RFC-003/004
  must use exactly `trim()` + `lower()`; this contract is restated in every dependent
  RFC.

## 9. Applicable rules (RULES.md)

- §4 (DB contract): invariants enforced in DB; the two-step activation constraint
  error is expected. §3 (English identifiers exactly as named). §2 (no new
  Python folders). §10 (no stubs; ask before touching a locked decision).

## 10. Testing strategy

DB-level manual verification in the Studio SQL editor per the acceptance criteria
(insert conflicting names, attempt second active, run `EXPLAIN`). No Python tests
in this RFC. Keep the verification SQL in `schema.sql` as commented examples.

---

## Completion record

- **Status:** ✅ Complete — **2026-07-18**, via `/rfc 001` orchestration (explore →
  plan → 1 code round → 1 review round; reviewer returned `BLOCKING ISSUES: None`).
- **Plan:** `.claude/rfc-plans/RFC-001-plan.md`.
- **Deliverables shipped:**
  - `schema.sql` (new, repo root) — `tournaments` + `players` tables,
    `trim_ingame_name()` function, `players_trim_ingame_name` trigger,
    `tournaments_one_active_idx` (single-active partial unique) and
    `players_tournament_name_idx` (case-insensitive per-tournament uniqueness), seed
    data (1 active tournament + 3 sample players, one with null `pokepaste_url`), and
    commented F3/F4/F6 verification queries. Idempotent (safe to re-run).
  - `.env.example` — added `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` placeholders
    (secret key `sb_secret_…`, worker-only).
- **Verification:** coder and reviewer independently applied `schema.sql` twice
  (idempotency) to a disposable local Postgres container and exercised every
  acceptance scenario F1–F6 plus FK cascade and the update-path trigger. `bot.py` and
  the real `.env` untouched.
- **Post-review polish applied:** F6 verification comment corrected (Seq Scan expected
  on the tiny seed set; `EXPLAIN` wrapped in `set local enable_seqscan = off`);
  `.env.example` French accent/arrow fixes and secret-vs-publishable-key clarification.
- **Tracked follow-up (not RFC-001's scope):** RLS enablement on both tables assigned
  to **RFC-003** (deny-by-default) — see `RFCS.md` § Tracked follow-ups.
- **Applying the schema** to a live Supabase project is documented as **step 0 of the
  RFC-002 runbook** (first-time bootstrap).
