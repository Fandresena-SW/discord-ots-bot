// Pure Challonge-payload -> cache-row mapping (RFC-008 §3.5). No network,
// no Supabase/Challonge calls here — kept separate from index.ts so it can
// be unit-tested in isolation (see mapping_test.ts).

export interface ParticipantCacheRow {
  tournament_id: number;
  challonge_participant_id: number;
  challonge_group_player_id: number | null;
  ingame_name: string;
}

export interface MatchCacheRow {
  tournament_id: number;
  challonge_match_id: number;
  round: number | null;
  state: string;
  player1_challonge_id: number | null;
  player2_challonge_id: number | null;
  winner_challonge_id: number | null;
}

// Raw shape after unwrapping Challonge's {"participant": {...}} /
// {"match": {...}} wrapper (index.ts does the unwrapping before calling
// these). Only the fields this RFC cares about are typed; Challonge sends
// more (seed, active, created_at, ...) that we deliberately ignore.
export interface RawChallongeParticipant {
  id: number;
  name: string;
  // Present (non-empty) only when the tournament has Challonge group stages
  // enabled. Group-stage matches' player1_id/player2_id reference THIS id,
  // not the participant's top-level `id` — but Challonge keeps returning it
  // even after the group stage ends, and the final bracket it generates
  // then uses the top-level `id` instead. Both ids can be "live" join keys
  // depending on which phase's matches are currently open — see
  // mapParticipant, which keeps both rather than picking one.
  group_player_ids?: number[] | null;
}

export interface RawChallongeMatch {
  id: number;
  round: number | null;
  state: string;
  player1_id: number | null;
  player2_id: number | null;
  winner_id: number | null;
}

export function mapParticipant(
  raw: RawChallongeParticipant,
  tournamentId: number,
): ParticipantCacheRow {
  return {
    tournament_id: tournamentId,
    // Stable top-level id: the upsert identity, and the join key for
    // final-bracket (post-group-stage) matches.
    challonge_participant_id: raw.id,
    // Group-stage-phase join key, when Challonge sends one. Bot-side
    // opponent resolution must check a candidate match against EITHER this
    // or challonge_participant_id (see bot.py's fetch_current_opponent) —
    // picking only one silently breaks resolution for whichever phase
    // doesn't use it.
    challonge_group_player_id: raw.group_player_ids?.[0] ?? null,
    // Stored as-is: RFC-007's reused trim_ingame_name() trigger trims it on
    // write, so no separate trimming is needed here (RFC-008 §3.5).
    ingame_name: raw.name,
  };
}

export function mapMatch(
  raw: RawChallongeMatch,
  tournamentId: number,
): MatchCacheRow {
  return {
    tournament_id: tournamentId,
    challonge_match_id: raw.id,
    round: raw.round ?? null,
    // Challonge's own values (pending/open/complete) map verbatim onto
    // RFC-007's check constraint — never translate or remap (RULES §13).
    state: raw.state,
    player1_challonge_id: raw.player1_id ?? null,
    player2_challonge_id: raw.player2_id ?? null,
    winner_challonge_id: raw.winner_id ?? null,
  };
}
