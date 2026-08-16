-- ============================================================================
-- BASELINE — v2.0 + v3.0 schema (RFC-001, RFC-003, RFC-007)
-- ============================================================================
-- This migration is the migration-era BASELINE: it reproduces the schema that
-- v2.0 and v3.0 built up in the retired root-level `schema.sql`, which was
-- hand-applied through the Studio SQL editor.
--
-- On an environment that already ran the old `schema.sql` (i.e. production),
-- this migration is marked applied WITHOUT executing, via:
--     supabase migration repair --status applied 20260731000000
-- On a fresh environment (a new local stack, CI) it executes normally and
-- produces the same schema.
--
-- Every statement is still individually idempotent. That is deliberate: it is
-- what makes the `migration repair` baseline safe, and it costs nothing.
--
-- Test fixtures that used to live in this file's "6. SEED DATA" section have
-- moved to `supabase/seed.sql` — migrations carry schema and reference data,
-- never test data. Mixing the two is what produced the RFC-007 seed bug found
-- on 2026-08-16 (see the RFC-011 Completion record).
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


