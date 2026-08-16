-- ============================================================================
-- schema.sql — Supabase (Postgres) data layer for discord-ots-bot v2.0/v3.0
-- ============================================================================
-- RFC-001: tournaments/players tables, DB-enforced invariants (single active
-- tournament, trimmed + case-insensitive unique player names per tournament),
-- read-path indexes, and idempotent seed data.
-- RFC-003: row level security enabled (deny-by-default; the bot's service
-- key bypasses RLS, so no policies are needed) — tracked follow-up from
-- RFC-001 review, see RFCS.md "Tracked follow-ups".
-- RFC-007: Challonge integration data layer — nullable
-- `tournaments.challonge_tournament_id` link, plus `challonge_participants_cache`
-- and `challonge_matches_cache` tables (RLS deny-by-default, same as above).
-- No Python/Edge Function code in this RFC — pure schema, written by and for
-- RFC-008 (writer) and RFC-009 (reader).
-- RFC-011: the v4.0 ranking/identity data layer — `profiles` (cross-tournament
-- identity), `seasons`, `tournament_tiers`, `tournament_results` (frozen
-- placements/points), plus `players.profile_id` and four new `tournaments`
-- columns (`event_date`, `season_id`, `tier_id`, `completed_at`), the
-- forward auto-link trigger (F60 DDL half) and the `current_season` /
-- `season_standings` views (F66, F70 DDL half). This is the project's first
-- NON-DISPOSABLE data (`profiles`, `tournament_results` cannot be
-- re-derived, unlike the Challonge caches above) and its first genuinely
-- personal data (`profiles.discord_user_id`). No Python/Edge Function code
-- in this RFC either — pure schema, consumed by RFC-012/013/014.
--
-- Section 8 (RFC-011) runs in its OWN internal order, not this file's usual
-- tables -> function -> trigger -> indexes -> RLS -> seed order, because
-- `tournaments.tier_id` is a NOT NULL FK added to a table that already has
-- rows: the tier rows must be seeded, and the column backfilled, before it
-- can be constrained. See the header comment on section 8 for the exact order
-- and do not reorder it.
--
-- Section 8 also breaks this file's uniform `on delete cascade` FK pattern:
-- `tournament_results.tournament_id` (and `.season_id`, and
-- `tournaments.tier_id`) use `on delete restrict` on purpose (F48) — frozen
-- history must not be deletable by accident. See the F48 comment in section 8.
--
-- Apply once per environment via the Supabase Studio SQL editor. This script
-- is fully idempotent: re-running it produces no error and no duplicate rows
-- or objects.
--
-- Order: tables -> function -> trigger -> indexes -> RLS -> seed -> (commented)
-- verification block, EXCEPT section 8 (RFC-011), which has its own internal
-- order — see that section's header comment.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. TABLES
-- ----------------------------------------------------------------------------

create table if not exists tournaments (
  id          bigint generated always as identity primary key,
  name        text not null,
  is_active   boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists players (
  id             bigint generated always as identity primary key,
  tournament_id  bigint not null references tournaments(id) on delete cascade,
  ingame_name    text not null,
  team_text      text not null,
  pokepaste_url  text null, -- nullable: a player row may have no pokepast.es link
  created_at     timestamptz not null default now()
);

-- Studio configuration (F5, non-code): in the `players` table editor, order
-- columns as ingame_name, team_text, pokepaste_url first (the fields an
-- organizer fills per player), then tournament_id, then system columns
-- (id, created_at) last. This lets a valid row be entered with just name +
-- team text (+ optional URL). This is a Studio UI setting only; it is not
-- (and cannot be) enforced in DDL.

-- RFC-007 (F26): nullable link from a tournament to a Challonge tournament
-- (id or url slug). NULL means "no Challonge integration for this
-- tournament" — drives RFC-009's hard-fail path (F34).
alter table tournaments
  add column if not exists challonge_tournament_id text null;

-- RFC-007 (F27): locally-readable cache of a Challonge tournament's
-- participants, keyed by Challonge's own participant id. Reuses the exact
-- same trim+lower identity contract as players.ingame_name (RFC-001/RULES
-- §4) via the trim_ingame_name() trigger below. Refreshed by upsert (RFC-008
-- owns the upsert statement), never plain append.
create table if not exists challonge_participants_cache (
  id                        bigint generated always as identity primary key,
  tournament_id             bigint not null references tournaments(id) on delete cascade,
  -- Challonge's stable, top-level participant id (participants.json's `id`).
  -- This is the identity used for the tournament_id+id upsert key below.
  challonge_participant_id  bigint not null,
  -- Nullable: only set for tournaments with Challonge group stages enabled
  -- (participants.json's `group_player_ids[0]`). Group-stage matches key
  -- their player1_id/player2_id off THIS value, not challonge_participant_id
  -- -- a distinct id space that coexists with the top-level id even after
  -- the group stage ends and a final bracket (which uses the top-level id)
  -- is generated. Bot-side opponent resolution must match a candidate match
  -- against EITHER column; storing only one silently breaks resolution for
  -- whichever phase (group vs. final bracket) doesn't use it.
  challonge_group_player_id bigint,
  ingame_name               text not null,
  fetched_at                timestamptz not null default now()
);

-- Idempotent add for environments that created this table before the
-- group_player_ids gap above was discovered and fixed.
alter table challonge_participants_cache
  add column if not exists challonge_group_player_id bigint;

-- RFC-007 (F28): locally-readable cache of a Challonge tournament's matches.
-- `state` mirrors Challonge's own three values verbatim — this is the field
-- RFC-009's "find my current match" query filters on (state = 'open').
-- Nullable player*_challonge_id columns represent a bye or a not-yet-fed-in
-- bracket slot, mirroring how Challonge itself represents them. Refreshed by
-- upsert (RFC-008 owns the upsert statement), never plain append.
create table if not exists challonge_matches_cache (
  id                    bigint generated always as identity primary key,
  tournament_id         bigint not null references tournaments(id) on delete cascade,
  challonge_match_id    bigint not null,
  round                 integer,
  state                 text not null check (state in ('pending', 'open', 'complete')),
  player1_challonge_id  bigint null,
  player2_challonge_id  bigint null,
  winner_challonge_id   bigint null,
  fetched_at            timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- 2. FUNCTION — trim + reject empty ingame_name on write
-- ----------------------------------------------------------------------------

create or replace function trim_ingame_name() returns trigger as $$
begin
  new.ingame_name := btrim(new.ingame_name);
  if new.ingame_name = '' then
    raise exception 'ingame_name must not be empty after trimming';
  end if;
  return new;
end;
$$ language plpgsql;


-- ----------------------------------------------------------------------------
-- 3. TRIGGER
-- ----------------------------------------------------------------------------

drop trigger if exists players_trim_ingame_name on players;
create trigger players_trim_ingame_name
  before insert or update on players
  for each row execute function trim_ingame_name();

-- RFC-007 (F27): reuses trim_ingame_name() verbatim rather than duplicating
-- it — it only inspects NEW.ingame_name, which this table also has.
drop trigger if exists challonge_participants_cache_trim_ingame_name
  on challonge_participants_cache;
create trigger challonge_participants_cache_trim_ingame_name
  before insert or update on challonge_participants_cache
  for each row execute function trim_ingame_name();


-- ----------------------------------------------------------------------------
-- 4. INDEXES
-- ----------------------------------------------------------------------------

-- F3: at most one tournament may be active at a time. A one-step attempt to
-- activate a second tournament raises a unique-violation — this is EXPECTED
-- behavior (documented in RFC-002/RULES §4). Never drop this index to "fix"
-- that error; activation is a two-step switch (deactivate old, then activate
-- new).
create unique index if not exists tournaments_one_active_idx
  on tournaments (is_active)
  where is_active = true;

-- F4/F6: case-insensitive unique player name per tournament. This functional
-- index is on lower(ingame_name); ingame_name is already trimmed by the
-- trigger above, so trimming here would be redundant. It also serves the
-- read-path predicate `lower(p.ingame_name) = lower($1)` (see verification
-- block below).
--
-- CONTRACT (read this before changing either side): the bot (RFC-003/004/005)
-- must apply trim() then lower() to user input before querying, to match this
-- stored normalization exactly. If you change the normalization here, change
-- the bot's lookup too — and vice versa.
--
-- `players.tournament_id` is the leading column of this composite index, so
-- it also serves FK-join / tournament-scoped lookups; no separate
-- single-column index on tournament_id is needed.
create unique index if not exists players_tournament_name_idx
  on players (tournament_id, lower(ingame_name));

-- RFC-007 (F27): unique per (tournament, Challonge participant id) — the key
-- RFC-008's upsert conflicts on — and per (tournament, lower(ingame_name)),
-- mirroring players_tournament_name_idx's contract above.
create unique index if not exists challonge_participants_cache_participant_idx
  on challonge_participants_cache (tournament_id, challonge_participant_id);

create unique index if not exists challonge_participants_cache_name_idx
  on challonge_participants_cache (tournament_id, lower(ingame_name));

-- Serves the bot's "match either id column" opponent-resolution lookups
-- (see challonge_group_player_id's comment above). Partial + unique since
-- it's null for non-group-stage tournaments and, when set, is as unique per
-- tournament as challonge_participant_id itself.
create unique index if not exists challonge_participants_cache_group_player_idx
  on challonge_participants_cache (tournament_id, challonge_group_player_id)
  where challonge_group_player_id is not null;

-- RFC-007 (F28): unique per (tournament, Challonge match id) — the key
-- RFC-008's upsert conflicts on.
create unique index if not exists challonge_matches_cache_match_idx
  on challonge_matches_cache (tournament_id, challonge_match_id);

-- RFC-007 (F28): serves RFC-009's "find my current match" read path — filter
-- to state = 'open' within the tournament, then match a participant id
-- against either side.
create index if not exists challonge_matches_cache_state_idx
  on challonge_matches_cache (tournament_id, state);


-- ----------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY (RFC-003 tracked follow-up — RFCS.md "Tracked
--    follow-ups"; PRD §6 / RULES §6)
-- ----------------------------------------------------------------------------
-- Supabase grants the `anon`/`authenticated` PostgREST roles default SELECT on
-- public-schema tables unless RLS is enabled. The bot never uses `anon` — it
-- authenticates every PostgREST request with the service key (see
-- `fetch_active_player` in bot.py), which BYPASSES RLS entirely. So enabling
-- RLS here with NO policies is a pure deny-by-default posture for any other
-- role: it closes the public anon read hole without affecting the bot's own
-- service-key access path (still reads live via `tournaments`/`players`).
-- Idempotent: `enable row level security` is safe to re-run.
alter table tournaments enable row level security;
alter table players enable row level security;

-- RFC-007 (F29): same deny-by-default posture — the only readers/writers are
-- the bot (service key, RFC-009) and the Edge Function (also service key,
-- RFC-008), both of which bypass RLS entirely.
alter table challonge_participants_cache enable row level security;
alter table challonge_matches_cache enable row level security;


-- ----------------------------------------------------------------------------
-- 6. SEED DATA (F5 — idempotent)
-- ----------------------------------------------------------------------------
-- One active test tournament + 3 sample players reusing entries from the
-- v1 USERNAME_URLS dict (bot.py). team_text is NOT NULL, and v1 stored no
-- team text for these entries, so each seeded player gets a short,
-- clearly-labeled PLACEHOLDER team_text. One player (koloina) is seeded with
-- pokepaste_url = NULL so RFC-005's optional-link path has test data.
--
-- Guarded so a re-run of this script is a no-op: the tournament insert only
-- fires if no tournament with this seed name already exists (this also
-- avoids tripping tournaments_one_active_idx on a second run), and each
-- player insert is guarded against players_tournament_name_idx via
-- `on conflict do nothing`.

insert into tournaments (name, is_active)
select 'RFC-001 Test Tournament', true
where not exists (
  select 1 from tournaments where name = 'RFC-001 Test Tournament'
);

insert into players (tournament_id, ingame_name, team_text, pokepaste_url)
select t.id, seed.ingame_name, seed.team_text, seed.pokepaste_url
from tournaments t
cross join (
  values
    ('giovlacouture', '[SEED PLACEHOLDER] Equipe de test — a remplacer par le vrai team_text.', 'https://pokepast.es/6b0e9bdcbf2c6a73'),
    ('zou',           '[SEED PLACEHOLDER] Equipe de test — a remplacer par le vrai team_text.', 'https://pokepast.es/091b94622a4ef357'),
    ('koloina',       '[SEED PLACEHOLDER] Equipe de test — a remplacer par le vrai team_text.', null)
) as seed(ingame_name, team_text, pokepaste_url)
where t.name = 'RFC-001 Test Tournament'
on conflict (tournament_id, lower(ingame_name)) do nothing;

-- RFC-007 (F29): reuses the existing 'RFC-001 Test Tournament' seed row and
-- its three seeded players so RFC-008/009 have concrete data to build and
-- test against without a live Challonge account. These placeholder Challonge
-- ids and the 'rfc007-test-tournament' slug are test-only fixtures, never
-- real event data.
update tournaments
set challonge_tournament_id = 'rfc007-test-tournament'
where name = 'RFC-001 Test Tournament'
  and challonge_tournament_id is null;

insert into challonge_participants_cache (tournament_id, challonge_participant_id, ingame_name)
select t.id, seed.challonge_participant_id, seed.ingame_name
from tournaments t
cross join (
  values
    (1001, 'giovlacouture'),
    (1002, 'zou'),
    (1003, 'koloina')
) as seed(challonge_participant_id, ingame_name)
where t.name = 'RFC-001 Test Tournament'
-- Untargeted `do nothing` is deliberate and load-bearing: this table carries
-- THREE unique indexes (participant id, lower(ingame_name), and the partial
-- group-player id), so a clause targeting only the participant id misses the
-- other two. Once a real Challonge sync has run, these placeholder ids
-- (1001-1003) collide with the synced rows on lower(ingame_name) instead --
-- same name, different id -- and a targeted clause turns a re-apply of this
-- file into a hard failure. Found applying RFC-011 to a database holding real
-- synced data; a container seeded only from this file never reproduces it.
on conflict do nothing;

-- Fixtures cover, ahead of time, RFC-009's main scenarios: a resolvable
-- current opponent (giovlacouture <-> zou, an 'open' match), a "no current
-- match" case (koloina, fed into the bracket but 'pending' with no
-- opponent), and — for any name not in this seed set at all — the
-- "requester not found in cache" case.
insert into challonge_matches_cache
  (tournament_id, challonge_match_id, round, state, player1_challonge_id, player2_challonge_id, winner_challonge_id)
select t.id, seed.challonge_match_id, seed.round, seed.state,
       seed.player1_challonge_id, seed.player2_challonge_id, seed.winner_challonge_id
from tournaments t
cross join (
  values
    -- giovlacouture vs zou: an open (current) match — RFC-009 happy-path fixture
    (5001, 1, 'open',    1001, 1002, null::bigint),
    -- koloina: fed into the bracket but no opponent yet — RFC-009 bye/no-current-match fixture
    (5002, 1, 'pending', 1003, null::bigint, null::bigint)
) as seed(challonge_match_id, round, state, player1_challonge_id, player2_challonge_id, winner_challonge_id)
where t.name = 'RFC-001 Test Tournament'
on conflict (tournament_id, challonge_match_id) do nothing;


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


-- ----------------------------------------------------------------------------
-- 8.7 SEED DATA (v4.0 — idempotent)
-- ----------------------------------------------------------------------------

-- One wide, clearly-fake test season so RFC-012/013/014 have data before any
-- live season exists.
insert into seasons (name, starts_on, ends_on)
select 'RFC-011 Test Season', '2026-01-01', '2026-12-31'
where not exists (
  select 1 from seasons where name = 'RFC-011 Test Season'
);

-- Amend the existing RFC-001 Test Tournament fixture in place: give it an
-- event_date and the test season (tier_id is already Hebdo from the backfill
-- above). Left with completed_at NULL and no tournament_results rows, so
-- RFC-012 can exercise a genuine first freeze against it.
--
-- WARNING: setting season_id here makes this tournament FREEZABLE, and
-- therefore UNDELETABLE under F48 the moment anything freezes against it.
-- That is deliberate — it is precisely the trap RUNBOOK §9 (RFC-014) has to
-- teach an organizer to avoid on their own real events.
--
-- No profiles seed row: a fake discord_user_id would be the one seed in this
-- file that cannot be exercised against a real Discord account, and it would
-- sit in the personal-data table. Do not "fix" this gap — RFC-013's E2E binds
-- a real account instead.
update tournaments
set event_date = '2026-01-15',
    season_id = (select id from seasons where name = 'RFC-011 Test Season')
where name = 'RFC-001 Test Tournament'
  and season_id is null;


-- ============================================================================
-- 9. VERIFICATION BLOCK (commented) — uncomment individual statements in the
--    Studio SQL editor to self-check the invariants above. Not part of the
--    idempotent apply path.
-- ============================================================================

-- -- F4a: case-only duplicate in the same tournament -> rejected
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, 'GiovLaCouture', 'dup test' from tournaments
-- where name = 'RFC-001 Test Tournament';
-- -- expected: ERROR duplicate key value violates unique constraint
-- -- "players_tournament_name_idx"

-- -- F4b: whitespace-only duplicate in the same tournament -> stored trimmed,
-- -- then rejected as a duplicate
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, '  zou  ', 'dup test' from tournaments
-- where name = 'RFC-001 Test Tournament';
-- -- expected: ERROR duplicate key value violates unique constraint
-- -- "players_tournament_name_idx"

-- -- F4c: same name allowed in a DIFFERENT tournament
-- -- NOTE (RFC-011): tier_id is NOT NULL with no default as of section 8, so
-- -- any new tournament insert below must supply it explicitly.
-- insert into tournaments (name, is_active, tier_id)
-- select 'RFC-001 Second Tournament', false, id from tournament_tiers where lower(name) = 'hebdo';
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, 'zou', 'different tournament, same name' from tournaments
-- where name = 'RFC-001 Second Tournament';
-- -- expected: succeeds

-- -- F4d: empty-after-trim name -> rejected
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, '   ', 'empty name test' from tournaments
-- where name = 'RFC-001 Test Tournament';
-- -- expected: ERROR ingame_name must not be empty after trimming

-- -- F3: attempting to activate a second tournament -> unique-violation (expected)
-- update tournaments set is_active = true where name = 'RFC-001 Second Tournament';
-- -- expected: ERROR duplicate key value violates unique constraint
-- -- "tournaments_one_active_idx"

-- -- F6: confirm the read-path query CAN use players_tournament_name_idx.
-- -- Note: on the tiny seed set below Postgres will pick a Seq Scan by cost —
-- -- that is expected and fine. Force the planner to prove the index is usable:
-- set local enable_seqscan = off;
-- explain
-- select p.ingame_name, p.team_text, p.pokepaste_url
-- from players p
-- join tournaments t on t.id = p.tournament_id
-- where t.is_active = true
--   and lower(p.ingame_name) = lower('giovlacouture');
-- -- expected: plan references players_tournament_name_idx
-- reset enable_seqscan;

-- -- RFC-003: RLS deny-by-default check. Run against PostgREST (not the SQL
-- -- editor, which runs as a superuser role and is unaffected by RLS) with two
-- -- different keys on `GET {SUPABASE_URL}/rest/v1/players?select=id&limit=1`:
-- --   1. Using the anon public key as `apikey`/`Authorization: Bearer <anon>`
-- --      -> expected: HTTP 200 with an EMPTY array (RLS enabled, no policies
-- --      grant anon anything -> deny-by-default; PostgREST does not error,
-- --      it just returns no rows).
-- --   2. Using SUPABASE_SERVICE_KEY (what bot.py's fetch_active_player sends)
-- --      -> expected: HTTP 200 with the seeded rows, unchanged from before
-- --      RLS was enabled -- the service_role key bypasses RLS entirely, so
-- --      the bot's live read path is unaffected by this migration.

-- -- RFC-007 F27a: case/whitespace-duplicate Challonge participant name in the
-- -- same tournament -> rejected, mirroring F4a/F4b above.
-- insert into challonge_participants_cache (tournament_id, challonge_participant_id, ingame_name)
-- select id, 9999, '  GiovLaCouture  ' from tournaments
-- where name = 'RFC-001 Test Tournament';
-- -- expected: ERROR duplicate key value violates unique constraint
-- -- "challonge_participants_cache_name_idx"

-- -- RFC-007 F28: unrecognized `state` value -> rejected by the check constraint.
-- insert into challonge_matches_cache
--   (tournament_id, challonge_match_id, round, state, player1_challonge_id, player2_challonge_id)
-- select id, 9999, 1, 'in_progress', 1001, 1002 from tournaments
-- where name = 'RFC-001 Test Tournament';
-- -- expected: ERROR new row for relation "challonge_matches_cache" violates
-- -- check constraint "challonge_matches_cache_state_check"

-- -- RFC-007 F27/F28: deleting the seeded test tournament cascades away both
-- -- new tables' rows with it (same FK-cascade contract as players).
-- -- RFC-011 AMENDMENT (F48): this DELETE now FAILS once anything has been
-- -- frozen for this tournament (tournament_results.tournament_id is
-- -- `on delete restrict`, not cascade). If you have run the F48/F69/F70
-- -- checks below against this same tournament, purge tournament_results
-- -- first:
-- --   delete from tournament_results where tournament_id = (select id from tournaments where name = 'RFC-001 Test Tournament');
-- --   delete from tournaments where name = 'RFC-001 Test Tournament';
-- delete from tournaments where name = 'RFC-001 Test Tournament';
-- -- expected: succeeds (when no tournament_results row references it); a
-- -- follow-up `select count(*) from challonge_participants_cache` /
-- -- `challonge_matches_cache` for that tournament_id returns 0

-- -- RFC-007: sanity-check the RFC-009 "current opponent" read pattern against
-- -- the seed fixtures -- expected: one row, the zou side of the open match.
-- select m.*
-- from challonge_matches_cache m
-- join challonge_participants_cache p
--   on p.tournament_id = m.tournament_id
--  and p.challonge_participant_id in (m.player1_challonge_id, m.player2_challonge_id)
-- join tournaments t on t.id = m.tournament_id
-- where t.name = 'RFC-001 Test Tournament'
--   and m.state = 'open'
--   and p.challonge_participant_id != (
--     select challonge_participant_id from challonge_participants_cache
--     where tournament_id = m.tournament_id and lower(ingame_name) = lower('giovlacouture')
--   )
--   and (m.player1_challonge_id = (
--          select challonge_participant_id from challonge_participants_cache
--          where tournament_id = m.tournament_id and lower(ingame_name) = lower('giovlacouture')
--        )
--     or m.player2_challonge_id = (
--          select challonge_participant_id from challonge_participants_cache
--          where tournament_id = m.tournament_id and lower(ingame_name) = lower('giovlacouture')
--        ));

-- ----------------------------------------------------------------------------
-- RFC-011 (v4.0 ranking/identity) checks
-- ----------------------------------------------------------------------------

-- -- RFC-011 check 1 — Idempotency: re-apply this ENTIRE file, then run:
-- select count(*) from tournament_tiers;
-- -- expected: 3 (not 6)
-- select count(*) from tournaments where tier_id is null;
-- -- expected: 0
-- select count(*) from seasons where name = 'RFC-011 Test Season';
-- -- expected: 1 (not 2)

-- -- RFC-011 check 2 — F42: same-boundary-day overlap is rejected; adjacent
-- -- (non-overlapping) ranges are accepted. Also confirm no extension was
-- -- installed to support it.
-- insert into seasons (name, starts_on, ends_on) values ('RFC-011 Check Season A', '2027-01-01', '2027-06-30');
-- insert into seasons (name, starts_on, ends_on) values ('RFC-011 Check Season B', '2027-06-30', '2027-12-31');
-- -- expected: ERROR conflicting key value violates exclusion constraint
-- -- "seasons_no_overlap_excl" (both ranges include 2027-06-30)
-- insert into seasons (name, starts_on, ends_on) values ('RFC-011 Check Season C', '2027-07-01', '2027-12-31');
-- -- expected: succeeds (adjacent, non-overlapping)
-- select extname from pg_extension where extname = 'btree_gist';
-- -- expected: 0 rows
-- delete from seasons where name in ('RFC-011 Check Season A', 'RFC-011 Check Season B', 'RFC-011 Check Season C');

-- -- RFC-011 check 3 — F40: one profile cannot hold two roster slots in the
-- -- SAME tournament; it can across two DIFFERENT tournaments.
-- insert into profiles (discord_user_id, display_name) values ('rfc011-check-discord-id', 'RFC-011 Check Profile');
-- insert into tournaments (name, is_active, tier_id)
-- select 'RFC-011 Second Check Tournament', false, id from tournament_tiers where lower(name) = 'hebdo';
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011checkA', 'check', (select id from profiles where discord_user_id = 'rfc011-check-discord-id')
-- from tournaments where name = 'RFC-001 Test Tournament';
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011checkB', 'check', (select id from profiles where discord_user_id = 'rfc011-check-discord-id')
-- from tournaments where name = 'RFC-001 Test Tournament';
-- -- expected: ERROR duplicate key value violates unique constraint
-- -- "players_tournament_profile_idx"
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011checkC', 'check', (select id from profiles where discord_user_id = 'rfc011-check-discord-id')
-- from tournaments where name = 'RFC-011 Second Check Tournament';
-- -- expected: succeeds (different tournament)
-- delete from players where ingame_name in ('rfc011checka', 'rfc011checkb', 'rfc011checkc');
-- delete from tournaments where name = 'RFC-011 Second Check Tournament';
-- delete from profiles where discord_user_id = 'rfc011-check-discord-id';

-- -- RFC-011 check 4 — F48: freezing a result against a tournament makes it
-- -- undeletable. FIXTURE MAKES THE TEST TOURNAMENT UNDELETABLE until purged
-- -- (see the amended RFC-007 cleanup step above).
-- insert into tournament_results
--   (tournament_id, challonge_participant_id, ingame_name, final_rank, awarded_points,
--    season_id, multiplier, formula_version, participant_count)
-- select t.id, 9001, 'rfc011-f48-fixture', 1, 100,
--        (select id from seasons where name = 'RFC-011 Test Season'), 1.0, 'v1', 8
-- from tournaments t where t.name = 'RFC-001 Test Tournament';
-- delete from tournaments where id = (select tournament_id from tournament_results where challonge_participant_id = 9001);
-- -- expected: ERROR update or delete on table "tournaments" violates foreign
-- -- key constraint "tournament_results_tournament_id_fkey" on table
-- -- "tournament_results"
-- -- cleanup (purge the fixture; do NOT try to delete the tournament again here):
-- delete from tournament_results where challonge_participant_id = 9001;

-- -- RFC-011 check 5 — F67: omitting a snapshot column fails at the database,
-- -- never a half-written row.
-- insert into tournament_results
--   (tournament_id, challonge_participant_id, ingame_name, final_rank, awarded_points,
--    season_id, formula_version, participant_count)
-- select t.id, 9002, 'rfc011-f67-fixture', 1, 100,
--        (select id from seasons where name = 'RFC-011 Test Season'), 'v1', 8
-- from tournaments t where t.name = 'RFC-001 Test Tournament';
-- -- expected: ERROR null value in column "multiplier" of relation
-- -- "tournament_results" violates not-null constraint

-- -- RFC-011 check 6 — F60: the four auto-link trigger paths, plus no-re-link
-- -- on UPDATE, plus the untrimmed-name insert. Six scratch tournaments (A-F)
-- -- keep each path's fixtures from tripping players_tournament_name_idx or
-- -- players_tournament_profile_idx on each other.
-- insert into profiles (discord_user_id, display_name) values ('rfc011-f60-p1', 'F60 Profile 1');
-- insert into profiles (discord_user_id, display_name) values ('rfc011-f60-p2', 'F60 Profile 2');
-- insert into tournaments (name, is_active, tier_id)
-- select v.name, false, (select id from tournament_tiers where lower(name) = 'hebdo')
-- from (values
--   ('RFC-011 F60 Tournament A'), ('RFC-011 F60 Tournament B'),
--   ('RFC-011 F60 Tournament C'), ('RFC-011 F60 Tournament D'),
--   ('RFC-011 F60 Tournament E'), ('RFC-011 F60 Tournament F')
-- ) as v(name);
--
-- -- Seed three EXPLICIT links (simulating /link-organizer, RFC-013), which the
-- -- rest of this check reads back through the resolver:
-- --   p1 <- 'rfc011f60clean'  in Tournament A
-- --   p1 <- 'rfc011f60cleanb' in Tournament B  (a second name for the same p1)
-- --   p2 <- 'rfc011f60ambig'  in Tournament B
-- --   p1 <- 'rfc011f60ambig'  in Tournament D  (SAME name as p2's, different
-- --         profile -- this is what makes 'rfc011f60ambig' ambiguous)
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011f60clean', 'check', (select id from profiles where discord_user_id = 'rfc011-f60-p1')
-- from tournaments where name = 'RFC-011 F60 Tournament A';
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011f60cleanb', 'check', (select id from profiles where discord_user_id = 'rfc011-f60-p1')
-- from tournaments where name = 'RFC-011 F60 Tournament B';
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011f60ambig', 'check', (select id from profiles where discord_user_id = 'rfc011-f60-p2')
-- from tournaments where name = 'RFC-011 F60 Tournament B';
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011f60ambig', 'check', (select id from profiles where discord_user_id = 'rfc011-f60-p1')
-- from tournaments where name = 'RFC-011 F60 Tournament D';
--
-- -- path 1: clean link. Tournament C has no p1 slot yet, and 'rfc011f60cleanb'
-- -- resolves to exactly one profile (p1, via B) -- insert with no profile_id given.
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, 'rfc011f60cleanb', 'check' from tournaments where name = 'RFC-011 F60 Tournament C';
-- select profile_id from players where ingame_name = 'rfc011f60cleanb' and tournament_id = (select id from tournaments where name = 'RFC-011 F60 Tournament C');
-- -- expected: the id of profile rfc011-f60-p1 (auto-linked, no WARNING)
--
-- -- path 2: ambiguous name. 'rfc011f60ambig' is bound to p1 (via D) AND p2
-- -- (via B) -- inserting a fresh third row with that name (in Tournament E)
-- -- resolves to two distinct profiles and must fail closed.
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, 'rfc011f60ambig', 'check' from tournaments where name = 'RFC-011 F60 Tournament E';
-- select profile_id from players where ingame_name = 'rfc011f60ambig' and tournament_id = (select id from tournaments where name = 'RFC-011 F60 Tournament E');
-- -- expected: WARNING auto-link: ingame_name rfc011f60ambig matches 2 distinct
-- -- profiles - leaving unlinked; insert still SUCCEEDS, profile_id null
--
-- -- path 3: profile already slotted in that tournament (F40 fail-open).
-- -- Tournament A already holds p1 (via 'rfc011f60clean'); insert a DIFFERENT
-- -- name in Tournament A that also resolves (uniquely, via B) to p1, and
-- -- confirm it stays unlinked with a WARNING, WITHOUT failing the insert or
-- -- tripping players_tournament_profile_idx.
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, 'rfc011f60cleanb', 'check' from tournaments where name = 'RFC-011 F60 Tournament A';
-- select profile_id from players where ingame_name = 'rfc011f60cleanb' and tournament_id = (select id from tournaments where name = 'RFC-011 F60 Tournament A');
-- -- expected: WARNING auto-link: profile <p1 id> already holds a roster slot
-- -- in tournament <A's id> - leaving rfc011f60cleanb unlinked; insert
-- -- SUCCEEDS, profile_id null
--
-- -- path 4: explicit profile_id is never overwritten, even though the trigger
-- -- still runs. Tournament C already holds p1 (from path 1); add p2 explicitly
-- -- under a different name -- no conflict, since it's a different profile.
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011f60explicit', 'check', (select id from profiles where discord_user_id = 'rfc011-f60-p2')
-- from tournaments where name = 'RFC-011 F60 Tournament C';
-- -- expected: profile_id is p2's id (the trigger returns immediately because
-- -- new.profile_id is not null)
--
-- -- no re-link on UPDATE: rename the still-unlinked Tournament E row (path 2)
-- -- to a name that would otherwise resolve cleanly, and confirm it stays null.
-- update players set ingame_name = 'rfc011f60cleanb' where ingame_name = 'rfc011f60ambig' and tournament_id = (select id from tournaments where name = 'RFC-011 F60 Tournament E');
-- select profile_id from players where ingame_name = 'rfc011f60cleanb' and tournament_id = (select id from tournaments where name = 'RFC-011 F60 Tournament E');
-- -- expected: still null (the trigger is `before insert` only, never `or update`)
--
-- -- untrimmed-name insert proves the resolver applies btrim/lower itself,
-- -- ahead of players_trim_ingame_name (trigger name-ordering, R5). Tournament
-- -- F has never held p1, so this is a clean, unambiguous auto-link.
-- insert into players (tournament_id, ingame_name, team_text)
-- select id, '  rfc011f60cleanB  ', 'check' from tournaments where name = 'RFC-011 F60 Tournament F';
-- select ingame_name, profile_id from players where tournament_id = (select id from tournaments where name = 'RFC-011 F60 Tournament F') and lower(btrim(ingame_name)) = 'rfc011f60cleanb';
-- -- expected: auto-links to p1 despite the untrimmed input, and the stored
-- -- ingame_name is trimmed to 'rfc011f60cleanB' by the (later-firing) trim
-- -- trigger
--
-- -- cleanup for check 6:
-- delete from players where tournament_id in (
--   select id from tournaments where name in (
--     'RFC-011 F60 Tournament A', 'RFC-011 F60 Tournament B',
--     'RFC-011 F60 Tournament C', 'RFC-011 F60 Tournament D',
--     'RFC-011 F60 Tournament E', 'RFC-011 F60 Tournament F'
--   )
-- );
-- delete from tournaments where name in (
--   'RFC-011 F60 Tournament A', 'RFC-011 F60 Tournament B',
--   'RFC-011 F60 Tournament C', 'RFC-011 F60 Tournament D',
--   'RFC-011 F60 Tournament E', 'RFC-011 F60 Tournament F'
-- );
-- delete from profiles where discord_user_id in ('rfc011-f60-p1', 'rfc011-f60-p2');

-- -- RFC-011 check 7 — F69: deleting a profile clears both FKs and leaves the
-- -- frozen ingame_name snapshot intact.
-- insert into profiles (discord_user_id, display_name) values ('rfc011-f69-check', 'F69 Check');
-- insert into players (tournament_id, ingame_name, team_text, profile_id)
-- select id, 'rfc011f69check', 'check', (select id from profiles where discord_user_id = 'rfc011-f69-check')
-- from tournaments where name = 'RFC-001 Test Tournament';
-- insert into tournament_results
--   (tournament_id, challonge_participant_id, player_id, profile_id, ingame_name, final_rank, awarded_points,
--    season_id, multiplier, formula_version, participant_count)
-- select t.id, 9003, p.id, p.profile_id, p.ingame_name, 1, 100,
--        (select id from seasons where name = 'RFC-011 Test Season'), 1.0, 'v1', 8
-- from tournaments t join players p on p.tournament_id = t.id and p.ingame_name = 'rfc011f69check'
-- where t.name = 'RFC-001 Test Tournament';
-- delete from profiles where discord_user_id = 'rfc011-f69-check';
-- -- expected: succeeds (no FK violation)
-- select profile_id from players where ingame_name = 'rfc011f69check';
-- -- expected: null
-- select profile_id, ingame_name from tournament_results where challonge_participant_id = 9003;
-- -- expected: profile_id null, ingame_name still 'rfc011f69check' (snapshot survives)
-- -- cleanup:
-- delete from tournament_results where challonge_participant_id = 9003;
-- delete from players where ingame_name = 'rfc011f69check';

-- -- RFC-011 check 8 — F70: hand-computed season_standings fixture. One bound
-- -- player across two events (2 x 100 = 200 points, 2 events, best_rank 1),
-- -- one unbound player across one event (50 points, 1 event, best_rank 2).
-- insert into profiles (discord_user_id, display_name) values ('rfc011-f70-check', 'F70 Check');
-- insert into tournaments (name, is_active, tier_id)
-- select 'RFC-011 F70 Check Tournament', false, id from tournament_tiers where lower(name) = 'hebdo';
-- update tournaments set season_id = (select id from seasons where name = 'RFC-011 Test Season')
-- where name = 'RFC-011 F70 Check Tournament';
-- insert into tournament_results
--   (tournament_id, challonge_participant_id, profile_id, ingame_name, final_rank, awarded_points,
--    season_id, multiplier, formula_version, participant_count)
-- select id, 9101, (select id from profiles where discord_user_id = 'rfc011-f70-check'), 'rfc011f70bound', 1, 100,
--        (select id from seasons where name = 'RFC-011 Test Season'), 1.0, 'v1', 4
-- from tournaments where name = 'RFC-001 Test Tournament';
-- insert into tournament_results
--   (tournament_id, challonge_participant_id, profile_id, ingame_name, final_rank, awarded_points,
--    season_id, multiplier, formula_version, participant_count)
-- select id, 9102, (select id from profiles where discord_user_id = 'rfc011-f70-check'), 'rfc011f70bound', 1, 100,
--        (select id from seasons where name = 'RFC-011 Test Season'), 1.0, 'v1', 4
-- from tournaments where name = 'RFC-011 F70 Check Tournament';
-- insert into tournament_results
--   (tournament_id, challonge_participant_id, ingame_name, final_rank, awarded_points,
--    season_id, multiplier, formula_version, participant_count)
-- select id, 9103, 'rfc011f70unbound', 2, 50,
--        (select id from seasons where name = 'RFC-011 Test Season'), 1.0, 'v1', 4
-- from tournaments where name = 'RFC-011 F70 Check Tournament';
-- select standing_key, total_points, events_played, best_rank from season_standings
-- where standing_key like 'profile:%' or standing_key = 'name:rfc011f70unbound'
-- order by total_points desc;
-- -- expected: bound row -> total_points 200, events_played 2, best_rank 1
-- --           unbound row -> total_points 50, events_played 1, best_rank 2
-- -- cleanup:
-- delete from tournament_results where challonge_participant_id in (9101, 9102, 9103);
-- delete from tournaments where name = 'RFC-011 F70 Check Tournament';
-- delete from profiles where discord_user_id = 'rfc011-f70-check';

-- -- RFC-011 check 9 — F49: MUST be run against PostgREST, not the SQL
-- -- editor (which runs as a superuser role and proves nothing here — same
-- -- caveat as the RFC-003 RLS check above). After applying this file, first
-- -- force PostgREST to see the new tables/views:
-- notify pgrst, 'reload schema';
-- -- A 404/PGRST205 on the checks below is a STALE SCHEMA CACHE, not a passing
-- -- RLS result -- re-run `notify pgrst, 'reload schema';` and retry before
-- -- concluding anything.
-- --
-- -- With the ANON key (apikey + Authorization: Bearer <anon>), GET each of:
-- --   /rest/v1/profiles?select=id&limit=1
-- --   /rest/v1/seasons?select=id&limit=1
-- --   /rest/v1/tournament_tiers?select=id&limit=1
-- --   /rest/v1/tournament_results?select=id&limit=1
-- --   /rest/v1/current_season?select=id&limit=1
-- --   /rest/v1/season_standings?select=season_id&limit=1
-- -- expected: HTTP 200, EMPTY array, for all six (RLS deny-by-default on the
-- -- four tables; security_invoker + explicit revoke on the two views).
-- --
-- -- With SUPABASE_SERVICE_KEY, the same six requests -> HTTP 200 with rows
-- -- (or [] where genuinely empty) -- confirms the bot's/Edge Function's own
-- -- read path is unaffected.
