// Pure-logic tests for the points engine (RFC-012 §3.2/§7.1 — F51, F52,
// F53). No network, no Supabase/Challonge calls — mirrors mapping_test.ts's
// pattern. This is "the single most test-worthy function in the release."

import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  allMatchesComplete,
  awardedPoints,
  basePointsForRank,
  findNullFinalRanks,
  FORMULA_VERSION,
} from "./points.ts";

// ---------------------------------------------------------------------------
// FORMULA_VERSION (F53)
// ---------------------------------------------------------------------------

Deno.test("FORMULA_VERSION is v1", () => {
  assertEquals(FORMULA_VERSION, "v1");
});

// ---------------------------------------------------------------------------
// basePointsForRank (F51)
// ---------------------------------------------------------------------------

Deno.test("basePointsForRank — every bucket edge and the rank either side", () => {
  assertEquals(basePointsForRank(1), 100);
  assertEquals(basePointsForRank(2), 70);
  assertEquals(basePointsForRank(3), 50);
  assertEquals(basePointsForRank(4), 50); // hole rank 4 falls into the rank-3 bucket
  assertEquals(basePointsForRank(5), 30);
  assertEquals(basePointsForRank(8), 30); // hole ranks 6-8 fall into the rank-5 bucket
  assertEquals(basePointsForRank(9), 15);
  assertEquals(basePointsForRank(16), 15);
  assertEquals(basePointsForRank(17), 5);
  assertEquals(basePointsForRank(100), 5);
});

Deno.test("basePointsForRank — throws on invalid rank", () => {
  assertThrows(() => basePointsForRank(0));
  assertThrows(() => basePointsForRank(-1));
  assertThrows(() => basePointsForRank(1.5));
  assertThrows(() => basePointsForRank(NaN));
  assertThrows(() => basePointsForRank(Infinity));
  assertThrows(() => basePointsForRank(-Infinity));
});

// ---------------------------------------------------------------------------
// awardedPoints (F51)
// ---------------------------------------------------------------------------

Deno.test("awardedPoints — tournament-3 real-data fixture at multiplier 1.0, total 480", () => {
  const ranks = [1, 2, 3, 3, 5, 5, 5, 5, 9, 10, 11, 12, 13, 14];
  const expected = [100, 70, 50, 50, 30, 30, 30, 30, 15, 15, 15, 15, 15, 15];
  const actual = ranks.map((r) => awardedPoints(r, 1.0));
  assertEquals(actual, expected);
  assertEquals(actual.reduce((a, b) => a + b, 0), 480);
});

Deno.test("awardedPoints — same fixture at multiplier 2.0 totals 960", () => {
  const ranks = [1, 2, 3, 3, 5, 5, 5, 5, 9, 10, 11, 12, 13, 14];
  const total = ranks.map((r) => awardedPoints(r, 2.0)).reduce((a, b) => a + b, 0);
  assertEquals(total, 960);
});

Deno.test("awardedPoints — tie equality: rank-3 and rank-5 ties pay equally", () => {
  assertEquals(awardedPoints(3, 1.0), awardedPoints(3, 1.0));
  assertEquals(awardedPoints(5, 1.0), awardedPoints(5, 1.0));
  assertEquals(awardedPoints(5, 1.0), awardedPoints(8, 1.0));
});

Deno.test("awardedPoints — multiplier axis: 1.0, 2.0, 3.0, and non-integer 2.5", () => {
  assertEquals(awardedPoints(1, 1.0), 100);
  assertEquals(awardedPoints(1, 2.0), 200);
  assertEquals(awardedPoints(1, 3.0), 300);
  assertEquals(awardedPoints(9, 2.5), 37.5);
  assertEquals(awardedPoints(17, 2.5), 12.5);
});

Deno.test("awardedPoints — rounding matches numeric(8,2)", () => {
  // 5 * 1.33 = 6.6499999999999995 in IEEE float; must round to 6.65.
  assertEquals(awardedPoints(17, 1.33), 6.65);
});

Deno.test("awardedPoints — throws on non-finite or negative multiplier", () => {
  assertThrows(() => awardedPoints(1, NaN));
  assertThrows(() => awardedPoints(1, Infinity));
  assertThrows(() => awardedPoints(1, -1));
});

Deno.test("awardedPoints — propagates basePointsForRank's throw for an invalid rank", () => {
  assertThrows(() => awardedPoints(0, 1.0));
  assertThrows(() => awardedPoints(1.5, 1.0));
});

// ---------------------------------------------------------------------------
// allMatchesComplete (F68)
// ---------------------------------------------------------------------------

Deno.test("allMatchesComplete — empty list is false (the arming guard)", () => {
  assertEquals(allMatchesComplete([]), false);
});

Deno.test("allMatchesComplete — all complete is true", () => {
  assertEquals(allMatchesComplete(["complete"]), true);
  assertEquals(allMatchesComplete(["complete", "complete", "complete"]), true);
});

Deno.test("allMatchesComplete — one open or one pending is false", () => {
  assertEquals(allMatchesComplete(["complete", "open"]), false);
  assertEquals(allMatchesComplete(["complete", "pending"]), false);
});

Deno.test("allMatchesComplete — Challonge's vocabulary is verbatim and case-sensitive", () => {
  assertEquals(allMatchesComplete(["Complete"]), false);
});

// ---------------------------------------------------------------------------
// findNullFinalRanks (F54)
// ---------------------------------------------------------------------------

Deno.test("findNullFinalRanks — none flagged when all ranks are valid", () => {
  const participants = [
    { challongeParticipantId: 1, name: "a", finalRank: 1 },
    { challongeParticipantId: 2, name: "b", finalRank: 2 },
  ];
  assertEquals(findNullFinalRanks(participants), []);
});

Deno.test("findNullFinalRanks — one null rank flagged with id and name", () => {
  const participants = [
    { challongeParticipantId: 1, name: "a", finalRank: 1 },
    { challongeParticipantId: 2, name: "b", finalRank: null },
  ];
  assertEquals(findNullFinalRanks(participants), [{ id: 2, name: "b" }]);
});

Deno.test("findNullFinalRanks — several invalid ranks flagged in input order", () => {
  const participants = [
    { challongeParticipantId: 1, name: "a", finalRank: null },
    { challongeParticipantId: 2, name: "b", finalRank: undefined as unknown as number },
    { challongeParticipantId: 3, name: "c", finalRank: 0 },
    { challongeParticipantId: 4, name: "d", finalRank: 1.5 },
    { challongeParticipantId: 5, name: "e", finalRank: 5 },
  ];
  assertEquals(findNullFinalRanks(participants), [
    { id: 1, name: "a" },
    { id: 2, name: "b" },
    { id: 3, name: "c" },
    { id: 4, name: "d" },
  ]);
});
