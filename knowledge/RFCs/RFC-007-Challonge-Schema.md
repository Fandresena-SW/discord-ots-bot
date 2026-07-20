# RFC-007 — Challonge Schema & Cache Tables

- **Status:** 📝 Drafted (not yet implemented) — see [§ Documentation gap](#documentation-gap)
- **Implementation order:** 7 of 10 (v3.0) — first RFC of the Challonge
  integration series; depends on **all** of v2.0 (RFC-001–006) being complete
- **Complexity:** Low–Medium
- **Features covered:** F26, F27, F28, F29
- **Grounding:** `knowledge/FEATURES.md` §"v3.0 — Challonge Integration"; the
  chat-based PRD-change analysis dated 2026-07-20 (no formal `PRD.md` v3.0
  section exists yet — see below)
- **Builds upon:** RFC-001 (schema conventions, `trim_ingame_name()` trigger
  function, RLS pattern), RFC-003 (RLS deny-by-default precedent)
- **Built upon by:** RFC-008 (Edge Function writes into these tables), RFC-009
  (`/ots` reads from these tables)

---

## Documentation gap

Unlike v2.0, there is no formal `knowledge/PRD.md` v3.0 section yet — v3.0's
goals and locked decisions currently live only in `knowledge/FEATURES.md`
§"v3.0 — Challonge Integration" (added alongside this RFC) and the chat history
that produced them. This is an acknowledged gap, not an oversight: a lightweight
PRD v3.0 addendum should be written before RFC-010 (release), consolidating the
goals/scope/decisions the way `PRD.md` did for v2.0. Not blocking for RFC-007,
since FEATURES.md's addendum fully specifies this RFC's scope.

## 1. Summary

Establish the **data layer** for the Challonge integration: a nullable link from
a Supabase `tournaments` row to a Challonge tournament, and two cache tables
that hold a locally-readable copy of that Challonge tournament's participants
and matches. This RFC produces **no Python changes** and **no Edge Function
code** — like RFC-001, its deliverable is an idempotent addition to
`schema.sql`, applied once via the Studio SQL editor.

The cache tables exist so that `bot.py` (RFC-009) never has to call the
Challonge API directly — it only ever reads Supabase via the existing
PostgREST pattern, preserving the v2.0 locked decision that the bot has zero
new runtime dependencies (PRD §11.5, RULES §1). All Challonge I/O happens in
RFC-008's Edge Function, which writes into the tables this RFC creates.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F26** | `tournaments.challonge_tournament_id` — nullable text column linking a tournament to a Challonge tournament (id or url slug). `NULL` means "no Challonge integration for this tournament" (drives RFC-009's hard-fail path, F34). |
| **F27** | `challonge_participants_cache` table: Challonge participant id → normalized `ingame_name`, per tournament. |
| **F28** | `challonge_matches_cache` table: Challonge match rows (`state`, `round`, both sides' participant ids, winner), per tournament. |
| **F29** | RLS (deny-by-default, no policies) on both new tables; idempotent seed/test fixtures so RFC-008/009 can be built and tested without a live Challonge account. |

## 3. Technical approach

### 3.1 `tournaments.challonge_tournament_id` (F26)

```sql
alter table tournaments
  add column if not exists challonge_tournament_id text null;
```

Nullable, no default. Existing v2.0 tournament rows are valid and unaffected —
they simply have no Challonge integration. Whether a tournament *should* have
one is an organizer decision made once, when they set up the Challonge bracket
alongside the Supabase roster (documented in RFC-010's runbook update).

### 3.2 `challonge_participants_cache` (F27)

```sql
create table if not exists challonge_participants_cache (
  id                       bigint generated always as identity primary key,
  tournament_id            bigint not null references tournaments(id) on delete cascade,
  challonge_participant_id bigint not null,
  ingame_name              text not null,
  fetched_at               timestamptz not null default now()
);
```

This table reuses the **exact same identity contract** as `players.ingame_name`
(RFC-001/RULES §4): trimmed on write, case-insensitive-unique per tournament.
Rather than duplicating the trigger, it **reuses RFC-001's
`trim_ingame_name()` function** — it only inspects `NEW.ingame_name`, which
this table also has:

```sql
drop trigger if exists challonge_participants_cache_trim_ingame_name
  on challonge_participants_cache;
create trigger challonge_participants_cache_trim_ingame_name
  before insert or update on challonge_participants_cache
  for each row execute function trim_ingame_name();

create unique index if not exists challonge_participants_cache_participant_idx
  on challonge_participants_cache (tournament_id, challonge_participant_id);

create unique index if not exists challonge_participants_cache_name_idx
  on challonge_participants_cache (tournament_id, lower(ingame_name));
```

**Contract for RFC-008 (the writer):** this table is refreshed by **upsert**,
not append — `on conflict (tournament_id, challonge_participant_id) do update`
— so a re-trigger reflects Challonge's current participant list without
accumulating duplicate/stale rows. RFC-008 owns the exact upsert statement;
RFC-007 only guarantees the unique keys that make it possible.

### 3.3 `challonge_matches_cache` (F28)

```sql
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

create unique index if not exists challonge_matches_cache_match_idx
  on challonge_matches_cache (tournament_id, challonge_match_id);

-- serves RFC-009's "find my current match" read path: filter to state='open'
-- within the tournament, then match a participant id against either side.
create index if not exists challonge_matches_cache_state_idx
  on challonge_matches_cache (tournament_id, state);
```

`state` mirrors Challonge's own three values verbatim (`pending` / `open` /
`complete`) — this is the field RFC-009's opponent-resolution query filters on
(`state = 'open'`), which is exactly why Challonge was chosen over the
`bracket` alternative (its match model has no equivalent signal). The `check`
constraint is deliberately strict: an unrecognized `state` value (e.g. from a
future Challonge API change) makes the Edge Function's upsert fail loudly
rather than silently storing a value nothing downstream understands — RFC-008
must handle that failure (log + alert-style behavior), not RFC-007.

Nullable `player1_challonge_id`/`player2_challonge_id` represent a bye or a
not-yet-fed-in bracket slot — mirroring how Challonge itself represents them
(a match can exist with one side unset). `winner_challonge_id` is null until
`state = 'complete'`.

**Contract for RFC-008:** same as §3.2 — upsert on
`(tournament_id, challonge_match_id)`, so a re-trigger reflects updated match
states (e.g. `pending` → `open` → `complete`) without duplicate rows.

### 3.4 Row Level Security (F29)

```sql
alter table challonge_participants_cache enable row level security;
alter table challonge_matches_cache enable row level security;
```

Same deny-by-default posture as `tournaments`/`players` (RFC-003's tracked
follow-up, `schema.sql` §5): no policies, because the only readers/writers are
the bot (service key, RFC-009) and the Edge Function (also service key,
RFC-008) — both bypass RLS entirely. This closes the public-anon-read hole for
the new tables the same way it does for the existing two.

### 3.5 Seed / test fixtures (F29)

Idempotent, guarded the same way as RFC-001's seed block — reuses the existing
`RFC-001 Test Tournament` row and its three seeded players so RFC-008/009 have
concrete data to build and test against without a live Challonge account:

```sql
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

insert into challonge_matches_cache
  (tournament_id, challonge_match_id, round, state, player1_challonge_id, player2_challonge_id, winner_challonge_id)
select t.id, seed.challonge_match_id, seed.round, seed.state,
       seed.player1_challonge_id, seed.player2_challonge_id, seed.winner_challonge_id
from tournaments t
cross join (
  values
    -- giovlacouture vs zou: an open (current) match — RFC-009 happy-path fixture
    (5001, 1, 'open',    1001, 1002, null),
    -- koloina: fed into the bracket but no opponent yet — RFC-009 bye/no-current-match fixture
    (5002, 1, 'pending', 1003, null, null)
) as seed(challonge_match_id, round, state, player1_challonge_id, player2_challonge_id, winner_challonge_id)
where t.name = 'RFC-001 Test Tournament'
on conflict (tournament_id, challonge_match_id) do nothing;
```

These three fixtures cover, ahead of time, the main scenarios RFC-009 will
need: a resolvable current opponent (giovlacouture ↔ zou), a "no current
match" case (koloina), and — for any name not in this seed set at all — the
"requester not found in cache" case.

## 4. Data models / schema changes

Adds `tournaments.challonge_tournament_id`; creates
`challonge_participants_cache`, `challonge_matches_cache`; reuses
`trim_ingame_name()` (defined in RFC-001) via a new trigger on
`challonge_participants_cache`; adds four new indexes and RLS on both new
tables. No existing objects modified beyond the one new nullable column.

## 5. Interfaces exposed

- **The DB contract** consumed by RFC-008 (writer) and RFC-009 (reader): "for a
  tournament with a non-null `challonge_tournament_id`, the current opponent of
  participant P is the other side of the row in `challonge_matches_cache` where
  `state = 'open'` and P's `challonge_participant_id` appears on either side;
  resolve P's id via `challonge_participants_cache` on
  `lower(trim(ingame_name))`." RFC-009 owns the exact PostgREST query shape;
  RFC-007 only guarantees the tables/indexes/constraints that make it correct.
- **Upsert contract** (§3.2/3.3): both cache tables are refreshed via
  `on conflict ... do update`, never plain append. RFC-008 must honor this or
  the tables will accumulate stale/duplicate rows across refreshes.

## 6. Acceptance criteria

- [ ] **F26:** `tournaments.challonge_tournament_id` exists, nullable, no
      default; existing v2.0 rows remain valid with it `NULL`.
- [ ] **F27:** Unique per `(tournament_id, challonge_participant_id)` and per
      `(tournament_id, lower(ingame_name))`; FK cascades on tournament delete;
      the reused trim trigger rejects an empty-after-trim name exactly as it
      does on `players`.
- [ ] **F28:** Unique per `(tournament_id, challonge_match_id)`; FK cascades on
      tournament delete; `state` rejects any value outside
      `pending`/`open`/`complete`; nullable participant-id columns accept
      `NULL` (bye/unfed slot).
- [ ] **F29:** RLS enabled on both new tables with no policies; `schema.sql`
      remains fully idempotent (re-running produces no error, no duplicate
      rows/objects); the three seed fixtures (open match, pending/no-opponent,
      and an absent name) are present and demonstrate all three RFC-009
      read-path scenarios.

## 7. Implementation details

- **File:** extend the existing `schema.sql` at repo root — do not create a
  second SQL file. Append in the same order RFC-001 established: tables →
  (reused) function/new trigger → indexes → RLS → seed → (commented)
  verification block, for the new objects.
- **Idempotency:** `add column if not exists`, `create table if not exists`,
  `create unique/regular index if not exists`, `drop trigger if exists` +
  `create trigger`, guarded `insert ... on conflict do nothing` /
  `update ... where ... is null` for seed data — same idioms as RFC-001.
- **No Python touched**, **no Edge Function code** in this RFC.

## 8. Edge cases & risks

- **Shared trigger function coupling:** `challonge_participants_cache` and
  `players` now both depend on `trim_ingame_name()`. This is intentional reuse
  (identical semantics — trim + reject-empty on a column literally named
  `ingame_name`), but it means a future rename of either table's `ingame_name`
  column must account for the other's dependency on the same function.
- **Name-sync fragility is inherited, not solved here:** this schema enforces
  that *within Supabase*, a cached Challonge name and a `players.ingame_name`
  match via the same trim+lower contract — it cannot enforce that the
  organizer actually kept the underlying names identical between Challonge and
  Supabase. A mismatch surfaces downstream as RFC-009's "opponent found in
  Challonge but no matching OTS row" fail-soft branch (F33), not as a schema
  violation here.
- **Unrecognized Challonge `state` values:** the `check` constraint will reject
  an upsert if Challonge ever introduces a new state value. This is
  deliberate (fail loud, not silently store an unknown value) — RFC-008 must
  design its error handling around this possibility.
- **Seed fixtures are test-only:** the placeholder Challonge ids (`1001`–`1003`,
  `5001`–`5002`) and `challonge_tournament_id = 'rfc007-test-tournament'` are
  tied to the existing `RFC-001 Test Tournament` seed row specifically — they
  are not, and must never be mistaken for, real event data.

## 9. Applicable rules (RULES.md)

- **§1 (dependency policy):** N/A for this RFC — pure SQL, no new Python
  dependency introduced.
- **§2 (architecture, "no new folders/packages"):** respected by this RFC (stays
  inside `schema.sql`). **Flag for RFC-008:** the Edge Function will need a new
  `supabase/functions/` directory — a deliberate, documented exception to this
  rule, not a silent violation. RULES.md itself should get a v3.0 addendum
  when RFC-008 lands, noting the exception explicitly.
- **§3 (naming):** new identifiers (`challonge_tournament_id`,
  `challonge_participants_cache`, `challonge_matches_cache`, etc.) are English,
  `snake_case`, and descriptive — consistent with existing `tournaments`/`players`
  naming.
- **§4 (DB contract):** extends the existing trim+lower normalization contract
  to a new table via the same trigger function, rather than inventing a second
  normalization scheme.
- **§9 (Won't-have list):** v2.0's F25(e) ("real-time pairings... deferred") is
  explicitly being picked up starting with this RFC. **Flag for RFC-009:**
  RULES.md's Won't-have summary (§9) should be updated to move F25(e) out of
  "do not build" once RFC-009 ships, so the rules file doesn't contradict what
  the bot actually does.
- **§10 (ask before touching locked decisions):** this RFC does not modify any
  v2.0 locked decision — it is purely additive (a new nullable column, two new
  tables). No confirmation needed beyond the RFC review itself.

## 10. Testing strategy

DB-level manual verification in the Studio SQL editor, mirroring RFC-001's
approach — no Python tests in this RFC (there is no Python code). Keep
verification SQL as commented examples in `schema.sql`:

- Re-run the full script twice; confirm no error and no duplicate rows/objects
  (idempotency).
- Insert a case/whitespace-duplicate `ingame_name` into
  `challonge_participants_cache` for the same tournament; confirm rejection,
  mirroring RFC-001's F4 verification.
- Insert a `state` value outside the three allowed; confirm the `check`
  constraint rejects it.
- Delete the seeded test tournament; confirm both new tables' rows cascade
  away with it.
- Sanity-check the RFC-009 read pattern directly against the seed fixtures,
  e.g.:
  ```sql
  -- expected: one row, the zou side of the open match
  select m.*
  from challonge_matches_cache m
  join challonge_participants_cache p
    on p.tournament_id = m.tournament_id
   and p.challonge_participant_id in (m.player1_challonge_id, m.player2_challonge_id)
  join tournaments t on t.id = m.tournament_id
  where t.name = 'RFC-001 Test Tournament'
    and m.state = 'open'
    and p.challonge_participant_id != (
      select challonge_participant_id from challonge_participants_cache
      where tournament_id = m.tournament_id and lower(ingame_name) = lower('giovlacouture')
    )
    and (m.player1_challonge_id = (
           select challonge_participant_id from challonge_participants_cache
           where tournament_id = m.tournament_id and lower(ingame_name) = lower('giovlacouture')
         )
      or m.player2_challonge_id = (
           select challonge_participant_id from challonge_participants_cache
           where tournament_id = m.tournament_id and lower(ingame_name) = lower('giovlacouture')
         ));
  ```
