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
--
-- Apply once per environment via the Supabase Studio SQL editor. This script
-- is fully idempotent: re-running it produces no error and no duplicate rows
-- or objects.
--
-- Order: tables -> function -> trigger -> indexes -> RLS -> seed -> (commented)
-- verification block.
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
  id                       bigint generated always as identity primary key,
  tournament_id            bigint not null references tournaments(id) on delete cascade,
  challonge_participant_id bigint not null,
  ingame_name              text not null,
  fetched_at               timestamptz not null default now()
);

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
on conflict (tournament_id, challonge_participant_id) do nothing;

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
-- 7. VERIFICATION BLOCK (commented) — uncomment individual statements in the
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
-- insert into tournaments (name, is_active) values ('RFC-001 Second Tournament', false);
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
-- delete from tournaments where name = 'RFC-001 Test Tournament';
-- -- expected: succeeds; a follow-up
-- -- `select count(*) from challonge_participants_cache` /
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
