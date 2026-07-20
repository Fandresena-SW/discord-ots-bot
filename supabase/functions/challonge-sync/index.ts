// RFC-008 — Challonge Sync Edge Function (manual trigger).
//
// The ONLY piece of this project that talks to the real Challonge API. On a
// secret-protected invocation naming one Supabase tournament, performs a
// full refresh (exactly 2 Challonge API calls) and upserts the results into
// RFC-007's two cache tables (challonge_participants_cache,
// challonge_matches_cache). Never polled/scheduled — the organizer triggers
// it manually after validating each round's results in Challonge.
//
// Request:  POST {SUPABASE_URL}/functions/v1/challonge-sync
//           header  x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET>
//           body    {"tournament_id": <Supabase tournaments.id, bigint>}
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
  mapMatch,
  mapParticipant,
  type MatchCacheRow,
  type ParticipantCacheRow,
  type RawChallongeMatch,
  type RawChallongeParticipant,
} from "./mapping.ts";

type FetchResult<T> = { ok: true; data: T } | { ok: false; error: string };

type TournamentResolution =
  | { status: "ok"; challongeTournamentId: string }
  | { status: "not_found" }
  | { status: "no_link" }
  | { status: "error"; detail: string };

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
  const url =
    `${supabaseUrl}/rest/v1/tournaments?id=eq.${tournamentId}&select=id,challonge_tournament_id`;
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
    const row = rows[0] as { challonge_tournament_id: string | null };
    if (!row.challonge_tournament_id) {
      return { status: "no_link" };
    }
    return { status: "ok", challongeTournamentId: row.challonge_tournament_id };
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

async function upsertRows(
  supabaseUrl: string,
  serviceRoleKey: string,
  table: string,
  onConflict: string,
  rows: (ParticipantCacheRow | MatchCacheRow)[],
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

  // 7. Success.
  return jsonResponse(200, {
    status: "ok",
    participants_synced: participantRows.length,
    matches_synced: matchRows.length,
  });
});
