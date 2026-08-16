# RFC-012 — Points Engine & Sync Freeze — Implementation Plan

**Plan status:** ready for implementation
**Source of truth:** `knowledge/RFCs/RFC-012-Points-Engine-And-Sync-Freeze.md`
(acceptance criteria §6), `knowledge/RFCs/implementation-prompt-RFC-012.md`
(scope limits), `knowledge/PRD.v4.final.md` §31.4/§31.5/§37/§40,
`knowledge/FEATURES.md` §O/§P, `.claude/RULES.md` §11–§25.

The coder executes this plan. Every architectural choice below is made here.
Where this plan takes a decision the RFC left implicit, it is marked
**[PLAN DECISION]** with its rationale; those are the only places where
judgement was applied, and each is repeated in §10.

---

## 1. SCOPE SUMMARY

RFC-012 teaches the existing `challonge-sync` Edge Function to **freeze a
tournament's results** when — and only when — Challonge itself reports the
tournament complete: carry `final_rank` through from `participants.json`
(**F54**), never filter the field on `active` (**F74**), compute points from a
pure placement table × the event's tier multiplier in a new I/O-free
`points.ts` (**F51**, **F52**, **F53**), and write one `tournament_results` row
per bracket participant carrying RFC-011's full F67 snapshot — including
entrants with no roster row (**F57**). Completion is confirmed by a
**conditional third Challonge API call** to `/tournaments/{id}.json`, fired only
when every cached match reads `complete` (**F68**); the freeze is skipped when
`season_id` is null (**F55**) and is one-way by default (**F56**), overridable
only by an explicit `{"refreeze": true}` body flag (**F72**). Two inherited
documentation obligations ship with it: rewording the "exactly 2 Challonge API
calls" invariant, and commenting the `active` trap at the mapping site.

**Explicitly out of scope** (implementation prompt §Scope Limitation): `bot.py`,
`test_bot.py`, any migration/DDL (RFC-011 owns all v4.0 schema), every Discord
command (`/link-organizer`, `/ots` refactor, `/standings`, `/profile` — RFC-013
and RFC-014), RUNBOOK §9, `E2E-CHECKLIST-v4.md`, and any DQ/forfeit handling or
any logic that assumes an answer to PRD §37's two known unknowns.

---

## 2. LOCKED DECISIONS THIS RFC MUST HONOR

| Decision (source) | How this plan honors it |
|---|---|
| **`bot.py` never talks to Challonge; cache tables are the only interface between runtimes** (RULES §12, CLAUDE.md) | `bot.py` and `test_bot.py` are not opened. The freeze lives entirely in the Edge Function. `tournament_results` joins the cache tables as a second Edge-Function-written / bot-read table. |
| **Full refresh, upsert-never-append, all-or-nothing before any write** (RULES §12/§14) | Handler steps 1–6 are byte-identical apart from the widened `resolveTournament` select and the `refreeze` body field. Both unconditional Challonge calls still resolve before any write; both cache upserts still run first. The freeze is appended as step 7, **after** the caches are written, so a freeze refusal never costs the organizer their cache update. |
| **`state` is Challonge's vocabulary verbatim; never translate or remap** (RULES §13) | `allMatchesComplete` compares against the literal `"complete"`, case-sensitively. The third call's `tournament.state` is likewise compared verbatim. `final_rank` is carried unmodified. |
| **Exactly 2 Challonge API calls per invocation** (RULES §18, PRD §21) | **Deliberately amended by this RFC** (PRD.v4 §31.5 F68, §40). Reworded in `.claude/RULES.md` §18, `knowledge/PRD.md` §21 and the `index.ts` file header to "2 per invocation, plus a conditional 3rd when the completion check is armed". This is the one locked decision RFC-012 is chartered to change; no other is touched. |
| **Frozen history snapshots the resolved value, never the lookup key** (RULES §22) | Rows store the numeric `multiplier` read via the `tournament_tiers(multiplier)` embed, never `tier_id`. A null embed on a non-null `tier_id` refuses the freeze; the multiplier is **never** defaulted to 1.0. |
| **Standings sum over `tournament_results.season_id`** (RULES §22) | The freeze writes the tournament's `season_id` onto every row at freeze time; nothing later re-derives it. |
| **Corrections are deliberate, never a side effect of a routine sync** (RULES §22, F56/F72) | The default path short-circuits on `completed_at is not null`. Only `refreeze: true` recomputes, and it increments `freeze_count` and refreshes `frozen_at`. No scheduled/automatic path can rewrite a frozen row. |
| **Durable vs. disposable data** (RULES §21) | `runFreeze()` is a textually separate function with its own guards; `upsertRows` is reused as a mechanical POST helper only, with a comment at the `tournament_results` call site stating that write-once semantics are enforced by the caller, not by the helper. |
| **Manual trigger only, never polled** (RULES §11, PRD §19) | No schedule, no cron, no new trigger surface. The freeze rides the organizer's existing `curl`. |
| **No new dependency in either runtime** (RULES §1/§11) | `fetch` only, plus the already-used `https://deno.land/std@0.224.0/assert/mod.ts` in tests. `points.ts` imports nothing at all. |
| **The freeze targets an explicit `tournament_id`, not the active tournament** (PRD §31.5) | `runFreeze()` receives the body's `tournament_id`; `is_active` is never read. |
| **Known unknowns stay flagged, not resolved** (RULES §20, PRD §37) | No code assumes whether `final_rank` is null before completion (step 6 handles either), and no DQ/forfeit handling is written. |

---

## 3. SCHEMA CHANGES (`schema.sql` / `supabase/migrations/`)

**N/A — deliberately.** RFC-012 creates zero DDL. Every column it writes was
created by `supabase/migrations/20260816000000_rfc011_ranking_schema.sql`.
`supabase/seed.sql` is **not** modified either (see §10, Risk 9). If the coder
finds itself needing a column, that is a signal RFC-011 was under-specified:
**stop and raise it** rather than adding DDL here (RFC-012 §4).

---

## 4. `bot.py` CHANGES

**N/A.** Not one line. `bot.py`, `test_bot.py`, `requirements.txt`,
`.env.example` and `deploy.sh` are untouched. The bot gains no write path, no
new env var, and no knowledge of the freeze. RFC-013 is where `bot.py` changes.

---

## 5. COMMANDS

**N/A.** RFC-012 ships no Discord command and no user-facing French string. All
new output is **operator-facing English** in the Edge Function's JSON response
and logs (RFC-012 §3.7 — French is for players).

---

## 6. EDGE FUNCTION CHANGES

All work is inside `supabase/functions/challonge-sync/`. Pure logic stays
separated from I/O exactly the way `mapping.ts` already is.

### 6.1 New file — `points.ts` (pure, F51/F52/F53)

**No imports. No I/O. No `console.*`.** This is the TypeScript sibling of
`normalize_name` / `render_team_text` / `pick_opponent_id` / `is_cache_stale`.

```ts
export const FORMULA_VERSION = "v1";

const PLACEMENT_TABLE: ReadonlyArray<{ minRank: number; points: number }> = [
  { minRank: 17, points: 5 },   // participation floor
  { minRank: 9,  points: 15 },
  { minRank: 5,  points: 30 },
  { minRank: 3,  points: 50 },
  { minRank: 2,  points: 70 },
  { minRank: 1,  points: 100 },
];

export function basePointsForRank(finalRank: number): number;
export function awardedPoints(finalRank: number, multiplier: number): number;
export function allMatchesComplete(states: readonly string[]): boolean;
export function findNullFinalRanks(
  participants: readonly { challongeParticipantId: number; name: string; finalRank: number | null }[],
): { id: number; name: string }[];
```

- The array literal is already in **descending `minRank`** order. Iterate it in
  array order and return the first bucket where `finalRank >= bucket.minRank`.
  It is a **range ladder, not an index lookup** (F51 edge case).
- `basePointsForRank` guard, **before** the loop:
  `if (!Number.isInteger(finalRank) || finalRank < 1) throw new Error(...)`.
  `Number.isInteger` rejects `1.5`, `NaN`, `Infinity` and `-Infinity` in one
  test. Include the offending value in the message. The post-loop `throw` is
  unreachable (the `minRank: 1` bucket catches everything ≥ 1) and is written as
  a defensive `throw`, not a `return 0`.
- `awardedPoints` guards the multiplier the same way —
  `if (!Number.isFinite(multiplier) || multiplier < 0) throw` — then
  `Math.round(basePointsForRank(finalRank) * multiplier * 100) / 100`. The
  rounding matches `tournament_results.awarded_points`'s `numeric(8,2)`; with
  today's 1.0/2.0/3.0 tiers every product is whole, which is exactly why it will
  never be added later if it is not added now (RFC-012 §8).
- `allMatchesComplete` = `states.length > 0 && states.every((s) => s === "complete")`.
  **The `length > 0` term is the requirement**, not a nicety: an empty match
  list must read `false` or a freshly-created bracket arms the third call on its
  very first sync.
- `findNullFinalRanks` returns, **in input order**, `{ id, name }` for every
  participant whose `finalRank` is not an integer ≥ 1 — i.e. `null`,
  `undefined`, `0`, or a non-integer. **[PLAN DECISION]** The RFC names it for
  the null case but states step 6 "already refuses that case loudly" for
  non-integers too (§3.2); widening the predicate here is what guarantees
  `basePointsForRank` can never throw during step 7, mid-write, after rows have
  started landing. The response `reason` stays `"null_final_rank"` per the
  locked contract.
- Comment block above `PLACEMENT_TABLE` reproduced from RFC-012 §3.2 verbatim in
  substance: bucket edges sit on the single-elim tie ranks, that alignment is
  the whole point, do **not** linearise it (holes at 4 and 6–8), no field-size
  term.

### 6.2 `mapping.ts` (F54, F74)

Modified, **additively** — `mapParticipant`, `mapMatch`, `ParticipantCacheRow`
and `MatchCacheRow` keep their exact current shapes so the seven existing
`mapping_test.ts` assertions pass unchanged.

1. `RawChallongeParticipant` gains `final_rank?: number | null;` with the F54
   comment (competition-style, ties **and** gaps, `1,2,3,3,5,5,5,5,9,10,11,12,
   13,14`; ranks 4/6/7/8 do not exist; never index an array by it, never assume
   `max(rank) === count`; verified live 2026-07-31 against Challonge 18251698).
2. `RawChallongeParticipant` gains the **F74 trap comment** — `active` is
   *deliberately not typed here* so nobody can filter on it by accident; it
   tracks *still advancing*, not *validly entered*; it was `false` for all six
   group-stage non-qualifiers on the live check, so the natural-looking filter
   drops 43 % of the field and precisely the players the participation floor
   exists to reward. Written at the same depth and in the same place as the
   existing dual-id comment on `group_player_ids` — a future reader adding a
   filter has to walk past it.
3. New freeze-time view — `final_rank` **does not** join `ParticipantCacheRow`,
   because `challonge_participants_cache` has no such column and RFC-011
   deliberately did not add one: the rank's durable home is
   `tournament_results`.

   ```ts
   export interface FreezeParticipant {
     challongeParticipantId: number;
     name: string;
     finalRank: number | null;
   }
   export function mapParticipantForFreeze(raw: RawChallongeParticipant): FreezeParticipant;
   // { challongeParticipantId: raw.id, name: raw.name, finalRank: raw.final_rank ?? null }
   ```
   `?? null` preserves a real `0` as `0` (caught by `findNullFinalRanks`) and
   never coerces `null` to `0`.
4. New one-line pure predicate for the defensive `group_player_ids` check:
   ```ts
   export function hasAmbiguousGroupPlayerIds(raw: RawChallongeParticipant): boolean;
   // (raw.group_player_ids?.length ?? 0) > 1
   ```
   **[PLAN DECISION]** RFC-012 §3.3 requires the warning to be "a new
   `console.warn` in `mapParticipant`'s **caller**, not a behavior change", while
   §10.1 wants a test that a length > 1 array "triggers the defensive warning".
   A `console.warn` inside `mapping.ts` would put I/O in the pure module and
   force console capture in the test. Splitting the *detection* (pure, tested,
   in `mapping.ts`) from the *warning* (`console.warn` in `index.ts`'s mapping
   loop) satisfies both literally and costs one line. `mapParticipant` still
   maps element 0 unchanged.
5. New pure normalizer, so the freeze's roster join is tested rather than
   hand-inlined:
   ```ts
   export function normalizeName(value: string): string; // value.trim().toLowerCase()
   ```
   **[PLAN DECISION]** placed in `mapping.ts` (the pure/tested module `index.ts`
   already imports) rather than `points.ts` (which must import nothing and is
   about points) or inline in `index.ts` (untested). Its comment must point at
   **`bot.py`'s `normalize_name` (bot.py:85)** and state that this is the third
   implementation site of the same trim-then-lower contract — change one, change
   all three (RULES §4).

### 6.3 `index.ts` — handler step order

Existing steps are **unchanged** except where listed. Explicitly: the secret
gate (step 1), the `POST`-only check, both unconditional Challonge calls and
their `Promise.all` all-or-nothing gate (step 4), the pure mapping (step 5), and
both cache upserts (step 6) keep their current code and order.

| Step | Status | Change |
|---|---|---|
| header comment | **modified** | "exactly 2 Challonge API calls" → "2 Challonge API calls per invocation, plus a conditional 3rd when the completion check is armed (F68)". Request block documents the optional `refreeze: true` body field. |
| 1. secret check | unchanged | — |
| 2. body parse | **modified** | Adds `refreeze` parsing/validation (below). `tournament_id` handling untouched. |
| env load | unchanged | No new env var, no new secret. |
| 3. resolve tournament | **modified** | Widened `select` only — same single round trip, same four `TournamentResolution` statuses, same 404/400/500 handling. |
| 4. two Challonge calls | unchanged | — |
| 5. map | **modified** | Adds the `hasAmbiguousGroupPlayerIds` → `console.warn` line in the participant loop. Mapping output unchanged. |
| 6. upsert both caches | unchanged | — |
| **7. freeze (new)** | **new** | One `await runFreeze(...)` call. |
| 8. success return | **modified** | Gains the `freeze` object. |

**Body parse (step 2) addition**, after the existing `tournament_id` validation:

```ts
const refreezeRaw = (body as Record<string, unknown> | null)?.refreeze;
if (refreezeRaw !== undefined && typeof refreezeRaw !== "boolean") {
  return errorResponse(400, "refreeze must be a boolean");
}
const refreeze = refreezeRaw === true;   // false and absent are identical
```

**`resolveTournament` widening** — the `select` becomes:

```
select=id,challonge_tournament_id,season_id,completed_at,tier_id,tournament_tiers(multiplier)
```

and the `ok` variant becomes
`{ status: "ok"; challongeTournamentId: string; seasonId: number | null; completedAt: string | null; tierId: number | null; multiplier: number | null }`.
Resolution rules, in the helper:

- PostgREST returns the `tier_id` FK embed as a **to-one object**; normalize
  defensively with `Array.isArray(e) ? e[0] : e` before reading `.multiplier`
  (one line — a to-many render would otherwise silently produce `undefined`).
- `multiplier` is coerced with `Number(...)` and stored as `null` unless
  `Number.isFinite`. **Never default to 1.0** — a missing multiplier refuses the
  freeze later (RULES §22).
- Everything else about the helper — headers, `not_found` / `no_link` / `error`
  statuses, the try/catch — is unchanged.

### 6.4 `index.ts` — `fetchChallongeTournament()` (the conditional third call)

`fetchChallongeList` requires an array body; `/tournaments/{id}.json` returns a
single `{"tournament": {...}}` object. Add one sibling helper next to
`fetchChallongeParticipants` / `fetchChallongeMatches`, same shape, same
`?api_key=` query-parameter auth, same `FetchResult<T>` return:

```ts
type RawChallongeTournament = { state: string; progress_meter?: number | null; completed_at?: string | null };
function fetchChallongeTournament(
  challongeTournamentId: string, apiKey: string,
): Promise<FetchResult<RawChallongeTournament>>;
// GET https://api.challonge.com/v1/tournaments/{id}.json?api_key=...
// unwraps body.tournament; a non-object body is { ok: false }.
```

This function is called from **exactly one place** — inside `runFreeze`, after
`allMatchesComplete` returns `true`. Immediately before the `fetch`, emit
`console.log("[freeze] completion check armed — third Challonge call for tournament <id>")`,
so the staged walkthrough (§10.2 of the RFC) can count calls from the function
logs.

### 6.5 `index.ts` — `runFreeze()`

One function, called once, returning a discriminated union. It does **not**
thread state through the cache-sync code (RFC-012 §7.3).

```ts
type FreezeOutcome =
  | { status: "frozen"; results_written: number; freeze_count: number;
      season_id: number; multiplier: number; total_points_awarded: number }
  | { status: "already_frozen" | "no_season" | "in_progress" | "not_yet_complete";
      detail: string }
  | { status: "refused";
      reason: "null_final_rank" | "no_multiplier" | "no_participants"
            | "third_call_failed" | "read_failed" | "write_failed";
      message: string; participants?: { id: number; name: string }[] };

async function runFreeze(
  supabaseUrl: string,
  serviceRoleKey: string,
  challongeApiKey: string,
  tournamentId: number,
  tournament: { challongeTournamentId: string; seasonId: number | null;
                completedAt: string | null; multiplier: number | null },
  rawParticipants: RawChallongeParticipant[],   // already fetched in step 4 — no extra call
  refreeze: boolean,
): Promise<FreezeOutcome>;
```

`runFreeze` **never throws**: every `fetch` is wrapped and every failure becomes
a `refused` outcome. Every log line is prefixed `[freeze]`.

**Algorithm, in order, short-circuiting** (PRD §31.5 / RFC-012 §3.5 — the order
is itself a requirement):

1. **already_frozen (F56/F72).** `tournament.completedAt !== null && !refreeze`
   → `{ status: "already_frozen", detail: "tournament was frozen at <completedAt>; pass refreeze:true to recompute" }`.
   *Consequence to preserve:* a frozen tournament whose `season_id` was later
   nulled still reports `already_frozen`, not `no_season` — the freeze already
   happened.
2. **no_season (F55).** `tournament.seasonId === null` → `{ status: "no_season", detail: "…" }`.
   **`completed_at` is left null** — this is what makes Journey O recoverable.
3. **in_progress.** Read the match states **from the cache the function just
   wrote**, not from the in-memory rows:
   `GET {supabaseUrl}/rest/v1/challonge_matches_cache?tournament_id=eq.{id}&select=state`.
   Read failure → `refused/read_failed`. Then
   `if (!allMatchesComplete(states))` → `{ status: "in_progress", detail: "<n> of <m> cached matches are not complete" }`.
   **No third call on this path.**
4. **not_yet_complete (F68) — the group-stage boundary.** Fire
   `fetchChallongeTournament`. Transport/HTTP failure → `refused/third_call_failed`.
   `if (tourney.state !== "complete")` →
   `{ status: "not_yet_complete", detail: "Challonge reports state=<state>, progress_meter=<n> — the final bracket may not exist yet" }`.
   Include `progress_meter` and Challonge's own `completed_at` in the detail
   string: they corroborate, and the walkthrough captures them.
5. **no_multiplier.** `tournament.multiplier === null` → `refused/no_multiplier`
   with a `console.error`. Checked here, immediately before the write path, so a
   mid-event trigger never 500s over a tier anomaly it did not need to read.
6. **null_final_rank (F54).** `const freezeParticipants = rawParticipants.map(mapParticipantForFreeze)`;
   `if (freezeParticipants.length === 0)` → `refused/no_participants`
   **[PLAN DECISION]** — freezing an empty field would latch `completed_at` over
   zero rows, which the default one-way mode could then never revisit.
   `const bad = findNullFinalRanks(freezeParticipants)`;
   `if (bad.length > 0)` → `console.error` with the count and every offending
   `{id, name}`, then `refused/null_final_rank` carrying `participants: bad`.
   **A partial freeze is worse than none, and under F56 it would be one-way.**
7. **Freeze.** For **every** participant — no filtering on `active` (F74):

   **Reads**
   - `GET players?tournament_id=eq.{id}&select=id,ingame_name,profile_id`
   - `GET tournament_results?tournament_id=eq.{id}&select=freeze_count&order=freeze_count.desc&limit=1`

   Either failing → `refused/read_failed` (nothing has been written yet).

   **Row construction**
   ```ts
   const frozenAt = new Date().toISOString();          // one UTC timestamp for the whole freeze
   const freezeCount = previousFreezeCount + 1;        // 0 when absent → first freeze writes 1
   const rosterByName = new Map(players.map((p) => [normalizeName(p.ingame_name), p]));
   // Unique by construction: players_tournament_name_idx is unique on
   // (tournament_id, lower(ingame_name)), so no ambiguity is possible here.
   const roster = rosterByName.get(normalizeName(p.name));   // F57: a miss is NORMAL
   ```

   Each row (every column is `not null` on the snapshot side — RFC-011 §3.5):

   | column | value |
   |---|---|
   | `tournament_id` | the body's `tournament_id` |
   | `challonge_participant_id` | `p.challongeParticipantId` — the **top-level** id, never the group id |
   | `player_id` | `roster?.id ?? null` (F57) |
   | `profile_id` | `roster?.profile_id ?? null` (RFC-013 backfills the nulls later) |
   | `ingame_name` | `p.name`, Challonge's value verbatim (RULES §13) |
   | `final_rank` | `p.finalRank` |
   | `awarded_points` | `awardedPoints(p.finalRank, tournament.multiplier)` |
   | `season_id` | `tournament.seasonId` |
   | `multiplier` | `tournament.multiplier` — the **resolved number**, never `tier_id` (F67) |
   | `formula_version` | `FORMULA_VERSION` (F53) |
   | `participant_count` | `freezeParticipants.length` — the **bracket**, not the roster (F47) |
   | `frozen_at` | `frozenAt` (same for every row; generated here, not left to the column default) |
   | `freeze_count` | `freezeCount` (uniform across the tournament's rows) |

   **Writes, in this order and no other**
   1. **Upsert** via the existing `upsertRows(..., "tournament_results", "tournament_id,challonge_participant_id", rows)`.
      Widen `upsertRows`'s `rows` parameter union with a new
      `TournamentResultRow` interface — that is the whole edit; the helper's
      body, headers and `resolution=merge-duplicates` prefer are untouched. At
      the call site, a comment: *this helper is mechanical; the write-once
      semantics of `tournament_results` are enforced by step 1's guard above,
      not here* (RFC-012 §8's seam warning).
   2. **Prune** —
      `DELETE tournament_results?tournament_id=eq.{id}&challonge_participant_id=not.in.({ids})`
      with `Prefer: return=representation` so the deleted rows come back and can
      be counted. **Upsert-then-prune, in that order**, so there is never a
      window where the tournament has no results. A prune that deletes anything
      is an anomaly (a participant vanished from a completed bracket):
      `console.warn` with the count — never fail.
   3. **`PATCH tournaments?id=eq.{id}`** with `{ completed_at: frozenAt }`,
      **set last** — it is the idempotency latch and must not be set before the
      rows it claims exist. **[PLAN DECISION]** send this PATCH **only when
      `tournament.completedAt === null`**; on a refreeze the original closure
      time is left intact and `frozen_at` / `freeze_count` carry the correction
      (RULES §22: a correction must not restate history). Log the skip.

   Any write failure → `refused/write_failed` with a message naming which write
   failed. **Comment required at the write site** (RFC-012 §3.6, verbatim in
   substance): PostgREST gives no cross-request transaction, so a crash between
   write 1 and write 3 leaves rows written with `completed_at` still null; that
   state is **self-healing** — the next default trigger sees a null
   `completed_at`, re-runs, and the upsert overwrites the same rows with
   identical values. The alternative (latch first) would leave a permanently
   half-frozen tournament only `refreeze` could fix.

8. Return `{ status: "frozen", results_written: rows.length, freeze_count,
   season_id, multiplier, total_points_awarded }`, the total being the sum of
   `awarded_points` rounded to 2 dp. `console.log` the same summary.

### 6.6 Request / response contract

Request (backward compatible — an existing v3.0 `curl` keeps working and simply
gains freeze behavior):

```
POST {SUPABASE_URL}/functions/v1/challonge-sync
  header  x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET>
  body    {"tournament_id": <bigint>}                    -- default mode
  body    {"tournament_id": <bigint>, "refreeze": true}  -- explicit correction
```

Response — a `freeze` object on **every** path:

```jsonc
// frozen
{ "status": "ok", "participants_synced": 14, "matches_synced": 26,
  "freeze": { "status": "frozen", "results_written": 14, "freeze_count": 1,
              "season_id": 2, "multiplier": 2, "total_points_awarded": 960 } }

// skipped — HTTP 200: the CACHE SYNC SUCCEEDED, only the freeze stood down
{ "status": "ok", "participants_synced": 14, "matches_synced": 26,
  "freeze": { "status": "already_frozen" | "no_season" | "in_progress" | "not_yet_complete",
              "detail": "<one operator-facing English sentence>" } }

// refused — anomaly
{ "status": "error",
  "message": "freeze refused: 3 participant(s) have a null final_rank",
  "freeze": { "status": "refused", "reason": "null_final_rank", "participants": [ … ] } }
```

HTTP status mapping in the handler:

| freeze outcome | HTTP |
|---|---|
| `frozen`, `already_frozen`, `no_season`, `in_progress`, `not_yet_complete` | **200** |
| `refused` / `third_call_failed` | **502** — consistent with the existing Challonge-failure branch |
| `refused` / every other reason | **500** |

Skips are 200 because the sync itself succeeded and an organizer must not read a
normal mid-event trigger as a failure. `refused` is loud because it is not a
normal state.

### 6.7 Challonge API call count per invocation — the tracked invariant

- **2 calls** on every invocation (participants, matches), unconditionally, as
  today.
- **+1 call** if and only if `allMatchesComplete(cachedStates) === true` — i.e.
  roughly once per event, on the last trigger, plus once at the group-stage
  boundary. Ceiling: **3 per invocation**. A 7-round event goes from ~14 to ~15
  calls against Challonge's 500/month cap.
- The third call fires **after** the caches are written and **never** on the
  `already_frozen` / `no_season` / `in_progress` paths — steps 1–3 short-circuit
  before it. This is asserted in the staged walkthrough at every step.

---

## 7. TESTS

### 7.1 New — `supabase/functions/challonge-sync/points_test.ts` (Deno, pure)

Same import as the existing suite: `assertEquals`/`assertThrows` from
`https://deno.land/std@0.224.0/assert/mod.ts` (identical version — do not
introduce a second std version).

`basePointsForRank`
- every bucket edge and the rank either side: 1→100, 2→70, 3→50, **4→50**,
  5→30, **8→30**, 9→15, **16→15**, 17→5, 100→5.
- throws on `0`, `-1`, `1.5`, `NaN`, `Infinity`, `-Infinity`.

`awardedPoints`
- **The tournament-3 real-data fixture** (the release's headline test): rank
  vector `[1,2,3,3,5,5,5,5,9,10,11,12,13,14]` at multiplier `1.0` produces
  exactly `[100,70,50,50,30,30,30,30,15,15,15,15,15,15]`, **total 480**.
- The same vector at multiplier `2.0` totals **960** (the value in the RFC's
  example response — one assertion ties the two together).
- **Tie equality:** the two rank-3 entries are equal to each other; all four
  rank-5 entries are equal to each other.
- Multiplier axis: `1.0`, `2.0`, `3.0`, and the non-integer `2.5`
  (`awardedPoints(9, 2.5) === 37.5`, `awardedPoints(17, 2.5) === 12.5`).
- **Rounding:** `awardedPoints(17, 1.33) === 6.65` (the float product is
  `6.649999…`) — proves the `numeric(8,2)` round-trip.
- Throws on a non-finite or negative multiplier (`NaN`, `Infinity`, `-1`), and
  propagates `basePointsForRank`'s throw for an invalid rank.

`allMatchesComplete`
- `[]` → **false** (its own named test — this is the arming guard).
- `["complete"]` → true; `["complete","complete","complete"]` → true.
- one `"open"` → false; one `"pending"` → false.
- `["Complete"]` → false (Challonge's vocabulary is verbatim and case-sensitive).

`findNullFinalRanks`
- none → `[]`.
- one null → one entry carrying that participant's `id` and `name`.
- several (`null`, `undefined`, `0`, `1.5`) → all flagged, **in input order**.

`FORMULA_VERSION`
- `=== "v1"` (F53), so a future bump is a deliberate test edit.

### 7.2 Extended — `mapping_test.ts`

Existing 7 tests must pass **unchanged**. Added:
- **Regression:** `mapParticipant({id, name, final_rank: 3, group_player_ids:[…]}, 42)`
  still returns exactly the four-key `ParticipantCacheRow` — asserted with a
  full-object `assertEquals`, so nobody accidentally leaks `final_rank` into the
  cache row.
- `mapParticipantForFreeze` carries `final_rank` through unchanged.
- `final_rank` absent → `null`; `final_rank: null` → `null` (**not** `0`);
  `final_rank: 0` → `0` (left for `findNullFinalRanks` to reject).
- The tie/gap vector maps untouched (no densification, no sorting).
- `hasAmbiguousGroupPlayerIds`: false for `undefined` / `null` / `[]` / `[x]`;
  **true** for `[x, y]` — and `mapParticipant` still maps element 0 in that case.
- `normalizeName`: `"  Zou  "` → `"zou"`; already-normalized unchanged; a
  mixed-case accented name lowercases — the trim-then-lower parity with
  `bot.py`'s `normalize_name`.

`deno test supabase/functions/challonge-sync/` must run both suites green.

### 7.3 Network-dependent branches — verified manually, not unit-tested

Everything in `runFreeze`'s I/O and the handler wiring: the widened
`resolveTournament` select and its embed, the third call, the three reads, the
three writes, the HTTP status mapping, and the group-stage boundary itself. Two
tiers:

**(a) Local PostgREST shape check** (cheap, before any live trigger; a local
Supabase stack exists). Against `supabase db reset`'s seeded
`RFC-001 Test Tournament` (which RFC-011 already gave a `season_id`), hand-run
with `curl` and the local service key:
- the widened `tournaments` select — confirm `tournament_tiers` embeds as an
  object with a numeric `multiplier`;
- one `tournament_results` upsert with `Prefer: resolution=merge-duplicates` on
  `on_conflict=tournament_id,challonge_participant_id`, run **twice**, and
  confirm no duplicate rows;
- the prune `DELETE … not.in.(…)` with `Prefer: return=representation`;
- the `PATCH tournaments` latch.

Then delete the inserted `tournament_results` rows (deleting *results* is fine;
F48's `on delete restrict` only blocks deleting the tournament).

**(b) The staged group-stage walkthrough** (RFC-012 §10.2) — the real gate, run
**with the user present**, on a real Challonge group-stage tournament of fake
players advanced one match at a time, with the Challonge call count read from
the function logs at every trigger. Steps 1–8 exactly as the RFC lists them.
**Step 2 (the group-stage boundary) exists for one trigger only** — capture the
raw `/tournaments/{id}.json` body there and put it in the Completion record.
Opportunistically record whether `final_rank` is null before completion (nothing
depends on the answer; this is the only occasion to observe it).

### 7.4 Must still pass unchanged

- `python -m unittest test_bot` — **30 tests**, untouched (`bot.py` is not
  opened).
- `mapping_test.ts` — the **7** existing tests, unmodified.
- v3.0 regression, verified during the walkthrough: both caches still
  upsert-never-append, the `state` enum is still strict, both Challonge calls
  still complete before any write, and an unknown / unlinked tournament still
  fails exactly as before (404 / 400).

---

## 8. DOCUMENTATION

Doc updates are deliverables of this RFC, not follow-ups.

1. **`.claude/RULES.md` §18** — replace "confirm exactly 2 Challonge API calls
   per invocation" with "confirm **2 Challonge API calls per invocation, plus a
   conditional 3rd** when the completion check is armed (every cached match
   reads `complete`) — roughly once per event; a 7-round event goes from ~14 to
   ~15 calls against the 500/month cap (F68, RFC-012)". The rest of §18's
   posture (Edge Function verification is manual/operational) stands.
2. **`.claude/RULES.md` §22 (v4.0 addendum, "Frozen history")** — append one
   bullet: **two opposing write semantics now live in one Edge Function** —
   cache tables refresh by upsert and are designed to be re-run constantly;
   `tournament_results` is write-once by default and must not be. Keep
   `runFreeze()` textually separate, and never share a helper that "just
   upserts" across both without the caller stating which semantics it wants.
   *(Appending a bullet to §22 rather than opening a §26 — smallest change, and
   §22 is already the frozen-history section.)*
3. **`knowledge/PRD.md` §21** — the "Challonge API calls per event" metric row:
   "Rounds-per-event × 2" → "Rounds-per-event × 2, **plus one conditional third
   call** on the trigger(s) where the completion check arms (F68, RFC-012 —
   amends this row's original flat ×2)".
4. **`supabase/functions/challonge-sync/index.ts` file header** — the
   "(exactly 2 Challonge API calls)" clause and the documented request body.
   *The invariant is stated in the source too; leaving it is a contradicted
   spec.*
5. **`knowledge/RUNBOOK.md` §8** (line ~485, **French**) — one line noting the
   response now also carries a `freeze` object, and that `refreeze` exists and
   is documented in §9. Do **not** write §9 — that is RFC-014's.
6. **`knowledge/DEPLOYMENT.md` §12** (line ~314, English) — the same one-line
   amendment to the quoted expected response.
7. **`knowledge/RFCs/RFC-012-Points-Engine-And-Sync-Freeze.md` Completion
   record** — status, deliverables, the observed Challonge call counts per
   trigger, the raw `/tournaments/{id}.json` body from the boundary, the
   `final_rank`-before-completion observation, and every deviation (including
   the four **[PLAN DECISION]**s above and the no-seed-change decision).
8. **`knowledge/RFCs/RFCS.md`** — RFC-012's status row, plus a line in the
   tracked notes if the walkthrough produced anything durable.

**Not touched:** `CLAUDE.md` and `knowledge/FEATURES.md`. CLAUDE.md's four-place
status update is a *release* ritual and v4.0 ships at RFC-014. FEATURES.md's
v3.0 section still says "exactly 2 calls" **by design** — its v4.0 supersession
table (line 609) already records the amendment, and those release sections are
append-only.

---

## 9. IMPLEMENTATION ORDER

Pure logic first, in isolation, exactly the way RFC-004 preceded RFC-005.

1. **`points.ts`** — the whole pure surface (§6.1), with the F51 comment block.
   No `index.ts` edits yet.
2. **`points_test.ts`** — every case in §7.1. Run
   `deno test supabase/functions/challonge-sync/` and get it green **before
   touching anything with I/O in it.** The tournament-3 fixture and
   `allMatchesComplete([]) === false` are the two that must not be deferred.
3. **`mapping.ts`** — `final_rank` on `RawChallongeParticipant`, the F74 trap
   comment, `FreezeParticipant` + `mapParticipantForFreeze`,
   `hasAmbiguousGroupPlayerIds`, `normalizeName` (§6.2). Additive only.
4. **`mapping_test.ts`** — the additions in §7.2, including the
   `mapParticipant`-shape regression assertion. Suite green: 7 existing + new.
5. **`index.ts` — plumbing, no behavior yet:** widen `resolveTournament`'s
   select and its `ok` variant, add `fetchChallongeTournament`, widen
   `upsertRows`'s row union with `TournamentResultRow`, add the `refreeze` body
   parsing, add the `hasAmbiguousGroupPlayerIds` warn in step 5. `deno check`
   clean; behavior still identical to v3.0 (nothing calls the new code yet).
6. **`index.ts` — `runFreeze()`**, written top-down in the algorithm's own order
   (§6.5), with the no-transaction comment at the write site.
7. **`index.ts` — wire step 7** and the response/HTTP mapping (§6.6).
8. **Local PostgREST shape check** (§7.3a) against the local stack. Fix any
   PostgREST syntax surprises here, not during the live walkthrough.
9. **Deploy** (`supabase functions deploy challonge-sync`) and run the **staged
   group-stage walkthrough** (§7.3b) with the user, steps 1–8, counting calls at
   every trigger.
10. **Documentation** (§8 items 1–6) — reword the invariant in all four places
    plus the two quoted-response lines.
11. **Completion record + `RFCS.md`** (§8 items 7–8), written from what was
    actually observed in step 9, not from what was expected.

Steps 1–4 are a self-contained, fully-testable unit and should be reviewable on
their own. Step 9 cannot be re-run cheaply — the boundary in its step 2 exists
for one trigger only.

---

## 10. RISK AREAS

1. **The group-stage boundary (F68) — the highest-risk item in v4.0.** A wrong
   completion check freezes half an event one-way. *Strategy:* completion is
   **never** derived from the cache alone. `allMatchesComplete` only **arms**
   the check; the authority is Challonge's own `tournament.state`. The third
   call is invoked from exactly one place, guarded by exactly one condition,
   preceded by a `[freeze]` log line, and exercised live in walkthrough step 2
   with the user present. Walkthrough step 3 additionally proves the answer
   **returns to `in_progress`** once the final bracket is generated — a latched
   `not_yet_complete` or a freeze firing there both fail the step.

2. **Two opposing write semantics in one function** (RFCS.md's #4 v4.0 risk).
   *Strategy:* all write-once logic lives in `runFreeze()`, textually separate
   from the cache sync; `upsertRows` stays a mechanical POST helper (widened
   type only, body untouched) with a comment at the `tournament_results` call
   site stating that the semantics are the caller's. RULES §22 gains the same
   warning so the next reader meets it before the code.

3. **`allMatchesComplete([])` reading as vacuously true.** *Strategy:* the
   `length > 0` term, plus a dedicated named test. This is the only thing
   preventing a freshly-created bracket from arming the third call on its first
   sync.

4. **The dual-id trap (RFC-009).** *Strategy:* the freeze writes only the
   **top-level `challonge_participant_id`** — the bracket's stable id and the
   `tournament_results` unique key. `mapParticipantForFreeze` touches neither
   `group_player_ids` nor `challonge_group_player_id`, and `mapParticipant`'s
   output shape is regression-asserted. Nothing reduces the candidate-id set.

5. **`participants[].active` (F74).** *Strategy:* it is **not typed** in
   `RawChallongeParticipant` and appears nowhere in any filter or condition —
   only in the trap comment. Acceptance check:
   `grep -rn "active" supabase/functions/challonge-sync/` returns comments only.

6. **`final_rank` ties and gaps (F54).** *Strategy:* range-ladder table, never
   an index lookup; nothing assumes `max(rank) === participant_count`
   (`participant_count` is `rows.length`); tie-equality and the 4/6–8 holes are
   both asserted in `points_test.ts`.

7. **Rounding / `numeric(8,2)`.** *Strategy:* `awardedPoints` rounds to 2 dp and
   is tested with a value whose float product is inexact (`5 × 1.33`). With
   today's tiers every product is whole — which is exactly why this gets
   forgotten if not done now.

8. **The `tournament_tiers` embed.** A null embed on a non-null `tier_id` is a
   schema-state anomaly. *Strategy:* refuse (`no_multiplier`, HTTP 500) and log;
   **never default to 1.0**. The array/object normalization line guards against
   a to-many render silently yielding `undefined`.

9. **RFC §10.3's local fixtures cannot exist as written.** It asks for "cached
   participants with `final_rank` values covering a tie and a gap", but
   `challonge_participants_cache` has **no `final_rank` column** (RFC-011
   deliberately did not add one), and the freeze reads ranks from Challonge's
   live payload, not from the cache. *Strategy:* **`supabase/seed.sql` is not
   modified.** RFC-011 already seeded the freezable target (a season, a tier and
   `season_id` on `RFC-001 Test Tournament`); everything a fixture could
   exercise between steps 4 and 7 is already covered by `points_test.ts`, and
   building a Challonge stub/mock layer to close the gap is exactly the
   abstraction the prime directive forbids. §7.3a's local PostgREST shape check
   replaces it for the write syntax. **Record this as a deviation in the
   Completion record.**

10. **`completed_at` on a refreeze — [PLAN DECISION].** The RFC's step 7 says
    "set `tournaments.completed_at`" unqualified. This plan sets it **only when
    it is currently null**, so a correction does not restate the event's closure
    time (RULES §22); `frozen_at` and `freeze_count` are the correction's audit
    trail. If the reviewer prefers the literal reading, the change is one
    condition — flag it rather than switching silently.

11. **`findNullFinalRanks` also flags non-integer / ≤ 0 ranks — [PLAN
    DECISION].** Prevents `basePointsForRank` from throwing mid-write after rows
    have started landing. Consistent with RFC §3.2 ("step 6 already refuses that
    case"); the response `reason` stays the locked `"null_final_rank"`.

12. **`hasAmbiguousGroupPlayerIds` as a pure predicate — [PLAN DECISION].**
    Reconciles RFC §3.3 ("the warn belongs in the caller") with §10.1 ("test
    that it triggers") without putting `console.warn` in the pure module. One
    exported line.

13. **PostgREST row cap on the match-state read.** Supabase caps rows on API
    reads; a bracket large enough to be truncated could hide open matches and
    **arm** the third call early. *Strategy:* accepted, no mitigation — the
    third call is the authority, so a truncated read can only cost one extra API
    call, never a wrong freeze. Note it in a comment at the read.

14. **Roster-name collisions in the F57 join.** *Strategy:* none needed —
    `players_tournament_name_idx` is unique on `(tournament_id,
    lower(ingame_name))`, so the `Map` can never lose a row. A Challonge name
    with no roster match is **normal** (`player_id`/`profile_id` null), not an
    error. JS `toLowerCase()` vs Python `str.lower()` vs Postgres `lower()`
    differ on a handful of exotic Unicode characters; that is the same accepted
    contract v3.0 already runs on — do not solve it here.

15. **Freezing the seeded test tournament makes it undeletable** under F48's
    `on delete restrict`. Expected, and exactly the trap RUNBOOK §9 (RFC-014)
    documents. If the walkthrough freezes it, say so in the Completion record.

16. **Known unknowns stay unknown** (PRD §37): whether `final_rank` is null
    before completion, and what Challonge reports for a DQ/forfeit. *Strategy:*
    no code branches on either; step 6 is safe both ways and the participant
    list is never filtered. Observe the first opportunistically during the
    walkthrough; build nothing on it.
