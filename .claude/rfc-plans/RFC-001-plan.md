# RFC-001 Implementation Plan — Supabase Schema, Constraints, Indexes & Trigger

> **Stack note:** This project is a single-file **Python Discord bot** with a
> **Supabase (Postgres + PostgREST)** backend — it is **not** a Flutter/Dart app.
> The standard plan template's Flutter sections (Dart Models, Riverpod Providers,
> Screens & Widgets, Routing) are **Not Applicable** and are marked as such below.
> RFC-001 is a **pure data-layer / DDL** deliverable: one idempotent `schema.sql`
> plus a two-line addition to `.env.example`. **No Python is touched.**

---

## 1. SCOPE SUMMARY

RFC-001 establishes the entire v2.0 data layer in Supabase Postgres: the
`tournaments` and `players` tables, the DB-enforced invariants that make the bot's
read path safe and unambiguous (exactly-one-active-tournament; whitespace-trimmed,
case-insensitive, unique player name per tournament; empty-name rejection), the two
indexes that serve the `/ots` read path, and one seeded active test tournament with
sample players. The deliverable is a single idempotent `schema.sql` at the repo root,
applied once per environment via the Supabase Studio SQL editor, plus placeholder
`SUPABASE_URL` / `SUPABASE_SERVICE_KEY` entries in `.env.example` (consumed later by
RFC-003).

**Explicitly out of scope:** any Python code change, RLS policies, PostgREST query
shapes, the runbook, and content validation/normalization of `team_text` — all owned
by later RFCs (RFC-002/003/004/005).

---

## 2. DATABASE (DDL — the sole deliverable)

There is **no migrations directory and no migration runner** in this repo. The
deliverable is **one idempotent script**, not a numbered migration. Do **not** create
a `migrations/` or `supabase/` folder (RULES §2 — no new folders).

**File to create:** `/Volumes/Data/Perso/discord-ots-bot/schema.sql` (repo root,
alongside `bot.py`, `Procfile`, `requirements.txt`).

Script must be ordered exactly: **tables → function → trigger → indexes → seed →
(commented) verification block.**

### 2.1 Tables

**`tournaments`**

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | `bigint` | `generated always as identity primary key` |
| `name` | `text` | `not null` |
| `is_active` | `boolean` | `not null default false` |
| `created_at` | `timestamptz` | `not null default now()` |

**`players`**

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | `bigint` | `generated always as identity primary key` |
| `tournament_id` | `bigint` | `not null references tournaments(id) on delete cascade` |
| `ingame_name` | `text` | `not null` |
| `team_text` | `text` | `not null` |
| `pokepaste_url` | `text` | `null` (nullable — first-class case, do NOT default to `''`) |
| `created_at` | `timestamptz` | `not null default now()` |

Use `create table if not exists` for both. Use `generated always as identity`
(**not** `serial`). Column identifiers are English, exactly as named — do not rename
(RULES §3).

### 2.2 PostgreSQL function

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
```

- **Signature:** `trim_ingame_name() returns trigger`, `language plpgsql`.
- **Behavior:** trims **only leading/trailing** whitespace via `btrim` (internal
  whitespace preserved — do NOT use `regexp_replace` to strip all spaces); raises if
  the result is empty.
- Idempotency via `create or replace`.

### 2.3 Trigger

```sql
drop trigger if exists players_trim_ingame_name on players;
create trigger players_trim_ingame_name
  before insert or update on players
  for each row execute function trim_ingame_name();
```

Idempotency via `drop trigger if exists` then `create trigger`.

> **`log_audit()` triggers:** the plan template calls for `log_audit()` on every
> writable table. **N/A here** — this project has no `log_audit()` function, no audit
> table, and no audit convention. Introducing one would violate RULES §2 (no new
> objects the PRD doesn't call for) and §10 (no unrequested additions). Do not add it.

### 2.4 Indexes

Every index below is required; each is idempotent via `if not exists`.

1. **Single-active-tournament (F3)** — partial unique index:
   ```sql
   create unique index if not exists tournaments_one_active_idx
     on tournaments (is_active)
     where is_active = true;
   ```
   At most one `is_active = true` row. A one-step "activate a second tournament"
   attempt **must** raise a unique-violation — this is **expected behavior**,
   documented in RFC-002, and must never be "fixed" by dropping the index (RULES §4).

2. **Case-insensitive unique name per tournament (F4)** — functional unique index
   (this also serves the read-path `lower(ingame_name)` predicate, F6):
   ```sql
   create unique index if not exists players_tournament_name_idx
     on players (tournament_id, lower(ingame_name));
   ```
   **Decision locked:** functional index on `lower(ingame_name)`, **not** `citext`
   (no extension step; makes the read-side normalization contract explicit — PRD
   §11.6 / RFC-001 §3.3).

**FK index note:** `players.tournament_id` is the leading column of
`players_tournament_name_idx`, so that composite index already serves FK-join /
tournament-scoped lookups. No separate single-column index on `tournament_id` is
needed; do not add a redundant one.

### 2.5 Seed data (F5 — idempotent)

Seed **one** test tournament marked `is_active = true`, plus **3 sample players**
reusing entries from the current `USERNAME_URLS` dict (`bot.py:29–37`). `team_text`
is `not null`, and v1 stored no team text for these entries, so seed each player with
a short **placeholder** `team_text` (clearly marked as seed/test data). Include **one
player with `pokepaste_url = NULL`** so RFC-005's optional-link path has test data.

Suggested seed rows (reuse real usernames; placeholder team text):

| ingame_name | pokepaste_url | team_text |
|-------------|---------------|-----------|
| `giovlacouture` | `https://pokepast.es/6b0e9bdcbf2c6a73` | placeholder seed text |
| `zou` | `https://pokepast.es/091b94622a4ef357` | placeholder seed text |
| `koloina` | `NULL` | placeholder seed text |

**Idempotency requirement:** re-running `schema.sql` must not duplicate seed rows and
must not error.
- Tournament: insert only if a tournament with that seed name does not already exist,
  e.g. `insert into tournaments (name, is_active) select 'RFC-001 Test Tournament',
  true where not exists (select 1 from tournaments where name = 'RFC-001 Test
  Tournament');`
- Players: resolve the seed tournament's `id` by its name in the insert `select`, and
  guard with `on conflict do nothing` against `players_tournament_name_idx` (or a
  matching `where not exists` on `(tournament_id, lower(ingame_name))`).
- Because `tournaments_one_active_idx` allows only one active row, the seed insert of
  an active tournament must be guarded by the `not exists` check above so a re-run on
  a DB that already has an active tournament does not raise a unique-violation.

### 2.6 Verification block (commented, F6)

Append a **commented** block at the end of `schema.sql` containing self-check queries
the maintainer can uncomment and run in Studio:
- Sample inserts proving F4: two names differing only by case → second rejected; two
  names differing only by leading/trailing whitespace → stored trimmed, second
  rejected; same name in a different tournament → allowed; empty-after-trim → rejected.
- Attempt to set a second tournament `is_active = true` → unique-violation (F3).
- The read-path `EXPLAIN` (F6):
  ```sql
  explain
  select p.ingame_name, p.team_text, p.pokepaste_url
  from players p
  join tournaments t on t.id = p.tournament_id
  where t.is_active = true
    and lower(p.ingame_name) = lower('giovlacouture');
  ```
  Confirm the plan references `players_tournament_name_idx`.

### RLS policies

**N/A for RFC-001.** The bot authenticates with the Supabase **service key**, which
**bypasses RLS** (RULES §6). RFC-001 does not create policies, roles, or public anon
exposure. Table access is service-key-only until a later RFC decides otherwise. Do not
add RLS in this RFC.

---

## 3. DART MODELS

**N/A.** No Dart/Flutter in this repo. Python is not touched by RFC-001. No
`build_runner`, no `@freezed`. (Downstream RFC-003 will add PostgREST access in
`bot.py`; that is not part of RFC-001.)

## 4. PROVIDERS

**N/A.** No Riverpod / Flutter. The equivalent read-path shape is documented for
RFC-003's benefit only (see the verification query in §2.6); RFC-001 owns only that
the indexes and normalization contract exist.

## 5. SCREENS & WIDGETS

**N/A.** No web/mobile UI. The only "admin UI" is Supabase Studio (§2.5 Studio config
below). Player output is a Discord embed built later in RFC-005.

**Studio configuration (F5, non-code):** document that in the `players` table editor
the organizer should order columns `ingame_name`, `team_text`, `pokepaste_url` first,
then `tournament_id`, then system columns — so a valid row needs only name + team text
(+ optional URL). This is a Studio UI setting, captured operationally in RFC-002; note
it in `schema.sql` comments but do not attempt to enforce column order in DDL.

## 6. ROUTING

**N/A.** No routing framework (Discord `CommandTree`, and even that is untouched here).

## 7. EDGE FUNCTIONS

**None.** No `supabase/functions/` directory, no pg_cron, no edge functions. All logic
is plain DDL applied by hand in the Studio SQL editor.

---

## 8. IMPLEMENTATION ORDER

1. **Create `schema.sql`** at repo root with the full script in this exact order:
   1. `create table if not exists tournaments (...)`
   2. `create table if not exists players (...)` (with FK `on delete cascade`)
   3. `create or replace function trim_ingame_name()`
   4. `drop trigger if exists players_trim_ingame_name` + `create trigger`
   5. `create unique index if not exists tournaments_one_active_idx` (partial)
   6. `create unique index if not exists players_tournament_name_idx` (functional)
   7. Idempotent seed: one active test tournament + 3 sample players (one with NULL
      URL), guarded per §2.5
   8. Commented verification block (§2.6)
2. **Edit `.env.example`** — append two placeholder lines with French comments matching
   the existing style, e.g.:
   ```
   # URL du projet Supabase (Project Settings -> API)
   SUPABASE_URL=https://votre-projet.supabase.co

   # Cle service Supabase — worker uniquement, ne jamais committer
   SUPABASE_SERVICE_KEY=votre_service_key_ici
   ```
   Placeholders only — never a real key (RULES §6).
3. **Self-verify idempotency** conceptually: confirm every statement uses
   `if not exists` / `or replace` / `drop ... if exists` / guarded seed inserts so a
   second run is a no-op with no errors.

> Template order (migrations → models → providers → UI) collapses to
> **migrations/DDL only** here; the model/provider/UI phases have no work in RFC-001.

---

## 9. RISK AREAS

The exploration report identified **no code conflicts** (greenfield DB, foundation RFC).
The residual risks are correctness details, handled as follows:

1. **Seed idempotency vs. the single-active partial index.** A naive re-run inserting
   an active tournament would hit `tournaments_one_active_idx`. **Resolution:** guard
   the tournament seed with `where not exists (select 1 from tournaments where name =
   '<seed name>')`, and guard player seeds with `on conflict do nothing` against
   `players_tournament_name_idx`. Verify a double-run produces no error and no dupes.

2. **`team_text NOT NULL` vs. seed data.** The reused `USERNAME_URLS` entries carry no
   team text. **Resolution:** seed a short, clearly-labeled placeholder `team_text`;
   do not leave it null and do not default the column.

3. **Read-side / index normalization drift.** The unique index uses
   `lower(ingame_name)` on already-`btrim`-trimmed stored values; RFC-003/004 must
   apply `trim()` then `lower()` to user input to match. **Resolution (this RFC):**
   restate the contract in a `schema.sql` comment above `players_tournament_name_idx`
   so the coupling is visible at the source of truth. "If you change one side, change
   both" (RULES §4).

4. **Internal whitespace preservation.** Trigger must use `btrim` (leading/trailing
   only), never a global space-strip. **Resolution:** use `btrim` exactly as specified;
   the verification block includes an internal-whitespace case.

5. **`.env.example` overlap with RFC-003.** RFC-003 also touches config.
   **Resolution:** RFC-001 adds the two Supabase placeholders now; RFC-003 assumes they
   exist. Additive, non-conflicting (exploration report §3).

6. **File-location preference.** `schema.sql` at repo root is the locked decision
   (RFC-001 §3.1). If the maintainer later prefers `knowledge/`, it is a trivial move —
   flagged, not blocking. Do not pre-emptively relocate.

---

## Rules compliance checklist (for the coder)

- No new Python folders/packages/modules; no `migrations/` dir (RULES §2).
- English DB identifiers exactly as named; French comments in `.env.example` (RULES §3).
- Invariants enforced in DB, not code; two-step-activation error is expected (RULES §4).
- No real secrets in `.env.example` — placeholders only (RULES §6).
- No stubs/TODOs; script must be complete and idempotent (RULES §10).
- No Python touched in this RFC (RFC-001 §7).
