# RFC-011 — Ranking Schema: Profiles, Seasons, Tiers & Frozen Results

- **Status:** 📝 Draft — not started
- **Implementation order:** 11 of 14 (v4.0) — first RFC of the ranking /
  identity series; depends on **all** of v2.0 (RFC-001–006) and **all** of v3.0
  (RFC-007–010) being complete
- **Complexity:** Medium
- **Features covered:** F38, F39, F40, F41, F42, F43, F44, F45, F46, F47, F48,
  F49, F50, F66, F67, plus the **DDL halves** of F60, F69 and F70 (their
  command halves are RFC-013/014)
- **Grounding:** `knowledge/PRD.v4.final.md` §31.1–§31.3, §37, §39;
  `knowledge/FEATURES.md` §L, §M, §N
- **Builds upon:** RFC-001 (schema conventions, `trim_ingame_name()`, the
  idempotent-apply contract, seed-data idioms), RFC-003 (RLS deny-by-default
  precedent), RFC-007 (the append-a-new-section-to-`schema.sql` precedent)
- **Built upon by:** RFC-012 (the freeze writes `tournament_results`), RFC-013
  (binding reads/writes `profiles` and `players.profile_id`), RFC-014 (the read
  commands query `season_standings` and `current_season`)

---

## 1. Summary

Establish the **durable data layer** for v4.0: a cross-tournament `profiles`
identity, a `seasons` calendar, a `tournament_tiers` weight lookup, the
per-event metadata the ranking needs (`event_date`, `season_id`, `tier_id`,
`completed_at`), and the `tournament_results` table that holds frozen
placements and points.

Like RFC-001 and RFC-007, this RFC produces **no Python and no TypeScript**.
Its entire deliverable is an idempotent addition to `schema.sql`, applied once
per environment via the Studio SQL editor, plus a `.claude/RULES.md` v4.0
addendum.

Two things make this RFC different in kind from every schema RFC before it:

- **This is the project's first non-disposable data.** `tournaments`/`players`
  are cheaply retypable; the Challonge caches are re-derivable from Challonge
  at any time. `profiles` and `tournament_results` are neither. The schema must
  make accidental loss hard — hence F48's `on delete restrict` and the deliberate
  break from this file's otherwise uniform cascade pattern.
- **`profiles.discord_user_id` is the first genuinely personal data the project
  stores** (PRD G17). The erasure path (F69) must be *possible by construction*
  in this RFC even though the `/unlink` command that drives it ships in RFC-013.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F38** | `profiles` — `id`, `discord_user_id` (not null, unique, **text**), `display_name` (nullable snapshot), `created_at`. The only table in the schema not scoped to a tournament. |
| **F39** | `players.profile_id` — nullable FK to `profiles`. Nullable is load-bearing: roster rows exist before bindings do, and some never get one. |
| **F40** | Unique index on `(tournament_id, profile_id) where profile_id is not null` — one person cannot hold two roster slots in one event. |
| **F41** | `seasons` — `id`, `name`, `starts_on`, `ends_on`. |
| **F42** | *(P1)* Non-overlapping season ranges as a DB invariant: `exclude using gist (daterange(starts_on, ends_on, '[]') with &&)`. Explicit `'[]'` bounds; **no `btree_gist`**. |
| **F43** | `tournaments.event_date` — the date the event happened. `created_at` cannot serve this purpose. |
| **F44** | `tournaments.season_id` — nullable FK. `NULL` = counts toward no ranking. |
| **F45** | `tournament_tiers` (`id`, `name`, `multiplier`) + `tournaments.tier_id`, a **not-null** FK. Seeded Hebdo 1.0 / Mensuel 2.0 / Majeur 3.0 via guarded inserts. |
| **F46** | `tournaments.completed_at` — nullable timestamp set by the freeze. Not a status enum, and independent of `is_active`. |
| **F47** | `tournament_results` — keyed `(tournament_id, challonge_participant_id)`, `player_id` and `profile_id` both nullable, `ingame_name` denormalized on purpose. |
| **F48** | `tournament_results.tournament_id` uses **`on delete restrict`**, breaking this file's uniform cascade pattern, with an explicit comment saying so. |
| **F49** | RLS enabled, deny-by-default, no policies, on all four new tables — identical posture to every existing table. |
| **F50** | Frozen history is correctable only deliberately — this RFC provides the `frozen_at` / `freeze_count` columns the mechanism (F72, RFC-012) records through. |
| **F66** | "Current season" is a defined, single-query concept: the unique `seasons` row whose `[starts_on, ends_on]` contains today. Delivered as the `current_season` view. |
| **F67** | Frozen results snapshot every points input: `season_id`, the resolved **`multiplier`**, `formula_version`, `participant_count`. |
| **F60 (DDL)** | The auto-link-forward trigger on `players`. Its command half (backfill on bind) is RFC-013. |
| **F69 (DDL)** | `on delete set null` on both `profile_id` FKs, making erasure possible by construction. The `/unlink` command is RFC-013. |
| **F70 (DDL)** | The `season_standings` aggregate view. Its render contract (ordering display, top-25 cap, mentions, char cap, footer) is RFC-014. |

### Deliberate scope decision — all v4.0 DDL lands here

PRD §40 assigns F60 to RFC-013 and F70 to RFC-014, but both have a DDL half
that cannot live in Python. Rather than have three separate RFCs each append to
`schema.sql`, this RFC takes **all** v4.0 DDL, using the PRD's own `F69 (DDL)`
convention. RFC-013 and RFC-014 then own only behavior, and `schema.sql` is
touched exactly once in v4.0 — matching how RFC-001 and RFC-007 each owned their
release's schema outright.

The one consequence worth stating: **RFC-011 encodes the aggregate and sort keys
F70 describes**, but not its presentation. The seam is drawn at "what the
database can compute correctly" (grouping, sums, tie-break keys) versus "what
Discord renders" (rank numbering, mentions, the 4096-char cap, the truncation
footer). RFC-014 must not need to change the view.

## 3. Technical approach

All DDL is appended to `schema.sql` as **one self-contained v4.0 section**,
placed after RFC-007's blocks and before the commented verification block.

### 3.1 A deliberate ordering exception

RFC-001 established the file order *tables → function → trigger → indexes →
RLS → seed → verification*. The v4.0 block **cannot** follow it globally,
because F45's `tournaments.tier_id` is a **not-null** FK added to a table that
already has rows: the tier rows must be seeded *before* the backfill that makes
the column non-null.

The v4.0 block therefore runs in its own internal order and says so in a header
comment:

```
tables (profiles, seasons, tournament_tiers)
  -> tier seed
  -> tournaments columns + tier backfill + set not null
  -> tournament_results
  -> functions + trigger (auto-link)
  -> indexes + constraints
  -> views
  -> RLS + grants
  -> (amendments to the existing verification block)
```

This is a documented exception, not drift. Do not "fix" it by reordering — the
backfill will fail.

### 3.2 Identity (F38, F39, F40, F69-DDL)

```sql
create table if not exists profiles (
  id              bigint generated always as identity primary key,
  -- TEXT, not bigint: Discord snowflakes exceed 2^53, and the Edge Function
  -- (JS/JSON) would silently lose precision on a numeric round-trip.
  discord_user_id text not null,
  -- Snapshot for Studio readability ONLY. Users rename themselves; this WILL
  -- drift. Never resolve identity through it (F38).
  display_name    text null,
  created_at      timestamptz not null default now()
);

create unique index if not exists profiles_discord_user_id_idx
  on profiles (discord_user_id);

-- F39: nullable FK, no default. Every existing v2.0/v3.0 row stays valid.
-- F69 (DDL): `on delete set null`, NOT cascade — deleting a profile (erasure)
-- must orphan the roster row, never delete a tournament's roster history.
alter table players
  add column if not exists profile_id bigint null
  references profiles(id) on delete set null;

-- F40: one person cannot hold two roster slots in the same event. Mirrors
-- players_tournament_name_idx's contract on the name axis.
create unique index if not exists players_tournament_profile_idx
  on players (tournament_id, profile_id)
  where profile_id is not null;
```

### 3.3 Seasons (F41, F42, F66)

```sql
create table if not exists seasons (
  id         bigint generated always as identity primary key,
  name       text not null,
  starts_on  date not null,
  ends_on    date not null,
  created_at timestamptz not null default now(),
  constraint seasons_bounds_ck check (ends_on >= starts_on)
);
```

F42's exclusion constraint has no `if not exists` form, so it is guarded on
`pg_constraint` to keep the file idempotent:

```sql
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'seasons_no_overlap_excl') then
    alter table seasons
      add constraint seasons_no_overlap_excl
      -- '[]' bounds, NOT daterange's default '[)': half-open would make
      -- ends_on exclusive and contradict its own name (F42).
      -- No btree_gist extension: range types ship a native GiST operator
      -- class, and there is no scalar `with =` column to mix in.
      exclude using gist (daterange(starts_on, ends_on, '[]') with &&);
  end if;
end $$;
```

F66 — "current season" as a single query — is delivered as a view so that
*today* is evaluated server-side in the database's timezone (UTC on Supabase),
not by whichever client happens to ask:

```sql
create or replace view current_season with (security_invoker = on) as
  select id, name, starts_on, ends_on
  from seasons
  where current_date between starts_on and ends_on;
```

F42 guarantees at most one row. **F66 must not assume F42 has been applied**
(F42 is P1): readers take the first row, and the view is documented as
"zero or one row; zero is a normal state, not an error" — covering both of
F66's states (today falls in no season, and a season with no results yet).

### 3.4 Tiers and event metadata (F43, F44, F45, F46)

```sql
create table if not exists tournament_tiers (
  id         bigint generated always as identity primary key,
  name       text not null,
  multiplier numeric(4,2) not null check (multiplier > 0)
);

create unique index if not exists tournament_tiers_name_idx
  on tournament_tiers (lower(name));

-- Guarded seed (F45). A lookup rather than a free numeric column so the
-- Studio surface is a typo-proof dropdown and "what counts as a major" is an
-- explicit, reviewable decision.
insert into tournament_tiers (name, multiplier)
select seed.name, seed.multiplier
from (values ('Hebdo', 1.0), ('Mensuel', 2.0), ('Majeur', 3.0))
     as seed(name, multiplier)
where not exists (
  select 1 from tournament_tiers t where lower(t.name) = lower(seed.name)
);
```

```sql
alter table tournaments
  add column if not exists event_date   date null,
  -- F44: NULL means the event counts toward no ranking (test tournaments,
  -- exhibitions). It is also F55's guard: the freeze refuses on a null season.
  add column if not exists season_id    bigint null references seasons(id) on delete set null,
  add column if not exists tier_id      bigint null references tournament_tiers(id) on delete restrict,
  -- F46: non-null means "results are frozen". Deliberately NOT a status enum
  -- and deliberately independent of is_active, which stays load-bearing for
  -- the /ots read path (tournaments_one_active_idx). A frozen tournament may
  -- remain active; /ots then reports no_current_match, which is correct.
  add column if not exists completed_at timestamptz null;

-- F45: tier_id is a NOT NULL FK, but the column is added to a table that
-- already has rows — so: add nullable, backfill to the base tier, then
-- constrain. Re-running `set not null` on an already-not-null column is a
-- no-op, so this stays idempotent.
update tournaments
set tier_id = (select id from tournament_tiers where lower(name) = 'hebdo')
where tier_id is null;

alter table tournaments alter column tier_id set not null;
```

`tier_id` uses `on delete restrict`: a tier that priced a real event must not be
deletable out from under it. Repricing is safe — F67 snapshots the resolved
multiplier, so it never restates history.

### 3.5 Frozen results (F47, F48, F67)

```sql
create table if not exists tournament_results (
  id                       bigint generated always as identity primary key,

  -- F48: `on delete restrict`, NOT `on delete cascade`. THIS BREAKS THE
  -- UNIFORM CASCADE PATTERN USED BY EVERY OTHER FK IN THIS FILE, ON PURPOSE.
  -- Frozen results are the one place in this system where data loss is
  -- unacceptable: a roster typo is recoverable, a deleted season of standings
  -- is not. A future reader WILL assume this cascades — it does not.
  -- Operational consequence: the "delete the test tournament" cleanup in the
  -- RFC-007 verification block below stops working once anything is frozen.
  -- Test tournaments must either never be frozen (season_id is null is the
  -- guard, enforced by F55) or get an explicit results-purge step first.
  -- See RUNBOOK.md §9.
  tournament_id            bigint not null references tournaments(id) on delete restrict,

  -- F47: the BRACKET, not the roster, decides who earned a result. Placement
  -- is a fact about the bracket: a bracket entrant with no roster row must
  -- still be recorded (F57), and a roster-only name must earn nothing.
  challonge_participant_id bigint not null,
  player_id                bigint null references players(id) on delete set null,
  -- Nullable AND backfillable: an unbound player's result freezes correctly,
  -- and binding later attributes their history (F60). `set null` supports
  -- erasure-by-anonymization (F69).
  profile_id               bigint null references profiles(id) on delete set null,
  -- Denormalized on purpose: history must stay readable if the roster row is
  -- later edited, renamed, or deleted.
  ingame_name              text not null,
  -- Competition-style, WITH TIES AND GAPS (F54). Never treat as dense 1..N.
  final_rank               integer not null check (final_rank >= 1),
  awarded_points           numeric(8,2) not null check (awarded_points >= 0),

  -- F67 — the snapshot. Every input the points depended on, captured at
  -- freeze time so later rule/pricing changes never restate history.
  -- Standings sum over THIS season_id, never over a join to tournaments:
  -- editing tournaments.season_id after a freeze must not relocate a frozen
  -- result into another season.
  season_id                bigint not null references seasons(id) on delete restrict,
  -- The RESOLVED numeric multiplier, not tier_id. Load-bearing, not prudent:
  -- tiers are shared rows, so repricing "Majeur" from 3.0 to 2.5 would
  -- otherwise silently restate every Majeur ever frozen.
  multiplier               numeric(4,2) not null,
  formula_version          text not null,
  -- One integer; keeps field-size scaling answerable later without a schema
  -- change and a Challonge re-fetch.
  participant_count        integer not null check (participant_count >= 0),

  -- F50: the audit trail a deliberate correction (F72) writes through.
  frozen_at                timestamptz not null default now(),
  freeze_count             integer not null default 1 check (freeze_count >= 1)
);

create unique index if not exists tournament_results_participant_idx
  on tournament_results (tournament_id, challonge_participant_id);

-- Serves RFC-014's season leaderboard and per-player history.
create index if not exists tournament_results_season_idx
  on tournament_results (season_id);

create index if not exists tournament_results_profile_idx
  on tournament_results (profile_id)
  where profile_id is not null;

-- Serves RFC-013's backfill-on-bind, which matches on normalized name within
-- the current season (F60).
create index if not exists tournament_results_season_name_idx
  on tournament_results (season_id, lower(ingame_name));
```

**`awarded_points` is `numeric`, not `integer`**, because a future tier
multiplier need not be a whole number (`2.5 × 15 = 37.5`). The three seeded
tiers all yield integers today.

**`tournament_results.ingame_name` deliberately does *not* get the
`trim_ingame_name()` trigger.** It is a historical snapshot written by the Edge
Function from Challonge's own participant name, not an identity key — trimming
it on write would be harmless, but adding a third table to that trigger's
dependency set for no read-path benefit is not. Its indexes apply
`lower(...)` at read time and RFC-013's backfill normalizes on the bot side.

### 3.6 Auto-link forward (F60 — DDL half)

F60's forward auto-link **must be a database trigger**. Roster rows are created
by the organizer in Supabase Studio, where no bot code runs — there is no other
place to hook it, and this project already prefers DB-enforced invariants
(single-active, name uniqueness) over application code.

```sql
-- F60: resolve the profile already holding a normalized in-game name.
-- Returns NULL rather than guessing when the answer is not unique — binding
-- is an AUTHORIZATION boundary (PRD §31.6), so this fails closed.
create or replace function resolve_profile_for_ingame_name(p_name text)
returns bigint as $$
declare
  v_ids bigint[];
begin
  select array_agg(distinct pl.profile_id) into v_ids
  from players pl
  where pl.profile_id is not null
    and lower(btrim(pl.ingame_name)) = lower(btrim(p_name));

  if v_ids is null then
    return null;
  end if;

  if array_length(v_ids, 1) <> 1 then
    raise warning 'auto-link: ingame_name % matches % distinct profiles - leaving unlinked',
      p_name, array_length(v_ids, 1);
    return null;
  end if;

  return v_ids[1];
end;
$$ language plpgsql stable;

create or replace function autolink_player_profile() returns trigger as $$
declare
  v_profile_id bigint;
begin
  -- An explicitly-supplied profile_id always wins: /link-organizer (RFC-013)
  -- and a deliberate Studio edit must never be second-guessed here.
  if new.profile_id is not null then
    return new;
  end if;

  v_profile_id := resolve_profile_for_ingame_name(new.ingame_name);
  if v_profile_id is null then
    return new;
  end if;

  -- F40 guard, FAIL-OPEN. A profile bound to two different names across
  -- seasons could otherwise auto-link into two roster rows of the same
  -- tournament, tripping players_tournament_profile_idx and blocking the
  -- organizer's Studio insert outright. Leaving profile_id NULL costs one
  -- /link-organizer; a rejected insert costs the roster.
  if exists (
    select 1 from players
    where tournament_id = new.tournament_id and profile_id = v_profile_id
  ) then
    raise warning 'auto-link: profile % already holds a roster slot in tournament % - leaving % unlinked',
      v_profile_id, new.tournament_id, new.ingame_name;
    return new;
  end if;

  new.profile_id := v_profile_id;
  raise notice 'auto-link: players.ingame_name % linked to profile %',
    new.ingame_name, v_profile_id;
  return new;
end;
$$ language plpgsql;

drop trigger if exists players_autolink_profile on players;
create trigger players_autolink_profile
  before insert on players
  for each row execute function autolink_player_profile();
```

**Trigger firing order.** Postgres fires same-event triggers in name order, so
`players_autolink_profile` runs *before* `players_trim_ingame_name`. That is
why `resolve_profile_for_ingame_name` applies `btrim`/`lower` itself rather
than relying on the trim trigger having run. Do not rename either trigger into
a different relative order without re-checking this.

**`before insert` only, not `before insert or update`.** A rename of an
existing roster row must not silently re-point it at a different person's
profile — that is exactly the "silently moves team-sheet access" hazard F60's
logging requirement exists for. Re-pointing is `/link-organizer`'s job.

### 3.7 The standings view (F70 — DDL half)

PostgREST's aggregate support is configuration-dependent, and this project's
style puts set logic in the database. A view keeps RFC-014's read to a single
indexed `GET` with `order=` parameters:

```sql
-- F70 (DDL half): one row per ranked competitor per season. Ordering,
-- rank numbering, the top-25 cap, mentions and the 4096-char budget are
-- RFC-014's; this view supplies only what the database can compute correctly.
create or replace view season_standings with (security_invoker = on) as
select
  r.season_id,
  -- Bound competitors group by profile; unbound ones group by normalized
  -- name, so an unbound player is shown and ranked from day one (F70) and
  -- merges into their profile's row the moment they are bound (F60).
  coalesce('profile:' || r.profile_id::text, 'name:' || lower(btrim(r.ingame_name)))
    as standing_key,
  max(r.profile_id)                                          as profile_id,
  (array_agg(r.ingame_name order by r.frozen_at desc))[1]    as ingame_name,
  sum(r.awarded_points)                                      as total_points,
  count(*)                                                   as events_played,
  min(r.final_rank)                                          as best_rank
from tournament_results r
group by
  r.season_id,
  coalesce('profile:' || r.profile_id::text, 'name:' || lower(btrim(r.ingame_name)));
```

`standing_key` is the concrete realization of F70's final stability key. The PRD
names `profile_id asc`; `standing_key` embeds it for bound rows and, unlike
`profile_id`, is never null — so ordering is total and deterministic for unbound
rows too. Documented refinement, not a reopened decision.

`ingame_name` resolves to the **most recently frozen** spelling, so a player who
changes their tag mid-season appears under the current one.

### 3.8 RLS and grants (F49)

```sql
alter table profiles           enable row level security;
alter table seasons            enable row level security;
alter table tournament_tiers   enable row level security;
alter table tournament_results enable row level security;
```

Same deny-by-default posture as every other table: no policies, because the
only readers/writers are the bot and the Edge Function, both on service keys
that bypass RLS entirely.

**Views need the extra step.** A view is not covered by its base tables' RLS
unless it is a security-invoker view, so both views declare
`with (security_invoker = on)` (§3.3, §3.7) *and* revoke the PostgREST roles
explicitly:

```sql
revoke all on current_season, season_standings from anon, authenticated;
```

Without `security_invoker`, a view owned by a superuser would happily serve
`anon` the very rows RLS denies on the base tables — reopening the hole RFC-003
closed. This is the single easiest mistake to make in this RFC.

### 3.9 Verification-block amendments

The existing RFC-007 verification block contains a `delete from tournaments
where name = 'RFC-001 Test Tournament'` cleanup step. F48 breaks it. Amend that
commented step in place with the reason and the purge-first alternative, and
append new commented checks for the v4.0 invariants (§10).

## 4. Data models / schema changes

**Four new tables:** `profiles`, `seasons`, `tournament_tiers`,
`tournament_results`.
**Five new columns:** `players.profile_id`; `tournaments.event_date`,
`.season_id`, `.tier_id`, `.completed_at`.
**Two new views:** `current_season`, `season_standings`.
**Two new functions + one trigger:** `resolve_profile_for_ingame_name()`,
`autolink_player_profile()`, `players_autolink_profile`.
**Indexes/constraints:** `profiles_discord_user_id_idx`,
`players_tournament_profile_idx`, `seasons_bounds_ck`,
`seasons_no_overlap_excl`, `tournament_tiers_name_idx`,
`tournament_results_participant_idx`, `tournament_results_season_idx`,
`tournament_results_profile_idx`, `tournament_results_season_name_idx`.
**Seed:** three tier rows, guarded.

Purely additive per PRD §39 — **no existing column changes type or meaning and
no existing query needs rewriting**. `tournaments.tier_id`'s not-null backfill
is the only write to pre-existing rows, and it only fills a column that did not
exist a statement earlier.

No new Postgres extension. No new external service, runtime, secret, or Python
dependency.

## 5. Interfaces exposed

The DB contract consumed by the next three RFCs:

- **To RFC-012 (the freeze, writer):** `tournament_results` is upsertable on
  `(tournament_id, challonge_participant_id)`. Every F67 snapshot column is
  `not null`, so a freeze that cannot resolve `season_id` or `multiplier` fails
  at the database rather than writing a half-snapshot. `tournaments.completed_at`
  and `tournament_results.freeze_count` are the freeze's own bookkeeping.
- **To RFC-013 (binding, reader/writer):** `profiles` is insertable and
  uniquely keyed on `discord_user_id`; `players.profile_id` is patchable;
  `tournament_results.profile_id` is patchable for backfill; both clear to
  `null` on profile delete, so `/unlink` cannot orphan or block. The
  `players_autolink_profile` trigger handles forward propagation with no bot
  involvement.
- **To RFC-014 (read commands, reader):** `current_season` returns zero or one
  row; `season_standings` returns one row per ranked competitor per season with
  `total_points`, `events_played`, `best_rank` and a total-ordering
  `standing_key`. Per-player history reads `tournament_results` directly,
  embedding `tournaments(name,event_date)` via the existing FK.

## 6. Acceptance criteria

- [ ] **F38:** `profiles` exists; `discord_user_id` is `text`, not null, and
      two rows cannot share one; `display_name` is nullable; the table has no
      `tournament_id` and no FK to `tournaments`.
- [ ] **F39:** `players.profile_id` exists, nullable, no default; every
      pre-existing roster row remains valid and readable; `/ots`'s existing
      v3.0 queries are byte-for-byte unaffected.
- [ ] **F40:** two roster rows in the *same* tournament cannot share a non-null
      `profile_id`; two rows in *different* tournaments can.
- [ ] **F41:** `seasons` exists with `name`, `starts_on`, `ends_on`; a row with
      `ends_on < starts_on` is rejected.
- [ ] **F42:** two seasons whose inclusive date ranges overlap — including
      sharing exactly one boundary day — are rejected by
      `seasons_no_overlap_excl`; two adjacent, non-overlapping seasons are
      accepted; no new extension was installed.
- [ ] **F66:** `current_season` returns exactly the season containing today,
      or zero rows when today falls in none; it never returns two rows given
      F42; readers are documented to treat zero rows as normal.
- [ ] **F43/F44:** `tournaments.event_date` and `.season_id` exist and are
      nullable; a tournament with `season_id is null` is valid.
- [ ] **F45:** `tournament_tiers` holds exactly Hebdo 1.0 / Mensuel 2.0 /
      Majeur 3.0 after any number of applies; `tournaments.tier_id` is
      **not null** and every pre-existing tournament row carries the base tier;
      a tier referenced by a tournament cannot be deleted.
- [ ] **F46:** `tournaments.completed_at` exists, nullable, defaults to null,
      and no constraint ties it to `is_active`; a tournament can be
      simultaneously `is_active = true` and `completed_at` non-null.
- [ ] **F47:** `tournament_results` is unique on
      `(tournament_id, challonge_participant_id)`; `player_id` and `profile_id`
      both accept null; `ingame_name`, `final_rank`, `awarded_points` are not
      null; a row survives deletion of its `players` row.
- [ ] **F48:** deleting a `tournaments` row that has any `tournament_results`
      row **fails** with a FK violation; the column carries an explicit comment
      saying it does not cascade; the RFC-007 verification block's delete step
      is amended in place.
- [ ] **F49:** `relrowsecurity = true` on all four new tables, with zero
      policies; `anon` receives an empty array from PostgREST for each of them
      **and for both views**; the service key still reads everything.
- [ ] **F50:** `frozen_at` and `freeze_count` exist with sane defaults
      (`now()`, `1`) and `freeze_count >= 1` is enforced.
- [ ] **F67:** `season_id`, `multiplier`, `formula_version`,
      `participant_count` are all **not null** on `tournament_results`; an
      insert omitting any of them fails; `season_id` references `seasons` with
      `on delete restrict`.
- [ ] **F60 (DDL):** inserting a roster row whose normalized name matches a
      bound profile links it automatically; an ambiguous name (two distinct
      profiles) leaves it null and raises a warning; a profile already holding
      a slot in that tournament leaves it null and raises a warning **without
      failing the insert**; an explicitly-supplied `profile_id` is never
      overwritten; an `update` to `ingame_name` never re-links.
- [ ] **F69 (DDL):** deleting a `profiles` row sets `players.profile_id` and
      `tournament_results.profile_id` to null and deletes nothing else; the
      frozen `ingame_name` snapshot survives.
- [ ] **F70 (DDL):** `season_standings` groups bound rows by profile and
      unbound rows by normalized name; `total_points`, `events_played` and
      `best_rank` are correct against a hand-computed fixture; `standing_key`
      is never null.
- [ ] **Idempotency:** `schema.sql` applies cleanly twice in a row against a
      fresh database *and* against a database already carrying v2.0/v3.0 data —
      no error, no duplicate object, no duplicate tier row, no second backfill.

## 7. Implementation details

- **File:** extend the existing `schema.sql` at repo root. Do not create a
  second SQL file, and do not create a migrations folder — this project applies
  DDL by hand in the Studio SQL editor (RFC-001 precedent, RULES §2).
- **Idempotency idioms:** `create table if not exists`,
  `add column if not exists`, `create [unique] index if not exists`,
  `create or replace function/view`, `drop trigger if exists` + `create
  trigger`, `insert ... where not exists` for seeds, and a `pg_constraint`-
  guarded `do $$ ... $$` for the one constraint with no `if not exists` form.
- **File header:** extend `schema.sql`'s top-of-file comment block with an
  RFC-011 paragraph, matching how RFC-003 and RFC-007 each added one.
- **`.claude/RULES.md`:** add a **v4.0 addendum starting at §21** (v3.0's
  addendum ends at §20) covering: the durable-data posture and F48's non-cascade;
  the "snapshot the multiplier, never `tier_id`" rule; the deny-by-default
  posture extended to views via `security_invoker`; and the auto-link trigger's
  fail-closed/fail-open rules. RFC-012 amends §18 separately; RFC-013/014 extend
  the addendum as their features require.
- **No Python, no TypeScript, no Edge Function change** in this RFC.

## 8. Edge cases & risks

- **The `security_invoker` trap (highest risk in this RFC).** Enabling RLS on
  four tables and then exposing an aggregate view over one of them without
  `security_invoker = on` hands `anon` the standings the RLS was meant to
  protect. Verify both views against the anon key, not just the tables.
- **F48 breaks an operational procedure, silently, later.** Nothing fails at
  apply time; the "delete the test tournament" step just stops working the
  first time something is frozen. The verification-block amendment and
  RUNBOOK §9 (RFC-014) are the only mitigations. Do not soften the constraint
  to make the cleanup convenient again.
- **The `tier_id` not-null backfill is a one-way write to production rows.** It
  assigns the base tier to every pre-existing tournament, including historical
  ones. Harmless (they have `season_id is null` and will never freeze), but it
  is a real `update` against live data and should be stated in the apply notes.
- **F42 rejects same-day-boundary seasons.** With `'[]'` bounds, a season ending
  2026-12-31 and one starting 2026-12-31 overlap and the second insert fails.
  That is the intent, and the organizer will hit it — RUNBOOK §9 must show
  adjacent bounds (`…-12-31` then `…-01-01`).
- **`current_season` depends on the database's timezone.** `current_date` is
  evaluated in the session timezone (UTC on Supabase). At a French event
  running past midnight UTC the "current" season could flip a day early on a
  boundary date. Accepted: season boundaries are months apart, and the
  alternative (passing the client's date in) makes the answer client-dependent.
  Document it; do not build timezone handling.
- **Ambiguous auto-link is a real, silent state.** Two people who used the same
  in-game name in different seasons produce a `null` link and a server warning
  that nobody reads. Pre-flight (G16) is what catches it; the trigger's job is
  only to never guess.
- **Auto-link makes the schema depend on name discipline.** F60 keys on the
  normalized name, so the organizer's existing "keep Challonge and Supabase
  names identical" discipline (PRD §36) now also governs *who gets whose team
  sheet*. This is stated in the PRD as an accepted trust argument; the schema
  cannot enforce it.
- **`display_name` will drift and someone will try to resolve identity through
  it.** Comment it at the column, not just here.

## 9. Applicable rules (RULES.md)

- **§1 (dependency policy):** N/A — pure SQL, no new Python dependency, and
  explicitly no new Postgres extension (F42).
- **§2 (architecture / no new folders):** respected — everything stays in
  `schema.sql`.
- **§3 (naming):** all new identifiers are English `snake_case`, consistent
  with existing tables. `profiles`, `seasons`, `tournament_tiers`,
  `tournament_results`, `profile_id`, `season_id`, `tier_id`, `event_date`,
  `completed_at`, `final_rank`, `awarded_points`, `frozen_at`, `freeze_count`,
  `formula_version`, `participant_count`, `multiplier`. Do not rename.
- **§4 (DB contract):** extends the existing "invariants live in the database"
  posture — F40 and F42 are index/constraint-enforced, not application-checked,
  exactly as single-active and per-tournament name uniqueness already are. The
  trim+lower identity contract is reused, never reimplemented.
- **§6 (security):** RLS deny-by-default extended to four tables and, via
  `security_invoker`, to two views. No secret is introduced by this RFC.
- **§10 (ask before touching locked decisions):** this RFC **reopens F25(b)**
  ("cross-tournament player identities", a v2.0 Won't-have) deliberately and
  with PRD authority (§29). That reopening is the core of v4.0, not a silent
  scope creep — annotate `FEATURES.md` F25(b) in place if RFC-011 is the first
  to land it.
- **v3.0 §14 (cache tables are disposable):** unchanged, but note the contrast
  the new tables introduce — `profiles`/`tournament_results` are **not**
  disposable and must never be treated as re-derivable. Add this to the v4.0
  RULES addendum.

## 10. Testing strategy

DB-level verification in the Studio SQL editor, mirroring RFC-001/RFC-007. No
Python or Deno tests — there is no Python or TypeScript in this RFC. Prefer
verifying against a disposable local `postgres:16-alpine` container first, as
RFC-007 did, before touching a live project.

Keep each check as a commented statement in `schema.sql`'s verification block:

1. **Idempotency:** apply the full script twice; confirm zero errors, three
   tier rows (not six), and no second `tier_id` backfill.
2. **F42:** insert two overlapping seasons → rejected by
   `seasons_no_overlap_excl`; insert two adjacent ones → accepted; confirm a
   shared boundary day is treated as an overlap.
3. **F40:** insert two roster rows in one tournament sharing a `profile_id` →
   rejected; the same across two tournaments → accepted.
4. **F48:** freeze a fixture result, then `delete from tournaments where id = …`
   → FK violation naming `tournament_results`.
5. **F67:** insert a `tournament_results` row omitting `multiplier` → rejected.
6. **F60:** the four trigger paths — clean link, ambiguous name, profile
   already slotted in that tournament, explicit `profile_id` supplied — plus an
   `update` to `ingame_name` confirming no re-link.
7. **F69:** delete a `profiles` row that has both `players` and
   `tournament_results` references → succeeds, both go null, `ingame_name`
   snapshots survive.
8. **F70:** insert a small hand-computed fixture (one bound player across two
   events, one unbound player across one) and confirm `season_standings`
   returns the expected `total_points` / `events_played` / `best_rank`.
9. **F49 (must be run against PostgREST, not the SQL editor):** with the anon
   key, `GET` each of `profiles`, `seasons`, `tournament_tiers`,
   `tournament_results`, **`current_season` and `season_standings`** → empty
   array for every one. With the service key → rows. The SQL editor runs as a
   superuser role and proves nothing here.

### Seed fixtures

Add a guarded v4.0 seed extending the existing `RFC-001 Test Tournament`
fixture, so RFC-012/013/014 have data before any live season exists:

- one `seasons` row covering a wide, clearly-fake range (e.g. `2026-01-01` →
  `2026-12-31`, named `RFC-011 Test Season`);
- the test tournament gets `event_date`, that `season_id`, and the `Hebdo` tier
  — **but is left with `completed_at` null and no `tournament_results` rows**,
  so RFC-012 can exercise a real first freeze against it;
- **no seeded `profiles` row.** A fake `discord_user_id` would be the one seed
  in this file that cannot be exercised (no real Discord account backs it) and
  would sit in the personal-data table. RFC-013's E2E binds a real account
  instead.

> ⚠️ Setting `season_id` on the test tournament makes it freezable, which under
> F48 makes it undeletable afterwards. That is deliberate — it is precisely the
> trap RUNBOOK §9 has to teach — but the seed comment must say so out loud.

---

## Completion record

- **Status:** ✅ Complete (2 review rounds) — schema-only, no bot/Edge Function
  code touched. Implemented directly against the approved planner blueprint
  (`.claude/rfc-plans/RFC-011-plan.md`).
- **Deliverables shipped:** one self-contained section `8. v4.0 — RANKING &
  IDENTITY (RFC-011)` appended to `schema.sql` (existing "7. VERIFICATION
  BLOCK" renumbered to "9."), plus a header-block paragraph documenting the
  addition and the ordering/cascade exceptions:
  - **Tables:** `profiles` (F38), `seasons` (F41, with inline
    `seasons_bounds_ck`), `tournament_tiers` (F45, seeded Hebdo 1.0 / Mensuel
    2.0 / Majeur 3.0), `tournament_results` (F47/F48/F50/F67).
  - **Columns:** `players.profile_id` (F39, `on delete set null`);
    `tournaments.event_date` (F43), `.season_id` (F44, `on delete set null`),
    `.tier_id` (F45, not-null via add → backfill → constrain),
    `.completed_at` (F46).
  - **Indexes/constraints:** `profiles_discord_user_id_idx`,
    `players_tournament_profile_idx` (F40), `seasons_no_overlap_excl` (F42, a
    `pg_constraint`-guarded exclusion constraint), `tournament_tiers_name_idx`,
    `tournament_results_participant_idx`, `_season_idx`, `_profile_idx`,
    `_season_name_idx`.
  - **Functions/trigger:** `resolve_profile_for_ingame_name()`,
    `autolink_player_profile()`, `players_autolink_profile` (F60 DDL half,
    fail-closed on ambiguity, fail-open on the F40 slot conflict, `before
    insert` only).
  - **Views:** `current_season` (F66), `season_standings` (F70 DDL half), both
    `with (security_invoker = on)` and both revoked from `anon`/`authenticated`
    (F49).
  - **RLS:** enabled, no policies, on all four new tables (F49).
  - **Seed:** one wide test season (`RFC-011 Test Season`), and the existing
    `RFC-001 Test Tournament` fixture amended in place with `event_date` and
    that season — left `completed_at` null and un-frozen for RFC-012.
  - **Verification block:** the RFC-007 "delete the test tournament" cleanup
    step amended in place with the F48 warning and a purge-first alternative;
    nine new commented checks appended (idempotency, F42, F40, F48, F67, F60's
    four paths + no-re-link + untrimmed insert, F69, F70, F49).
  - **`.claude/RULES.md`:** v4.0 addendum added, §21 (durable data / F48's
    non-cascade / personal-data erasure), §22 (frozen history: snapshot the
    resolved value, sum on `tournament_results.season_id`, deliberate-only
    corrections), §23 (`security_invoker` + revoke on every new view, verified
    through PostgREST only), §24 (auto-link's fail-closed/fail-open split,
    `before insert` only, trigger-name ordering, the name-discipline
    dependency).
  - `knowledge/RFCs/RFCS.md` line 145 flipped from `📝 Draft` to
    `✅ Complete`, with the verification summary inline.
  - `knowledge/FEATURES.md` F25(b) and its Supersession table were already
    annotated in place before this RFC started — verified, not re-annotated,
    per the plan.
- **Verification performed (real, not simulated):**
  - **Idempotency, fresh database:** `postgres:16-alpine` in Docker, with a
    container-only prelude creating `anon`/`authenticated` roles (never added
    to `schema.sql` itself — see the R6 note on the `revoke` statement).
    `psql -v ON_ERROR_STOP=1 -f schema.sql` applied **twice**: exit 0 both
    times; the second run showed `INSERT 0 0` / `UPDATE 0` for every seed and
    the `tier_id` backfill, and `NOTICE ... already exists, skipping` for every
    table/index/column — no duplicate objects, no duplicate tier rows.
  - **Idempotency, database already carrying v2.0/v3.0 data:** a second,
    separate container. Applied `git show HEAD:schema.sql` (the pre-RFC-011
    file) first, producing the standard v2.0/v3.0 seed (1 tournament, 3
    players, Challonge cache fixtures) — then added two more hand-inserted
    "historical" tournaments to more realistically exercise the backfill
    against pre-existing production-like rows. Applied the **new**
    `schema.sql` twice: pass 1 showed `UPDATE 3` for the `tier_id` backfill
    (confirmed via `select name, tier_id from tournaments` — all three,
    including both historical rows, got Hebdo); pass 2 showed `UPDATE 0`.
    Post-pass-2 invariants: 3 tier rows, 0 null `tier_id`, 1 `RFC-011 Test
    Season` row, 3 tournaments unchanged. Both containers removed after the
    run.
  - **F42:** same-boundary-day overlap (`...-06-30` then `2027-06-30-...`)
    rejected with `ERROR: conflicting key value violates exclusion constraint
    "seasons_no_overlap_excl"`; the adjacent pair (`2027-07-01`) succeeded;
    `select extname from pg_extension where extname = 'btree_gist'` returned 0
    rows both before and after.
  - **F40:** two roster rows sharing a `profile_id` in the same tournament →
    `ERROR: duplicate key value violates unique constraint
    "players_tournament_profile_idx"`; the same across two tournaments →
    succeeded.
  - **F48:** a fixture `tournament_results` row, then `delete from tournaments
    where id = ...` → `ERROR: ... violates foreign key constraint
    "tournament_results_tournament_id_fkey" on table "tournament_results"`,
    exactly as documented.
  - **Not separately re-verified in-container (noted for completeness, not
    blocking):** `tournament_tiers.id`'s own restrict behavior — that a tier
    referenced by any `tournaments.tier_id` row cannot be deleted — was not
    exercised by a dedicated `delete from tournament_tiers ...` check. It rests
    on the identical `on delete restrict` pattern proven above for
    `tournament_results`'s two FKs, which is standard, well-understood
    Postgres FK semantics, but it was confirmed by construction/analogy rather
    than by an independent run.
  - **F67:** an insert omitting `multiplier` → `ERROR: null value in column
    "multiplier" ... violates not-null constraint`.
  - **F60, all four paths, live-tested with six scratch tournaments (A–F) to
    avoid incidental `players_tournament_name_idx`/`players_tournament_profile_idx`
    collisions:** clean auto-link (no warning, correct `profile_id`);
    ambiguous name → `WARNING: auto-link: ingame_name ... matches 2 distinct
    profiles - leaving unlinked`, insert still succeeded with `profile_id`
    null; F40 slot conflict → `WARNING: auto-link: profile ... already holds a
    roster slot in tournament ... - leaving ... unlinked`, insert still
    succeeded; explicit `profile_id` supplied → never overwritten. Plus: an
    `update` to `ingame_name` on the still-unlinked row confirmed no re-link
    (trigger is `before insert` only); an insert of `'  rfc011f60cleanB  '`
    auto-linked correctly despite the untrimmed input and the stored name came
    back trimmed by the later-firing `players_trim_ingame_name` trigger.
  - **F69:** deleted a `profiles` row referenced by both a `players` row and a
    `tournament_results` row → succeeded; both FKs went null;
    `tournament_results.ingame_name` (the frozen snapshot) survived unchanged.
  - **F70:** hand-computed fixture (one bound player across two events at 100
    points each, one unbound player across one event at 50 points) — the
    view returned exactly `total_points 200 / events_played 2 / best_rank 1`
    for the bound row and `50 / 1 / 2` for the unbound row.
  - **F41/F50:** `ends_on < starts_on` → rejected by `seasons_bounds_ck`;
    `freeze_count` defaulted to `1` and `frozen_at` was non-null on insert.
  - **F49, the anon/`security_invoker` mechanism (§7.2 of the plan), including
    the required control case:** with the PostgREST roles granted `select` on
    all tables (simulating Supabase's automatic default-privilege grant, since
    a plain container-harness `grant ... to anon` predates the RFC-011
    objects), `set role anon` reads of `profiles`, `seasons`,
    `tournament_tiers`, `tournament_results`, `current_season` and
    `season_standings` all returned **0 rows** — RLS (and, for the views,
    `security_invoker`) doing the work, not a missing grant. **Control case:**
    created a deliberate non-`security_invoker` copy of `current_season`
    (`rfc011_control_no_invoker`), granted it to `anon`, and confirmed `anon`
    **did** get back the real `RFC-011 Test Season` row through it — proving
    the mechanism rather than assuming it. The control view was dropped
    immediately after and never entered `schema.sql`. Re-running the same
    read against `current_season` itself (the shipped, `security_invoker`
    view) returned 0 rows under identical grants.
  - **Regression:** `python -m unittest test_bot` — 30/30 `PASS`, unmodified.
    `deno test supabase/functions/challonge-sync/mapping_test.ts` — 7/7
    `PASS`, unmodified. `git status` showed only `schema.sql` modified
    (`.claude/RULES.md` and the two doc files were the only other intended
    touches) — no accidental edit reached `bot.py`, `test_bot.py`, or
    `supabase/functions/`.
- **Round 1 → Round 2 fix:** reviewer found that `tournaments.tier_id` being
  `not null` with no default (see the bug note directly below) silently breaks
  `RUNBOOK.md` §1's documented "create a tournament in Studio's Table Editor by
  filling only `name`" procedure, and that this was disclosed nowhere — not in
  this Completion record, not in the operator apply notes, not in the tracked
  follow-ups. Fixed with documentation only, no DDL change (RFC-011 does not
  own `RUNBOOK.md`): added operator apply note 8 above, extended the tracked
  follow-ups below, and added a matching entry to `RFCS.md`'s own "Tracked
  follow-ups" section so a future reader finds the gap regardless of which
  file they start from. Also added, as a non-blocking completeness note, that
  `tournament_tiers.id`'s FK-restrict behavior was proven by construction
  against the identical `tournament_results` pattern rather than by a
  dedicated in-container `delete` attempt (see the F48 verification entry
  above).
- **Bug found and fixed during verification (not in the RFC text, a coder
  responsibility per the plan):** `tournaments.tier_id` is `not null` with no
  default. The pre-existing F4c verification-block fixture
  (`insert into tournaments (name, is_active) values (...)`) and this RFC's
  own new verification fixtures (checks 3, 6, 8) all create fresh tournament
  rows — every one of them now needs an explicit `tier_id` (looked up from
  `tournament_tiers`) or the insert fails with a not-null violation. Fixed by
  adding `tier_id` (selecting the Hebdo tier's id) to every such insert,
  including the F4c fixture that predates RFC-011. Caught by actually running
  the checks in the container, not by inspection.
- **Deviations from the plan:** none. R6 was kept exactly as specified (the
  plain `revoke` stays in `schema.sql`; the `anon`/`authenticated` roles are
  created only in the container-harness prelude, with the one-line comment
  above the `revoke` explaining why); no `pg_roles`-guarded `do $$` swap was
  made.
- **Operator apply notes (Tier 2 — steps 3–5 now discharged against a *local*
  Supabase stack on 2026-08-16; steps 1, 2 and 6 discharged against the live
  project the same day — see "Live verification" below).** The plan assumed
  Tier 2 could not be run without the live project. That turned out to be
  wrong: a full local Supabase stack (real PostgREST + Kong, PG 17.6) was
  available, and the anon/service-key matrix ran against it for real — see
  "Local Supabase verification" below.

  The steps below are kept as written for the record, but note that step 2 was
  overtaken by the migration cutover: the schema was **not** pasted into the
  Studio SQL editor in the end. Production was baselined with
  `supabase migration repair --status applied` and this RFC's DDL arrived via
  `supabase db push`, making RFC-011 the first migration ever pushed to the
  live project rather than the last one hand-applied.
  1. Before applying, run `select version();` against the live Supabase
     project to confirm PG ≥ 15 (required for `security_invoker`).
  2. Apply the new `schema.sql` section via the Studio SQL editor, as always.
     **This writes to every pre-existing tournament row**: the `tier_id`
     backfill sets `tier_id = <Hebdo>` for every tournament that predates this
     RFC, including historical/completed ones. This is harmless (those rows
     have `season_id null` and can never freeze, F55) but it is a real `update`
     against live data — confirmed the same behavior in-container against a
     database carrying v2.0/v3.0 fixtures above.
  3. Run `notify pgrst, 'reload schema';` so PostgREST picks up the four new
     tables and two new views immediately — a `404`/`PGRST205` before this is
     a stale cache, not a passing RLS check.
  4. With the **anon** key (`apikey` + `Authorization: Bearer <anon>`), `GET`
     each of `/rest/v1/profiles`, `/rest/v1/seasons`,
     `/rest/v1/tournament_tiers`, `/rest/v1/tournament_results`,
     `/rest/v1/current_season`, `/rest/v1/season_standings`
     (`?select=*&limit=1`) → the four **tables** return HTTP 200 and an
     **empty array**; the two **views** return **HTTP 401** with
     `{"code":"42501","message":"permission denied for view ..."}`. Both are
     passes. The views differ because `revoke all ... from anon` denies the
     privilege outright, so PostgREST rejects before RLS is ever consulted —
     a strictly stronger result than an empty array, not a failure. *(An
     earlier draft of this note said "empty array for all six"; verified
     against a real PostgREST instance on 2026-08-16 and corrected.)*
  5. With `SUPABASE_SERVICE_KEY`, the same six requests → expect HTTP 200 with
     rows (or `[]` where genuinely empty) — confirms the bot's own read path
     is unaffected.
  6. Run a `/ots` smoke test in the guild after applying, confirming the v3.0
     read path (unchanged by this RFC) still works.
  7. This is the local container's proxy for step 4/5 above — treat it as
     evidence the mechanism works, not as a substitute for actually running it
     against the live PostgREST endpoint.
  8. **`RUNBOOK.md` §1 is now stale and this RFC cannot fix it (that file
     belongs to RFC-014).** §1 documents creating a tournament in Studio's
     Table Editor by filling only `name` and leaving everything else at
     default. As of this schema, `tournaments.tier_id` is `not null` with no
     default, so that procedure will fail with a not-null violation the
     moment this schema is live. **Until RFC-014 rewrites `RUNBOOK.md` §1,
     any organizer creating a new tournament via the Table Editor must
     manually select a `tier_id` (e.g. Hebdo) at insert time**, or the insert
     is rejected. Also tracked in `RFCS.md`'s "Tracked follow-ups" section so
     it surfaces independently of this file.
- **Local Supabase verification (2026-08-16).** Run against a live local
  Supabase stack (real PostgREST + Kong, PG 17.6) whose database already held
  v2.0/v3.0 data *and* real synced Challonge rows — a materially better target
  than a bare container, and the run that caught the seed bug below.
  - **Idempotency:** first apply wrote `INSERT 0 3` (tiers), `UPDATE 2` (the
    `tier_id` backfill hitting exactly the two pre-existing tournaments),
    `INSERT 0 1` (test season), `UPDATE 1` (test-tournament amendment). Second
    and third applies: every write `0`, `tournament_tiers` still 3 rows, zero
    null `tier_id`. Final apply exited 0 under `ON_ERROR_STOP=1`.
  - **F49 matrix, anon key:** `profiles`, `seasons`, `tournament_tiers`,
    `tournament_results` → `200 []`; `current_season`, `season_standings` →
    `401 permission denied for view`. No `404`/`PGRST205` (cache reloaded
    first), so these are genuine results rather than cache artifacts.
  - **F49 matrix, service key:** all six `200`; `seasons` 1 row,
    `tournament_tiers` 3 rows, `current_season` correctly resolving to the
    test season; `profiles`/`tournament_results`/`season_standings` `[]`
    because they are genuinely empty.
  - **Mechanism confirmed at the catalog level, not inferred from behavior:**
    both views carry `reloptions = {security_invoker=on}`; all four new tables
    show `relrowsecurity = t` with **0 policies**; `btree_gist` absent.
  - **`/ots` v3.0 read path re-verified** by replaying the bot's three actual
    queries through PostgREST: active tournament resolves with its
    `challonge_tournament_id`, participant lookup returns the expected id, and
    the `players` read returns `ingame_name`/`pokepaste_url` unchanged.
- **Pre-existing v3.0 seed bug found and fixed during that run (RFC-007
  block, outside RFC-011's nominal scope — fixed with explicit approval
  because it blocked RFC-011's own apply).** The RFC-007 participants seed
  guarded `on conflict (tournament_id, challonge_participant_id) do nothing`,
  but `challonge_participants_cache` carries **three** unique indexes. Against
  any database where a real Challonge sync has run, the placeholder ids
  (1001–1003) collide with synced rows on `lower(ingame_name)` instead — same
  name, different id — which the targeted clause does not catch. Under
  `ON_ERROR_STOP=1` the apply **aborted at that statement before creating a
  single v4.0 object**. A container seeded only from `schema.sql` always holds
  the placeholder ids and therefore never reproduces it, which is why every
  prior container run passed. Fixed by dropping the conflict target
  (`on conflict do nothing`), which catches all three indexes. Re-verified
  both directions: a fresh database still seeds 3 participants / 3 tiers /
  3 players on pass 1 and writes nothing on pass 2, and the previously-failing
  database now applies clean at exit 0.
- **Live verification (2026-08-16) — reported by the operator, closing the
  Tier-2 items.** Production was baselined with `supabase migration repair
  --status applied` against the baseline migration, so the v2.0/v3.0 DDL was
  marked applied without re-running against live data, and this RFC's DDL was
  delivered with `supabase db push`. The operator reports the anon/service-key
  matrix **sane** and `/ots` **intact** in the guild. RFC-011's schema is
  therefore live and its read path unregressed.

  Recorded at the granularity the operator reported it: no per-object HTTP
  codes or row counts were captured from the live run, so this entry claims
  only what was actually observed. The detailed per-object matrix in "Local
  Supabase verification" above remains the reproducible evidence for the
  mechanism; this entry is the confirmation that production agrees.
- **Tracked follow-ups (not RFC-011's scope):** RFC-012 must write
  `tournament_results.ingame_name` already-trimmed if it wants
  `season_standings.ingame_name` to display without whitespace (the view
  deliberately does not `btrim()` it — see §3.7's comment); RFC-013 owns the
  command half of F60/F69 (`/link-organizer`, `/unlink`); RFC-014 owns
  `RUNBOOK.md` §9 (the F48 undeletability trap and F42's same-boundary-day
  gotcha) and the presentation half of F70. **RFC-014 also owes a `RUNBOOK.md`
  §1 rewrite** to require an explicit `tier_id` selection when creating a
  tournament via Studio's Table Editor — see Operator apply note 8 above and
  the matching entry in `RFCS.md`'s "Tracked follow-ups" — since §1 as written
  today will fail a not-null violation on `tier_id` the moment this schema is
  live.
