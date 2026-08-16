// Pure points-engine logic (RFC-012 §3.2/§6.1 — F51, F52, F53). No imports,
// no I/O, no console.* — the TypeScript sibling of bot.py's normalize_name /
// render_team_text / pick_opponent_id / is_cache_stale. Every function here
// is decidable from its arguments alone; tested in points_test.ts.

// F53. A future rule change bumps this — never rewrite it in place, since
// tournament_results.formula_version is what makes old frozen results
// explicable under whatever the formula becomes later.
export const FORMULA_VERSION = "v1";

// F51. Bucket edges sit on 1 / 2 / 3 / 5 / 9 / 17 — exactly where single-elim
// tie ranks land. THAT ALIGNMENT IS THE WHOLE POINT: it is what makes
// Challonge's tied placements pay their members equally, automatically.
//
// DO NOT "simplify" this into a linear formula. multiplier × (N − rank + 1)
// opens holes at ranks 4 and 6–8 (which competition-style ranking never
// emits) and pays only three points between 2nd and 5th. Verified against
// real data — see the tournament-3 fixture in points_test.ts.
//
// No field-size term: `multiplier` already encodes how big a deal the event
// was, and a second scaling axis makes the number unexplainable to a player
// who asks why they got 30.
//
// This is a RANGE LADDER, not an index lookup: iterate in this (descending
// minRank) order and return the first bucket whose minRank the rank meets or
// exceeds.
const PLACEMENT_TABLE: ReadonlyArray<{ minRank: number; points: number }> = [
  { minRank: 17, points: 5 }, // participation floor
  { minRank: 9, points: 15 },
  { minRank: 5, points: 30 },
  { minRank: 3, points: 50 },
  { minRank: 2, points: 70 },
  { minRank: 1, points: 100 },
];

export function basePointsForRank(finalRank: number): number {
  // Number.isInteger rejects 1.5, NaN, Infinity and -Infinity in one guard.
  // A rank below 1 or non-integer means Challonge's shape changed; step 6 of
  // the freeze algorithm already refuses that case loudly rather than
  // storing a guess, so this throws instead of clamping.
  if (!Number.isInteger(finalRank) || finalRank < 1) {
    throw new Error(`basePointsForRank: invalid finalRank ${finalRank}`);
  }
  for (const bucket of PLACEMENT_TABLE) {
    if (finalRank >= bucket.minRank) {
      return bucket.points;
    }
  }
  // Unreachable: the minRank: 1 bucket catches everything >= 1, and the
  // guard above already rejected everything < 1. Written as a defensive
  // throw, not a `return 0`, so a future edit to the table can't silently
  // fall through to a wrong answer.
  throw new Error(`basePointsForRank: no bucket matched finalRank ${finalRank}`);
}

export function awardedPoints(finalRank: number, multiplier: number): number {
  if (!Number.isFinite(multiplier) || multiplier < 0) {
    throw new Error(`awardedPoints: invalid multiplier ${multiplier}`);
  }
  const raw = basePointsForRank(finalRank) * multiplier;
  // Rounds to 2 dp, matching tournament_results.awarded_points's
  // numeric(8,2). With today's 1.0/2.0/3.0 tiers every product is whole,
  // which is exactly why this would never be added later if it is not added
  // now (RFC-012 §8) — a future non-integer multiplier (e.g. 2.5) needs it.
  return Math.round(raw * 100) / 100;
}

// F68. This only ARMS the conditional third Challonge call — it never
// decides completion on its own; Challonge's own tournament.state is the
// authority (see index.ts's runFreeze). An EMPTY match list must read
// false: a freshly-created bracket with no matches would otherwise
// vacuously satisfy "every state is complete" and arm the third call on its
// very first sync.
export function allMatchesComplete(states: readonly string[]): boolean {
  return states.length > 0 && states.every((s) => s === "complete");
}

// F54. Flags every participant whose final_rank is not a valid rank (null,
// undefined, 0, or non-integer) so the freeze can refuse loudly BEFORE any
// row is written, rather than have basePointsForRank throw mid-write after
// rows have already started landing. Returned in input order. The response
// `reason` stays the locked "null_final_rank" regardless of which of these
// cases triggered it.
export function findNullFinalRanks(
  participants: readonly {
    challongeParticipantId: number;
    name: string;
    finalRank: number | null;
  }[],
): { id: number; name: string }[] {
  const bad: { id: number; name: string }[] = [];
  for (const p of participants) {
    if (
      p.finalRank === null ||
      p.finalRank === undefined ||
      !Number.isInteger(p.finalRank) ||
      p.finalRank < 1
    ) {
      bad.push({ id: p.challongeParticipantId, name: p.name });
    }
  }
  return bad;
}
