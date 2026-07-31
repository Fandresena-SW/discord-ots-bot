// Pure-logic tests for the Challonge payload -> cache-row mapping
// (RFC-008 §3.5/§10). No network, no Supabase/Challonge calls — mirrors
// RFC-004's pure-logic testing precedent (RULES §18) on the Deno side.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { mapMatch, mapParticipant } from "./mapping.ts";

Deno.test("mapParticipant maps id and name as-is, no group_player_id when absent", () => {
  const row = mapParticipant({ id: 1001, name: "giovlacouture" }, 42);
  assertEquals(row, {
    tournament_id: 42,
    challonge_participant_id: 1001,
    challonge_group_player_id: null,
    ingame_name: "giovlacouture",
  });
});

Deno.test("mapParticipant maps group_player_id to null when group_player_ids is null", () => {
  const row = mapParticipant({ id: 1001, name: "giovlacouture", group_player_ids: null }, 42);
  assertEquals(row.challonge_participant_id, 1001);
  assertEquals(row.challonge_group_player_id, null);
});

Deno.test("mapParticipant maps group_player_id to null when group_player_ids is empty", () => {
  const row = mapParticipant({ id: 1001, name: "giovlacouture", group_player_ids: [] }, 42);
  assertEquals(row.challonge_participant_id, 1001);
  assertEquals(row.challonge_group_player_id, null);
});

Deno.test("mapParticipant keeps both the top-level id and group_player_ids[0]", () => {
  // Real Challonge group-stage payload shape: matches.json's player1_id/
  // player2_id reference group_player_ids[0] (46790479) while the final
  // bracket generated once group stages end references the top-level id
  // (299830841) instead — both must be kept, not one picked over the other.
  const row = mapParticipant({ id: 299830841, name: "Asan", group_player_ids: [46790479] }, 42);
  assertEquals(row.challonge_participant_id, 299830841);
  assertEquals(row.challonge_group_player_id, 46790479);
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
