# PRD v4.0 — Ranking System (seasons, results, ranking points)

**Status:** 📝 **Draft for discussion — nothing locked, nothing approved.**
This document exists to be argued with. It records the outcome of a
feature-exploration conversation (2026-07-31) so the decisions taken there are
visible and challengeable before any RFC is drafted.

**Relationship to `PRD.md`:** this is a standalone successor document, not an
addendum edited into `PRD.md`. Section numbering continues from `PRD.md`'s §26,
feature IDs from `FEATURES.md`'s F37, goals from G10, journeys from Journey H,
and RFCs from RFC-010 — so cross-references between the two files stay
unambiguous. `PRD.md` remains the record of v2.0 (§1–§13) and v3.0 (§14–§26).

**Prerequisite: met.** v3.0's release gate (`knowledge/E2E-CHECKLIST-v3.md`, 9
scenarios) passed 9/9 live and was signed off 2026-07-31, so the Challonge sync
pipeline v4.0 builds on is proven in real event conditions.

---

## 27. Overview (v4.0)

v2.0 made the roster live. v3.0 made pairings live. Both are **within-event**
features: everything the bot knows is scoped to the one tournament where
`is_active = true`, and the moment a tournament ends its data stops meaning
anything.

v4.0 adds the **across-event** dimension: a persistent ranking that accumulates
results over a season, so players have a reason to come back and organizers
have a standings table they don't maintain by hand.

The product surface is two views of the same underlying record:

- **Per user** — "show me everything *this player* has done this season": each
  tournament they entered, the team they brought, where they placed, and the
  points it earned them.
- **Per tournament** — "show me everyone who played *this event*": the same
  columns read along the other axis.

**The central change this release makes** is not the ranking maths — it's the
introduction of a **persistent player identity**. Today a "player" is a row
scoped to one tournament, joined to nothing. v4.0 introduces a person who
exists independently of any event and whose results accumulate. Every other
piece of this PRD follows from that, and it is the one decision worth the most
scrutiny before building.

**What v4.0 deliberately does not touch:** `/ots` keeps v3.0's meaning and
behavior exactly. This release is additive.

## 28. Goals and Objectives (v4.0)

| # | Goal | Measure |
|---|------|---------|
| G11 | A player's results persist and accumulate across tournaments | A player who entered 3 events this season sees all 3, with teams, placements, and points, in one command |
| G12 | Standings require no manual bookkeeping | Organizer effort per event is unchanged from v3.0's Journey F — placement and points are derived from Challonge, not typed |
| G13 | Ranking history is tamper-evident and durable | A frozen result cannot be silently changed or deleted; correcting one is an explicit, logged action |
| G14 | Identity is accurate, not guessed | Points attach to a Discord account the player themselves claimed — never to a string match that could be two different people |
| G15 | Zero regression to `/ots` | v3.0's opponent-resolution path is untouched; its E2E checklist still passes verbatim after v4.0 ships |

## 29. Scope (v4.0)

### In scope

- A persistent `profiles` identity keyed by **Discord user ID**, and a nullable
  link from each per-tournament roster row to it.
- A player-driven **self-claim** command binding a Discord account to an
  in-game name on the active tournament's roster.
- A `seasons` entity with date bounds, and tournament metadata to place each
  event in a season (`event_date`, `season_id`) and weight it (`weight`).
- A **frozen results** table written once, when a tournament closes: final
  placement (from Challonge) and awarded ranking points (computed).
- A points formula of the shape `f(placement, weight)`, evaluated at freeze
  time and **stored**, so later rule changes never silently restate history.
- Extension of the RFC-008 sync Edge Function to pull `final_rank` and to
  perform the one-way freeze when a Challonge tournament reaches `complete`.
- Two new French read commands: a season leaderboard, and a per-player history.
- Runbook and E2E-checklist updates covering season setup, event weighting,
  the freeze step, and correcting a bad freeze.

### Explicitly out of scope (this release)

- **Elo, Glicko, or any rating system that updates per-match.** v4.0 is a
  points-accumulation ladder driven by final placements only. Per-match rating
  is a materially different product and a materially different data model.
- **Retroactive import of past tournaments.** The ranking starts empty at the
  first season boundary after ship. Backfilling historical events is a
  separate, organizer-driven exercise.
- **Cross-guild or global rankings** — still single-guild, per `PRD.md` §3.
- **Player-facing dispute/appeal flow.** Corrections go through the organizer.
- **A web leaderboard, embeds with avatars/graphics, or any surface outside
  Discord.** Standings are read via bot commands and Supabase Studio.
- **Automatic detection of tournament completion.** The freeze runs on the
  organizer's existing manual trigger, consistent with v3.0's §24 rejection of
  polling.
- **Ranking-aware seeding** (using standings to seed the next bracket).
  Interesting, but it inverts the dependency between the bot and Challonge.
- **Multiple concurrent seasons**, and reopening a closed season.
- Everything already out of scope in `PRD.md` §3 and §16 that this document
  does not explicitly reopen. Note that this release **does** reopen one such
  item deliberately: *persistent cross-tournament identities*, listed as out of
  scope in both prior releases, is the core of v4.0.

## 30. User Personas (v4.0 additions)

### Persona A — Tournament Organizer (extended)

- New setup responsibility, **once per season**: create the season row with its
  date bounds.
- New setup responsibility, **once per tournament**: set the event's date and
  its weight/tier. This is a judgement call (is this a weekly or a major?) and
  the one place organizer discretion enters the ranking.
- New closing responsibility, **once per tournament**: trigger the freeze after
  the bracket is final in Challonge. This is the same `curl` they already run
  in v3.0's Journey F, invoked one last time against a completed tournament.
- **Success = "weight the event when I create it, hit the same refresh command
  at the end, and standings are correct."**

### Persona B — Tournament Player (extended)

- New one-time action: claim their in-game name with a `/link`-style command.
  Until they do, their results are still recorded but are not attributed to
  them in standings.
- New capability: check their own season history and the leaderboard.
- **Unlike v3.0, nothing they already know changes.** `/ots` behaves exactly as
  before; v4.0 is purely additive from a player's perspective.

## 31. Functional Requirements (v4.0)

Priority: **P0** = must ship; **P1** = strongly desired; **P2** = nice-to-have.
Same scheme as `PRD.md` §5 and §18.

### 31.1 Data model — identity

- **P0 (F38)** `profiles` — `id`, `discord_user_id` (not null, **unique**),
  `created_at`. Optionally a `display_name` snapshot for readability in Studio.
  This is the only table in the schema not scoped to a tournament.
- **P0 (F39)** `players.profile_id` — nullable FK to `profiles`. Nullable is
  load-bearing: an organizer creates roster rows before players have claimed
  them, and some players never will.
- **P0 (F40)** A unique index on `(tournament_id, profile_id) where profile_id
  is not null` — one person cannot hold two roster slots in the same event.
  This mirrors the existing `players_tournament_name_idx` contract on the name
  axis.

### 31.2 Data model — seasons and event metadata

- **P0 (F41)** `seasons` — `id`, `name`, `starts_on`, `ends_on`.
- **P1 (F42)** Non-overlapping season ranges enforced as a **DB invariant**
  (`exclude using gist (daterange(starts_on, ends_on) with &&)`), consistent
  with how this schema already enforces single-active and per-tournament name
  uniqueness in the database rather than in application code. Requires the
  `btree_gist` extension — available on Supabase, but a new dependency to
  confirm.
- **P0 (F43)** `tournaments.event_date` — the date the event actually happened.
  **`created_at` cannot serve this purpose**: it is row-creation time, which
  diverges from event date whenever an organizer sets a tournament up in
  advance. Season assignment depends on this being right.
- **P0 (F44)** `tournaments.season_id` — nullable FK. `NULL` means the event
  does not count toward any ranking (test tournaments, exhibitions).
- **P0 (F45)** `tournaments.weight` — the multiplier feeding the points
  formula. See §33 for the unresolved question of free numeric vs. fixed tiers.
- **P0 (F46)** `tournaments.completed_at` — nullable timestamp, set by the
  freeze. Non-null means "results are frozen." **This is deliberately not a
  status enum and deliberately does not touch `is_active`**, which remains
  load-bearing for the `/ots` read path (`tournaments_one_active_idx`,
  RFC-001/005/009). Adding a lifecycle enum alongside `is_active` would create
  two overlapping notions of tournament state.

### 31.3 Data model — frozen results

- **P0 (F47)** `tournament_results` — `tournament_id`, `player_id`,
  `profile_id`, `ingame_name` (snapshot), `final_rank`, `awarded_points`,
  `frozen_at`. Unique on `(tournament_id, player_id)`.
  - `ingame_name` is denormalized on purpose: history must stay readable even
    if the roster row is later edited or renamed.
  - `profile_id` is nullable and **backfillable** — an unclaimed player's
    result is still frozen correctly, and claiming later can attribute their
    whole back-catalogue at once.
- **P0 (F48)** `tournament_results.tournament_id` uses **`on delete restrict`,
  not `on delete cascade`**. This intentionally breaks uniformity with every
  other FK in `schema.sql` and must carry an explicit comment saying so,
  because a future reader will otherwise assume it cascades.
  - **Operational consequence:** the "delete the test tournament" cleanup used
    in `schema.sql`'s RFC-007 verification block stops working once anything is
    frozen. Test tournaments must either never be frozen (`season_id is null`
    is the natural guard) or get an explicit results-purge step. This needs
    covering in the runbook, not discovered live.
- **P0 (F49)** RLS enabled, deny-by-default, no policies — identical posture to
  every other table (`PRD.md` §18.1).
- **P1 (F50)** A correction path: re-freezing a tournament is an explicit,
  deliberate action that overwrites prior results and is visible as such, not a
  silent re-run. See §33 — the exact shape is open.

### 31.4 Points engine

- **P0 (F51)** `awarded_points = f(final_rank, weight)`, evaluated **once**, at
  freeze time, and stored.
- **P0 (F52)** The formula lives in **pure, unit-tested logic** with no I/O —
  the same pattern as `normalize_name`, `render_team_text`, `pick_opponent_id`,
  and `is_cache_stale`. Whether it lives in `bot.py` (Python) or in the Edge
  Function (TypeScript) depends on where the freeze runs; §33.
- **P1 (F53)** A `formula_version` stored alongside each frozen result, so a
  future rule change is auditable and old results are explicable rather than
  merely immutable.
- The formula's actual curve is **unresolved** — see §33.

### 31.5 Challonge sync extension — freeze

- **P0 (F54)** `mapParticipant` extended to carry `final_rank` from
  `participants.json`. **Needs live verification:** `final_rank` is expected to
  be null until the tournament completes, and its behavior for
  group-stage tournaments is unconfirmed. The dual-id-space surprise found
  during v3.0 is precedent for not assuming Challonge's shape.
- **P0 (F55)** The sync detects `tournament.state = 'complete'` and, when the
  tournament has a `season_id`, performs the freeze: write `tournament_results`
  rows, set `completed_at`.
- **P0 (F56)** The freeze is **idempotent and one-way**: re-triggering sync on
  an already-frozen tournament is a no-op, not a rewrite. This differs
  fundamentally from the cache tables' refresh-by-upsert model, which is
  designed to be re-run constantly — the same Edge Function now has two write
  modes with opposite semantics, and that seam is where bugs will live.
- **P1 (F57)** A player in the Challonge bracket with no `players` row (v3.0's
  `opponent_no_ots` case) still gets a frozen result — placement and points are
  independent of whether an OTS was submitted.

### 31.6 Discord identity self-claim

- **P0 (F58)** A `/link <ingame_name>`-style command capturing
  `interaction.user.id` automatically. The Discord ID is never typed by a
  human, which is the entire point of choosing self-claim.
- **P0 (F59)** Conflict rules, each with distinct French copy:
  - name not on the active tournament's roster → reject;
  - name already claimed by a **different** Discord account → reject, tell them
    to contact the organizer (never reveal who holds it);
  - name already claimed by **this same** account → idempotent success;
  - this account already claimed a **different** name in this tournament →
    reject (F40's invariant), organizer must intervene.
- **P0 (F60)** On claim, backfill `profile_id` across the player's existing
  `players` and `tournament_results` rows where the normalized name matches, so
  a late claim recovers prior history rather than starting from zero.
- **P1 (F61)** An organizer override in Studio — reassigning or clearing a bad
  claim. Purely a documented Studio procedure, no bot surface.
- The backfill in F60 is a **name-match heuristic applied once, on the player's
  own request** — which is meaningfully safer than name-matching as a standing
  identity rule, but is not free of risk. See §33.

### 31.7 Discord read commands

- **P0 (F62)** A season leaderboard command (French naming, e.g.
  `/classement`): profiles ranked by summed `awarded_points` in the current
  season. Needs a defined tie-break and a result cap.
- **P0 (F63)** A per-player history command (e.g. `/profil`): one row per
  tournament entered — event name, date, placement, points — for the current
  season.
- **P1 (F64)** Per-tournament standings, either as a third command or an
  argument to F63. Cheap: same table, different filter.
- **P1 (F65)** Both commands fail soft in French on the same outcomes the rest
  of the bot handles (`unavailable`, no current season, profile not linked),
  consistent with `PRD.md` §18.3.

### 31.8 Configuration

- No new environment variables anticipated. The freeze reuses the Edge
  Function's existing Supabase and Challonge credentials, and the read commands
  reuse `bot.py`'s existing service-key path.

## 32. Non-Functional Requirements (v4.0)

- **Read latency:** leaderboard and history commands stay within the existing
  5s bounded-read budget (`PRD.md` §6). Both are single indexed queries over a
  table whose size is bounded by (players × events per season) — small for the
  foreseeable future.
- **Fail-soft, always:** a ranking outage must never affect `/ots`. The new
  commands are independent read paths.
- **French throughout**, per `CLAUDE.md` conventions.
- **Durability over convenience:** frozen results are the one place in this
  system where data loss is unacceptable. Roster typos are recoverable; a
  deleted season of standings is not.
- **Privacy:** `discord_user_id` is stored persistently and indefinitely — the
  first genuinely personal data this project holds. Retention and deletion
  expectations should be stated before shipping, not after.
- **Pure logic is unit-tested with no network**, matching the existing
  `test_bot.py` discipline.

## 33. Open Questions (nothing here is resolved)

These are the decisions this draft deliberately leaves open, roughly in
descending order of how much they change the build.

1. **The points curve.** `f(placement, weight)` is a shape, not a formula.
   Linear (`weight × (N − rank + 1)`)? Top-heavy? Scaled by field size so a
   4-player event can't pay like a 64-player one? Participation floor for
   everyone who shows up? This blocks F51 and therefore the whole freeze step.
2. **`weight`: free numeric or fixed tier vocabulary?** A numeric column is
   flexible and trivial to build; a `tournament_tiers` lookup is
   self-documenting, prevents typos, and makes "what counts as a major" an
   explicit decision. Recommend tiers if more than one organizer will ever
   touch this.
3. **Where does the freeze run — Edge Function or bot?** The Edge Function
   already holds the Challonge credentials and the sync logic, which argues
   strongly for it. But it puts the points formula in TypeScript while the rest
   of the project's pure logic is Python, splitting the test suite across two
   languages for one formula.
4. **Correction semantics (F50).** What actually happens when a freeze was
   wrong — a DQ discovered afterwards, a Challonge fix landed late? Options:
   organizer-only unfreeze-and-refreeze; append a correction row; or edit in
   Studio and accept the audit gap.
5. **Unclaimed players in the leaderboard.** Hidden entirely? Shown by in-game
   name without a Discord mention? The second is friendlier and advertises the
   `/link` command, but starts publishing per-name standings for people who
   never opted in.
6. **F60's backfill risk.** Claiming `zou` attributes *every* historical `zou`
   to the claimant. If two different people used that name across seasons, the
   claim silently absorbs someone else's results. Cap the backfill to the
   current season? Require organizer confirmation above some result count?
7. **Ties.** Two players on equal points — shared rank, or broken by best
   finish / events played / head-to-head?
8. **Season rollover.** Is there a ceremony (announcement, final standings
   snapshot), or does the boundary just pass silently?
9. **Does Challonge's `final_rank` behave as assumed** for the group-stage
   tournaments this community actually runs (F54)? This should be verified
   against real data *before* RFC-011 is drafted, not during implementation.
10. **Minimum participation** to appear in standings — one event, or a floor?

## 34. Proposed User Journeys (v4.0)

### Journey I — Organizer opens a season (once per season)

Create the season row in Studio with its date bounds. Nothing else changes
until the first event of that season is created.

### Journey J — Player claims their identity (once per player)

Player runs `/link <their in-game name>`. The bot binds their Discord account,
backfills any prior results matching that name, and confirms in French. From
then on, everything they enter accumulates automatically.

### Journey K — Organizer closes an event (once per tournament)

Bracket finishes in Challonge. Organizer runs the same refresh `curl` from
v3.0's Journey F. The sync sees `state = 'complete'`, freezes results, and sets
`completed_at`. Standings update immediately. **No new organizer action is
introduced at close time** — this is the key ergonomic claim of the design, and
worth stress-testing in discussion.

### Journey L — Player checks standings

`/classement` for the season leaderboard; `/profil` for their own history with
teams, placements, and points per event.

### Journey M — A freeze was wrong (failure path)

Currently **undefined** — see §33 item 4. This journey must be written before
the release is buildable; a ranking system without a correction story will
acquire one improvised under pressure during an event.

## 35. Proposed RFC Breakdown

Continuing from RFC-010. Each depends on the previous.

| # | RFC | Features | Complexity |
|---|-----|----------|------------|
| **011** | Ranking Schema (profiles, seasons, results, invariants) | F38–F50 | Medium |
| **012** | Points Engine & Sync Freeze | F51–F57 | High |
| **013** | Discord Identity Self-Claim (`/link`) | F58–F61 | Medium |
| **014** | Ranking Read Commands, Runbook & Release | F62–F65 | Medium |

RFC-011 is buildable as soon as §33 items 2 and 9 are settled. RFC-012 is
blocked on items 1, 3, and 4. RFC-013 is blocked on item 6.

## 36. Assumptions

- Tournaments continue to run in Challonge, and the v3.0 sync pipeline is
  live and healthy (its E2E gate closed).
- Organizers will reliably set `event_date` and `weight` at tournament-creation
  time. If they forget, the event lands in no season and pays no points — a
  silent failure worth an explicit check in the runbook.
- Players will claim their names. Adoption is the main product risk: an
  unclaimed majority makes the leaderboard useless regardless of how correct
  the maths are.
- The community is small enough that Supabase free-tier limits and single-guild
  scope remain non-issues.

## 37. Dependencies & Migration

- **Depends on:** v3.0 shipped and E2E-signed-off (✅ 2026-07-31); the RFC-008
  Edge Function; `btree_gist` if F42 is adopted.
- **Migration:** purely additive DDL — one new column on `players`, four on
  `tournaments`, three new tables. No existing column changes type or meaning,
  and no existing query needs rewriting. `schema.sql`'s idempotent-apply
  contract must be preserved.
- **The one non-additive change is F48's `on delete restrict`**, which alters
  an operational procedure (test-tournament cleanup) rather than any data.
- **Rollback:** the new commands can be removed and the new tables left in
  place without affecting `/ots` at all. This release is unusually safe to back
  out of, which is a point in favour of building it after v3.0 rather than
  alongside.
