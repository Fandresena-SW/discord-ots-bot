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

  // F54. Competition-style, WITH TIES AND GAPS: a real 14-player group-stage
  // event returned 1, 2, 3, 3, 5, 5, 5, 5, 9, 10, 11, 12, 13, 14 — ranks 4,
  // 6, 7 and 8 simply do not exist. NOTHING may treat this as a dense 1..N
  // sequence, index into an array by it, or assume max(rank) === count.
  // Non-null for every participant on a complete tournament, including those
  // who never reached the final bracket. Verified live 2026-07-31 against
  // Challonge tournament 18251698. Does NOT join ParticipantCacheRow —
  // challonge_participants_cache has no final_rank column (RFC-011
  // deliberately did not add one); the rank's durable home is
  // tournament_results. See mapParticipantForFreeze below.
  final_rank?: number | null;

  // F74 — TRAP, at the same depth as the dual-id trap above. Challonge also
  // sends `active`. It is DELIBERATELY NOT TYPED HERE so no one can filter
  // on it by accident.
  //
  // `active` tracks STILL ADVANCING, not VALIDLY ENTERED. On that same live
  // tournament it was false for all six group-stage non-qualifiers and true
  // for the eight who advanced — so the natural-looking "skip inactive
  // participants" filter silently drops 43% of the field, and precisely the
  // lower-placed players the participation floor (F51) exists to reward.
  // Freeze the WHOLE participant list. If a genuine DQ/forfeit signal is
  // ever needed, it is not this field (PRD §37 known unknown — do not guess).
}

// F54. A freeze-time view of a participant: only what awardedPoints and the
// tournament_results write need. Deliberately NOT merged into
// ParticipantCacheRow (see the final_rank comment above).
export interface FreezeParticipant {
  challongeParticipantId: number;
  name: string;
  finalRank: number | null;
}

export function mapParticipantForFreeze(
  raw: RawChallongeParticipant,
): FreezeParticipant {
  return {
    challongeParticipantId: raw.id,
    name: raw.name,
    // `?? null` preserves a real 0 as 0 (left for findNullFinalRanks to
    // reject) and never coerces a genuine null into 0.
    finalRank: raw.final_rank ?? null,
  };
}

// F54 defensive check. Every participant in the live verification had
// exactly one group_player_ids entry, matching mapParticipant's
// single-column shape — but that is not guaranteed. Pure predicate so the
// caller (index.ts) can log a console.warn without putting I/O in this
// module; mapParticipant itself keeps mapping element 0 unchanged either way.
export function hasAmbiguousGroupPlayerIds(
  raw: RawChallongeParticipant,
): boolean {
  return (raw.group_player_ids?.length ?? 0) > 1;
}

// Third implementation site of the same trim-then-lower contract as bot.py's
// normalize_name (bot.py:85) — change one, change all three (RULES §4). Used
// by the freeze's roster join (F57) to match a Challonge participant name
// against players.ingame_name.
export function normalizeName(value: string): string {
  return value.trim().toLowerCase();
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
