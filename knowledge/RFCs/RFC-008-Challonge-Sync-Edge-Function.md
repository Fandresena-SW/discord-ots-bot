# RFC-008 — Challonge Sync Edge Function (Manual Trigger)

- **Status:** ✅ Complete (2026-07-20 — see [§ Completion record](#completion-record))
- **Implementation order:** 8 of 10 (v3.0) — depends on RFC-007's cache tables;
  depends transitively on all of v2.0 (RFC-001–006)
- **Complexity:** Medium
- **Features covered:** F30, F31
- **Grounding:** `knowledge/PRD.md` §16, §18.2, §18.4, §19, §24 (items 2–3),
  §26 (v3.0 addendum); `knowledge/FEATURES.md` §"v3.0 — Challonge Integration"
  §I
- **Builds upon:** RFC-007 (`challonge_participants_cache`,
  `challonge_matches_cache`, their upsert contract and unique keys)
- **Built upon by:** RFC-009 (`bot.py` reads what this RFC writes), RFC-010
  (documents the trigger procedure, deploys this function to production)

---

## 1. Summary

Build the **Supabase Edge Function** (TypeScript/Deno) that is the *only*
piece of this project that ever talks to the Challonge API. On a
secret-protected HTTP invocation naming one tournament, it performs a **full
refresh** — exactly two Challonge API calls (participants, matches) — and
**upserts** the results into RFC-007's two cache tables. It is never polled or
scheduled; the organizer runs it manually via a documented `curl` command
(RFC-010) immediately after validating each round's results in Challonge.

This RFC produces **no Python changes** — `bot.py` is untouched here and, per
the locked v2.0/v3.0 decision (PRD §18.2, §24 item 3), never will call
Challonge directly. This is also the **first non-Python runtime** in the
repo: its source lives in a new `supabase/functions/` directory, a deliberate,
documented exception to RULES §2 ("no new folders"), tracked in the v3.0
RULES addendum §12.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F30** | A Supabase Edge Function that, on invocation, calls the Challonge API for one tournament's participants and matches and **upserts** them wholesale into RFC-007's cache tables. Exactly 2 Challonge API calls per invocation, regardless of tournament size. An invalid/missing Challonge link fails **loudly**, never silently. |
| **F31** | The function's invocation endpoint requires a **shared secret** (not the public Supabase anon key) — only the organizer, holding that secret, can trigger a refresh. |

## 3. Technical approach

### 3.1 Why an Edge Function, not `pg_cron`/`pg_net` (locked, PRD §24 item 2)

Restated for implementers: correct JSON parsing and upsert logic is
materially easier to write and debug in TypeScript than in `plpgsql` against
`pg_net`'s async request/response model. Do not revisit this during
implementation — if `pg_net` seems simpler for a sub-piece, that is a signal
the Edge Function is being over-engineered, not a reason to switch runtimes.

### 3.2 Request contract (F31)

- **Endpoint:** `POST {SUPABASE_URL}/functions/v1/challonge-sync`
- **Auth:** the function is deployed with **`verify_jwt = false`**
  (`supabase/config.toml`) — a deliberate opt-out of Supabase's default
  anon/service-JWT gate, because PRD §18.2/§24 item 3 specifically rejects
  "protected by the anon key" as sufficient. Authorization is instead a
  **custom header the function checks itself**:
  - Header: `x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET>`
  - Any request missing this header or with a non-matching value →
    **HTTP 401**, `{"status": "error", "message": "invalid or missing secret"}`,
    before any Supabase or Challonge call is made.
- **Body:** `{"tournament_id": <bigint>}` — the **Supabase** `tournaments.id`
  (not the Challonge id) to refresh. Using the internal id (rather than
  requiring the organizer to pass the Challonge id/slug directly) means the
  function is the single place that resolves and validates the link, and the
  organizer's `curl` command only ever needs the tournament they already know
  from Studio.

### 3.3 Resolution & validation sequence

1. Check the secret header (§3.2). Fail fast with 401 if invalid.
2. Parse `tournament_id` from the JSON body. Missing/non-numeric → **HTTP
   400**, `{"status": "error", "message": "tournament_id is required and must be a number"}`.
3. `GET {SUPABASE_URL}/rest/v1/tournaments?id=eq.{tournament_id}&select=id,challonge_tournament_id`
   using the service role key (auto-provisioned as `SUPABASE_URL` /
   `SUPABASE_SERVICE_ROLE_KEY` env vars in every Edge Function — no manual
   secret needed for these two).
   - No row → **HTTP 404**, `{"status": "error", "message": "tournament not found"}`.
   - Row found but `challonge_tournament_id IS NULL` → **HTTP 400**,
     `{"status": "error", "message": "tournament has no challonge_tournament_id set"}`
     (F30's "fails loudly on invalid/missing link").
4. Call the Challonge API **twice** (§3.4) using the resolved
   `challonge_tournament_id`. **Both calls must succeed before any write
   begins** — this is the RFC-007-flagged "all-or-nothing" contract: a
   partial failure must never leave one cache table refreshed and the other
   stale in a misleading combination. If either call fails (network error,
   non-200, unparseable body), return **HTTP 502**,
   `{"status": "error", "message": "Challonge API request failed: <detail>"}`,
   and perform **no writes**.
5. Transform both payloads (§3.5) and **upsert** into the two cache tables
   (§3.6). A write failure at this stage → **HTTP 500**,
   `{"status": "error", "message": "Supabase upsert failed: <detail>"}`.
6. Success → **HTTP 200**,
   `{"status": "ok", "participants_synced": <N>, "matches_synced": <M>}`.

### 3.4 Calling the Challonge API (F30)

- `GET https://api.challonge.com/v1/tournaments/{challonge_tournament_id}/participants.json`
- `GET https://api.challonge.com/v1/tournaments/{challonge_tournament_id}/matches.json`
- **Auth:** Challonge API v1 uses HTTP Basic Auth with the API key as the
  password (username is conventionally ignored/arbitrary). **Verify this
  exact convention against Challonge's current API v1 docs at implementation
  time** before hardcoding it — treat it the same way PRD §19 already flags
  Challonge's pricing as "needs checking directly," not as a locked fact.
- The API key (`CHALLONGE_API_KEY`) is a **Supabase Edge Function secret**
  (`supabase secrets set CHALLONGE_API_KEY=...`), held only in this function's
  environment — never in `bot.py`, never committed (RULES §16).
- Both endpoints return a JSON array where each element wraps the object in a
  singular key — `[{"participant": {...}}, ...]` and
  `[{"match": {...}}, ...]` respectively. Unwrap this before mapping.
- Neither endpoint paginates for a single tournament's own participants/matches
  at hobby-VGC scale (dozens of entrants) — confirm this holds for whatever
  tournament size is actually used; if Challonge's response is ever
  unexpectedly truncated, that is a signal this assumption needs revisiting,
  not a case to silently work around.

### 3.5 Mapping Challonge payloads to cache rows

- **Participant** (Challonge `participant` object) → `challonge_participants_cache`:
  - `id` → `challonge_participant_id`
  - `name` → `ingame_name` (stored as-is; RFC-007's reused `trim_ingame_name()`
    trigger trims it on write — no separate trimming needed here)
- **Match** (Challonge `match` object) → `challonge_matches_cache`:
  - `id` → `challonge_match_id`
  - `round` → `round`
  - `state` → `state` (Challonge's own values — `pending`/`open`/`complete` —
    map **verbatim** onto RFC-007's `check` constraint; do not translate)
  - `player1_id` → `player1_challonge_id`, `player2_id` → `player2_challonge_id`
    (either may be `null` — a bye or not-yet-fed-in slot)
  - `winner_id` → `winner_challonge_id` (`null` until `state = 'complete'`)

### 3.6 Writing the cache (upsert, not append — RFC-007's contract)

Same data-access posture as `bot.py`: **raw PostgREST HTTP via `fetch`, no
`supabase-js` client library.** This is a deliberate choice for this RFC (not
inherited from RULES §1, which is Python-specific) — it keeps a single
consistent mental model across both runtimes in this repo ("talk to Postgres
via PostgREST, no ORM/client library, anywhere") rather than introducing a
second data-access idiom just because the runtime changed. Use the service
role key headers (`apikey` / `Authorization: Bearer`) exactly like `bot.py`'s
`fetch_active_player`.

- `POST {SUPABASE_URL}/rest/v1/challonge_participants_cache` with header
  `Prefer: resolution=merge-duplicates` and `on_conflict=tournament_id,challonge_participant_id`
  as a query param, body = the full mapped array (batch upsert in one call).
- `POST {SUPABASE_URL}/rest/v1/challonge_matches_cache` with
  `Prefer: resolution=merge-duplicates` and
  `on_conflict=tournament_id,challonge_match_id`, body = the full mapped
  array.
- Both requests set `tournament_id` (the Supabase id from §3.3 step 3) on
  every row — the Challonge payload has no notion of this internal id.
- Do **not** delete/append; PostgREST's `merge-duplicates` upsert combined
  with RFC-007's unique indexes is what gives "re-trigger reflects current
  state, no duplicates" (F30's core acceptance criterion).

## 4. Data models / schema changes

None — this RFC only writes into the tables RFC-007 already created. No
`schema.sql` changes.

## 5. Interfaces exposed

- **`POST {SUPABASE_URL}/functions/v1/challonge-sync`** — the manual-trigger
  HTTP contract (§3.2–§3.3), consumed by the organizer's documented `curl`
  command (RFC-010) and by no other component.
- **Cache-table write contract** consumed implicitly by RFC-009 (the reader):
  after a successful invocation, `challonge_participants_cache` and
  `challonge_matches_cache` for the given tournament reflect Challonge's
  current state as of that moment, with `fetched_at` updated to "now" on
  every touched row.

## 6. Acceptance criteria

- [ ] **F30:** A valid invocation performs **exactly 2** Challonge API calls
      (participants, matches), regardless of tournament size.
- [ ] **F30:** Re-invoking against an unchanged Challonge tournament produces
      **no duplicate rows** in either cache table (verify row counts before/after).
- [ ] **F30:** Invoking against a tournament with a match that has progressed
      (e.g. `open` → `complete`) updates that row **in place** (same
      `challonge_match_id`, new `state`/`winner_challonge_id`).
- [ ] **F30:** A `tournament_id` whose row has `challonge_tournament_id IS NULL`
      fails with **HTTP 400** and a clear message — no partial write occurs.
- [ ] **F30:** A Challonge API failure (simulate: wrong/revoked API key, or an
      unreachable/invalid `challonge_tournament_id`) returns **HTTP 502** and
      leaves both cache tables at their prior state (no partial write).
- [ ] **F31:** An invocation without the `x-challonge-sync-secret` header, or
      with an incorrect value, is rejected with **HTTP 401** before any
      Supabase/Challonge call is made.
- [ ] **F31:** `CHALLONGE_API_KEY` and `CHALLONGE_SYNC_SECRET` are Edge
      Function secrets only — never present in `bot.py`'s env, never
      committed, never logged in full (mask/omit in any error output).

## 7. Implementation details

- **File structure:**
  - `supabase/functions/challonge-sync/index.ts` — the function body
    (`Deno.serve` handler implementing §3.3).
  - `supabase/config.toml` — add a `[functions.challonge-sync]` section with
    `verify_jwt = false` (§3.2).
  - Keep the function to a **single file** unless the mapping logic (§3.5)
    is extracted into a small pure module for testability (§10) — mirrors
    this repo's "one small seam" ethos (RULES §2), now applied to the Deno
    side too.
- **Secrets to provision** (organizer, via Supabase CLI, not committed):
  `supabase secrets set CHALLONGE_API_KEY=... CHALLONGE_SYNC_SECRET=...`
  (RFC-010 documents the exact commands).
- **Deploy command:** `supabase functions deploy challonge-sync` (RFC-010
  adds this to `knowledge/DEPLOYMENT.md`; not this RFC's deliverable to
  execute against production, only to make deployable).
- **No Python touched.** `bot.py`, `requirements.txt`, `schema.sql` are all
  unaffected by this RFC.

## 8. Edge cases & risks

- **Partial-failure ordering is the highest risk here:** the implementation
  must gate *all* writes behind *both* Challonge calls succeeding. A tempting
  shortcut — upsert participants immediately after the first call succeeds,
  then fetch matches — must be avoided; it would leave a stale
  `challonge_matches_cache` paired with a fresh `challonge_participants_cache`
  if the second call then failed.
- **Concurrent invocations** (organizer double-triggers): both are individually
  idempotent upserts, so a race is safe by construction — no locking needed.
- **Unrecognized `state` value** from a future Challonge API change: the
  RFC-007 `check` constraint rejects the upsert. This function must surface
  that as a clear 500 (not swallow it), so the organizer sees "sync failed,"
  not a silent no-op.
- **Large batch upserts:** hobby-scale tournaments (dozens of participants,
  at most a few hundred matches even in a large bracket) fit comfortably in a
  single PostgREST batch upsert call — no chunking logic needed.
- **Basic Auth convention uncertainty (§3.4):** flagged explicitly above —
  confirm against current Challonge docs rather than trusting this RFC's
  description as gospel.

## 9. Applicable rules (RULES.md)

- **v3.0 Addendum §11 (stack):** Challonge API v1 (Basic auth), Supabase Edge
  Function (TypeScript/Deno) — both introduced by this RFC.
- **§12 (architecture exception):** `supabase/functions/` is the documented,
  scoped exception to §2's "no new folders" — this RFC is what actually
  creates it.
- **§14 (data handling):** upsert-not-append is mandatory and non-negotiable;
  reuse of `trim_ingame_name()` (RFC-007) is preserved, not reimplemented here.
- **§16 (security):** Challonge API key + trigger secret live only in the
  Edge Function's own Supabase environment config.
- **§19 (build order):** this RFC is Must-priority, strictly after RFC-007
  and strictly before RFC-009.

## 10. Testing strategy

There is no Python test runner for this code — it is Deno/TypeScript.
- **Local dev loop:** `supabase functions serve challonge-sync --env-file <local secrets>`
  against a local or dev Supabase project seeded with RFC-007's fixtures, and
  a real (or a deliberately small/disposable) Challonge test tournament.
- **Pure-logic unit tests, mirroring RFC-004's precedent:** if the
  Challonge-payload-to-cache-row mapping (§3.5) is factored into a small pure
  function (`challonge participant/match JSON in → cache row object out`),
  cover it with `Deno.test` cases — no network needed for these. Do not build
  broader test infrastructure than this one pure seam needs.
- **Manual verification checklist** (executed here, and re-verified as part
  of RFC-010's release E2E):
  1. First trigger against a freshly-linked tournament — confirm both tables
     populate correctly.
  2. Re-trigger with no Challonge-side change — confirm row counts are
     unchanged (no duplicates).
  3. Advance a round in Challonge, re-trigger — confirm the affected match
     row(s) update in place (`state`, `winner_challonge_id`).
  4. Trigger with a wrong/missing secret — confirm 401, no Challonge call
     made (check Challonge-side request logs/rate if possible).
  5. Trigger against a tournament with no Challonge link — confirm 400, no
     writes.
  6. Trigger with an intentionally invalid `CHALLONGE_API_KEY` — confirm 502,
     no writes to either cache table.

---

## Completion record

- **Status:** ✅ Complete — **2026-07-20**, implemented directly (no `/rfc`
  sub-agent orchestration — same rationale as RFC-007: this repo's
  `.claude/agents/*.md` and `/rfc` skill are templated for an unrelated
  Flutter/Supabase project; tracked in `RFCS.md`).
- **Deliverables shipped:**
  - `supabase/config.toml` (new) — declares `[functions.challonge-sync]` with
    `verify_jwt = false`. `supabase/` is the documented RULES §12 exception.
  - `supabase/functions/challonge-sync/mapping.ts` (new) — pure
    `mapParticipant`/`mapMatch` functions (Challonge JSON → cache row),
    factored out of the handler per §10 so they're unit-testable without
    network access.
  - `supabase/functions/challonge-sync/index.ts` (new) — the `Deno.serve`
    handler implementing the full §3.3 sequence (secret check → body parse →
    tournament/link resolution → both Challonge calls, all-or-nothing → map
    → upsert → response), with every error path returning the exact
    `{"status": "error", "message": "..."}` shape and status code §3.2–3.3
    specifies.
  - `supabase/functions/challonge-sync/mapping_test.ts` (new) — 4 `Deno.test`
    cases covering a normal participant/match, a null second-side (bye/unfed
    slot), and a completed match with a non-null winner.
  - **No Python touched** — `bot.py`, `schema.sql`, `requirements.txt` are
    all unaffected, per RFC-008's own scope limitation.
- **Deliberate deviation from §3.4 (documented, not silent), confirmed correct
  by live testing:** §3.4 itself flagged its Basic-Auth description as
  needing verification. I initially researched real Challonge API v1 client
  libraries and found the ecosystem inconsistent (`pychallonge`/`pychal` use
  real-username HTTP Basic Auth; `dolejska-daniel/challonge-api` (PHP) uses
  the `?api_key=...` query parameter; Challonge's own docs list both as
  valid), and implemented the **query-parameter method** to avoid the
  username ambiguity entirely. **A subsequent live test against a real
  Challonge account (below) confirmed this works end-to-end** — no code
  change was needed. That same live test also surfaced a real wrinkle worth
  recording: Challonge has since introduced a `v2.1` JSON:API host that
  accepts legacy `v1` keys via `Authorization`/`Authorization-Type` headers,
  and a tournament that isn't visible to a given API key's account 404s
  identically on *both* the legacy `v1` host and the new `v2.1` host — so a
  "tournament not found" error is genuinely ambiguous between "wrong
  identifier" and "wrong account," not just a v1-specific quirk. This is
  called out in `index.ts`'s header comment.
- **Verification performed:**
  - `deno test` — all 4 mapping unit tests pass.
  - `deno check` and `deno lint` on `index.ts` — clean, no errors/warnings.
  - Local HTTP verification (no Challonge account needed) against a
    disposable stack: a `postgres:16-alpine` container with `schema.sql`
    applied, a `postgrest/postgrest` container with
    `service_role`/`anon`/`authenticator` roles mirroring real Supabase, and
    a tiny `nginx` reverse proxy adding the `/rest/v1` path prefix Supabase's
    own gateway adds (bare PostgREST serves at root). Confirmed: 401
    (missing/wrong secret), 400 (missing/non-numeric `tournament_id`), 404
    (unknown `tournament_id`), 400 (no Challonge link), and 502 (Challonge
    API failure) — plus the upsert HTTP contract directly (`Prefer:
    resolution=merge-duplicates` + `on_conflict=...`: first insert 201,
    re-upsert 200, no duplicate row). Infrastructure was disposable and
    removed after the run.
  - **Full live verification against a real Challonge account**, using
    `supabase start` (the actual local Supabase stack — Postgres, PostgREST,
    gateway, on a project-specific port range to avoid colliding with
    another local Supabase project on the same machine) and `supabase
    functions serve challonge-sync --env-file .env.local` (see
    `supabase/functions/challonge-sync/.env.example`). All of RFC-008 §10's
    manual checklist items 1–6 passed:
    1. First trigger against a real tournament (linked via
       `tournaments.challonge_tournament_id`) populated both cache tables
       correctly — 8 real participants, 4 real matches, exact field values
       matched Challonge's own API responses.
    2. Re-trigger with no Challonge-side change — row counts unchanged (no
       duplicates).
    3. Reported a real match result on Challonge, re-triggered — that match's
       row updated **in place** (`open` → `complete`, `winner_challonge_id`
       set), same `challonge_match_id`, still exactly 4 rows.
    4. Wrong/missing secret header — 401, no writes.
    5. Trigger against a tournament with no Challonge link — 400, no writes.
    6. Trigger with a deliberately invalid `CHALLONGE_API_KEY` against the
       real `api.challonge.com` — 502, no writes.
  - **Real bug found during live testing (fixed by test data cleanup, not a
    code change):** RFC-007's seed data pre-populates
    `challonge_participants_cache` for the seeded `RFC-001 Test Tournament`
    row with placeholder names (`giovlacouture`/`zou`/`koloina`) under fake
    Challonge participant ids (1001–1003). Linking that same tournament row
    to a real Challonge tournament containing participants with those same
    names (but real, different Challonge ids) correctly trips the
    `challonge_participants_cache_name_idx` unique constraint on upsert — the
    `on_conflict` target is `(tournament_id, challonge_participant_id)`, so
    Postgres doesn't recognize the seeded and real rows as "the same"
    participant, and the name-uniqueness constraint (correctly) blocks a
    second row with the same name. **This is expected, local-dev-only
    behavior, not a production concern** — a real organizer's active
    tournament was never seeded in the first place. Fixed by deleting the
    seed rows from both cache tables for that tournament id before the live
    trigger. **Flag for RFC-010's runbook:** note this explicitly if the
    runbook ever suggests reusing the RFC-001/007 seeded tournament for
    local Challonge-integration testing.
- **Not yet done (deliberately out of this RFC's scope):** provisioning
  `CHALLONGE_API_KEY`/`CHALLONGE_SYNC_SECRET` via `supabase secrets set` and
  `supabase functions deploy challonge-sync` against the real production
  project — both are RFC-010's runbook/release territory. (This RFC's live
  test ran entirely against a local Supabase stack, never production.)
