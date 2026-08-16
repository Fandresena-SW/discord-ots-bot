-- ============================================================================
-- SEED DATA — test fixtures only (F5, F29, RFC-011)
-- ============================================================================
-- Applied by `supabase db reset` on LOCAL/dev environments. NEVER pushed to
-- production: `supabase db push` ships migrations only, not this file.
--
-- Why this is a separate file. These fixtures used to live inside the root
-- `schema.sql`, interleaved with DDL, so every hand-apply against production
-- re-ran them against a database whose data had drifted since they were
-- written. On 2026-08-16 that produced a real failure: the RFC-007 participant
-- seed's placeholder ids (1001-1003) collided on `lower(ingame_name)` with
-- rows from a real Challonge sync, and under `ON_ERROR_STOP=1` the apply
-- aborted before creating a single v4.0 object. Reference data (the tiers)
-- stays in its migration; test data lives here and never reaches production.
--
-- Everything below is still idempotent, so re-running is safe.
-- ============================================================================


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

-- `tier_id` is supplied explicitly because it is NOT NULL with no default
-- (F45). Under the retired monolithic schema.sql this insert ran *before* the
-- v4.0 block added that column, so it could omit it; with migrations, all DDL
-- lands before any seed does, and omitting it fails. This is the same trap
-- that makes RUNBOOK §1's "fill only `name`" procedure stale — RFC-014 owns
-- that fix.
insert into tournaments (name, is_active, tier_id)
select 'RFC-001 Test Tournament', true,
       (select id from tournament_tiers where lower(name) = 'hebdo')
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
