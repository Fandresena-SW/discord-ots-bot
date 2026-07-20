// Pure-logic tests for the Challonge payload -> cache-row mapping
// (RFC-008 §3.5/§10). No network, no Supabase/Challonge calls — mirrors
// RFC-004's pure-logic testing precedent (RULES §18) on the Deno side.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { mapMatch, mapParticipant } from "./mapping.ts";

Deno.test("mapParticipant maps id and name as-is under the resolved tournament", () => {
  const row = mapParticipant({ id: 1001, name: "giovlacouture" }, 42);
  assertEquals(row, {
    tournament_id: 42,
    challonge_participant_id: 1001,
    ingame_name: "giovlacouture",
  });
});

Deno.test("mapMatch maps a normal open match with both sides fed in", () => {
  const row = mapMatch(
    { id: 5001, round: 1, state: "open", player1_id: 1001, player2_id: 1002, winner_id: null },
    42,
  );
  assertEquals(row, {
    tournament_id: 42,
    challonge_match_id: 5001,
    round: 1,
    state: "open",
    player1_challonge_id: 1001,
    player2_challonge_id: 1002,
    winner_challonge_id: null,
  });
});

Deno.test("mapMatch preserves a null second side (bye / not-yet-fed-in slot)", () => {
  const row = mapMatch(
    { id: 5002, round: 1, state: "pending", player1_id: 1003, player2_id: null, winner_id: null },
    42,
  );
  assertEquals(row.player2_challonge_id, null);
  assertEquals(row.winner_challonge_id, null);
  assertEquals(row.state, "pending");
});

Deno.test("mapMatch carries a non-null winner once a match is complete", () => {
  const row = mapMatch(
    { id: 5003, round: 2, state: "complete", player1_id: 1001, player2_id: 1002, winner_id: 1001 },
    42,
  );
  assertEquals(row.state, "complete");
  assertEquals(row.winner_challonge_id, 1001);
});
