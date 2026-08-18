# RFC-012 — Points Engine & Sync Freeze

- **Status:** 📝 Draft — not started
- **Implementation order:** 12 of 14 (v4.0) — depends on RFC-011 and on all of
  v2.0/v3.0
- **Complexity:** High
- **Features covered:** F51, F52, F53, F54, F55, F56, F57, F68, F72, F74
- **Grounding:** `knowledge/PRD.v4.final.md` §31.4, §31.5 (including the
  seven-step freeze algorithm), §34, §37; `knowledge/FEATURES.md` §O, §P
- **Builds upon:** RFC-008 (the `challonge-sync` Edge Function this extends —
  its handler, its `mapping.ts`/`mapping_test.ts` split, its secret gate, its
  upsert helper), RFC-011 (`tournament_results`, `tournament_tiers`,
  `tournaments.season_id` / `.tier_id` / `.completed_at`)
- **Built upon by:** RFC-013 (backfill-on-bind attributes the rows this RFC
  writes), RFC-014 (both read commands read them)

---

## 1. Summary

Teach the `challonge-sync` Edge Function to **freeze a tournament's results**
when — and only when — that tournament is genuinely complete: carry
`final_rank` through from Challonge, compute points from a pure placement
table × the event's tier multiplier, and write one `tournament_results` row per
bracket participant with a full snapshot of every input the points depended on.

This is the highest-risk RFC in v4.0 and the reason is narrow: **the freeze is
one-way by default (F56), and the obvious way to detect completion is wrong
(F68).** Deriving "the tournament is over" from "all cached matches are
complete" fires at the *group-stage boundary*, before the final bracket's
matches exist in `matches.json` at all — freezing half an event, irreversibly,
under the default mode. A conditional third Challonge call is what closes that
hole.

No new organizer action ships with this RFC. The freeze rides the exact same
`curl` the organizer already runs after every round (v3.0's Journey F), which
is why PRD G12 can claim zero new close-time actions.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F54** | `mapParticipant` extended to carry `final_rank` from `participants.json`. Ranks are competition-style **with ties and gaps** (`1,2,3,3,5,5,5,5,9,10,…`) — never a dense 1..N sequence. |
| **F74** | `participants[].active` **must never be used to filter the field.** It tracks *still advancing*, not *validly entered*: it is `false` for every group-stage non-qualifier. Freeze the whole participant list. |
| **F51** | `awarded_points = multiplier × table(final_rank)`, table = 100 / 70 / 50 / 30 / 15 / 5 at bucket edges 1 / 2 / 3 / 5 / 9 / 17. Evaluated **once**, at freeze time, and stored. |
| **F52** | The formula lives in pure, unit-tested, I/O-free logic: `supabase/functions/challonge-sync/points.ts`, tested by a new `points_test.ts` joining the existing Deno suite. |
| **F53** | *(P1)* `formula_version` stored alongside each frozen result, so a future rule change is auditable and old results are explicable. |
| **F55** | The freeze runs only when `season_id` is non-null, and `completed_at` is set **only when the freeze actually runs** — making a forgotten `season_id` recoverable (Journey O), not permanently lossy. |
| **F68** | Completion confirmed by a **conditional third Challonge API call** to `/tournaments/{id}.json`, fired only when every cached match reads `complete`. Amends the "exactly 2 calls" invariant in `RULES.md` §18 and `PRD.md` §21. |
| **F56** | The default freeze is idempotent and one-way: re-triggering an already-frozen tournament does not rewrite results. |
| **F72** | Two-mode freeze. Default `{"tournament_id": X}` skips a frozen tournament; explicit `{"tournament_id": X, "refreeze": true}` recomputes, overwrites, updates `frozen_at`, increments `freeze_count`. |
| **F57** | A bracket participant with no `players` row still gets a frozen result — `player_id` stays null. Placement is independent of whether an OTS was submitted. |

## 3. Technical approach

### 3.1 Where the code goes

```
supabase/functions/challonge-sync/
  index.ts          MODIFIED — freeze orchestration bolted onto the existing handler
  mapping.ts        MODIFIED — final_rank on ParticipantCacheRow-adjacent types (F54, F74 comment)
  mapping_test.ts   MODIFIED — final_rank + ties/gaps cases
  points.ts         NEW      — pure points logic (F51, F52, F53)
  points_test.ts    NEW      — the release's most test-worthy function
```

`bot.py` is **not touched by this RFC.** Not one line. The freeze lives in the
Edge Function because that is where `final_rank` arrives and because giving the
bot a bulk write path over Challonge-derived data is the larger architectural
break (F52, locked in PRD §37).

### 3.2 The points engine (`points.ts`, F51/F52/F53)

Pure, no imports, no I/O — the TypeScript sibling of `normalize_name`,
`render_team_text`, `pick_opponent_id` and `is_cache_stale`.

```ts
export const FORMULA_VERSION = "v1";

// F51. Bucket edges sit on 1 / 2 / 3 / 5 / 9 / 17 — exactly where single-elim
// tie ranks land. THAT ALIGNMENT IS THE WHOLE POINT: it is what makes
// Challonge's tied placements pay their members equally, automatically.
//
// DO NOT "simplify" this into a linear formula. multiplier × (N − rank + 1)
// opens holes at ranks 4 and 6–8 (which competition-style ranking never
// emits) and pays only three points between 2nd and 5th. Verified against
// real data — see the fixture in points_test.ts.
//
// No field-size term: `multiplier` already encodes how big a deal the event
// was, and a second scaling axis makes the number unexplainable to a player
// who asks why they got 30.
const PLACEMENT_TABLE: ReadonlyArray<{ minRank: number; points: number }> = [
  { minRank: 17, points: 5 },   // participation floor
  { minRank: 9,  points: 15 },
  { minRank: 5,  points: 30 },
  { minRank: 3,  points: 50 },
  { minRank: 2,  points: 70 },
  { minRank: 1,  points: 100 },
];

export function basePointsForRank(finalRank: number): number { … }
export function awardedPoints(finalRank: number, multiplier: number): number { … }
```

`basePointsForRank` walks the table from the top edge down and returns the
first bucket whose `minRank <= finalRank`. A rank below 1, a non-integer, or a
non-finite value **throws** — it means Challonge's shape changed, and step 6 of
the algorithm already refuses that case loudly rather than storing a guess.

`awardedPoints` multiplies and rounds to 2 decimal places, matching
`tournament_results.awarded_points`'s `numeric(8,2)`. With today's three tiers
every product is a whole number; the rounding exists so a future `2.5`
multiplier cannot produce a value the column silently truncates differently
than the code believes.

Also pure, and also in `points.ts` because it belongs to the same "decide,
don't fetch" layer:

```ts
export function allMatchesComplete(states: readonly string[]): boolean;
// true only if states is non-empty AND every entry === "complete".
// An EMPTY match list must return FALSE: a freshly-created bracket with no
// matches would otherwise vacuously read as "complete" and arm the third call.
export function findNullFinalRanks(participants): { id: number; name: string }[];
```

### 3.3 `mapping.ts` — `final_rank` and the `active` trap (F54, F74)

```ts
export interface RawChallongeParticipant {
  id: number;
  name: string;
  group_player_ids?: number[] | null;
  // F54. Competition-style, WITH TIES AND GAPS: a real 14-player group-stage
  // event returned 1, 2, 3, 3, 5, 5, 5, 5, 9, 10, 11, 12, 13, 14 — ranks 4,
  // 6, 7 and 8 simply do not exist. NOTHING may treat this as a dense 1..N
  // sequence, index into an array by it, or assume max(rank) === count.
  // Non-null for every participant on a complete tournament, including those
  // who never reached the final bracket. Verified live 2026-07-31 against
  // Challonge tournament 18251698.
  final_rank?: number | null;

  // F74 — TRAP. Challonge also sends `active`. It is DELIBERATELY NOT TYPED
  // HERE so no one can filter on it by accident.
  //
  // `active` tracks STILL ADVANCING, not VALIDLY ENTERED. On that same live
  // tournament it was false for all six group-stage non-qualifiers and true
  // for the eight who advanced — so the natural-looking "skip inactive
  // participants" filter silently drops 43 % of the field, and precisely the
  // lower-placed players the participation floor (F51) exists to reward.
  // Freeze the WHOLE participant list. If a genuine DQ/forfeit signal is ever
  // needed, it is not this field.
}
```

`final_rank` is carried on a **freeze-time view of the participant**, not added
to `ParticipantCacheRow` — `challonge_participants_cache` has no `final_rank`
column and RFC-011 did not add one, because the rank's durable home is
`tournament_results`. Introduce a small `mapParticipantForFreeze(raw)` returning
`{ challongeParticipantId, name, finalRank }` alongside the untouched
`mapParticipant`, so the cache-row mapping keeps its exact current shape and
`mapping_test.ts`'s existing assertions keep passing.

`group_player_ids` is a JSON array; every participant in the live check had
exactly one entry, matching the single-column shape. That is not guaranteed —
**log defensively if the array is ever longer than 1** (F54). This is a new
`console.warn` in `mapParticipant`'s caller, not a behavior change.

### 3.4 The freeze, in the handler (`index.ts`)

The existing handler's steps 1–6 (secret gate → body parse → env → resolve
tournament → 2 Challonge calls → map → upsert both caches) are **unchanged**.
The freeze is appended as step 7, after the caches are refreshed, so a freeze
refusal never costs the organizer their cache update.

Two request-shape changes:

```
POST {SUPABASE_URL}/functions/v1/challonge-sync
  header  x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET>
  body    {"tournament_id": <bigint>}                      -- default mode
  body    {"tournament_id": <bigint>, "refreeze": true}    -- explicit correction
```

`refreeze` is optional; anything other than the boolean `true` is treated as
absent, and a non-boolean value is a 400. **The flag is the safety property**
(F72): an organizer cannot corrupt frozen history by muscle-memory `curl`, and
can correct it by adding six characters they had to look up in RUNBOOK §9.

`resolveTournament()` widens its `select` — no extra round trip — to pull
everything the freeze needs at once:

```
select=id,challonge_tournament_id,season_id,completed_at,tier_id,tournament_tiers(multiplier)
```

PostgREST resource embedding on the `tier_id` FK returns the tier inline. If
`tournament_tiers` embeds as null while `tier_id` is non-null, that is a
schema-state anomaly → refuse the freeze and log, never default the multiplier
to 1.0.

### 3.5 The freeze algorithm (PRD §31.5, verbatim, short-circuiting)

```
1. Fetch participants.json + matches.json (2 calls, ALWAYS). Upsert both
   caches exactly as v3.0 does.               [unchanged existing code]

2. completed_at non-null AND no refreeze flag
     -> SKIP.  freeze.status = "already_frozen"           (F56)

3. season_id is null
     -> SKIP. Leave completed_at NULL. freeze.status = "no_season"   (F55)
        This is what makes Journey O recoverable: the organizer sets
        season_id in Studio and triggers again.

4. Any cached match state != "complete"  (allMatchesComplete === false)
     -> SKIP.  freeze.status = "in_progress"

5. All matches complete -> THIRD CHALLONGE CALL: GET /tournaments/{id}.json
     state != "complete"
       -> SKIP.  freeze.status = "not_yet_complete"       (F68)
          *** THIS IS THE GROUP-STAGE BOUNDARY. ***
          progress_meter: 100 and a non-null completed_at corroborate.

6. Any participant has a null final_rank
     -> REFUSE AND LOG LOUDLY. HTTP 500.                  (F54)
        An anomaly here means Challonge's shape changed; a PARTIAL freeze is
        worse than none, and under F56 it would be one-way.

7. Otherwise FREEZE. For EVERY participant — no filtering on `active` (F74):
     awarded_points = multiplier × table(final_rank)
     write tournament_results with the full F67 snapshot
     set frozen_at, set freeze_count, set tournaments.completed_at
```

Steps 2 and 3 are ordered as the PRD specifies. Note the consequence: a frozen
tournament whose `season_id` is later nulled still reports `already_frozen`, not
`no_season`. That is correct — the freeze already happened.

### 3.6 The write, in detail (step 7)

The freeze needs three reads and three writes, all PostgREST, all with the
service role key the function already holds:

**Reads**
1. `challonge_matches_cache?tournament_id=eq.X&select=state` — for step 4.
   Read from the cache the function just wrote, not from the in-memory rows, so
   the check reflects what actually landed.
2. `players?tournament_id=eq.X&select=id,ingame_name,profile_id` — to attach
   `player_id` and `profile_id` by normalized name (F57: a miss is normal and
   leaves both null).
3. `tournament_results?tournament_id=eq.X&select=freeze_count&limit=1` — the
   previous freeze count, `0` if absent.

**Writes**
1. **Upsert** all result rows on `tournament_id,challonge_participant_id` with
   `Prefer: resolution=merge-duplicates`, reusing the existing `upsertRows`
   helper.
2. **Prune** — `DELETE tournament_results?tournament_id=eq.X&challonge_participant_id=not.in.(…)`.
   Upsert-then-prune, in that order, so there is never a window where the
   tournament has no results. A prune that deletes anything is an anomaly (a
   participant vanished from a completed bracket) and gets a `console.warn`
   with the count.
3. **`PATCH tournaments?id=eq.X`** with `completed_at`. Set **last**: it is the
   idempotency latch, so it must not be set before the rows it claims exist.

`freeze_count` is uniform across a tournament's rows and is computed as
`previousCount + 1` (so a first freeze writes `1`). `frozen_at` is one
timestamp generated once per freeze and applied to every row, so a tournament's
rows always share it.

**On the absence of transactions.** PostgREST gives no cross-request
transaction, so a crash between write 1 and write 3 leaves rows written with
`completed_at` still null. That state is **self-healing**: the next default
trigger sees `completed_at` null, re-runs the freeze, and the upsert overwrites
the same rows with identical values. This is the one place where the default
mode's write is not strictly one-way, and it is deliberate — the alternative
(latch first) would leave a permanently half-frozen tournament that only
`refreeze` could fix. State this in a comment at the write site.

### 3.7 Response contract

Every path returns a `freeze` object so the organizer's `curl` output is
unambiguous:

```jsonc
// success
{ "status": "ok", "participants_synced": 14, "matches_synced": 26,
  "freeze": { "status": "frozen", "results_written": 14, "freeze_count": 1,
              "season_id": 2, "multiplier": 2.0, "total_points_awarded": 960 } }

// skipped (HTTP 200 — the CACHE SYNC SUCCEEDED, only the freeze stood down)
{ "status": "ok", "participants_synced": 14, "matches_synced": 26,
  "freeze": { "status": "already_frozen" | "no_season" | "in_progress"
                        | "not_yet_complete",
              "detail": "<one French-free, operator-facing English sentence>" } }

// anomaly (HTTP 500 — Challonge's shape changed)
{ "status": "error",
  "message": "freeze refused: 3 participant(s) have a null final_rank",
  "freeze": { "status": "refused", "reason": "null_final_rank",
              "participants": [ … ] } }
```

Skips are HTTP 200 because the sync itself succeeded and the organizer must not
read a normal mid-event trigger as a failure. The null-`final_rank` anomaly is
HTTP 500 because it is not a normal state and "log loudly" has to reach a human
who is looking at a terminal. Edge Function output is **English**, like every
operator-facing string in this repo — French is for players.

## 4. Data models / schema changes

**None.** RFC-011 created every column this RFC writes. If this RFC finds
itself needing a schema change, that is a signal RFC-011 was under-specified —
raise it rather than adding DDL here, so `schema.sql` keeps one v4.0 owner.

## 5. Interfaces exposed

- **HTTP:** the same endpoint and secret header as RFC-008, with one new
  optional body field, `refreeze: true`, and a new `freeze` object on every
  response. Backward compatible: an existing v3.0 `curl` keeps working
  unchanged and simply gains freeze behavior.
- **To RFC-013:** `tournament_results` rows carrying `profile_id` where the
  roster row was already bound at freeze time, and `null` where it was not —
  the rows backfill-on-bind (F60) later attributes.
- **To RFC-014:** `tournament_results` and, through RFC-011's view,
  `season_standings`. RFC-014 needs no knowledge of this RFC beyond "rows
  appear when the organizer closes an event."
- **Pure exports for reuse and test:** `FORMULA_VERSION`, `basePointsForRank`,
  `awardedPoints`, `allMatchesComplete`, `findNullFinalRanks`.

## 6. Acceptance criteria

> **Round 3 status note (2026-08-16):** the staged live group-stage
> walkthrough (§10.2) has now run, against a real Challonge tournament
> (`18374775`, group stages + single-elim final, 8 fake entrants) synced
> through the organizer's **local** Supabase stack. Every criterion below is
> now checked. Full evidence — the boundary's raw `/tournaments/{id}.json`
> body, the per-step response bodies, and the DB cross-checks — is in the
> Completion record's Round 3 entry. The one thing this walkthrough does
> **not** cover is a **deployed** function against a hosted Supabase project;
> that remains a separate operational step (see Tracked follow-ups).

- [x] **F51:** `basePointsForRank` returns 100/70/50/30/15/5 at ranks
      1/2/3/5/9/17; returns 50 for rank 4 and 30 for ranks 6–8 (ranks
      competition-style ranking never emits, but which must not fall through a
      hole); returns 5 for any rank ≥ 17; throws on 0, −1, 1.5 and NaN.
      Verified: `points_test.ts` — "every bucket edge and the rank either
      side" plus "throws on invalid rank".
- [x] **F51 (the real-data fixture):** tournament 3's rank vector
      `[1,2,3,3,5,5,5,5,9,10,11,12,13,14]` at multiplier 1.0 produces
      `100, 70, 50, 50, 30, 30, 30, 30, 15, 15, 15, 15, 15, 15` — **total
      480**, with every tied rank paying its members equally. This exact case
      is a test. Verified: `points_test.ts`'s "tournament-3 real-data fixture"
      test (and its 2.0-multiplier/960 sibling).
- [x] **F52:** `points.ts` imports nothing, performs no I/O, and is fully
      covered by `points_test.ts`; `deno test supabase/functions/challonge-sync/`
      runs both suites green. Verified: `deno test` — 35 passed, 0 failed
      (17 `points_test.ts` + 18 `mapping_test.ts`); `deno check` clean.
- [x] **F53:** every frozen row carries `formula_version = "v1"`.
      Verified: `points_test.ts`'s `FORMULA_VERSION is v1` test, and
      `FORMULA_VERSION` used verbatim in `runFreeze`'s row construction.
- [x] **F54:** `final_rank` is carried through from `participants.json`; ties
      and gaps survive untouched; no code path indexes an array by rank or
      assumes `max(rank) === participant_count`. Verified:
      `mapping_test.ts`'s tie/gap-vector and null/0/absent tests, plus code
      review of `basePointsForRank`'s table-walk (no array indexing anywhere).
      The separate, non-blocking question of whether `final_rank` is null
      *before* completion is an opportunistic live observation (§10.2), not
      this criterion.
- [x] **F74:** `active` appears nowhere in any filter, type, or condition — a
      `grep -n "active" supabase/functions/challonge-sync/` returns only the
      warning comments. Live-verified 2026-08-16: tournament `18374775` (8
      entrants, group stage + single-elim final) froze **all 8** entrants —
      `results_written (8) === participants_synced (8)` on every freeze,
      including participants who did not advance past the group stage.
      The exact `active:false` split among those 8 was not read from
      `participants.json` directly, but the equality of the two counts is
      itself the assertion this criterion makes: nothing filtered.
- [x] **F55:** triggering a complete tournament with `season_id is null` writes
      nothing, leaves `completed_at` null, and reports `no_season`; setting
      `season_id` and re-triggering then freezes normally (Journey O).
      Live-verified 2026-08-16: nulling `season_id` on the already-completed
      walkthrough tournament and re-triggering returned
      `{"status":"no_season","detail":"tournament has no season_id set"}` with
      `completed_at` confirmed still null and zero `tournament_results` rows;
      restoring `season_id` and re-triggering returned `"frozen"` with 8 fresh
      rows (`freeze_count` restarting at 1, since the rows had been deleted
      for this test).
- [x] **F68:** with every cached match `complete` but Challonge's tournament
      `state != "complete"`, **nothing is frozen** and the response says
      `not_yet_complete`; the third call fires only in that armed condition;
      total calls are 2 normally and 3 on the arming trigger.
      **Live-verified 2026-08-16 — the walkthrough's actual gate.** With all 8
      cached group matches `complete` but Challonge's final bracket not yet
      generated, the trigger returned
      `{"freeze":{"status":"not_yet_complete","detail":"Challonge reports state=group_stages_underway, progress_meter=0…"}}`,
      the function log printed `[freeze] completion check armed — third
      Challonge call for tournament 2 (Challonge id 18374775)` confirming the
      third call fired from exactly the one guarded call site, and zero
      `tournament_results` rows existed afterward. The raw
      `/tournaments/18374775.json` body captured at that exact moment is in
      the Round 3 Completion record entry below. Finalizing the group stage
      and re-triggering correctly returned to `in_progress` (no latch, no
      premature freeze) before the bracket was played out to completion.
- [x] **F56:** re-triggering an already-frozen tournament with no flag
      refreshes both caches, leaves every `tournament_results` row byte-identical
      (including `frozen_at` and `freeze_count`), and reports `already_frozen`.
      Live-verified 2026-08-16: re-triggering the frozen walkthrough tournament
      with no flag returned
      `{"freeze":{"status":"already_frozen","detail":"tournament was frozen at 2026-08-16T18:43:04.235+00:00…"}}`;
      all 8 rows confirmed still at `freeze_count = 1` afterward.
- [x] **F72:** re-triggering with `"refreeze": true` recomputes and overwrites
      every row, updates `frozen_at`, and increments `freeze_count` to 2.
      Live-verified 2026-08-16: after bumping the tournament's `tier_id` from
      Hebdo (×1.0) to Mensuel (×2.0) and re-triggering with `refreeze: true`,
      every row's `awarded_points` exactly doubled (e.g. rank 1: 100.00 →
      200.00; total 390 → 780), `freeze_count` became 2 with a new
      `frozen_at`, and — per the `[PLAN DECISION]` — `tournaments.completed_at`
      stayed pinned at its **original** timestamp rather than being
      overwritten.
- [x] **F57:** a bracket participant with no matching `players` row is frozen
      with `player_id` null, `profile_id` null, and the correct points; a
      roster-only name that never entered the bracket gets **no row at all**.
      Verified by code review (`runFreeze`'s `rosterByName` join is built only
      from `freezeParticipants`, never from `players`) and now also
      live-exercised: the walkthrough tournament had no matching `players`
      rows at all, and all 8 frozen rows correctly carry `player_id = null`,
      `profile_id = null`, with points computed correctly regardless.
- [x] **F67 (inherited):** every row carries the resolved `multiplier` (not
      `tier_id`), the tournament's `season_id`, `formula_version`, and
      `participant_count` equal to the number of rows written. Verified by
      code review of the row-construction map in `runFreeze`, by the local
      PostgREST shape check confirming the `tournament_tiers` embed resolves
      to a numeric `multiplier`, and live-confirmed against tournament
      `18374775`'s 8 rows: `multiplier` read 1.00 then 2.00 across the two
      freezes (never `tier_id`), `participant_count = 8` on every row, and
      `formula_version = "v1"` throughout.
- [x] **Docs:** `.claude/RULES.md` §18 and `PRD.md` §21 no longer state a flat
      "exactly 2 Challonge API calls per invocation." Verified: `RULES.md`
      §18 now reads "2 Challonge API calls per invocation, plus a conditional
      3rd…"; `PRD.md` §21's metrics row is amended with "plus one conditional
      third call… (F68, RFC-012 — amends this row's original flat ×2)"; the
      §22 "two opposing write semantics" addendum is also in place.
- [x] **Regression:** every v3.0 behavior is unchanged — both caches still
      upsert-never-append, `state` is still a strict enum, both Challonge calls
      still complete before any write begins, and an unlinked or unknown
      tournament still fails exactly as before. Verified: `python -m unittest
      test_bot` — 30 passed, unchanged (`bot.py` was not touched); the
      pre-existing cache-sync code path in `index.ts` is untouched by this
      RFC's additions.

## 7. Implementation details

### 7.1 Two inherited documentation obligations (PRD §40)

These are **deliverables of this RFC**, not nice-to-haves. Skipping them leaves
the release gate contradicting the code:

1. **Reword the call-count invariant** in `.claude/RULES.md` §18 and
   `knowledge/PRD.md` §21 — from "confirm exactly 2 Challonge API calls per
   invocation" to "2 per invocation, plus a conditional 3rd when the completion
   check is armed (≈ once per event); a 7-round event goes from ~14 to ~15
   calls against the 500/month cap." Also extend the RULES v4.0 addendum
   (created by RFC-011) with the two-opposing-write-modes warning from §8 below.
2. **Comment F74's `active` trap at the mapping site**, at the same depth and
   in the same place the dual-id trap already lives in `mapping.ts`. The bar is
   that a future reader adding a filter has to walk past the explanation.

### 7.2 Key algorithms

**`basePointsForRank` (F51)** — table walk, not arithmetic:
```
for bucket in PLACEMENT_TABLE (descending minRank):
    if finalRank >= bucket.minRank: return bucket.points
throw   # unreachable: minRank 1 catches everything >= 1; guard clause
        # rejects < 1 before the loop
```

**Attaching roster identity (F57)** — normalized-name join, bot-side semantics:
```
rosterByName = Map(players, key = lower(trim(ingame_name)))
for p in participants:
    roster = rosterByName.get(lower(trim(p.name)))
    player_id  = roster?.id      ?? null
    profile_id = roster?.profile_id ?? null
```
The normalization must match `bot.py`'s `normalize_name` exactly (`trim` then
`lower`) — same contract, third implementation site. Note it in a comment
pointing at `normalize_name`.

**Third-call arming (F68)** — the whole point is *when it does not fire*:
```
states = read challonge_matches_cache states for this tournament
if not allMatchesComplete(states): skip "in_progress"          # no 3rd call
tourney = GET /tournaments/{challongeTournamentId}.json
if tourney.state != "complete": skip "not_yet_complete"        # group boundary
```

### 7.3 Coding standards

- Standard TypeScript/Deno idioms (RULES §13) — PEP 8 does not apply here.
- No framework, no ORM, no second HTTP client: `fetch` only, matching RFC-008.
- No new secret and no new env var. The freeze reuses `CHALLONGE_API_KEY`,
  `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CHALLONGE_SYNC_SECRET`.
- Keep `index.ts` readable: the freeze is one `runFreeze()` function returning a
  discriminated union, called once from the handler. Do not thread freeze state
  through the existing sync code.

## 8. Edge cases & risks

- **The group-stage boundary (F68) — the single highest-risk item in v4.0.**
  A wrong answer freezes half an event's results one-way. In a group-stage
  tournament the final bracket's matches **do not exist in `matches.json` until
  the group stage is finalized**, so `allMatchesComplete` is `true` while half
  the event is unplayed. Never derive completion from the cache alone. E2E
  scenario 11 is the most important row in the release gate for this reason.
- **Two opposing write semantics now live in one function.** The cache tables
  are designed to be re-run constantly and overwritten; `tournament_results` is
  designed to be written once and never overwritten. **That seam is where bugs
  will live.** Keep `runFreeze()` textually separate from the cache-sync code
  and never share a helper that "just upserts" across both without the caller
  stating which semantics it wants.
- **Empty match list reads as complete.** `allMatchesComplete([])` must return
  `false`, or a freshly-created bracket arms the third call on its very first
  sync. Explicitly tested.
- **Rank 4 and ranks 6–8 do not exist in the wild but must still be defined.**
  A future Challonge change, a non-single-elim format, or a manually-edited
  bracket could emit them. The table covers them; the tests assert it.
- **`participant_count` counts frozen rows, not roster rows.** Tournament 3 had
  14 bracket entrants against 16 roster rows. The bracket decides (F47).
- **A prune that deletes rows is an anomaly, not routine.** It means a
  participant disappeared from a completed bracket between freezes. Warn with
  the count; do not fail.
- **Rounding.** `numeric(8,2)` in Postgres versus IEEE floats in JS: round in
  `awardedPoints` so the stored value is exactly the computed one. With `2.5 ×
  15 = 37.5` this matters; with today's tiers it does not, which is precisely
  why it will be forgotten if not done now.
- **Timezone of `frozen_at`.** Generated in the function as an ISO-8601 UTC
  string, not left to the column default, so all rows in one freeze share it
  exactly.
- **`refreeze` on a never-frozen tournament** is not an error — it takes the
  normal path and writes `freeze_count = 1`. Do not add a guard that rejects it;
  the organizer will use it that way under pressure.
- **Known unknown (PRD §37, non-blocking):** whether `final_rank` is null
  *before* a tournament completes is unverified — it cannot be observed from a
  completed bracket. **F68 was deliberately written not to depend on the
  answer**, and step 6 handles it safely either way. Do not add logic that
  assumes one behavior.
- **Known unknown (PRD §37, non-blocking):** what Challonge reports for a DQ or
  forfeit. F74 establishes what the signal is *not*. The freeze is safe either
  way because it never filters the participant list.

## 9. Applicable rules (RULES.md)

- **§1/§11 (dependency policy):** no new dependency in either runtime. The Edge
  Function stays on `fetch` and the Deno stdlib.
- **§12 (architecture):** `bot.py` still never talks to Challonge and gains
  nothing from this RFC. The cache tables — now plus `tournament_results` —
  remain the only interface between the two runtimes.
- **§13 (naming):** Challonge's `state` vocabulary and `final_rank` are external
  contracts, carried verbatim, never translated or remapped.
- **§14 (data handling):** cache upserts stay mandatory and all-or-nothing.
  **New, and opposite:** `tournament_results` is write-once by default —
  add this contrast to the v4.0 RULES addendum so the two are never conflated.
- **§18 (testing/quality gates):** **this RFC amends it.** The "exactly 2 calls"
  verification becomes "2, plus a conditional 3rd." The rest of §18's Edge
  Function verification posture (manual/operational, not a Python suite) holds.
- **§20 (still-open items / no silent resolution):** the two known unknowns in
  §8 above are flagged, not resolved. Do not build speculative DQ handling.
- **§10 (ask before touching locked decisions):** the placement table, the
  Edge-Function location of the freeze, the conditional third call, and the
  `refreeze` flag are all locked in PRD §37. "Simplifying" any of them is a
  scope change.

## 10. Testing strategy

### 10.1 Deno unit tests (the primary gate)

`points_test.ts` — the PRD calls this "the single most test-worthy function in
the release: pure, where the product's meaning lives, and the only new code
whose bugs stay invisible until someone disputes a standing."

- every bucket edge and the rank either side of it (1, 2, 3, 4, 5, 8, 9, 16,
  17, 100);
- the tournament-3 real-data fixture, asserting the full 14-element vector and
  the 480 total;
- tie equality — every member of a tied rank gets identical points;
- the multiplier axis — 1.0 / 2.0 / 3.0 and a non-integer 2.5;
- invalid input — 0, −1, 1.5, NaN, Infinity all throw;
- `allMatchesComplete` — all complete → true; one `open` → false; one `pending`
  → false; **empty → false**;
- `findNullFinalRanks` — none, one, several.

`mapping_test.ts` (extended) — `final_rank` carried through; null preserved as
null rather than coerced to 0; a `group_player_ids` array of length > 1 still
maps element 0 and triggers the defensive warning; and a regression assertion
that `mapParticipant`'s existing output shape is unchanged.

### 10.2 Operational verification — the staged group-stage walkthrough

Manual, mirroring RFC-008's posture. Count calls in the function logs at every
step.

**The method, agreed 2026-08-16.** The organizer sets up a **real Challonge
group-stage tournament populated with fake players**, then **advances it one
match at a time**, triggering the sync after each and inspecting the response
together with the implementer. This replaces stubbing or simulating the third
call: F68's failure mode only exists in the *transition* between phases, and a
completed bracket cannot reproduce it after the fact.

Set the tournament up to mirror the live-verified shape from F54 — group stages
enabled, enough entrants that some fail to qualify — so F74's `active: false`
population exists to be checked. Give it a `season_id` and a tier from the
outset, since Journey O is exercised separately in step 6.

The walkthrough, in order:

1. **Mid-group trigger** — some group matches still open → 2 calls,
   `in_progress`, nothing frozen. Repeat after each match; the answer must not
   change.
2. **THE GROUP-STAGE BOUNDARY (F68)** — every group match complete, final
   bracket **not yet generated in Challonge**. This is the step the whole
   walkthrough exists for. Expect **3 calls**, `not_yet_complete`, and
   **nothing written to `tournament_results`**. Capture the raw
   `/tournaments/{id}.json` body at this moment and record it in the Completion
   record — it is the evidence that the match check alone would have frozen
   here, and the only chance to capture it.
3. **Finalize the group stage in Challonge**, then trigger again → the final
   bracket's matches now exist and read `open`/`pending`, so the answer returns
   to `in_progress` with 2 calls. **A regression to `not_yet_complete` staying
   latched, or to a freeze firing, both fail this step.**
4. **Play out the final bracket**, triggering after each match, then trigger on
   the completed tournament → 3 calls, rows written, `completed_at` set.
   Compare every row against Challonge's final standings by hand: the tied
   ranks pay equally, the gaps at 4 and 6–8 are absent, and **every
   group-stage non-qualifier is present** (F74).
5. **Idempotency (F56)** — re-trigger, no flag → caches refresh, results
   untouched, `already_frozen`.
6. **Refreeze (F72)** — change the tier in Studio, re-trigger with the flag →
   points recomputed against the new multiplier, `freeze_count = 2`,
   `frozen_at` updated.
7. **Journey O (F55)** — null the `season_id`, clear `completed_at` and the
   result rows in Studio, trigger → `no_season`, `completed_at` still null;
   restore the season, trigger → frozen.
8. **Not active (E2E 16)** — deactivate the tournament, trigger → still
   freezes; the trigger takes an explicit `tournament_id`.

**Opportunistic, non-blocking (PRD §35):** while the tournament is still in
progress, read `participants.json` once and record whether `final_rank` is null
before completion. Nothing depends on the answer — F68 was designed not to —
but this walkthrough is the only occasion the project will have to observe it,
so capture it in the Completion record either way.

Steps 1–4 must be walked through **with the implementer present**, not
reported afterwards: the boundary in step 2 exists for one trigger only, and if
it is missed the tournament has to be rebuilt to see it again.

### 10.3 Fixtures before live data

RFC-011's `RFC-011 Test Season` + the seeded test tournament give this RFC a
freezable target with no live Challonge account, exactly as RFC-007's fixtures
de-risked RFC-009. Add matching cached participants with `final_rank` values
covering a tie and a gap so step 6 and F51 can be exercised end-to-end locally.

> ⚠️ Freezing the seeded test tournament makes it undeletable under F48. Expected,
> and the reason RUNBOOK §9 (RFC-014) documents the purge-first cleanup.

---

## Completion record

**Status (Round 4, 2026-08-17): ✅ COMPLETE.** `supabase functions deploy
challonge-sync` shipped the function to the actual hosted Supabase project
(`qvgnstyucqyhkluskcdc`), and a live trigger against a real, already-linked,
finished production tournament (`tournament_id: 3`, "Open Swiss 2",
Challonge id `18251698`) confirmed it: `{"status":"ok",
"participants_synced":14,"matches_synced":35,"freeze":{"status":"no_season",
"detail":"tournament has no season_id set"}}`. The `no_season` freeze outcome
is the correct, expected fail-soft result (F55) for this tournament — it
predates RFC-011's `season_id` column and was never assigned one — not an
error. This closes the one remaining item from Round 3: the deployed
function has now been triggered live against production, not just verified
against a local stack. See the Round 4 entry below for full detail.

**Status (Round 3, 2026-08-16): the staged live group-stage walkthrough has
run, against a real Challonge tournament, synced through the organizer's
local Supabase stack.** F68 — the highest-risk item in v4.0 and this RFC's
whole reason for existing — held under a live group-stage-to-final-bracket
transition. Every §6 acceptance criterion is now checked. **What remains
outstanding is deploying the function to the actual hosted Supabase
project** — this walkthrough was deliberately run entirely against a local
stack, per the user's explicit method — and the corresponding entry in
`RFCS.md`/`CLAUDE.md`'s four-place release ritual, which applies once that
deploy happens. See the Round 3 entry below for full evidence.

**Status (Round 2, 2026-08-16): code implementation is Round-2-complete;
F68 live verification and deployment remain deferred by explicit user
decision.** Round 2 addressed the two Round 1 improvement suggestions: a
crash-recovery asymmetry comment at the `tournament_results` write site
(`index.ts`), and reconciling §6's acceptance-criteria checkboxes against
what is actually verified (see below). **No production code behavior changed
in Round 2** — only a comment and documentation. The user has explicitly
decided to defer the staged live group-stage walkthrough (§10.2) and the
function deployment rather than run them in this round; this is a deliberate,
recorded decision, not an oversight or a failure of this round's work. **RFC-013
must not treat RFC-012's frozen `tournament_results` rows as trustworthy
output until that live walkthrough runs** — its own reader (`/standings`,
`/profile`, backfill-on-bind) inherits whatever the freeze actually wrote,
and F68 is the one failure mode that only manifests live.

**Status (Round 1, 2026-08-16): code + tests complete, live walkthrough not
yet run.** This RFC's code, unit tests, and local shape-check are done; the
staged live group-stage walkthrough (§10.2 — this RFC's actual gate for F68,
the highest-risk item in v4.0) requires a real Challonge account with fake
players, advanced one match at a time, with the implementer present, and was
not performed in this round. It cannot be simulated: the failure mode it
exists to catch only appears in the live transition between Challonge's
group stage and its final bracket. Treat F68 as **unverified against a real
group-stage tournament** until that walkthrough runs.

**Deliverables shipped**
- `supabase/functions/challonge-sync/points.ts` (new) — the pure points
  engine: `FORMULA_VERSION`, `basePointsForRank`, `awardedPoints`,
  `allMatchesComplete`, `findNullFinalRanks`. No imports, no I/O.
- `supabase/functions/challonge-sync/points_test.ts` (new) — 17 Deno tests:
  every placement-table bucket edge plus a rank either side, the
  tournament-3 real-data fixture (`[1,2,3,3,5,5,5,5,9,10,11,12,13,14]` at
  multiplier 1.0 totals exactly 480, at 2.0 totals 960), tie equality, the
  2.5 non-integer multiplier axis, the `5 × 1.33 = 6.65` rounding case,
  invalid-input throws, `allMatchesComplete([]) === false` as its own named
  test, and `findNullFinalRanks`'s input-order guarantee.
- `supabase/functions/challonge-sync/mapping.ts` (modified, additively) —
  `final_rank` and the F74 `active`-trap comment on
  `RawChallongeParticipant`; the new `FreezeParticipant` type,
  `mapParticipantForFreeze`, `hasAmbiguousGroupPlayerIds`, and
  `normalizeName` (the third trim-then-lower implementation site alongside
  `bot.py::normalize_name`). `mapParticipant`'s existing shape and the
  original 7 `mapping_test.ts` assertions are untouched.
- `supabase/functions/challonge-sync/mapping_test.ts` (extended) — 11 new
  tests (18 total): a full-object regression assertion that `final_rank`
  never leaks into `ParticipantCacheRow`, `mapParticipantForFreeze`'s
  null/0/absent handling and the tie/gap vector passing through untouched,
  `hasAmbiguousGroupPlayerIds`'s false/true cases (with `mapParticipant`
  still mapping element 0 on the ambiguous case), and `normalizeName` parity
  with `bot.py`.
- `supabase/functions/challonge-sync/index.ts` (modified) — widened
  `resolveTournament` (adds `season_id`, `completed_at`, `tier_id`, the
  `tournament_tiers(multiplier)` embed, with to-one/to-many normalization and
  a `null`-not-`1.0` multiplier fallback); new `fetchChallongeTournament`
  (the conditional 3rd call); `upsertRows`'s row union widened with
  `TournamentResultRow`; `refreeze` body-field parsing (F72); the
  `hasAmbiguousGroupPlayerIds` → `console.warn` line in the mapping loop; the
  new `runFreeze()` implementing the 7-step algorithm exactly in the PRD's
  order (already_frozen → no_season → in_progress → not_yet_complete →
  no_multiplier → null_final_rank → freeze-and-write); step 7 wiring and the
  `freeze` object on every response, with the `refused`/`third_call_failed`
  → HTTP 502 and every other `refused` → HTTP 500 mapping. Header comment and
  request-shape documentation updated in place.

**Verification performed**
- `deno test supabase/functions/challonge-sync/` — **35 passed, 0 failed**
  (17 `points_test.ts` + 18 `mapping_test.ts`, up from the prior 7).
- `deno check supabase/functions/challonge-sync/index.ts` — clean.
- `python -m unittest test_bot` — **30 passed, 0 failed**, unchanged
  (`bot.py` was not opened).
- `grep -rn "active" supabase/functions/challonge-sync/` — every hit is a
  comment; F74's trap holds with no filter, type, or condition referencing
  it.
- `grep -rn "TODO\|FIXME\|XXX"` across `bot.py`, `schema.sql`,
  `supabase/functions/` — no hits.
- **Local PostgREST shape check (§7.3a)**, against the running local stack
  (`supabase status`) and the seeded `RFC-001 Test Tournament` (id 1, already
  carrying `season_id`/`tier_id` from RFC-011's seed):
  - the widened `tournaments` select confirmed `tournament_tiers` embeds as
    a to-one **object** with a numeric `multiplier` (`1.0` for the seeded
    Hebdo tier);
  - a 3-row `tournament_results` upsert on
    `on_conflict=tournament_id,challonge_participant_id` with
    `Prefer: resolution=merge-duplicates` was run **twice** (HTTP 201, then
    HTTP 200) — the table held exactly 3 rows after both runs, no
    duplicates;
  - the prune `DELETE …&challonge_participant_id=not.in.(1001,1002)` with
    `Prefer: return=representation` correctly deleted and returned only the
    excluded row (`1003`/`koloina`);
  - the `PATCH tournaments?id=eq.1 {"completed_at": …}` latch applied
    cleanly (HTTP 204) and read back correctly.
  - **Cleanup performed**: the inserted `tournament_results` rows were
    deleted and `tournaments.completed_at` was reset to `null` afterward, so
    the seeded fixture is left exactly as `supabase/seed.sql` leaves it —
    freezable but not yet frozen — for RFC-013/014's own local testing.
    (F48's `on delete restrict` only blocks deleting the *tournament*, not
    its results, so this cleanup was possible without hitting that trap.)

**Deviations from the plan**
- **§10.9 / seed.sql**: confirmed and followed as planned — no fixtures were
  added to `supabase/seed.sql`. `challonge_participants_cache` has no
  `final_rank` column by design (RFC-011), and the freeze reads ranks from
  Challonge's live payload, not the cache; building a Challonge stub to close
  that gap would be exactly the abstraction the prime directive forbids.
  Everything a local fixture could exercise between algorithm steps 4 and 7
  is already covered by `points_test.ts`.
- **§10.10 / `completed_at` on a refreeze [PLAN DECISION]**: implemented
  exactly as the plan specifies — `completed_at` is set only when currently
  `null`; a refreeze leaves the original closure time intact and lets
  `frozen_at`/`freeze_count` carry the correction. Not yet exercised live
  (that requires the walkthrough's step 6).
- **§10.11 `findNullFinalRanks` widened predicate [PLAN DECISION]** and
  **§10.12 `hasAmbiguousGroupPlayerIds` as a pure predicate [PLAN
  DECISION]**: both implemented exactly as specified in the plan.
- **The staged live group-stage walkthrough (§7.3b / RFC §10.2) was not
  run in this round.** It requires a real Challonge account, a real
  group-stage tournament of fake players advanced one match at a time, and
  the user present for the one-shot group-stage-boundary trigger. Nothing in
  this round observed: the raw `/tournaments/{id}.json` body at the
  boundary, the actual Challonge call counts per trigger, or whether
  `final_rank` is null before completion (PRD §37's non-blocking known
  unknown). These remain open until that walkthrough runs — **flag, not
  silently resolve** (RULES §20).
- Deploying the function (`supabase functions deploy challonge-sync`) was
  likewise not performed in this round, since the live walkthrough that
  would exercise the deployed version hasn't run yet.

**Tracked follow-ups for Round 2 (or a dedicated verification pass)**
1. ~~Run the staged live group-stage walkthrough (§10.2)~~ — **done, Round 3
   (2026-08-16)**. See that section for the raw `/tournaments/{id}.json` body,
   per-step results, and the log-line fix. The one item it did not capture:
   the opportunistic `final_rank`-before-completion observation (PRD §35,
   explicitly non-blocking) — open for whoever next has a live tournament in
   progress to check.
2. **Deploy the function** (`supabase functions deploy challonge-sync`) to
   the actual hosted Supabase project, and re-verify with a live trigger,
   before RFC-013 starts depending on frozen rows produced against
   production. The Round 3 walkthrough verified the algorithm only against a
   local stack, by explicit user choice of method.

---

### Round 2 (2026-08-16)

**Reviewer's Round 1 blocking issues:** one item — run the live F68
group-stage-boundary walkthrough (§10.2) with the user present. **The user has
explicitly decided to defer this rather than run it in this round.** It is not
attempted here, per instruction: no deployment, no simulation of the
walkthrough. It remains the single tracked follow-up above.

**This round instead resolved the reviewer's two (non-blocking) improvement
suggestions:**

1. **Crash-recovery asymmetry comment** — `supabase/functions/challonge-sync/index.ts`,
   at the prune write site (step 2 of the writes, immediately before the
   `try` block that performs the `DELETE`). Documents that a crash between the
   upsert and the prune is self-healing on a **first freeze** (`completed_at`
   still null → next default-mode trigger reruns everything, matching the
   existing write-1/write-3 self-healing comment already at the
   `completed_at` latch), but is **not** self-healing on a **refreeze**
   (`completed_at` was already non-null *before* this call started, so it
   carries no information about whether this call's prune succeeded; the next
   default-mode trigger reads `already_frozen` and returns immediately,
   without retrying the prune). No code fix shipped — the comment states this
   is a known, accepted gap, and that closing it is a correctness question for
   a future RFC, not a hidden default here.
2. **Acceptance criteria (§6) reconciled** — every criterion actually verified
   by the Deno/Python test suites or the Round 1 local PostgREST shape check
   is now checked, with the specific test/verification cited inline. Every
   criterion whose verification requires the still-deferred live walkthrough
   (F55, F56, F68, F72, and half of F74) is left unchecked with an explicit
   `(deferred — requires the live walkthrough, §10.2 step N; see Completion
   record)` annotation naming which walkthrough step covers it, rather than
   left ambiguously unchecked as in Round 1.

**Verification performed (Round 2)**
- `deno check supabase/functions/challonge-sync/index.ts` — clean (comment-only
  change).
- `deno test supabase/functions/challonge-sync/` — **35 passed, 0 failed**,
  unchanged from Round 1 (no test or production-logic edit this round).
- `grep -rn "TODO\|FIXME\|XXX" bot.py supabase/functions/` — no hits.
- Confirmed `.claude/RULES.md` §18, `PRD.md` §21, and `RULES.md` §22 already
  carry the amended call-count wording and the two-opposing-write-modes
  addendum from Round 1 — no further doc change was needed there.
- `RFCS.md`'s RFC-012 status row updated to say "code complete (Round 2)"
  with the deployment/walkthrough deferral and the RFC-013 trust caveat
  spelled out explicitly.

**Explicitly NOT done this round, by the user's decision:**
- The staged live group-stage walkthrough (§10.2) — not run, not simulated.
- Deploying the function (`supabase functions deploy challonge-sync`) — not
  performed.
- No production code path was changed; the `index.ts` edit is a comment only.

**Status for RFC-013:** do not consume `tournament_results` rows produced by
a live trigger of this function as trustworthy until the walkthrough in the
tracked follow-up above has run. Rows produced against the seeded local
fixture (RFC-011's `RFC-001 Test Tournament`) remain fine for RFC-013/014's
own local development and testing, per the Round 1 cleanup note — that
fixture was never a stand-in for the live F68 verification.

---

### Round 3 (2026-08-16) — Live walkthrough

**Method (per the user's explicit instruction):** a real Challonge
tournament (id `18374775`, "Test Tournament", single-elimination final with
group stages enabled, 8 fake participants, game "Pokémon champions") was
created and piloted by the organizer. `challonge-sync` was served **locally**
via `supabase functions serve challonge-sync --no-verify-jwt --env-file
supabase/functions/challonge-sync/.env.local` against the organizer's local
Supabase stack (`supabase start`) — no hosted project was touched. A
dedicated local `tournaments` row (id `2`, name "RFC-012 Walkthrough
Tournament", `is_active = false` throughout) was inserted linking
`challonge_tournament_id = '18374775'` to RFC-011's seeded `RFC-011 Test
Season` and the Hebdo tier, so the seeded `RFC-001 Test Tournament` (id `1`)
was never touched by this walkthrough. The organizer ran every `curl`
trigger and Challonge-side action; the implementer read the JSON response
and the `supabase functions serve` logs after each and independently queried
the local Postgres (`psql`) to cross-check `tournaments`/`tournament_results`
state after every step.

**Steps 1–8, in order, all PASS:**

1. **Mid-group trigger.** Two triggers while group matches were still open
   (`2 of 8` then `1 of 8` cached matches incomplete) both returned
   `freeze.status: "in_progress"`; the answer held steady across the repeat,
   and `tournaments.completed_at` / `tournament_results` stayed empty both
   times.
2. **THE GROUP-STAGE BOUNDARY (F68).** With all 8 cached group matches
   `complete` but the final bracket not yet generated in Challonge, the
   trigger returned:
   ```json
   {"status":"ok","participants_synced":8,"matches_synced":8,
    "freeze":{"status":"not_yet_complete",
              "detail":"Challonge reports state=group_stages_underway, progress_meter=0 — the final bracket may not exist yet"}}
   ```
   The function log printed
   `[freeze] completion check armed — third Challonge call for tournament 2`
   (see the log-line fix below), confirming the third call fired from
   exactly its one guarded call site. Zero `tournament_results` rows existed
   afterward; `completed_at` stayed null. The raw `/tournaments/18374775.json`
   body captured at this exact moment (the one chance to see it):
   ```json
   {"tournament":{"id":18374775,"name":"Test Tournament","url":"y5lkhwq",
     "tournament_type":"single elimination","started_at":null,
     "completed_at":null,"state":"group_stages_underway",
     "progress_meter":0,"participants_count":8,
     "group_stages_enabled":true,"group_stages_were_started":true,
     "game_name":"Pokémon champions","participants_locked":true, … }}
   ```
   (truncated to the fields relevant to the boundary check; full body is in
   the session transcript). This is direct evidence that deriving
   completion from the cache alone would have frozen here — the cache said
   every match was `complete`, but Challonge's own `state` was not.
3. **Finalize the group stage, re-trigger.** The final bracket generated 1
   new match (`matches_synced` 8 → 9); the answer correctly returned to
   `"in_progress"` (`"1 of 9 cached matches are not complete"`) rather than
   staying latched on `not_yet_complete` or firing a premature freeze.
4. **Play out the final bracket, trigger on completion.** The closing
   trigger returned:
   ```json
   {"status":"ok","participants_synced":8,"matches_synced":9,
    "freeze":{"status":"frozen","results_written":8,"freeze_count":1,
              "season_id":1,"multiplier":1,"total_points_awarded":390}}
   ```
   Cross-checked by hand against the 8 written rows: final ranks
   `1,2,3,4,5,5,7,8` (a tie at rank 5 correctly produces a gap at rank 6, not
   ranks 6–8 — this bracket's tie shape differs from the F54 fixture's, and
   the table handled it correctly either way); points
   `100,70,50,50,30,30,30,30` sum to exactly **390**, matching
   `total_points_awarded`; rank 4 correctly shares rank 3's bucket (50, not a
   new value) and rank 7 correctly shares rank 5's bucket (30) — the
   "range-ladder, not linear" design working as specified. `participant_count
   = 8` on every row, matching `results_written`. `tournaments.completed_at`
   (`2026-08-16 18:43:04.235+00`) exactly matched every row's `frozen_at`.
5. **Idempotency (F56).** Re-triggering with no flag returned
   `freeze.status: "already_frozen"` at the identical original timestamp;
   all 8 rows confirmed still at `freeze_count = 1` afterward — cache still
   refreshed normally (`participants_synced: 8, matches_synced: 9`).
6. **Refreeze (F72).** `tier_id` bumped from Hebdo (×1.0) to Mensuel (×2.0)
   in Studio/psql, then re-triggered with `{"tournament_id": 2, "refreeze":
   true}`. Every row's points exactly doubled (390 → **780**), `multiplier`
   read `2`, `freeze_count` became `2` with a new `frozen_at`
   (`2026-08-16 18:46:10.625+00`) — while `tournaments.completed_at` stayed
   pinned at its **original** `18:43:04.235` timestamp, confirming the
   `[PLAN DECISION]` (a correction must not restate the event's closure
   time, RULES §22) behaves exactly as designed.
7. **Journey O (F55).** `tournament_results` deleted and `tournaments`
   `completed_at`/`season_id` nulled by hand; re-triggering returned
   `freeze.status: "no_season"` with `completed_at` confirmed still null and
   zero rows. Restoring `season_id` and re-triggering returned `"frozen"`
   again (`freeze_count` restarting at `1`, since the prior rows had been
   deleted for this test; `multiplier: 2`, `total_points_awarded: 780` —
   still Mensuel from step 6).
8. **Not active (E2E 16).** The walkthrough tournament was `is_active =
   false` from its creation in step 0 through every one of the six freezes
   above, all of which succeeded — substantively proving `is_active` is
   never read by `runFreeze`, without needing a separate deactivate/re-trigger
   pair.

**Not captured this round:** the opportunistic, non-blocking observation of
whether `final_rank` is null before completion (PRD §35) — `participants.json`
was not read mid-tournament during this walkthrough. This was explicitly
non-blocking in the RFC and nothing depends on the answer; it simply means
this particular walkthrough did not produce that observation. A future
walkthrough (or the eventual live-tournament deploy) could still capture it.
Per-step Challonge call counts were confirmed by direct log inspection only
at step 2 (the boundary, where it matters most); the other steps' call
counts were inferred from response shape and DB state rather than
individually re-confirmed against the logs line by line.

**Bug found and fixed during the walkthrough:** the `[freeze] completion
check armed…` log line (`index.ts`, just before `fetchChallongeTournament`)
interpolated `tournamentId` — the **local Supabase id** — making the message
read "third Challonge call for tournament 2" during step 2, even though the
underlying API call correctly used `tournament.challongeTournamentId`
(`18374775`). Not a correctness bug (the right Challonge tournament was
always called), but a diagnostic-clarity gap for an operator correlating logs
against the Challonge dashboard. Fixed to log both ids:
`` `[freeze] completion check armed — third Challonge call for tournament
${tournamentId} (Challonge id ${tournament.challongeTournamentId})` ``.
Re-verified: `deno check` clean, `deno test` still 35/35 green.

**Cleanup:** the walkthrough tournament (local id `2`) is left in the
database in its final frozen state (Mensuel multiplier, 8 rows,
`freeze_count = 2`) rather than deleted — per F48's `on delete restrict`, a
frozen tournament cannot be deleted anyway. This does not affect RFC-011's
own seeded fixture (id `1`), which this walkthrough never touched.

**Still outstanding — deployment.** This walkthrough deliberately ran
entirely against the organizer's **local** Supabase stack, per their explicit
choice of method. `supabase functions deploy challonge-sync` to the actual
hosted project, and a confirming trigger against it, have **not** happened.
RFC-013 may treat the **algorithm** as live-verified, but the first live
trigger against production is still a separate, unperformed step — and is
the point at which `CLAUDE.md`'s four-place release-status update (RFC's
Completion record, `RFCS.md`, `PRD.md`, `CLAUDE.md`) actually applies.

---

### Round 4 (2026-08-17) — Hosted deploy and live production trigger

**What this round closes:** the single item Round 3 left outstanding —
deploying the already-algorithm-verified function to the actual hosted
Supabase project and confirming it with a real trigger there.

**Steps performed:**
1. Confirmed the repo was already linked to the correct hosted project
   (`supabase projects list` → `qvgnstyucqyhkluskcdc`, `discord-ots-bot`,
   `linked: true`) and that both required secrets were already provisioned
   (`supabase secrets list` → `CHALLONGE_API_KEY`, `CHALLONGE_SYNC_SECRET`,
   set 2026-07-20 — pre-existing, not newly created this round).
2. `supabase functions deploy challonge-sync` — succeeded:
   `{"project_ref":"qvgnstyucqyhkluskcdc","functions":["challonge-sync"],
   "dashboard_url":"...","message":"Deployed Functions."}`.
3. Queried the live `tournaments` table (read-only, via the bot's own
   `SUPABASE_URL`/`SUPABASE_SERVICE_KEY`) for real, already Challonge-linked
   tournaments safe to re-sync as a verification target — found two:
   id `3` ("Open Swiss 2", Challonge `18251698`) and id `4` ("Online
   Tournament Brawl", Challonge `18334344`), both `is_active: false`
   (finished v3.0-era events). Re-syncing either is a pure upsert, per the
   locked "upsert never append" decision — non-destructive.
4. The organizer ran the trigger curl against tournament `3` with the real
   `CHALLONGE_SYNC_SECRET` (never seen or handled by the assistant) and
   reported the response:
   ```json
   {"status":"ok","participants_synced":14,"matches_synced":35,
    "freeze":{"status":"no_season","detail":"tournament has no season_id set"}}
   ```
   `200 ok`, correct participant/match counts, and `freeze.status:
   "no_season"` is the documented F55 fail-soft outcome for a tournament with
   no `season_id` — expected here since tournament 3 predates RFC-011.

**Verification performed (Round 4)**
- `supabase functions deploy challonge-sync` — clean deploy, no errors.
- Live HTTP trigger against the hosted project — `200`, correct sync counts,
  correct (and expected) freeze outcome.
- No code, test, or schema changes this round — deployment and live-trigger
  verification only.

**Deviations:** none. This round performed exactly the two steps Round 3
flagged as outstanding, nothing else.

**RFC-012 is now ✅ complete.** All four release-status trackers (this
record, `RFCS.md`, `PRD.md`, `CLAUDE.md`) are updated in this same pass.
