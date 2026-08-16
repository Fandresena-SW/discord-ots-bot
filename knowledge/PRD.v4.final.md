# PRD v4.0 — Ranking System & `/ots` Identity Binding

**Product:** discord-ots-bot
**Version:** 4.0
**Date:** 2026-07-31
**Status:** ✅ **Specified and decided. Ready for RFC-011.** No RFC written, no
code exists. Every decision in this document is locked for build; reopening one
is a deliberate scope change, not a judgement call.
**Target release:** no date set (see §35).

**Relationship to other documents.** This is the authoritative specification for
v4.0. Section numbering continues from `PRD.md`'s §26, feature IDs from
`FEATURES.md`'s F37, goals from G10, journeys from Journey H, and RFCs from
RFC-010, so cross-references stay unambiguous. `PRD.md` remains the record of
v2.0 (§1–§13) and v3.0 (§14–§26); its §17 and §24 item 4 describe the `/ots`
contract this release supersedes.

> ⚠️ **v4.0 is not an additive release.** It removes `/ots`'s argument. That is
> a breaking change to the project's only player-facing command, and it makes
> the identity binding a **security boundary** rather than bookkeeping. §31.7 is
> the section to read first.

---

## 27. Overview

v2.0 made the roster live. v3.0 made pairings live. Both are **within-event**
features: everything the bot knows is scoped to the one tournament where
`is_active = true`, and when a tournament ends its data stops meaning anything.

v4.0 does two things.

**It adds the across-event dimension.** A persistent ranking accumulates results
over a season, so players have a reason to come back and the organizer has a
standings table they don't maintain by hand. Two views of one record: per player
("everything I've done this season") and per tournament ("everyone who played
this event").

**It closes a team-sheet leak found during v3.0.** Because `/ots <name>` means
"I am *name*, who am I playing?" and returns *that person's opponent's* sheet,
any player could walk the roster and scout the whole field before being paired.
v4.0 removes the argument: `/ots` infers the caller from their bound Discord
account and can only ever reveal their own opponent.

These are one release because the second depends on the first. Inferring "who is
calling" requires a persistent identity, which is the same identity the ranking
needs. The ranking pays for the schema; the leak fix is why that schema has to
be trustworthy.

**The central design consequence.** The `players`↔Discord binding is not a
convenience — it authorizes access to opponent team sheets. A false binding buys
silent, instant access to a sheet the holder is not entitled to, and no
after-the-fact correction can un-see it. Binding is therefore
**organizer-established**, one-time per person, with no self-service claim.

**The central trade-off.** v4.0 exchanges *disposable* data for *durable* data.
Every table this project has held so far is either re-derivable (the Challonge
caches) or cheaply retypable (a 20-row roster). `profiles` and
`tournament_results` are neither: a lost season of standings cannot be
reconstructed, and a wrong one cannot be quietly corrected without players
noticing. §32, §38 and F69 exist to manage that.

## 28. Goals and Objectives

| # | Goal | Measure |
|---|------|---------|
| G11 | A player's results persist and accumulate across tournaments | A player who entered 3 events this season sees all 3 — teams, placements, points — in one command |
| G12 | Closing an event requires no new organizer action | The close-time procedure is byte-identical to v3.0's Journey F trigger. Setup grows by two fields per event, one row per season, and one binding per new person — ever |
| G13 | Ranking history is durable, and correcting it is deliberate | A frozen result cannot change by re-running the normal sync; correcting one requires an explicitly flagged re-freeze, recorded via `frozen_at` and `freeze_count`. This is durability plus an audit trail, **not** tamper-evidence — an operator with the service key can still edit Studio rows, and v4.0 does not try to prevent that |
| G14 | Identity is established, never guessed | A binding is created by the organizer selecting a Discord account from the native picker. No Discord id is ever typed, and no player can assert an identity |
| G15 | `/ots` becomes simpler and safe | The argument is removed; the caller is inferred from their bound profile. Typed-name lookup survives only as an organizer-gated debug command. **The v3.0 scouting leak is closed** |
| G16 | Every entrant is bound before they need the bot | **100 %** of an event's roster rows have a `profile_id` at the start of round 1. Under G15 this is a prerequisite, not an adoption metric — an unbound player cannot use `/ots` |
| G17 | Personal data is held deliberately | `discord_user_id` — the first genuinely personal data this project stores — has a stated retention posture and a working erasure path before release, not after |

## 29. Scope

### In scope

- A persistent `profiles` identity keyed by **Discord user ID**, and a nullable
  link from each per-tournament roster row to it.
- An **organizer-run binding** command tying a Discord account to an in-game
  name, one-time per person, plus a player-run erasure.
- A refactor of **`/ots` to take no argument**, inferring the caller from their
  bound profile, plus an **organizer-only typed-name variant** for debugging.
- A `seasons` entity with date bounds, and tournament metadata placing each
  event in a season (`event_date`, `season_id`) and weighting it (`tier_id`).
- A `tournament_tiers` lookup supplying the points multiplier.
- A **frozen results** table written once when a tournament closes: final
  placement from Challonge, awarded points, and a snapshot of every input the
  points depended on.
- A points formula — a fixed placement table × tier multiplier — evaluated at
  freeze time and **stored**, so later rule changes never restate history.
- Extension of the RFC-008 Edge Function to carry `final_rank` and perform the
  one-way freeze, with a conditional third Challonge API call to confirm
  completion.
- Two French read commands — a season leaderboard and a per-player history —
  restricted to one configured channel.
- Runbook (§9) and `E2E-CHECKLIST-v4.md` covering season setup, tiering,
  binding, the freeze, and correcting a bad freeze.

### Out of scope

- **Elo, Glicko, or any per-match rating.** v4.0 is a points-accumulation ladder
  driven by final placements only — a materially different product and data
  model.
- **Retroactive import of past tournaments.** The ranking starts empty at the
  first season boundary after ship.
- **Historical-season browsing.** Both read commands serve the current season
  only.
- **Ranking-aware seeding.** It would invert the dependency between the bot and
  Challonge.
- **Multiple concurrent seasons**, and reopening a closed season.
- **Automatic detection of tournament completion.** The freeze rides the
  organizer's existing manual trigger; there is no polling and no schedule.
- **A player-facing dispute or appeal flow.** Corrections go through the
  organizer.
- **A web leaderboard, avatars, or any surface outside Discord.**
- **A Discord role model.** Authorization is a single organizer id.
- **Cross-guild or global rankings** — still single-guild.
- Everything already out of scope in `PRD.md` §3 and §16, with one deliberate
  exception: **persistent cross-tournament identities**, listed as out of scope
  in both prior releases, is the core of this one.

## 30. User Personas

### Persona A — Tournament Organizer (extended)

- **Once per season:** create the season row in Studio with its date bounds.
- **Once per tournament:** set `event_date` and pick a `tier_id`. The tier is a
  judgement call — is this a weekly or a major? — and the only place organizer
  discretion enters the ranking.
- **Once per person, ever:** bind their Discord account to their in-game name.
  Roster rows in later tournaments link forward automatically, so this is never
  repeated for the same player.
- **At event close:** nothing new. The freeze rides the same trigger command
  already run in v3.0's Journey F.
- **Exceptionally:** correct a bad freeze, rebind a wrong binding, or debug a
  player's `/ots` complaint. All three are single commands, runnable from a
  phone.
- **Success = "pick the tier when I create the event, hit the same refresh
  command at the end, and standings are correct."**

### Persona B — Tournament Player (extended)

- **Their `/ots` habit changes.** They type `/ots` with no argument. Simpler to
  use, and it removes the ability to look up anyone else — which some players
  were using, so the change needs announcing.
- **No action required to be bound.** The organizer does it once; there is no
  command for the player to discover.
- **New capability:** their own season history and the leaderboard, in the
  ranking channel.
- **New right:** erasure — which also revokes their own `/ots`, so the
  confirmation must say so.

### Persona C — The unbound player

Not a preference but an **operational state**: someone the organizer has not
bound yet. They have exactly one bad moment — round 1, needing their opponent's
sheet and unable to get it. The requirements that follow:

- The organizer can bind them in seconds, from a phone, without Studio (F61).
- Pre-flight catches it before round 1 rather than during it (G16).
- Their results freeze correctly whether bound or not (F57), and binding later
  still recovers the season's history (F60).
- They still appear on the leaderboard by in-game name (F70), so being unbound
  is invisible everywhere except `/ots`.

## 31. Functional Requirements

Priority: **P0** = must ship, **P1** = strongly desired, **P2** = nice-to-have —
the same scheme as `PRD.md` §5 and §18. `FEATURES.md` is MoSCoW; the mapping is
**P0 → Must**, **P1 → Should**, **P2 → Could**, and §29's out-of-scope list is
the Won't column. Requirements are grouped by topic; IDs are stable and not
sequential within a group.

### 31.1 Data model — identity

- **P0 (F38)** `profiles` — `id`, `discord_user_id` (not null, **unique**),
  `created_at`, optionally a `display_name` snapshot for Studio readability.
  The only table in the schema not scoped to a tournament.
- **P0 (F39)** `players.profile_id` — nullable FK to `profiles`. Nullable is
  load-bearing: roster rows exist before bindings do, and some rows never get
  one.
- **P0 (F40)** Unique index on `(tournament_id, profile_id) where profile_id is
  not null` — one person cannot hold two roster slots in the same event. Mirrors
  the existing `players_tournament_name_idx` contract on the name axis.

### 31.2 Data model — seasons, tiers, event metadata

- **P0 (F41)** `seasons` — `id`, `name`, `starts_on`, `ends_on`.
- **P1 (F42)** Non-overlapping season ranges enforced as a **DB invariant**:
  `exclude using gist (daterange(starts_on, ends_on, '[]') with &&)`, consistent
  with how this schema already enforces single-active and per-tournament name
  uniqueness in the database rather than in application code.
  - Build the range with explicit **`'[]'` bounds**. `daterange`'s default is
    half-open `[)`, which would make `ends_on` exclusive and contradict its
    name.
  - **No new Postgres extension.** Range types ship a native GiST operator
    class; `btree_gist` would only be needed to mix a scalar `with =` column
    into the constraint, and single-guild scope means there is none.
- **P0 (F66)** **"Current season" is a defined, single-query concept:** the
  unique `seasons` row whose `[starts_on, ends_on]` contains today. F42
  guarantees at most one. Two states need their own French copy: **today falls
  in no season** (between seasons, or before the first exists), and **the current
  season has no frozen results yet** (opening weeks — an empty leaderboard is
  normal, not an error).
- **P0 (F43)** `tournaments.event_date` — the date the event happened.
  `created_at` cannot serve this purpose: it is row-creation time, which diverges
  whenever an organizer sets a tournament up in advance, and season assignment
  depends on this being right.
- **P0 (F44)** `tournaments.season_id` — nullable FK. `NULL` means the event
  counts toward no ranking (test tournaments, exhibitions).
- **P0 (F45)** `tournament_tiers` — `id`, `name`, `multiplier` — plus
  `tournaments.tier_id`, a not-null FK. Seeded with **Hebdo 1.0, Mensuel 2.0,
  Majeur 3.0** via guarded inserts. A lookup rather than a free numeric column
  so the Studio surface is a typo-proof dropdown and "what counts as a major" is
  an explicit, reviewable decision.
- **P0 (F46)** `tournaments.completed_at` — nullable timestamp set by the freeze.
  Non-null means "results are frozen."
  - **Deliberately not a status enum, and deliberately independent of
    `is_active`**, which remains load-bearing for the `/ots` read path
    (`tournaments_one_active_idx`, RFC-001/005/009). A lifecycle enum alongside
    `is_active` would create two overlapping notions of tournament state.
  - A frozen tournament may remain active; `/ots` will report no open match,
    which is v3.0's existing `no_current_match` outcome and the correct answer.
    Deactivation stays the organizer's normal two-step switch (F8).

### 31.3 Data model — frozen results

- **P0 (F47)** `tournament_results` — `tournament_id`,
  `challonge_participant_id`, `player_id` (**nullable**), `profile_id`
  (nullable), `ingame_name` (snapshot), `final_rank`, `awarded_points`,
  `frozen_at`, `freeze_count`. **Unique on
  `(tournament_id, challonge_participant_id)`.**
  - **The bracket, not the roster, decides who earned a result.** Placement is a
    fact about the bracket. Tournament 3 had 14 bracket entrants against 16
    roster rows; the two roster-only names must earn nothing, and a bracket
    entrant with no roster row must still be recorded.
  - `ingame_name` is denormalized on purpose: history must stay readable if the
    roster row is later edited or renamed.
  - `profile_id` is nullable and **backfillable** — an unbound player's result
    freezes correctly, and binding later attributes their history (F60).
- **P0 (F67)** **Frozen results snapshot every input the points depended on:**
  `season_id`, **`multiplier`** (the resolved numeric value, *not* `tier_id`),
  `formula_version`, and `participant_count`, all captured at freeze time.
  - Standings sum over `tournament_results.season_id`, **never** over a join to
    `tournaments`. Editing `tournaments.season_id` after a freeze must not
    relocate a frozen result into another season.
  - **Snapshotting `multiplier` rather than `tier_id` is load-bearing, not
    prudent.** Tiers are shared rows: repricing "Majeur" from 3.0 to 2.5 next
    season would otherwise silently restate every Majeur ever frozen.
  - `participant_count` costs one integer and keeps field-size scaling
    answerable later without a schema change and a Challonge re-fetch.
- **P0 (F48)** `tournament_results.tournament_id` uses **`on delete restrict`,
  not `on delete cascade`**. This breaks uniformity with every other FK in
  `schema.sql` and **must carry an explicit comment saying so**, because a future
  reader will otherwise assume it cascades.
  - **Operational consequence:** the "delete the test tournament" cleanup in
    `schema.sql`'s RFC-007 verification block stops working once anything is
    frozen. Test tournaments must either never be frozen (`season_id is null` is
    the guard, and F55 enforces it) or get an explicit results-purge step.
    Covered in runbook §9.
  - It also blocks the naive erasure path for a profile with results, which is
    why F69 anonymizes rather than deletes.
- **P0 (F49)** RLS enabled, deny-by-default, no policies — identical posture to
  every other table (`PRD.md` §18.1).
- **P0 (F50)** **Frozen history is correctable only deliberately.** A correction
  must be an explicit action that overwrites prior values and leaves a record;
  it must never be a side effect of a routine sync. F72 is the mechanism.

### 31.4 Points engine

- **P0 (F51)** `awarded_points = multiplier × table(final_rank)`, evaluated
  **once**, at freeze time, and stored. The table:

  | Placement | Base points |
  |---|---|
  | 1st | 100 |
  | 2nd | 70 |
  | 3rd–4th | 50 |
  | 5th–8th | 30 |
  | 9th–16th | 15 |
  | 17th and below | 5 (participation floor) |

  - **Bucket edges sit on 1 / 2 / 3 / 5 / 9 / 17 — exactly where single-elim tie
    ranks land.** That alignment is what makes tied placements pay their members
    equally, automatically. Verified against real data: tournament 3's rank
    vector produces 100 / 70 / 50·50 / 30·30·30·30 / 15×6, total 480, with no
    tied rank paying unequally.
  - **Do not "simplify" this into a linear formula.** `multiplier × (N − rank +
    1)` opens holes at ranks 4 and 6–8 on that same tournament and pays only
    three points between 2nd and 5th.
  - No field-size term: `multiplier` already encodes how big a deal the event
    was, and a second scaling axis makes the number unexplainable to a player
    who asks why they got 30.
- **P0 (F52)** The formula lives in **pure, unit-tested logic with no I/O** —
  the same pattern as `normalize_name`, `render_team_text`, `pick_opponent_id`
  and `is_cache_stale`. It lives in
  `supabase/functions/challonge-sync/points.ts`, tested by a new
  `points_test.ts` joining the existing `mapping_test.ts` Deno suite.
  - It sits in the Edge Function because that is where `final_rank` arrives and
    because `bot.py` has **no write path at all** — giving it one would be a
    larger architectural break than one pure function in TypeScript.
- **P1 (F53)** `formula_version` stored alongside each frozen result (part of
  F67's snapshot), so a future rule change is auditable and old results are
  explicable rather than merely immutable.

### 31.5 Challonge sync — the freeze

- **P0 (F54)** `mapParticipant` extended to carry `final_rank` from
  `participants.json`. **Verified live 2026-07-31** against tournament id 3
  (Challonge `18251698`; 14 players, 4-round Swiss group stage plus a top-8
  single-elim final, `state = 'complete'`, `group_stages_enabled = true`). Three
  facts constrain the build:
  - `final_rank` is **non-null for every participant**, including those who never
    reached the final bracket.
  - Ranks are **competition-style with ties and gaps** — `1, 2, 3, 3, 5, 5, 5,
    5, 9, 10, 11, 12, 13, 14`. Ranks 4, 6, 7, 8 do not exist. **`final_rank` is
    not a dense 1..N sequence and nothing may treat it as one.**
  - Group-stage non-qualifiers are ranked **distinctly** (9–14), not collapsed to
    a shared 9th; Challonge breaks those ties itself, presumably via the
    `tie_break_points` field in the same payload.
  - `group_player_ids` is a JSON **array**. Every participant here had exactly
    one entry, matching `challonge_group_player_id`'s single-column shape — but
    that is not guaranteed, so log defensively if the array is ever longer.
- **P0 (F74)** **`participants[].active` must never be used to filter the
  field.** The live check found `active: false` on all six group-stage
  non-qualifiers and `true` on the eight who advanced. The field tracks *still
  advancing*, **not** *validly entered* — so the natural-looking "skip inactive
  participants" filter silently drops 43 % of that tournament's field, and
  precisely the lower-placed players the participation floor exists to reward.
  Freeze the whole participant list. If a genuine DQ/forfeit signal is ever
  needed, it is not this field.
- **P0 (F55)** The freeze runs only when the tournament has a **non-null
  `season_id`**, and `completed_at` is set **only when the freeze actually
  runs**. A complete tournament with no season writes nothing and leaves
  `completed_at` null, so the organizer can set the season afterwards and
  trigger again (Journey O). This is what makes a forgotten `season_id`
  recoverable rather than permanently lossy under F56.
- **P0 (F68)** **Completion is confirmed by a conditional third Challonge API
  call.** Completion must **not** be derived from the cached matches alone: in a
  group-stage tournament the final bracket's matches **do not exist in
  `matches.json` until the group stage is finalized**, so "all cached matches are
  complete" fires at the group-stage boundary, while half the event is unplayed.
  Under F56 that freeze is one-way.
  - Keep the two unconditional calls. When — and only when — every cached match
    reads `complete`, call `/tournaments/{id}.json` and freeze only if
    `state == 'complete'`. (`progress_meter: 100` and a non-null `completed_at`
    corroborate.)
  - The third call fires roughly **once per event**, on the last trigger. A
    7-round event goes from ~14 calls to ~15 against Challonge's 500/month cap.
  - **This is a conscious amendment to `.claude/RULES.md` §18 and `PRD.md` §21**,
    which both state a flat "exactly 2 calls per invocation". Both must be
    reworded as part of RFC-012, or the release gate contradicts the code.
- **P0 (F56)** The default freeze is **idempotent and one-way**: re-triggering on
  an already-frozen tournament does not rewrite results. This is the opposite of
  the cache tables' refresh-by-upsert model, which is designed to be re-run
  constantly — the same Edge Function now has two write modes with opposing
  semantics, and that seam is where bugs will live. Overriding it requires F72's
  explicit flag; there is no other path.
- **P0 (F72)** **Two-mode freeze.**
  - **Default** (`{"tournament_id": X}`): if `completed_at` is non-null, the
    freeze step is skipped and the response says so. Cache refresh proceeds
    normally.
  - **Explicit** (`{"tournament_id": X, "refreeze": true}`): recompute and
    overwrite every `tournament_results` row for that tournament, update
    `frozen_at`, increment `freeze_count`.
  - The flag *is* the safety property: an organizer cannot corrupt frozen history
    by muscle-memory `curl`, and can correct it by adding six characters they had
    to look up in the runbook.
- **P0 (F57)** A bracket participant with **no `players` row** (v3.0's
  `opponent_no_ots` case) still gets a frozen result. Placement and points are
  independent of whether an OTS was submitted — which is why F47 keys on
  `challonge_participant_id` and leaves `player_id` nullable.
- **P0** The freeze targets an **explicit `tournament_id`** supplied in the
  trigger body, exactly as the RFC-008 sync already does. It does **not** use
  the active tournament, so a tournament may be deactivated before being frozen.
  Runbook §9 must say so, because organizers will assume otherwise.

**Freeze algorithm, per trigger.** In order, and short-circuiting:

1. Fetch `participants.json` and `matches.json` (2 calls, always). Upsert both
   caches as v3.0 already does.
2. `completed_at` non-null and no `refreeze` flag → **skip**, report skipped.
3. `season_id` is null → **skip**, leave `completed_at` null, report no-season.
4. Any cached match not `complete` → **skip**, report in-progress.
5. All matches complete → third call. `state != 'complete'` → **skip**, report
   not-yet-complete. *(This is the group-stage boundary.)*
6. Any participant has a null `final_rank` → **refuse and log loudly.** An
   anomaly here means Challonge's shape changed; a partial freeze is worse than
   none.
7. Otherwise freeze: for **every** participant, no filtering on `active`,
   compute `multiplier × table(final_rank)`, write `tournament_results` with
   F67's snapshot, set `frozen_at`, set `completed_at`, set/increment
   `freeze_count`.

### 31.6 Identity binding

Binding authorizes access to opponent team sheets (§31.7), so it is preventive:
established by the organizer, never asserted by a player. **There is no
self-service claim command.**

- **P0 (F58)** `/link-organizer <ingame_name> <@user>` — organizer-only. The
  Discord account arrives as a **native user mention**, so Discord supplies the
  account object and no id is ever typed: the organizer *selects*.
  - Creates the `profiles` row if the account has none, then sets `profile_id` on
    the matching `players` row.
  - **One-time per person, not per event** — F60's forward auto-link carries it
    into every later tournament.
- **P0 (F77)** Organizer authorization for F58, F61 and F78. Gate on **both**
  `default_member_permissions` (Discord hides the command from non-organizers)
  **and** an explicit `interaction.user.id == ORGANIZER_DISCORD_ID` check, from a
  new env var validated at boot per F19. Belt and braces is justified because
  these commands grant team-sheet access. No Discord role model is introduced; a
  single id is the whole authorization model, matching the "just me" persona.
- **P0 (F59)** Conflict rules, each with distinct French copy, all addressed to
  the organizer:
  - in-game name not found on any searched roster → reject;
  - name already bound to a **different** account → reject **unless** the command
    carries an explicit rebind confirmation (F61);
  - name already bound to **this same** account → idempotent success;
  - this account already bound to a **different** name in this tournament →
    reject (F40);
  - no active tournament, or Supabase unavailable → standard fail-soft, in
    French.
- **P0 (F60)** Two propagation rules:
  - **Backfill on bind** — set `profile_id` across existing `players` and
    `tournament_results` rows whose normalized name matches, **bounded to the
    current season**, so a binding recovers recent history without a name
    collision costing years of it.
  - **Auto-link forward** — when a roster row is created in a *later*
    tournament, it links automatically to the profile already holding that
    normalized name. **This is what makes binding one-time.** The trust it adds
    is nil: the organizer typing "Sen" into a roster is already the assertion
    `/ots` has depended on since v3.0.
  - **Every propagation is logged server-side** — profile, normalized name,
    season, row count, tournament ids. This is the one operation in v4.0 that can
    silently move another player's results *and* another player's team-sheet
    access, and F61 is useless without a record of what moved.
- **P0 (F61)** Rebinding is the same command plus an explicit confirmation — not
  a Studio procedure. When a bad binding blocks a player from `/ots` at a live
  event, the fix has to be runnable from a phone in ten seconds. Clearing a
  binding entirely remains a Studio edit.
- **P0 (F71)** Binding is **not scoped to the active tournament.** The command
  searches the active roster first, then any roster in the current season, so a
  player sitting out the current event — or being bound ahead of one they are
  about to enter — can still be bound.
- **P0 (F69)** **Erasure.** `/unlink` clears `profile_id` from the caller's
  `players` rows and deletes their `profiles` row. Their `tournament_results`
  rows are **anonymized, not deleted** — `profile_id` set null, `ingame_name`
  snapshot retained. Deletion is blocked by F48 anyway and would corrupt other
  players' historical context.
  - **Stays player-runnable, and must:** erasure of your own personal data cannot
    require asking someone else.
  - It **also revokes the caller's `/ots` access**, so it needs an explicit
    French confirmation naming that consequence — otherwise a curious player
    disables themselves mid-event and blames the bot. Restoring requires F58.
  - **Retention posture:** `discord_user_id` is held as long as the profile
    exists and is erasable by the player at any time. In-game names in frozen
    results are tournament records, retained indefinitely.

### 31.7 The `/ots` refactor

- **P0 (F76)** **`/ots` takes no argument and infers the caller.**
  - **Behavior:** resolve `interaction.user.id` → `profiles` → the caller's
    `players` row in the active tournament → v3.0's existing opponent
    resolution, unchanged.
  - **`fetch_current_opponent()` keeps its shape**; only the entry point
    changes. Everything from `participant_candidate_ids()` downward — the
    dual-id handling, `pick_opponent_id()`, the embed, DM delivery with
    ephemeral fallback, `render_team_text()` hardening — is reused verbatim.
  - **Two new fail-soft statuses**, French, distinct, never raising:
    `not_linked` (no profile for this account — direct them to the organizer) and
    `not_in_tournament` (bound, but no roster row in the active event). v3.0's
    seven are otherwise unchanged, for a total of **nine**.
  - **The typed-name form is removed from `/ots` entirely** — not hidden behind
    an optional argument or a flag. It survives only as F78.
  - **Accepted consequence:** an unbound player cannot use `/ots` at all. That
    is the point, but it moves the failure to round 1, which is why G16 and
    pre-flight are load-bearing rather than advisory.
- **P1 (F78)** `/ots-organizer <ingame_name>` — organizer-only debug lookup.
  Resolves an *arbitrary* player's current opponent, exactly as v3.0's `/ots`
  did, so the organizer can reproduce a player's complaint instead of taking
  their word for it.
  - **A separate command, never an optional argument on `/ots`.** The reason is
    fail-direction: an optional parameter puts the typed-name path one faulty
    conditional away from every player, whereas a separate command guarded at
    registration fails closed — a broken auth check costs the organizer their
    debug tool and nothing else. A visible-but-unusable parameter on `/ots`
    would also undo the ergonomic win.
  - **Ephemeral reply**, never DM and never public: a diagnostic, not a
    delivery. **Not** channel-restricted — debugging happens wherever the problem
    is reported.
  - **Bypasses the binding requirement by design**, since diagnosing unbound
    players is its purpose.
  - **Every invocation logged** with caller, queried name, and resolved status.
  - **Implementation consequence, and a welcome one:** v3.0's `normalize_name`
    resolution is **retained, not deleted**. The refactor becomes "extract the
    resolution core, give it two thin entry points" — a bound profile for `/ots`,
    a normalized name for this command — which keeps the existing `test_bot.py`
    name-path coverage meaningful.
  - **P1, not P0:** the release ships without it and it must never delay a
    security fix, but ship it in the same RFC — an organizer who cannot debug
    will improvise something worse.

### 31.8 Ranking read commands

- **P0 (F62)** A season leaderboard command (e.g. `/standings`): profiles and
  unbound players ranked by summed `awarded_points` in the current season.
  Ordering and limits per F70.
- **P0 (F70)** **Leaderboard render contract.**
  - Ordering: `sum(awarded_points)` desc → **most events played** desc → best
    single `final_rank` asc → `profile_id` asc (stability only, never
    player-visible). **Turnout breaks ties before peak performance**, so a player
    who attended more and won nothing can outrank an event winner on equal
    points. Runbook §9 states this plainly so the organizer can answer for it.
  - Equal points always display the **same rank number**; sort keys decide row
    order only.
  - **Unbound players are shown and ranked** by in-game name with no Discord
    mention — the leaderboard is correct from day one, and nothing is published
    that the Challonge bracket does not already show. Bound profiles render as a
    mention.
  - **No participation floor** — one event is enough to appear.
  - Cap at **top 25**, with a French footer stating the total ranked count when
    truncated and directing unbound players to the organizer.
  - The rendered block is **hard-capped to Discord's 4096-character description
    limit** by the same discipline as `render_team_text`. A standings table that
    overflows is rejected by Discord outright, so this is a correctness
    requirement, not presentation polish — and the footer carries two things,
    both counting against the budget.
- **P0 (F63)** A per-player history command (e.g. `/profile`): one row per
  tournament entered — event name, date, placement, points — for the current
  season. **Self-only in v4.0**; no target-user argument. Replies
  **ephemerally**, unlike `/standings`.
- **P0 (F75)** **Ranking commands are restricted to one configured channel.**
  `/standings` and `/profile` work only in the channel named by
  `RANKING_CHANNEL_ID`; invoked elsewhere they refuse with their own French
  message. `/standings` replies **publicly** within that channel.
  - **`/ots` is unaffected and must stay unaffected** — it keeps working
    everywhere and DMs as before. The channel check must not be implemented
    anywhere the `/ots` path can reach.
- **P1 (F64)** Per-tournament standings — a third command or an argument to
  F63. Cheap: same table, different filter.
- **P1 (F65)** Every ranking command fails soft in French on the same outcomes
  the rest of the bot handles (`unavailable`, no current season, profile not
  bound, wrong channel). **Never let a ranking command raise** — same rule as
  `/ots`; new failure modes get new named statuses, not exceptions.

### 31.9 Configuration

- **Two new environment variables**, neither a secret: `RANKING_CHANNEL_ID`
  (F75) and `ORGANIZER_DISCORD_ID` (F77). Both are Discord snowflakes and may
  safely appear in logs and documentation, unlike every other var in `.env`.
  - Both validated at boot by `validate_config()` alongside the existing four
    (F19). `ORGANIZER_DISCORD_ID` especially: a bot that starts with a wrong
    organizer id has silently locked its operator out of the only commands that
    can unblock a player mid-event.
  - `.env.example` gains two placeholder lines; `DEPLOYMENT.md` documents both.
- **No new secrets.** The freeze reuses the Edge Function's existing Supabase and
  Challonge credentials; the read commands reuse `bot.py`'s existing service-key
  path.
- **`on_ready` guild sync registers six commands** — `/ots` (F76),
  `/ots-organizer` (F78), `/link-organizer` (F58), `/unlink` (F69),
  `/standings` and `/profile` (F75). Two of the six must be invisible to
  non-organizers.
- **Command and parameter names are English; every user-facing string stays
  French.** Decided 2026-08-16 during the RFC-011–014 breakdown, superseding the
  French working names this document originally used (`/ots-organisateur`,
  `/classement`, `/profil`). `ots` is itself English — it stands for *open team
  sheet* — so the whole surface is now consistent: `/ots`, `/ots-organizer`,
  `/link-organizer`, `/unlink`, `/standings`, `/profile`, with parameters
  `name`, `user`, `confirm_rebind`, `confirm`, `tournament`. This is the same
  split RULES §3 already draws — internal identifiers English, user-visible copy
  French — extended to the command surface. Descriptions, replies and error
  messages remain French without exception.

## 32. Non-Functional Requirements

- **Read latency:** leaderboard and history commands stay within the existing 5s
  bounded-read budget (`PRD.md` §6). Both are single indexed queries over a table
  bounded by (players × events per season). Both **defer immediately, before any
  I/O**, exactly as `/ots` does — F18's rule is not `/ots`-specific.
- **Render safety is not optional.** The leaderboard is the second place in this
  project emitting variable-length text into a Discord embed; F70's cap applies
  for the same reason F14's does. An oversized description is rejected outright,
  which presents to a player as the command silently failing.
- **Fail-soft, always.** A ranking outage must never affect `/ots`. The new
  commands are independent read paths.
- **Fail-closed on authorization.** Where an authorization check can fail, it
  must fail toward denying the organizer a tool rather than granting a player
  access (F78).
- **French throughout**, per `CLAUDE.md` conventions.
- **Durability over convenience.** Frozen results are the one place in this
  system where data loss is unacceptable. Roster typos are recoverable; a deleted
  season of standings is not.
- **Privacy.** `discord_user_id` is the first genuinely personal data this
  project holds; retention and erasure are specified in F69.
- **Pure logic is unit-tested with no network**, matching the `test_bot.py` and
  `mapping_test.ts` discipline. The points formula is the single most test-worthy
  function in the release: pure, where the product's meaning lives, and the only
  new code whose bugs stay invisible until someone disputes a standing.

## 33. User Journeys

### Journey I — Organizer opens a season (once per season)
Create the season row in Studio with its date bounds. Nothing else changes until
the first event of that season is created.

### Journey J — Organizer binds a player (once per person)
Run `/link-organizer <ingame_name> <@user>`, selecting the account from the
native picker. The bot creates the profile if needed, links the roster row,
backfills that player's current-season results, logs what it moved, and confirms
in French. The player never touches it again — later tournaments' roster rows
auto-link by name. Steady state is one binding per newcomer.

### Journey K — Player looks up their opponent
Player runs `/ots`, no argument. The bot defers, resolves their bound profile,
finds their `open` match in the Challonge cache, resolves the opponent, and DMs
the OTS embed (ephemeral in-channel if DMs are closed). They cannot look up
anyone else.

### Journey L — Organizer closes an event (once per tournament)
The bracket finishes in Challonge. The organizer runs the same refresh trigger
from v3.0's Journey F. The sync sees every match complete, confirms `state =
'complete'` with one extra call, freezes results, and sets `completed_at`.
Standings update immediately. **No new organizer action at close time.**

### Journey M — Player checks standings
`/standings` in the ranking channel for the season leaderboard; `/profile` for
their own history with placements and points per event.

### Journey N — A freeze was wrong
1. Organizer discovers the error — a late DQ, a Challonge result corrected after
   the fact, a wrong `tier_id`.
2. They fix the underlying cause: the bracket in Challonge, or the `tournaments`
   row in Studio.
3. They re-run the trigger **with `"refreeze": true`**. Results are recomputed
   and overwritten, `frozen_at` updates, `freeze_count` increments.
4. Standings correct themselves on the next read. Nothing is retained about the
   superseded values beyond the incremented count.

### Journey O — Organizer forgot `season_id` before closing
The trigger writes nothing and leaves `completed_at` null, reporting why. The
organizer sets `season_id` in Studio and triggers again; the freeze runs
normally. **Nothing is lost**, because F55 ties `completed_at` to the freeze
actually happening.

### Journey P — Organizer debugs a player's complaint
A player reports that `/ots` isn't working. The organizer runs
`/ots-organizer <that player's name>` and sees exactly what the bot resolves
for them — including when the player is unbound, which is the most likely cause
and is fixed with one `/link-organizer`.

### Journey Q — Player leaves the community
The player runs `/unlink` and confirms the warning that it also disables `/ots`.
Their profile and Discord id are deleted; their frozen results are anonymized in
place, keeping other players' standings intact. Re-binding later starts a new
profile.

## 34. Success Metrics

| Metric | Target | How measured |
|--------|--------|--------------|
| `/ots` scouting leak | **Closed** — `/ots` accepts no argument; typed-name lookup exists only organizer-gated | §41 scenarios **25 and 29** together; a suite passing with either failing means the release's security goal was not met |
| Players bound before round 1 | **100 %** | Pre-flight check: every roster row has a `profile_id` |
| One-time bindings to reach steady state | ~14, then 1 per newcomer | F60's forward auto-link is what keeps this from being per-event |
| New organizer actions at event close | **0** | Journey L: the trigger command is byte-identical to v3.0's |
| New organizer actions at event setup | **2 fields** (`event_date`, `tier_id`) + 1 row per season | Runbook §9 walkthrough, timed against `PRD.md` G2's 5-minute budget |
| Challonge API calls per invocation | **2**, plus **1** when the completion check is armed (≈ once per event) | F68 |
| Challonge calls per event vs. the 500/month cap | ≤ 16 for a 7-round event | Rounds × 2 + 1 |
| New secrets / services / runtimes / Python deps | **0** | §31.9, §39 |
| New env vars | **2**, both non-secret | §31.9 |
| Standings correctness after a freeze | 100 % match against Challonge's final bracket | Organizer compares `/standings` to Challonge once per event |
| Freeze corrections needed | ≤ 1 per season | `max(freeze_count)`; a high value means `final_rank` is not behaving as verified |
| Ranking-command failures reaching a player as a crash | **0** | F65 |

## 35. Timeline & Sequencing

**No delivery date is set**, consistent with v3.0's posture (`PRD.md` §22).
Strictly sequential, same discipline as v2.0 and v3.0.

| Step | Milestone | Gate |
|------|-----------|------|
| 0 | Challonge `final_rank` verification | ✅ **Complete 2026-07-31** — see F54 |
| 1 | RFC-011 — ranking schema | `schema.sql` applies idempotently; invariants proven by its verification block, as RFC-001/007 did |
| 2 | RFC-012 — points engine + freeze | Deno tests green; call-count invariant re-verified and `RULES.md` §18 / `PRD.md` §21 reworded; freeze proven idempotent *and* re-freezable; group-stage boundary refused |
| 3 | RFC-013 — binding, `/ots` refactor, debug lookup | `test_bot.py` green; all F59 branches exercised; all nine `/ots` statuses covered; typed-name form provably absent from `/ots` |
| 4 | RFC-014 — read commands, runbook §9, `E2E-CHECKLIST-v4.md`, release | §41 passes in full; four status trackers updated per `CLAUDE.md` convention |

**Opportunistic and non-blocking:** read `participants.json` once during an
*in-progress* event to confirm `final_rank` is null before completion. Nothing
depends on the answer — F68 was designed not to.

## 36. Assumptions

- Tournaments continue to run in Challonge, and the v3.0 sync pipeline stays
  live and healthy.
- **Roster name discipline continues.** The organizer keeps `players.ingame_name`
  identical to the Challonge participant name. This was already load-bearing in
  v3.0; F60's forward auto-link makes it doubly so, since it keys on the
  normalized name.
- The organizer reliably sets `event_date` and `tier_id` at tournament creation.
  Forgetting `season_id` is recoverable (Journey O); it still warrants a
  pre-flight check.
- The organizer binds every entrant before round 1. This is the release's main
  **operational** risk, and G16 measures it.
- The community is small enough that Supabase and Challonge free-tier limits
  remain non-issues.
- Players accept that their in-game name and placement appear in a public
  standings table — already true of the Challonge bracket, but v4.0 is the first
  time this bot republishes it.
- Announcing the `/ots` change is a release requirement, as v3.0's was.

## 37. Decisions (locked for build)

Reopening any of these is a scope change.

| Area | Decision |
|---|---|
| Points curve | Fixed placement table × tier multiplier — 100/70/50/30/15/5. Bucket edges aligned to elimination rounds so tied ranks pay equally. No field-size term |
| Event weight | `tournament_tiers` lookup with `tournaments.tier_id`; frozen results snapshot the resolved multiplier |
| Freeze location | Edge Function (TypeScript), `points.ts` + `points_test.ts` |
| Completion detection | Two unconditional Challonge calls plus a conditional third; never derived from cached matches alone |
| Corrections | Explicit `refreeze: true` flag, recorded via `frozen_at` + `freeze_count` |
| Frozen-result key | `(tournament_id, challonge_participant_id)`, `player_id` nullable — the bracket decides who earned a result |
| Identity binding | Organizer-only, one-time per person, forward auto-link by normalized name. No self-service claim |
| `/ots` | No argument; caller inferred from bound profile. Typed-name lookup survives only as a separate organizer-gated command |
| Unbound players in standings | Shown and ranked by in-game name, no mention |
| Binding backfill scope | Current season only, every propagation logged |
| Season-points tie-break | Points → most events played → best finish → `profile_id` |
| Participation floor | None — one event is enough |
| Season rollover | Silent; no ceremony, no snapshot step (F67 already makes standings reconstructible) |
| Ranking-command visibility | Restricted to one configured channel; `/standings` public within it, `/profile` ephemeral |
| Adoption lever | Organizer announcement — operational, no code |
| Season date bounds | `daterange(..., '[]')`; no `btree_gist` |
| Authorization model | A single `ORGANIZER_DISCORD_ID`, plus `default_member_permissions`. No Discord roles |

### Known unknowns (non-blocking)

1. **Is `final_rank` null before a tournament completes?** Unverifiable from a
   completed bracket. F68 was deliberately written not to depend on the answer.
2. **What Challonge reports for a disqualified or forfeited entrant.** No DQ has
   occurred yet. F74 establishes what the signal is *not*; the freeze handles it
   safely either way by never filtering the participant list.

## 38. Contingency & Rollback

- **A player is unbound at round 1.** The live-event failure this design creates.
  `/link-organizer` fixes it in ten seconds from a phone. Pre-flight makes it
  rare; F61's move out of Studio makes it survivable when pre-flight was skipped.
- **`ORGANIZER_DISCORD_ID` is wrong in production.** The operator loses both
  organizer surfaces at once, since they share one gate. F19 catches a malformed
  value but not a valid-but-wrong one — so pre-flight should include running
  `/link-organizer` once, idempotently, on an already-bound player. Cheap, and it
  proves the authorization path before an event depends on it.
- **A freeze produced wrong points.** Journey N. This is the designed path, not
  an emergency.
- **The points formula itself turns out wrong** after several events froze.
  `formula_version` identifies the affected rows and F72 recomputes them one
  tournament at a time. Deliberately not automatic: a bulk re-freeze across a
  season visibly changes published standings and is an organizer decision.
- **Challonge unreachable at close time.** The freeze doesn't run, `completed_at`
  stays null, the organizer retries. No partial state, because F55 ties
  `completed_at` to the freeze succeeding.
- **The leaderboard is unavailable during an event.** Nothing breaks. Ranking is
  not a live-event dependency the way `/ots` is; the correct response is
  "standings later," which is how the community operated before v4.0.
- **A bad binding gave someone else's access or history.** F61 rebinds; F60's
  mandatory log identifies what moved. Bounded to one season.
- **The `/ots` refactor proves unworkable mid-event.** There is no operational
  fallback: pairings can be announced by hand, team sheets cannot. Break-glass is
  redeploying the previous `bot.py` from git (v2.0 §12's philosophy), which
  restores `/ots <name>` **and the scouting leak with it**. Accept that trade
  knowingly rather than discovering it under pressure.
- **Full back-out.** Remove the ranking commands and leave the tables. Note that
  unlike prior releases `/ots` is **not** untouched, so a full back-out reverts a
  player-facing contract as well. The only irreversible residue is frozen results
  already written, which are inert if nothing reads them.

## 39. Dependencies & Migration

- **Depends on:** v3.0 shipped and E2E-signed-off (✅ 2026-07-31); the RFC-008
  Edge Function.
- **No new external services, runtimes, secrets, Python dependencies, or
  Postgres extensions.** Two new non-secret env vars (§31.9).
- **Migration — purely additive DDL:**
  - one new column on `players` (`profile_id`);
  - four on `tournaments` (`event_date`, `season_id`, `tier_id`,
    `completed_at`);
  - four new tables (`profiles`, `seasons`, `tournament_tiers`,
    `tournament_results`);
  - guarded seed inserts for the three tiers.
  No existing column changes type or meaning and no existing query needs
  rewriting. `schema.sql`'s idempotent-apply contract must be preserved
  (`if not exists` / `add column if not exists` / guarded inserts).
- **The one non-additive change is F48's `on delete restrict`**, which alters an
  operational procedure (test-tournament cleanup) rather than any data.
- **Documents this release amends:** `.claude/RULES.md` §18 and `PRD.md` §21
  (the Challonge call-count invariant, F68); `E2E-CHECKLIST-v3.md` (scenarios
  keyed to a typed `/ots` argument are superseded by F76 and must be struck, not
  left silently failing); `RUNBOOK.md` (new §9); `DEPLOYMENT.md` (two env vars);
  `FEATURES.md` (F38–F78).

## 40. RFC Breakdown

Continuing from RFC-010. Each depends on the previous.

| # | RFC | Features | Complexity |
|---|-----|----------|------------|
| **011** | Ranking Schema — profiles, seasons, tiers, results, invariants, snapshot | F38–F50, F66, F67, F69 (DDL) | Medium |
| **012** | Points Engine & Sync Freeze | F51–F57, F68, F72, F74 | High |
| **013** | Identity Binding, `/ots` Refactor, Debug Lookup | F58–F61, F69 (commands), F71, F76, F77, F78 | High |
| **014** | Ranking Read Commands, Runbook & Release | F62–F65, F70, F73, F75 | Medium |

**Nothing is blocked.** Every decision this design needs is in §37.

RFC-013 carries the release's only breaking change and its security goal. If it
grows unwieldy, the natural split is RFC-013 (identity) / RFC-015 (`/ots`
refactor) — but they share a schema seam and a release announcement, so keep them
together unless the reviewer objects.

RFC-012 inherits two obligations beyond its features: reword the call-count
invariant in `RULES.md` §18 and `PRD.md` §21, and comment F74's `active` trap at
the mapping site the way the dual-id trap already is in `mapping.ts`.

Per `PRD.md` §24 item 8's convention, each RFC restates its own acceptance
criteria rather than only pointing back here.

## 41. Release Gate (`E2E-CHECKLIST-v4.md`)

**P0 (F73)** — the primary release gate, mirroring the v2.0 (F37) and v3.0 (9/9)
pattern. French, as with `E2E-CHECKLIST-v3.md`. Must pass in full before deploy.

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `E2E-CHECKLIST-v3.md` re-run, **minus scenarios keyed to a typed `/ots` name** | Everything downstream of opponent resolution still passes: embed build, DM delivery, DMs-closed fallback, render-safety, staleness warning. The typed-name scenarios are superseded and struck from that document |
| 2 | `/link-organizer` with a valid name and mentioned user | Binds; French confirmation; `profile_id` set |
| 3 | `/link-organizer` repeated, same name and user | Idempotent success, not an error |
| 4 | `/link-organizer` on a name absent from every roster | Distinct French rejection |
| 5 | `/link-organizer` for a player absent from the active event but present earlier in the season | Succeeds (F71) |
| 6 | `/link-organizer` on a name bound to another account, without confirmation | Refused; with explicit confirmation, rebinds and logs (F61) |
| 7 | `/link-organizer` run by a non-organizer | Refused, and absent from their command list (F77) |
| 8 | Bind, then check the player's history | Prior in-season results attributed; backfill logged (F60) |
| 9 | Bind a player, then create a roster row for them in a **new** tournament | `profile_id` auto-links forward; `/ots` works without rebinding (F60) |
| 10 | Freeze a completed tournament with a `season_id` | Results written, `completed_at` set, 2 + 1 Challonge calls |
| 11 | **Trigger at the group-stage boundary** — all cached matches complete, final bracket not yet generated | **Nothing frozen.** The third call reports a non-complete state and the freeze is refused. The single most important row in this table |
| 12 | Freeze a group-stage tournament, then compare against Challonge | Every entrant present including non-qualifiers; tied ranks pay equally; nobody dropped for `active: false` (F74) |
| 13 | Re-trigger the same tournament, no flag | Cache refreshes, results untouched, response says skipped (F56) |
| 14 | Re-trigger with `"refreeze": true` | Results recomputed, `freeze_count` incremented (F72) |
| 15 | Trigger a completed tournament with `season_id IS NULL`, then set it and retrigger | Nothing frozen first time, `completed_at` still null, freeze succeeds second time (Journey O) |
| 16 | Freeze a tournament that is **not** `is_active` | Succeeds — the trigger takes an explicit `tournament_id` |
| 17 | `/standings` with a full season of results, in the configured channel | Public reply; correct order and tie-break; capped at 25 with a French total footer (F70) |
| 18 | `/standings` with an oversized field | Renders within Discord's 4096-char limit — no silent failure |
| 19 | `/standings` or `/profile` in any other channel | Distinct French refusal; no standings leaked (F75) |
| 20 | `/standings` and `/profile` outside any season | Distinct French messages, no crash (F66) |
| 21 | `/profile` in the configured channel | Ephemeral — visible only to the caller (F63) |
| 22 | `/profile` by an unbound player | Distinct French message pointing at the organizer (F65) |
| 23 | Supabase unreachable during `/standings` | French fail-soft, no exception (F65) |
| 24 | `/ots` with no argument, bound player, open match | Opponent's OTS by DM — v3.0's happy path via the new entry point (F76) |
| 25 | `/ots <a name>` attempted as a player | **The command accepts no argument at all** — not "rejects it". Proves the scouting leak is closed |
| 26 | `/ots` by a player with no profile | Distinct French `not_linked` message pointing at the organizer |
| 27 | `/ots` by a bound player with no roster row in the active tournament | Distinct French `not_in_tournament` message |
| 28 | All nine `/ots` fail-soft statuses | Each has its own French message; none raises |
| 29 | `/ots-organizer <name>` as a non-organizer | Refused, and absent from their command list (F78) |
| 30 | `/ots-organizer <name>` as the organizer | Returns that player's current opponent ephemerally; logs the call |
| 31 | `/ots-organizer` on an **unbound** player | Works — must not require a `profile_id` |
| 32 | `/unlink`, then `/ots` | Confirmation warned that `/ots` would stop working; it does; organizer restores in one command (F69) |
| 33 | `/unlink`, then `/standings` | Profile gone; frozen results anonymized and still counted in totals |
| 34 | Boot with either new env var missing or malformed | Refuses to start with a clear log (F19) |
| 35 | All six commands appear after `on_ready` sync | The two organizer-only ones hidden from ordinary members |
| 36 | Pre-flight: a roster row with a null `profile_id` | Caught before round 1, not during it (G16) |

**Sign-off convention:** on release, update the status in **all four** places
`CLAUDE.md` requires — the RFC's Completion record, `RFCS.md`, `PRD.md`, and
`CLAUDE.md`.
