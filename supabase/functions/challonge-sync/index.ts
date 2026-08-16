// RFC-008 — Challonge Sync Edge Function (manual trigger).
// RFC-012 — extends it with the points engine and the one-way results freeze.
//
// The ONLY piece of this project that talks to the real Challonge API. On a
// secret-protected invocation naming one Supabase tournament, performs a
// full refresh (2 Challonge API calls per invocation, plus a conditional 3rd
// when the completion check is armed — see runFreeze, F68) and upserts the
// results into RFC-007's two cache tables (challonge_participants_cache,
// challonge_matches_cache). Never polled/scheduled — the organizer triggers
// it manually after validating each round's results in Challonge. When the
// tournament is genuinely complete (F68) and has a season assigned (F55),
// the same trigger also freezes tournament_results (RFC-012) — one-way by
// default (F56), overridable with an explicit refreeze flag (F72).
//
// Request:  POST {SUPABASE_URL}/functions/v1/challonge-sync
//           header  x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET>
//           body    {"tournament_id": <Supabase tournaments.id, bigint>}                    -- default mode
//           body    {"tournament_id": <Supabase tournaments.id, bigint>, "refreeze": true}   -- explicit correction (F72)
//
// Secrets (organizer-provisioned, never committed):
//   supabase secrets set CHALLONGE_API_KEY=... CHALLONGE_SYNC_SECRET=...
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-provisioned by Supabase
// for every Edge Function — no manual secret needed for those two.
//
// DEVIATION FROM RFC-008 §3.4 (documented, not silent): the RFC describes
// Challonge API v1 auth as HTTP Basic Auth with an "arbitrary" username.
// Verifying this against real client libraries at implementation time found
// conflicting practice — some use real-username Basic Auth, others use the
// `?api_key=` query parameter, and Challonge's own docs confirm both are
// valid. This function uses the query-parameter method: it needs no
// username at all, sidestepping the ambiguity entirely. See RFC-008's
// Completion record for the full rationale.

import {
  hasAmbiguousGroupPlayerIds,
  mapMatch,
  mapParticipant,
  mapParticipantForFreeze,
  normalizeName,
  type MatchCacheRow,
  type ParticipantCacheRow,
  type RawChallongeMatch,
  type RawChallongeParticipant,
} from "./mapping.ts";
import {
  allMatchesComplete,
  awardedPoints,
  findNullFinalRanks,
  FORMULA_VERSION,
} from "./points.ts";

type FetchResult<T> = { ok: true; data: T } | { ok: false; error: string };

type TournamentResolution =
  | {
    status: "ok";
    challongeTournamentId: string;
    seasonId: number | null;
    completedAt: string | null;
    tierId: number | null;
    multiplier: number | null;
  }
  | { status: "not_found" }
  | { status: "no_link" }
  | { status: "error"; detail: string };

// RFC-011's tournament_results row shape (§3.5 of that RFC). Every field
// here is `not null` on the table side.
interface TournamentResultRow {
  tournament_id: number;
  challonge_participant_id: number;
  player_id: number | null;
  profile_id: number | null;
  ingame_name: string;
  final_rank: number;
  awarded_points: number;
  season_id: number;
  multiplier: number;
  formula_version: string;
  participant_count: number;
  frozen_at: string;
  freeze_count: number;
}

type FreezeOutcome =
  | {
    status: "frozen";
    results_written: number;
    freeze_count: number;
    season_id: number;
    multiplier: number;
    total_points_awarded: number;
  }
  | {
    status: "already_frozen" | "no_season" | "in_progress" | "not_yet_complete";
    detail: string;
  }
  | {
    status: "refused";
    reason:
      | "null_final_rank"
      | "no_multiplier"
      | "no_participants"
      | "third_call_failed"
      | "read_failed"
      | "write_failed";
    message: string;
    participants?: { id: number; name: string }[];
  };

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function errorResponse(status: number, message: string): Response {
  return jsonResponse(status, { status: "error", message });
}

async function resolveTournament(
  supabaseUrl: string,
  serviceRoleKey: string,
  tournamentId: number,
): Promise<TournamentResolution> {
  // Widened select (RFC-012) — same single round trip, now also pulling
  // everything the freeze needs: season_id/completed_at for F55/F56, and the
  // tier's resolved multiplier via PostgREST resource embedding on tier_id.
  const url =
    `${supabaseUrl}/rest/v1/tournaments?id=eq.${tournamentId}&select=id,challonge_tournament_id,season_id,completed_at,tier_id,tournament_tiers(multiplier)`;
  try {
    const resp = await fetch(url, {
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
      },
    });
    if (!resp.ok) {
      return { status: "error", detail: `tournaments query failed (status ${resp.status})` };
    }
    const rows = await resp.json();
    if (!Array.isArray(rows) || rows.length === 0) {
      return { status: "not_found" };
    }
    const row = rows[0] as {
      challonge_tournament_id: string | null;
      season_id: number | null;
      completed_at: string | null;
      tier_id: number | null;
      tournament_tiers: { multiplier: number | string } | { multiplier: number | string }[] | null;
    };
    if (!row.challonge_tournament_id) {
      return { status: "no_link" };
    }
    // PostgREST renders a to-one FK embed as an object, but normalize
    // defensively in case a future schema change ever turns it to-many — a
    // to-many render would otherwise silently yield `undefined` here.
    const embed = Array.isArray(row.tournament_tiers) ? row.tournament_tiers[0] : row.tournament_tiers;
    const multiplierRaw = embed ? Number(embed.multiplier) : NaN;
    // Never default to 1.0 — a missing multiplier refuses the freeze later
    // (RULES §22) rather than silently under/over-pricing an event.
    const multiplier = Number.isFinite(multiplierRaw) ? multiplierRaw : null;
    return {
      status: "ok",
      challongeTournamentId: row.challonge_tournament_id,
      seasonId: row.season_id,
      completedAt: row.completed_at,
      tierId: row.tier_id,
      multiplier,
    };
  } catch (err) {
    return { status: "error", detail: String(err) };
  }
}

async function fetchChallongeList(
  endpointUrl: string,
  apiKey: string,
  wrapperKey: string,
): Promise<FetchResult<Record<string, unknown>[]>> {
  try {
    const url = `${endpointUrl}?api_key=${encodeURIComponent(apiKey)}`;
    const resp = await fetch(url);
    if (!resp.ok) {
      return { ok: false, error: `${endpointUrl} returned HTTP ${resp.status}` };
    }
    const body = await resp.json();
    if (!Array.isArray(body)) {
      return { ok: false, error: `${endpointUrl} returned a non-array response` };
    }
    return {
      ok: true,
      data: body.map((wrapped) => (wrapped as Record<string, unknown>)[wrapperKey] as Record<string, unknown>),
    };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
}

function fetchChallongeParticipants(
  challongeTournamentId: string,
  apiKey: string,
): Promise<FetchResult<RawChallongeParticipant[]>> {
  return fetchChallongeList(
    `https://api.challonge.com/v1/tournaments/${encodeURIComponent(challongeTournamentId)}/participants.json`,
    apiKey,
    "participant",
  ) as Promise<FetchResult<RawChallongeParticipant[]>>;
}

function fetchChallongeMatches(
  challongeTournamentId: string,
  apiKey: string,
): Promise<FetchResult<RawChallongeMatch[]>> {
  return fetchChallongeList(
    `https://api.challonge.com/v1/tournaments/${encodeURIComponent(challongeTournamentId)}/matches.json`,
    apiKey,
    "match",
  ) as Promise<FetchResult<RawChallongeMatch[]>>;
}

// F68 — the conditional third Challonge call. Called from exactly one
// place: inside runFreeze, after allMatchesComplete(cachedStates) returns
// true. /tournaments/{id}.json returns a single {"tournament": {...}} object
// rather than an array, so this does not reuse fetchChallongeList.
type RawChallongeTournament = {
  state: string;
  progress_meter?: number | null;
  completed_at?: string | null;
};

async function fetchChallongeTournament(
  challongeTournamentId: string,
  apiKey: string,
): Promise<FetchResult<RawChallongeTournament>> {
  try {
    const url =
      `https://api.challonge.com/v1/tournaments/${encodeURIComponent(challongeTournamentId)}.json?api_key=${
        encodeURIComponent(apiKey)
      }`;
    const resp = await fetch(url);
    if (!resp.ok) {
      return { ok: false, error: `tournament.json returned HTTP ${resp.status}` };
    }
    const body = await resp.json();
    const tournament = (body as Record<string, unknown> | null)?.tournament;
    if (!tournament || typeof tournament !== "object") {
      return { ok: false, error: "tournament.json returned a non-object tournament" };
    }
    return { ok: true, data: tournament as RawChallongeTournament };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
}

async function upsertRows(
  supabaseUrl: string,
  serviceRoleKey: string,
  table: string,
  onConflict: string,
  rows: (ParticipantCacheRow | MatchCacheRow | TournamentResultRow)[],
): Promise<{ ok: true } | { ok: false; error: string }> {
  // Nothing to upsert (e.g. a freshly-created Challonge tournament with no
  // participants yet) is not a failure.
  if (rows.length === 0) {
    return { ok: true };
  }
  const url = `${supabaseUrl}/rest/v1/${table}?on_conflict=${onConflict}`;
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
        // Upsert, never plain append — RFC-007/RULES §14's mandatory contract.
        prefer: "resolution=merge-duplicates",
      },
      body: JSON.stringify(rows),
    });
    if (!resp.ok) {
      const detail = await resp.text().catch(() => "");
      return { ok: false, error: `${table} upsert returned HTTP ${resp.status}${detail ? `: ${detail}` : ""}` };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, error: String(err) };
  }
}

// RFC-012 — the one-way results freeze (F51-F57, F68, F72, F74). Called
// once, from step 7 of the handler, AFTER both caches have already been
// upserted — so a freeze refusal never costs the organizer their cache
// update. Never throws: every fetch is wrapped and every failure becomes a
// `refused` outcome. Does not thread state through the cache-sync code
// above; this function is textually separate on purpose (RULES §22's
// warning that cache tables and tournament_results carry OPPOSING write
// semantics — upsert-forever vs. write-once — and must never share a helper
// that "just upserts" without the caller stating which semantics it wants).
async function runFreeze(
  supabaseUrl: string,
  serviceRoleKey: string,
  challongeApiKey: string,
  tournamentId: number,
  tournament: {
    challongeTournamentId: string;
    seasonId: number | null;
    completedAt: string | null;
    multiplier: number | null;
  },
  rawParticipants: RawChallongeParticipant[],
  refreeze: boolean,
): Promise<FreezeOutcome> {
  // Step 1 (F56/F72): already frozen and no explicit override. Note the
  // consequence this preserves: a frozen tournament whose season_id was
  // later nulled still reports already_frozen, not no_season — the freeze
  // already happened.
  if (tournament.completedAt !== null && !refreeze) {
    return {
      status: "already_frozen",
      detail: `tournament was frozen at ${tournament.completedAt}; pass refreeze:true to recompute`,
    };
  }

  // Step 2 (F55). completed_at is deliberately left null here — this is
  // what makes Journey O recoverable: set season_id in Studio and retrigger.
  if (tournament.seasonId === null) {
    return { status: "no_season", detail: "tournament has no season_id set" };
  }

  // Step 3 (in_progress). Read match states from the cache the function
  // JUST wrote (step 6 of the handler), not from in-memory rows, so this
  // reflects what actually landed.
  //
  // NOTE: PostgREST caps rows per request. A bracket large enough to be
  // truncated could hide open matches and arm the third call early — that
  // is accepted, uncorrected: the third call is the completion authority, so
  // a truncated read can only cost one extra Challonge call, never a wrong
  // freeze.
  let matchStates: string[];
  try {
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/challonge_matches_cache?tournament_id=eq.${tournamentId}&select=state`,
      { headers: { apikey: serviceRoleKey, authorization: `Bearer ${serviceRoleKey}` } },
    );
    if (!resp.ok) {
      return {
        status: "refused",
        reason: "read_failed",
        message: `[freeze] reading challonge_matches_cache failed (status ${resp.status})`,
      };
    }
    const rows = (await resp.json()) as { state: string }[];
    matchStates = rows.map((r) => r.state);
  } catch (err) {
    return { status: "refused", reason: "read_failed", message: `[freeze] reading challonge_matches_cache failed: ${err}` };
  }

  if (!allMatchesComplete(matchStates)) {
    const openCount = matchStates.filter((s) => s !== "complete").length;
    return {
      status: "in_progress",
      detail: `${openCount} of ${matchStates.length} cached matches are not complete`,
    };
  }

  // Step 4 (F68) — THE GROUP-STAGE BOUNDARY. allMatchesComplete only ARMS
  // this check; Challonge's own tournament.state is the authority, never the
  // cache alone. Fired from exactly this one place, guarded by exactly this
  // one condition.
  console.log(`[freeze] completion check armed — third Challonge call for tournament ${tournamentId}`);
  const tourneyResult = await fetchChallongeTournament(tournament.challongeTournamentId, challongeApiKey);
  if (!tourneyResult.ok) {
    return {
      status: "refused",
      reason: "third_call_failed",
      message: `[freeze] third Challonge call failed: ${tourneyResult.error}`,
    };
  }
  if (tourneyResult.data.state !== "complete") {
    return {
      status: "not_yet_complete",
      detail:
        `Challonge reports state=${tourneyResult.data.state}, progress_meter=${tourneyResult.data.progress_meter ?? "null"} — the final bracket may not exist yet`,
    };
  }

  // Step 5 — no_multiplier. Checked immediately before the write path so a
  // mid-event trigger never 500s over a tier anomaly it did not need to
  // read. Never defaulted to 1.0 (RULES §22).
  if (tournament.multiplier === null) {
    console.error(`[freeze] tournament ${tournamentId} has no resolvable tier multiplier`);
    return {
      status: "refused",
      reason: "no_multiplier",
      message: "[freeze] tournament_tiers embed was null on a non-null tier_id",
    };
  }

  // Step 6 (F54) — null_final_rank. A partial freeze is worse than none,
  // and under F56 it would be one-way.
  const freezeParticipants = rawParticipants.map(mapParticipantForFreeze);
  if (freezeParticipants.length === 0) {
    return { status: "refused", reason: "no_participants", message: "[freeze] Challonge returned zero participants" };
  }
  const badRanks = findNullFinalRanks(freezeParticipants);
  if (badRanks.length > 0) {
    console.error(
      `[freeze] ${badRanks.length} participant(s) have a null/invalid final_rank`,
      badRanks,
    );
    return {
      status: "refused",
      reason: "null_final_rank",
      message: `freeze refused: ${badRanks.length} participant(s) have a null final_rank`,
      participants: badRanks,
    };
  }

  // Step 7 — the freeze itself. No filtering on `active` anywhere (F74).

  // Reads.
  let players: { id: number; ingame_name: string; profile_id: number | null }[];
  try {
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/players?tournament_id=eq.${tournamentId}&select=id,ingame_name,profile_id`,
      { headers: { apikey: serviceRoleKey, authorization: `Bearer ${serviceRoleKey}` } },
    );
    if (!resp.ok) {
      return { status: "refused", reason: "read_failed", message: `[freeze] reading players failed (status ${resp.status})` };
    }
    players = await resp.json();
  } catch (err) {
    return { status: "refused", reason: "read_failed", message: `[freeze] reading players failed: ${err}` };
  }

  let previousFreezeCount = 0;
  try {
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/tournament_results?tournament_id=eq.${tournamentId}&select=freeze_count&order=freeze_count.desc&limit=1`,
      { headers: { apikey: serviceRoleKey, authorization: `Bearer ${serviceRoleKey}` } },
    );
    if (!resp.ok) {
      return {
        status: "refused",
        reason: "read_failed",
        message: `[freeze] reading tournament_results failed (status ${resp.status})`,
      };
    }
    const rows = (await resp.json()) as { freeze_count: number }[];
    previousFreezeCount = rows.length > 0 ? rows[0].freeze_count : 0;
  } catch (err) {
    return { status: "refused", reason: "read_failed", message: `[freeze] reading tournament_results failed: ${err}` };
  }

  // Row construction. One UTC timestamp and one freeze_count for the whole
  // freeze, so a tournament's rows always share both.
  const frozenAt = new Date().toISOString();
  const freezeCount = previousFreezeCount + 1;
  // Unique by construction: players_tournament_name_idx is unique on
  // (tournament_id, lower(ingame_name)), so this Map can never lose a row.
  const rosterByName = new Map(players.map((p) => [normalizeName(p.ingame_name), p]));

  const rows: TournamentResultRow[] = freezeParticipants.map((p) => {
    // F57: a miss here is NORMAL — a bracket entrant with no roster row
    // still gets frozen, with player_id/profile_id left null.
    const roster = rosterByName.get(normalizeName(p.name));
    return {
      tournament_id: tournamentId,
      // The top-level id, never the group id (the dual-id trap, RFC-009) —
      // this is the bracket's stable id and tournament_results' unique key.
      challonge_participant_id: p.challongeParticipantId,
      player_id: roster?.id ?? null,
      profile_id: roster?.profile_id ?? null, // RFC-013 backfills the nulls later
      ingame_name: p.name, // Challonge's value verbatim (RULES §13)
      final_rank: p.finalRank as number, // validated non-null/integer/>=1 above
      awarded_points: awardedPoints(p.finalRank as number, tournament.multiplier as number),
      season_id: tournament.seasonId as number,
      multiplier: tournament.multiplier as number, // the resolved number, never tier_id (F67)
      formula_version: FORMULA_VERSION,
      participant_count: freezeParticipants.length, // the BRACKET, not the roster (F47)
      frozen_at: frozenAt,
      freeze_count: freezeCount,
    };
  });

  // Writes, in this order and no other.
  //
  // 1. Upsert. `upsertRows` is a mechanical POST helper reused as-is; the
  //    write-once semantics of tournament_results are enforced by step 1's
  //    already_frozen guard above, not by this helper.
  const upsert = await upsertRows(
    supabaseUrl,
    serviceRoleKey,
    "tournament_results",
    "tournament_id,challonge_participant_id",
    rows,
  );
  if (!upsert.ok) {
    return { status: "refused", reason: "write_failed", message: `[freeze] tournament_results upsert failed: ${upsert.error}` };
  }

  // 2. Prune. Upsert-then-prune, in this order, so there is never a window
  //    where the tournament has no results. A prune that deletes anything is
  //    an anomaly (a participant vanished from a completed bracket) — warn,
  //    never fail.
  //
  //    CRASH-RECOVERY ASYMMETRY between a first freeze and a refreeze, if the
  //    function dies right here (upsert done, prune not yet run):
  //      - First freeze: completed_at is still null (write 3 hasn't run), so
  //        the NEXT DEFAULT-MODE trigger falls through step 1's already_frozen
  //        guard, reruns the whole freeze, and this prune executes again —
  //        self-healing, same mechanism as the write-1/write-3 gap documented
  //        below.
  //      - Refreeze: completed_at was already non-null *before* this call
  //        started (that is what made it a refreeze), so step 3 below leaves
  //        it untouched either way — its value carries no information about
  //        whether THIS refreeze's prune succeeded. The next default-mode
  //        trigger reads already_frozen and returns immediately, without ever
  //        reaching this code again. The failed prune is NOT retried, and any
  //        stale (vanished-participant) row from the state being refrozen
  //        stays behind until an operator explicitly refreezes again.
  //    No fix shipped for this: retrying it would mean acting on a refreeze
  //    flag whose upsert already landed, which is a correctness question for
  //    a future RFC, not a hidden default here (RULES §20 — flag, don't
  //    silently resolve).
  try {
    const ids = freezeParticipants.map((p) => p.challongeParticipantId).join(",");
    const pruneUrl =
      `${supabaseUrl}/rest/v1/tournament_results?tournament_id=eq.${tournamentId}&challonge_participant_id=not.in.(${ids})`;
    const resp = await fetch(pruneUrl, {
      method: "DELETE",
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
        prefer: "return=representation",
      },
    });
    if (!resp.ok) {
      const detail = await resp.text().catch(() => "");
      return {
        status: "refused",
        reason: "write_failed",
        message: `[freeze] tournament_results prune failed (status ${resp.status})${detail ? `: ${detail}` : ""}`,
      };
    }
    const pruned = (await resp.json().catch(() => [])) as unknown[];
    if (pruned.length > 0) {
      console.warn(`[freeze] pruned ${pruned.length} stale tournament_results row(s) for tournament ${tournamentId}`);
    }
  } catch (err) {
    return { status: "refused", reason: "write_failed", message: `[freeze] tournament_results prune failed: ${err}` };
  }

  // 3. Latch completed_at, LAST — it must not be set before the rows it
  //    claims exist. Sent only when currently null: on a refreeze the
  //    original closure time is left intact and frozen_at/freeze_count carry
  //    the correction instead (RULES §22 — a correction must not restate
  //    history).
  //
  //    On the absence of transactions: PostgREST gives no cross-request
  //    transaction, so a crash between write 1 and this write leaves rows
  //    written with completed_at still null. That state is SELF-HEALING —
  //    the next default trigger sees completed_at null, re-runs the freeze,
  //    and the upsert overwrites the same rows with identical values. The
  //    alternative (latch first) would leave a permanently half-frozen
  //    tournament that only refreeze could fix.
  if (tournament.completedAt === null) {
    try {
      const resp = await fetch(`${supabaseUrl}/rest/v1/tournaments?id=eq.${tournamentId}`, {
        method: "PATCH",
        headers: {
          apikey: serviceRoleKey,
          authorization: `Bearer ${serviceRoleKey}`,
          "content-type": "application/json",
          prefer: "return=minimal",
        },
        body: JSON.stringify({ completed_at: frozenAt }),
      });
      if (!resp.ok) {
        const detail = await resp.text().catch(() => "");
        return {
          status: "refused",
          reason: "write_failed",
          message: `[freeze] setting tournaments.completed_at failed (status ${resp.status})${detail ? `: ${detail}` : ""}`,
        };
      }
    } catch (err) {
      return { status: "refused", reason: "write_failed", message: `[freeze] setting tournaments.completed_at failed: ${err}` };
    }
  } else {
    console.log(`[freeze] refreeze — leaving tournaments.completed_at at its original ${tournament.completedAt}`);
  }

  const totalPointsAwarded = Math.round(rows.reduce((sum, r) => sum + r.awarded_points, 0) * 100) / 100;
  console.log(
    `[freeze] tournament ${tournamentId} frozen: ${rows.length} results, freeze_count=${freezeCount}, total_points_awarded=${totalPointsAwarded}`,
  );
  return {
    status: "frozen",
    results_written: rows.length,
    freeze_count: freezeCount,
    season_id: tournament.seasonId as number,
    multiplier: tournament.multiplier as number,
    total_points_awarded: totalPointsAwarded,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return errorResponse(405, "method not allowed");
  }

  // 1. Secret check — before any Supabase/Challonge call is made (F31).
  const expectedSecret = Deno.env.get("CHALLONGE_SYNC_SECRET");
  const providedSecret = req.headers.get("x-challonge-sync-secret");
  if (!expectedSecret || !providedSecret || providedSecret !== expectedSecret) {
    return errorResponse(401, "invalid or missing secret");
  }

  // 2. Body parse.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "tournament_id is required and must be a number");
  }
  const tournamentId = (body as Record<string, unknown> | null)?.tournament_id;
  if (typeof tournamentId !== "number" || !Number.isFinite(tournamentId)) {
    return errorResponse(400, "tournament_id is required and must be a number");
  }
  // F72 — the refreeze flag. Absent and `false` are identical; anything
  // other than the boolean `true` is a 400, not a silent no-op, so an
  // organizer's typo doesn't get quietly ignored.
  const refreezeRaw = (body as Record<string, unknown> | null)?.refreeze;
  if (refreezeRaw !== undefined && typeof refreezeRaw !== "boolean") {
    return errorResponse(400, "refreeze must be a boolean");
  }
  const refreeze = refreezeRaw === true;

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const challongeApiKey = Deno.env.get("CHALLONGE_API_KEY");
  if (!supabaseUrl || !serviceRoleKey || !challongeApiKey) {
    return errorResponse(500, "function is missing required environment configuration");
  }

  // 3. Resolve + validate the tournament's Challonge link.
  const tournament = await resolveTournament(supabaseUrl, serviceRoleKey, tournamentId);
  if (tournament.status === "not_found") {
    return errorResponse(404, "tournament not found");
  }
  if (tournament.status === "no_link") {
    return errorResponse(400, "tournament has no challonge_tournament_id set");
  }
  if (tournament.status === "error") {
    return errorResponse(500, `Supabase read failed: ${tournament.detail}`);
  }

  // 4. Both Challonge calls must succeed before any write begins
  // (all-or-nothing contract, RFC-007/RULES §14).
  const [participantsResult, matchesResult] = await Promise.all([
    fetchChallongeParticipants(tournament.challongeTournamentId, challongeApiKey),
    fetchChallongeMatches(tournament.challongeTournamentId, challongeApiKey),
  ]);
  if (!participantsResult.ok || !matchesResult.ok) {
    const detail = !participantsResult.ok ? participantsResult.error : (matchesResult as { error: string }).error;
    return errorResponse(502, `Challonge API request failed: ${detail}`);
  }

  // 5. Map (pure, no network — see mapping.ts).
  for (const p of participantsResult.data) {
    // F54 defensive check. See mapping.ts's group_player_ids comment: every
    // participant observed live has had at most one entry, but this is not
    // guaranteed. Detection is pure (hasAmbiguousGroupPlayerIds); the
    // console.warn is I/O and belongs here, in the caller, not in the pure
    // module. mapParticipant still maps element 0 either way.
    if (hasAmbiguousGroupPlayerIds(p)) {
      console.warn(`[sync] participant ${p.id} (${p.name}) has more than one group_player_id — using element 0`);
    }
  }
  const participantRows = participantsResult.data.map((p) => mapParticipant(p, tournamentId));
  const matchRows = matchesResult.data.map((m) => mapMatch(m, tournamentId));

  // 6. Upsert — never delete/append.
  const participantsUpsert = await upsertRows(
    supabaseUrl,
    serviceRoleKey,
    "challonge_participants_cache",
    "tournament_id,challonge_participant_id",
    participantRows,
  );
  if (!participantsUpsert.ok) {
    return errorResponse(500, `Supabase upsert failed: ${participantsUpsert.error}`);
  }
  const matchesUpsert = await upsertRows(
    supabaseUrl,
    serviceRoleKey,
    "challonge_matches_cache",
    "tournament_id,challonge_match_id",
    matchRows,
  );
  if (!matchesUpsert.ok) {
    return errorResponse(500, `Supabase upsert failed: ${matchesUpsert.error}`);
  }

  // 7. Freeze (RFC-012) — runs after both caches are refreshed, so a freeze
  // refusal never costs the organizer their cache update. Targets the
  // request's explicit tournament_id, never the active tournament.
  const freeze = await runFreeze(
    supabaseUrl,
    serviceRoleKey,
    challongeApiKey,
    tournamentId,
    tournament,
    participantsResult.data,
    refreeze,
  );

  // 8. Response. A skip is HTTP 200 — the cache sync itself succeeded, and
  // an organizer must not read a normal mid-event trigger as a failure. A
  // refusal is loud because it is not a normal state.
  const successBody = {
    status: "ok",
    participants_synced: participantRows.length,
    matches_synced: matchRows.length,
    freeze,
  };
  if (freeze.status === "refused") {
    const httpStatus = freeze.reason === "third_call_failed" ? 502 : 500;
    return jsonResponse(httpStatus, {
      status: "error",
      message: freeze.message,
      freeze,
    });
  }
  return jsonResponse(200, successBody);
});
