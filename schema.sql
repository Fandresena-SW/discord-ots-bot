-- ============================================================================
-- schema.sql — Supabase (Postgres) data layer for discord-ots-bot v2.0
-- ============================================================================
-- RFC-001: tournaments/players tables, DB-enforced invariants (single active
-- tournament, trimmed + case-insensitive unique player names per tournament),
-- read-path indexes, and idempotent seed data.
--
-- Apply once per environment via the Supabase Studio SQL editor. This script
-- is fully idempotent: re-running it produces no error and no duplicate rows
-- or objects.
--
-- Order: tables -> function -> trigger -> indexes -> seed -> (commented)
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


-- ----------------------------------------------------------------------------
-- 5. SEED DATA (F5 — idempotent)
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


-- ============================================================================
-- 6. VERIFICATION BLOCK (commented) — uncomment individual statements in the
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
