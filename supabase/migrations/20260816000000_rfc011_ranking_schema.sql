-- ============================================================================
-- RFC-011 — Ranking Schema: Profiles, Seasons, Tiers & Frozen Results (v4.0)
-- ============================================================================
-- The first migration actually PUSHED to production through the migration
-- tooling rather than pasted into the Studio SQL editor.
--
-- Contents: four tables (profiles, seasons, tournament_tiers,
-- tournament_results), five columns on the existing tournaments/players
-- tables, the F60 auto-link trigger, two security_invoker views, and RLS
-- across all of it. See knowledge/RFCs/RFC-011-Ranking-Schema.md.
--
-- `tournament_tiers`' three rows (Hebdo / Mensuel / Majeur) are seeded HERE,
-- not in `supabase/seed.sql`: they are reference data, not test data. The
-- not-null `tournaments.tier_id` backfill below depends on them existing, so
-- they must land in the same transaction as the DDL that requires them.
-- The v4.0 TEST fixtures (the test season, the test-tournament amendment) are
-- in `supabase/seed.sql` instead.
--
-- Every statement is individually idempotent, matching the baseline's posture.
-- ============================================================================


-- ============================================================================
-- 8. v4.0 — RANKING & IDENTITY (RFC-011)
-- ============================================================================
-- DOCUMENTED ORDERING EXCEPTION — do not reorder, the backfill will fail:
--
--   tables (profiles, seasons, tournament_tiers)
--     -> tier seed
--     -> tournaments columns + players.profile_id + tier backfill + set not null
--     -> tournament_results
--     -> functions + trigger (auto-link)
--     -> indexes + constraints
--     -> views
--     -> RLS + grants
--     -> v4.0 seed (test season + test-tournament amendment)
--     -> (amendments to the section 9 verification block, below)
--
-- Reason: `tournaments.tier_id` is a NOT NULL FK added to a table that
-- already has rows, so the tier rows must exist before the backfill that
-- precedes `set not null`. This file's usual tables -> function -> trigger ->
-- indexes -> RLS -> seed order cannot express that dependency.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 8.1 IDENTITY (F38, F39, F40, F69 DDL half)
-- ----------------------------------------------------------------------------

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

create table if not exists seasons (
  id         bigint generated always as identity primary key,
  name       text not null,
  starts_on  date not null,
  ends_on    date not null,
  created_at timestamptz not null default now(),
  constraint seasons_bounds_ck check (ends_on >= starts_on)
);

create table if not exists tournament_tiers (
  id         bigint generated always as identity primary key,
  name       text not null,
  multiplier numeric(4,2) not null check (multiplier > 0)
);

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
-- no-op, so this stays idempotent. This is the one write this RFC makes to
-- pre-existing production rows: every tournament that predates this RFC gets
-- tier_id = Hebdo. Harmless (those rows have season_id null and can never
-- freeze, F55) but real — stated here for the operator applying this by hand.
update tournaments
set tier_id = (select id from tournament_tiers where lower(name) = 'hebdo')
where tier_id is null;

alter table tournaments alter column tier_id set not null;

-- tier_id uses `on delete restrict`: a tier that priced a real event must not
-- be deletable out from under it. Repricing is safe — F67 snapshots the
-- resolved multiplier, so it never restates history.


-- ----------------------------------------------------------------------------
-- 8.2 FROZEN RESULTS (F47, F48, F67, F50)
-- ----------------------------------------------------------------------------

create table if not exists tournament_results (
  id                       bigint generated always as identity primary key,

  -- F48: `on delete restrict`, NOT `on delete cascade`. THIS BREAKS THE
  -- UNIFORM CASCADE PATTERN USED BY EVERY OTHER FK IN THIS FILE, ON PURPOSE.
  -- Frozen results are the one place in this system where data loss is
  -- unacceptable: a roster typo is recoverable, a deleted season of standings
  -- is not. A future reader WILL assume this cascades — it does not.
  -- Operational consequence: the "delete the test tournament" cleanup in the
  -- section 9 (formerly 7) verification block below stops working once
  -- anything is frozen. Test tournaments must either never be frozen
  -- (season_id is null is the guard, enforced by F55) or get an explicit
  -- results-purge step first. See RUNBOOK.md §9 (RFC-014).
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
  -- Also carries `on delete restrict` (next to F48 above): the same "frozen
  -- history must not be deletable by accident" reasoning applies to a
  -- season, not just a tournament.
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

-- awarded_points is numeric, not integer, because a future tier multiplier
-- need not be a whole number (2.5 x 15 = 37.5). The three seeded tiers all
-- yield integers today.
--
-- tournament_results.ingame_name deliberately does NOT get the
-- trim_ingame_name() trigger. It is a historical snapshot written by the Edge
-- Function from Challonge's own participant name, not an identity key —
-- trimming it on write would be harmless, but adding a third table to that
-- trigger's dependency set for no read-path benefit is not. Its indexes
-- apply lower(...) at read time and RFC-013's backfill normalizes on the bot
-- side.


-- ----------------------------------------------------------------------------
-- 8.3 AUTO-LINK FORWARD (F60 — DDL half)
-- ----------------------------------------------------------------------------
-- F60's forward auto-link MUST be a database trigger. Roster rows are created
-- by the organizer in Supabase Studio, where no bot code runs — there is no
-- other place to hook it, and this project already prefers DB-enforced
-- invariants (single-active, name uniqueness) over application code.

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

-- Trigger firing order. Postgres fires same-event triggers in name order, so
-- players_autolink_profile runs BEFORE players_trim_ingame_name. That is why
-- resolve_profile_for_ingame_name() applies btrim/lower itself rather than
-- relying on the trim trigger having run. Do not rename either trigger into
-- a different relative order without re-checking this.
--
-- `before insert` only, NOT `before insert or update`. A rename of an
-- existing roster row must not silently re-point it at a different person's
-- profile — that is exactly the "silently moves team-sheet access" hazard
-- F60's logging requirement exists for. Re-pointing is /link-organizer's job.
drop trigger if exists players_autolink_profile on players;
create trigger players_autolink_profile
  before insert on players
  for each row execute function autolink_player_profile();


-- ----------------------------------------------------------------------------
-- 8.4 CONSTRAINTS — F42's exclusion constraint (no `if not exists` form)
-- ----------------------------------------------------------------------------
-- F42's exclusion constraint has no `if not exists` form, so it is guarded on
-- pg_constraint to keep the file idempotent.
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

create unique index if not exists tournament_tiers_name_idx
  on tournament_tiers (lower(name));


-- ----------------------------------------------------------------------------
-- 8.5 VIEWS (F66, F70 DDL half)
-- ----------------------------------------------------------------------------

-- F66 — "current season" as a single query, evaluated server-side so that
-- *today* is read in the database's timezone (UTC on Supabase), not by
-- whichever client happens to ask. Zero or one row; zero is a normal state,
-- not an error — covering both of F66's states (today falls in no season,
-- and a season with no results yet). F42 guarantees at most one row, but
-- this view must not ASSUME F42 has been applied (F42 is P1), so it is
-- written to tolerate more than one candidate row without erroring.
-- Note: current_date is evaluated in the DATABASE's session timezone (UTC on
-- Supabase's default), not the caller's.
create or replace view current_season with (security_invoker = on) as
  select id, name, starts_on, ends_on
  from seasons
  where current_date between starts_on and ends_on;

-- F70 (DDL half): one row per ranked competitor per season. Ordering, rank
-- numbering, the top-25 cap, mentions and the 4096-char budget are RFC-014's;
-- this view supplies only what the database can compute correctly (grouping,
-- sums, tie-break keys).
--
-- ingame_name resolves to the ingame_name of the MOST RECENTLY FROZEN row for
-- that standing_key (array_agg ordered by frozen_at desc), so a player who
-- changes their tag mid-season appears under the current one. Per §3.5's
-- comment above, tournament_results.ingame_name is deliberately un-trimmed —
-- grouping is still safe (standing_key normalizes with lower(btrim(...))),
-- but the DISPLAYED spelling here can carry whitespace if the freeze writer
-- (RFC-012) stores it that way. Do not add btrim() to this view's output —
-- that is RFC-012's write-side concern, not this view's.
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


-- ----------------------------------------------------------------------------
-- 8.6 ROW LEVEL SECURITY + GRANTS (F49)
-- ----------------------------------------------------------------------------
-- Same deny-by-default posture as every other table: no policies, because the
-- only readers/writers are the bot and the Edge Function, both on service
-- keys that bypass RLS entirely.
alter table profiles           enable row level security;
alter table seasons            enable row level security;
alter table tournament_tiers   enable row level security;
alter table tournament_results enable row level security;

-- Views need the extra step. A view is not covered by its base tables' RLS
-- unless it is a security-invoker view, so both views above declare
-- `with (security_invoker = on)` AND revoke the PostgREST roles explicitly
-- here. Without security_invoker, a view owned by a superuser would happily
-- serve `anon` the very rows RLS denies on the base tables — reopening the
-- hole RFC-003 closed. This is the single easiest mistake to make in this
-- RFC. Both halves are required: the revoke alone would not survive a future
-- re-grant, and security_invoker alone leaves the view *readable* (but empty)
-- to anon.
--
-- NOTE for anyone applying this against a bare/local Postgres (not Supabase):
-- this statement errors with "role does not exist" unless the anon/
-- authenticated roles have been created first. On Supabase both roles always
-- exist by default, which is this statement's only real target — a local
-- container harness must create them itself (see the verification block's
-- F49 check below), never by adding a guard here.
revoke all on current_season, season_standings from anon, authenticated;
