# RFC-010 — Runbook, Staleness Backstop & Release

- **Status:** 📝 Drafted (not yet implemented)
- **Implementation order:** 10 of 10 (v3.0, final) — depends on RFC-007,
  RFC-008, RFC-009 all being complete
- **Complexity:** Medium
- **Features covered:** F35, F36, F37
- **Grounding:** `knowledge/PRD.md` §17, §18.3 (outcome 7), §19, §20
  (Journeys E/F), §21, §22, §26 (v3.0 addendum); `knowledge/FEATURES.md`
  §"v3.0 — Challonge Integration" §K
- **Builds upon:** RFC-007…009 (a complete, working Challonge-integrated bot
  + Edge Function)
- **Built upon by:** — (release; closes out v3.0)

---

## 1. Summary

Close out the v3.0 addendum the same way RFC-006 closed out v2.0: **document,
harden, verify, and ship.** Concretely: extend `knowledge/RUNBOOK.md` with the
linking + trigger-discipline procedure (F35); add the **passive 48h staleness
warning** to `bot.py`'s opponent-resolution read path (F36); extend
`knowledge/DEPLOYMENT.md` with the Edge Function's deploy/secrets procedure;
author and execute a v3.0 E2E checklist covering all six fail-soft outcomes
plus the happy path (F37); and update `.claude/RULES.md`'s v2.0-era §9
Won't-have bookkeeping now that F25(e) has actually shipped. Unlike RFC-006,
this RFC **does** touch `bot.py` (the staleness check, F36) — it is not purely
operational.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F35** | `RUNBOOK.md` gets a new procedure: link a tournament to Challonge, keep names identical across both systems, and the exact discipline for triggering a refresh. |
| **F36** | A passive, server-side-only check/log when a tournament's cache is older than 48h — never blocks a player, purely an operator signal. |
| **F37** | An in-guild E2E checklist exercising all six fail-soft outcomes (RFC-009 §3.1) plus the happy path, before this addendum ships; release sign-off recorded the same way RFC-006's was. |

## 3. Technical approach

### 3.1 Runbook additions (F35)

Extend `knowledge/RUNBOOK.md` with a new **§8 — Lier un tournoi à Challonge
et déclencher une synchronisation (F35)**, following straight on from the
existing §0–§7 (RFC-002/RFC-006). Cover, in order:

1. **Linking (Journey E, setup):** after creating the tournament as usual in
   Studio (§1), set its `challonge_tournament_id` to the Challonge
   tournament's id/slug. Note this is a manual Studio edit — no UI is built
   for it (out of scope, PRD §16).
2. **Name discipline:** the organizer is solely responsible for keeping
   Challonge participant names identical to `players.ingame_name` in the same
   tournament (exact, trim+lower-normalized match, no reconciliation
   tooling) — mismatches surface as the `opponent_no_ots` fail-soft outcome
   (RFC-009 §3.5), not a schema error.
3. **First population:** run the trigger once (below) immediately after
   linking, before any player uses `/ots` for that tournament.
4. **The trigger command**, with the secret redacted to a placeholder in the
   doc itself (RULES §16):
   ```
   curl -X POST "https://<project-ref>.supabase.co/functions/v1/challonge-sync" \
     -H "Content-Type: application/json" \
     -H "x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET — depuis vos notes, jamais dans ce fichier>" \
     -d '{"tournament_id": <id Supabase du tournoi>}'
   ```
   Document the expected success response
   (`{"status":"ok","participants_synced":N,"matches_synced":M}`) and the
   error shapes from RFC-008 §3.3 so the organizer can self-diagnose a failed
   trigger (401 wrong secret, 400 no link, 404 unknown id, 502 Challonge
   unreachable).
5. **The steady-state discipline (Journey F, the load-bearing rule):**
   validate the round's results in Challonge **first**, then run the trigger
   **before making any further change in Challonge**. This ordering is the
   entire correctness model for cache freshness (PRD §19) — state this
   explicitly and prominently, not as a footnote.
6. **Forgotten-trigger recovery:** if a refresh is realized to have been
   missed, simply re-trigger as soon as noticed — F36's warning (§3.2 below)
   is what surfaces this after 48h if it's forgotten for longer than a normal
   between-rounds gap.

### 3.2 Staleness backstop (F36) — the one code change in this RFC

Fold a passive check into RFC-009's `fetch_current_opponent`, at the point
where the requester's cache row is already fetched (§3.2 step 3 of RFC-009):

- Extend that query's `select=` to also return `fetched_at`:
  ```
  select=challonge_participant_id,fetched_at
  ```
  (No extra round-trip — this reuses a query the resolution path already
  makes.)
- After a successful lookup, compare `fetched_at` against `now() - 48h`
  (Python-side: `datetime.now(timezone.utc) - parsed_fetched_at > timedelta(hours=48)`).
- If stale: `print(...)` (or the project's existing logging call) a clear
  operator-facing warning — e.g. `f"Challonge cache stale for tournament
  {tournament_id}: last refreshed {fetched_at} (>48h ago)"` — **and continue
  resolution normally.** This must never change the returned status or block
  the player (RULES §17).
- This check runs on every invocation that reaches the participant-lookup
  step (i.e., not on `no_active`/`no_challonge_link`, which fail before it) —
  including repeatedly for a tournament that's legitimately idle between
  events. That repetition is accepted, not suppressed (F36's own documented
  edge case) — it's a cheap, operator-only log line, not a rate-limited
  alert.

### 3.3 Deployment additions

Extend `knowledge/DEPLOYMENT.md` with a new section covering the Edge
Function — this project's first deployment target beyond the OCI
systemd/Python worker:

- **Prerequisites:** Supabase CLI installed and linked to the project
  (`supabase link`).
- **Secrets provisioning** (once per environment, not committed):
  ```
  supabase secrets set CHALLONGE_API_KEY=<...>
  supabase secrets set CHALLONGE_SYNC_SECRET=<...>
  ```
- **Deploy / redeploy:**
  ```
  supabase functions deploy challonge-sync
  ```
- **Verifying a deploy:** run the RFC-010 §3.1 curl command against a known
  test tournament and confirm a 200 with the expected counts.
- **Troubleshooting log entry stub** — mirror `DEPLOYMENT.md`'s existing §11
  pattern (append entries as real issues are hit in production, not
  speculatively).

### 3.4 E2E checklist (F37, the release gate)

Author `knowledge/E2E-CHECKLIST-v3.md` (a **new** file — do not overwrite or
append to the existing, already-signed-off `knowledge/E2E-CHECKLIST.md` from
RFC-006, which remains v2.0's release record), mirroring its
Scenario/Steps/Expected/Result/Notes table shape and sign-off block. Rows to
include, against RFC-007's seed fixtures (or a real linked Challonge test
tournament — whichever is available; note which was used per row):

- Happy path: `/ots giovlacouture` → zou's OTS; `/ots zou` → giovlacouture's
  OTS (both directions of the seeded open match).
- `no_active` — deactivate all tournaments, confirm the unchanged v2.0
  message.
- `no_challonge_link` — a tournament with `challonge_tournament_id IS NULL`.
- `requester_not_found` — a name absent from the cached participants.
- `no_current_match` — `/ots koloina` (seeded pending, no opponent).
- `opponent_no_ots` — a Challonge participant with no matching `players` row.
- `unavailable` — Supabase unreachable/timeout, same forcing technique as
  RFC-006's checklist.
- Staleness log — force a cache older than 48h (e.g. manually backdate a
  seeded row's `fetched_at` in Studio) and confirm the server-side warning
  appears without affecting the player-facing response.
- Trigger round-trip — Journey F rehearsed live: validate a round in
  Challonge, run the documented curl trigger, confirm `/ots` reflects it
  immediately.

All items must pass before release (mirrors RULES §19's quality thresholds).

### 3.5 RULES.md bookkeeping (deferred item, now due)

The v3.0 RULES addendum (§20) flagged: *"once RFC-009 ships, update §9
above (v2.0's Won't-have list) to note that F25(e) has been picked up by
v3.0."* RFC-009 will have shipped by the time this RFC executes — so this RFC
makes that edit: amend `.claude/RULES.md` §9's Won't-have bullet for
"pairings / hidden-until-reveal" to note it is now **superseded by v3.0
(RFC-007–010)**, not simply cross out F25(e) silently.

## 4. Data models / schema changes

None new. (F36 reads an existing column, `fetched_at`, that RFC-007 already
created.)

## 5. Interfaces exposed

- Final `knowledge/RUNBOOK.md` §8 — the organizer's Challonge operating
  procedure.
- Final `knowledge/DEPLOYMENT.md` Edge Function section.
- `knowledge/E2E-CHECKLIST-v3.md` with recorded results — the v3.0
  release-gate artifact.
- The staleness-warning log line (`fetch_current_opponent`'s one new
  behavior).

## 6. Acceptance criteria

- [ ] **F35:** A first-time organizer can follow `RUNBOOK.md` §8 to link a
      tournament and populate the cache without external help; the trigger
      command is documented with a placeholder secret, never a real value.
- [ ] **F36:** A cache older than 48h produces a server-side log entry on the
      next `/ots` invocation that reaches the participant lookup;
      player-visible behavior is unaffected (same response as if fresh).
- [ ] **F36:** A fresh cache (< 48h) produces no staleness log line.
- [ ] **F37:** All checklist rows in `knowledge/E2E-CHECKLIST-v3.md` pass,
      including the live trigger round-trip (Journey F) and the staleness
      warning.
- [ ] `knowledge/DEPLOYMENT.md` documents a working `supabase functions
      deploy challonge-sync` procedure, verified against the actual project.
- [ ] `.claude/RULES.md` §9's Won't-have list no longer contradicts the
      shipped bot (F25(e) noted as superseded, not silently removed).

## 7. Implementation details

- **Files:** `knowledge/RUNBOOK.md` (extend), `knowledge/DEPLOYMENT.md`
  (extend), `knowledge/E2E-CHECKLIST-v3.md` (new), `.claude/RULES.md`
  (small §9 amendment), `bot.py` (the F36 staleness check only — inside
  `fetch_current_opponent`, no new function).
- **No new Python dependency**, no new Edge Function code in this RFC —
  RFC-008 already shipped the function this RFC only documents deploying.

## 8. Edge cases & risks

- **Staleness check placement:** must sit **after** a successful participant
  lookup (so it has `fetched_at` to compare) but must not gate/delay the
  response — it is a side-effect log, not a branch.
- **Backdating `fetched_at` for the E2E test** (§3.4) is a manual Studio
  `UPDATE` for testing purposes only — never a real operational action;
  note this explicitly in the checklist so it isn't mistaken for a documented
  organizer procedure.
- **Two release-gate artifacts now exist** (`E2E-CHECKLIST.md` for v2.0,
  `E2E-CHECKLIST-v3.md` for this addendum) — do not merge them; v2.0's is a
  closed historical record, v3.0's documents the *changed* `/ots` contract
  and would be confusing prose if interleaved with the superseded v2.0
  scenarios.
- **No dry-run gate required for v3.0** (unlike RFC-006's timed 20-player
  dry-run, G2) — the PRD's v3.0 success metrics (§21) don't include a timing
  target; don't invent one.

## 9. Applicable rules (RULES.md)

- **v3.0 Addendum §17** (staleness is a log, never a gate). **§18** (E2E
  checklist expands to all six outcomes + happy path — the release gate).
  **§19** (F37 is the final Must; F36 is Should but still shipped here, not
  deferred). **§20** (the flagged §9 Won't-have bookkeeping, executed by this
  RFC now that RFC-009 has shipped; RFC-008/009/010 restating their own
  acceptance criteria rather than only pointing at the PRD, per PRD §24
  item 8 — this document does so throughout).

## 10. Testing strategy

This RFC **is** the verification stage, same role RFC-006 played for v2.0:
manual E2E execution of the full v3.0 checklist in the guild (or against
RFC-007's seed fixtures where a live Challonge round isn't practical to
rehearse repeatedly), plus a live Journey F rehearsal (validate → trigger →
confirm) at least once. Re-run `python -m unittest test_bot` as a pre-release
sanity check (unchanged from RFC-006's practice) to confirm the v2.0 pure-logic
suite still passes untouched. Sign-off on the v3.0 E2E checklist is the
go/no-go for this addendum's release, mirroring RFC-006's Completion-record
pattern exactly.
