# FEATURES — OTS Bot Backoffice (v2.0)

Derived from `knowledge/PRD.md` (v2, 2026-07-18). This is the implementation
planning breakdown for the Supabase-backed backoffice release.

**Legend**
- **Priority (MoSCoW):** Must / Should / Could / Won't. Mapped from PRD priority
  (P0→Must, P1→Should, P2→Could) and scope (§3 out-of-scope → Won't).
- **Persona:** ORG = Tournament Organizer · PLR = Player · SYS = system/internal.
- **Complexity:** Low / Medium / High (relative effort + risk).

---

## Summary

**Total features:** 30 (23 in-release + 7 explicit Won't-have)

### By priority
| Priority | Count | Feature IDs |
|----------|-------|-------------|
| Must     | 17    | F1, F2, F3, F4, F7, F8, F9, F10, F11, F12, F13, F14, F15, F19, F22, F23, F24 |
| Should   | 3     | F6, F16, F20 |
| Could    | 2     | F5, F21 |
| Won't    | 7     | F25 (a–g) |

### By category
| Category | IDs | Count |
|----------|-----|-------|
| A. Data model (Supabase) | F1–F6 | 6 |
| B. Backoffice (Studio) | F7–F10 | 4 |
| C. Discord bot / player flow | F11–F18 | 8 |
| D. Configuration | F19 | 1 |
| E. Reliability & contingency | F20–F22 | 3 |
| F. Dependencies & migration | F23–F24 | 2 |
| G. Out of scope (Won't) | F25 | 7 |

### By complexity (in-release only)
| Complexity | IDs |
|------------|-----|
| Low | F2, F5, F7, F9, F16, F19, F24 |
| Medium | F1, F3, F4, F6, F8, F10, F12, F13, F15, F17, F18, F20, F21, F22, F23 |
| High | F11, F14 |

---

## A. Data model (Supabase)

### F1 — `tournaments` table
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Medium · **PRD:** §5.1
- **Description:** Table modeling a tournament with `id`, `name`, `is_active` (bool, default `false`), `created_at`.
- **Acceptance criteria:**
  - Table exists with the four columns and stated defaults.
  - `created_at` auto-populates on insert.
- **Technical considerations:** Base object other schema hangs off; keep column set minimal per PRD.
- **Edge cases:** None beyond defaults.

### F2 — `players` table
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** §5.1
- **Description:** Table with `id`, `tournament_id` (FK → tournaments, `on delete cascade`), `ingame_name` (text), `team_text` (text), `pokepaste_url` (text, nullable), `created_at`.
- **Acceptance criteria:**
  - FK cascades on tournament delete.
  - `pokepaste_url` is nullable; all other listed columns are populated on a normal insert.
- **Technical considerations:** `team_text` stores full Showdown export verbatim.
- **Edge cases:** Null `pokepaste_url` must be a first-class case (drives F13's optional-link behavior).

### F3 — Single-active-tournament DB constraint
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §5.1, §11.1
- **Description:** Partial unique index on `is_active` where `is_active = true`, so at most one tournament can be active.
- **Acceptance criteria:**
  - Attempting to set a second tournament active while one is active fails with a constraint error.
  - Bot resolves "the active tournament" as the single `is_active = true` row.
- **Technical considerations:** Partial unique index (`CREATE UNIQUE INDEX ... WHERE is_active`).
- **Edge cases:** Zero active tournaments is valid (drives F15 "no active tournament" outcome).

### F4 — Case-insensitive, trimmed, unique player name per tournament
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §5.1, §11.6, §11.8
- **Description:** `ingame_name` is whitespace-trimmed on write (DB `BEFORE INSERT OR UPDATE` trigger) and uniquely indexed on `(tournament_id, lower(ingame_name))` (or `citext`), so a lookup never returns more than one player.
- **Acceptance criteria:**
  - Names differing only by case in the same tournament are rejected.
  - Names differing only by leading/trailing whitespace in the same tournament are rejected (both stored trimmed).
  - Same name is allowed across different tournaments.
  - Stored `ingame_name` has no leading/trailing whitespace regardless of Studio paste.
  - Bot query normalizes with matching `trim()` + `lower()` (ties to F12).
- **Technical considerations:** Trigger trims before the functional index applies `lower()`; index normalization must match the query exactly or the planner won't use it.
- **Edge cases:** Internal (mid-name) whitespace is preserved — only leading/trailing is trimmed; empty-after-trim name should be rejected.

### F5 — Studio-friendly defaults & column ordering
- **Priority:** Could · **Persona:** ORG · **Complexity:** Low · **PRD:** §5.1 (P1), §5.2
- **Description:** Defaults and column order tuned so a row fills fast (name + team text, optional URL); `is_active` defaults false; timestamps auto-populate.
- **Acceptance criteria:** Organizer can create a valid player row by filling only name + team text.
- **Edge cases:** None.

### F6 — Indexed read path
- **Priority:** Should · **Persona:** SYS · **Complexity:** Medium · **PRD:** §5.1
- **Description:** The active-tournament + name lookup is served by an index; confirm the planner uses it.
- **Acceptance criteria:** `EXPLAIN` on the lookup query shows index usage (F4's index typically serves it).
- **Technical considerations:** Small dataset makes this low-urgency for performance but cheap to verify.

---

## B. Backoffice (Supabase Studio)

### F7 — Create & activate a tournament
- **Priority:** Must · **Persona:** ORG · **Complexity:** Low · **PRD:** §5.2
- **Description:** Organizer creates a tournament row and marks it active in Studio.
- **Acceptance criteria:** A newly created + activated tournament becomes the one the bot reads.
- **Edge cases:** See F8 for the case where another tournament is already active.

### F8 — Deliberate two-step activation switch
- **Priority:** Must · **Persona:** ORG · **Complexity:** Medium · **PRD:** §5.2, §7 Journey A
- **Description:** When another tournament is active, activation is two steps: deactivate current, then activate the new one. The DB rejects two active rows by design.
- **Acceptance criteria:**
  - Organizer can switch the active tournament without a code change.
  - The constraint error on a one-step attempt is documented as expected behavior (not a bug).
- **Technical considerations:** Pairs with F3; belongs in the organizer runbook (F22-adjacent, F10).
- **Edge cases:** Constraint error must be recognizable/understood by the organizer.

### F9 — Add / edit / delete players without redeploy
- **Priority:** Must · **Persona:** ORG · **Complexity:** Low · **PRD:** §5.2, §7 Journey B
- **Description:** Full CRUD on players (name, team text, optional URL) for the active tournament, all in Studio.
- **Acceptance criteria:**
  - Add/edit/delete take effect on the next `/ots` with no redeploy.
  - Roster edit → visible on next lookup (live).
- **Edge cases:** Editing a player mid-event is a supported flow (Journey B).

### F10 — 20-player fast-setup workflow
- **Priority:** Should · **Persona:** ORG · **Complexity:** Medium · **PRD:** §5.2 (P1), §8
- **Description:** Studio workflow supports pasting ~20 players from a notes app in under 5 minutes.
- **Acceptance criteria:** Timed Day-6 dry-run completes a 20-player setup in < 5 min.
- **Technical considerations:** Depends on F5 column ordering/defaults; largely a UX/validation-of-flow feature, not code.
- **Edge cases:** Bulk paste formatting differences from the organizer's notes app.

---

## C. Discord bot / player flow (`/ots <username>`)

### F11 — Live Supabase read on every invocation
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** High · **PRD:** §5.3, §3
- **Description:** Replace `USERNAME_URLS` + pokepast.es scraper with a live query to the active tournament's matching player on every `/ots`.
- **Acceptance criteria:**
  - No hardcoded map or scraper remains.
  - Each `/ots` reflects current Supabase data.
- **Technical considerations:** Core refactor; via PostgREST over `aiohttp` (F23). Highest-risk item — touches the main command path.
- **Edge cases:** Feeds every fail-soft branch (F15).

### F12 — Trimmed, case-insensitive player lookup
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** Medium · **PRD:** §5.3, §5.1, §11.8
- **Description:** Lookup applies `trim()` then `lower()` to the user's input before matching `ingame_name`, matching F4's stored normalization + index.
- **Acceptance criteria:**
  - `/ots NAME`, `/ots name`, `/ots NaMe` resolve to the same player.
  - `/ots "  name  "` (stray leading/trailing whitespace) resolves to `name`.
- **Technical considerations:** Normalization must match F4 exactly (trim + lower).

### F13 — Embed build (title, optional URL, code block, color)
- **Priority:** Must · **Persona:** PLR · **Complexity:** Medium · **PRD:** §5.3, §6
- **Description:** Build the existing embed: title `OTS de {username}`; clickable title URL = `pokepaste_url` if present else no link; description = `team_text` in a code block; color `0x3B4CCA`.
- **Acceptance criteria:**
  - URL-present and URL-absent embeds both render correctly.
  - Visual format matches v1 (no regression).
- **Edge cases:** Null URL → embed renders without a link (ties to F2).

### F14 — Render-safety on `team_text`
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** High · **PRD:** §5.3, §11.4
- **Description:** Output hardening (not content validation): truncate to Discord's 4096-char description limit (accounting for code-fence chars) with a clear French truncation marker; neutralize fence-breaking sequences (literal ` ``` `) so they can't corrupt the code block.
- **Acceptance criteria:**
  - Oversized `team_text` produces a truncated, valid embed rather than a rejected message.
  - `team_text` containing ` ``` ` renders inside the code block without breaking out.
- **Technical considerations:** Must coexist with the locked "trust content as-is" decision — this hardens rendering only. Complexity is in getting the char accounting + escaping right.
- **Edge cases:** Empty `team_text`; text exactly at the limit; multiple backtick runs.

### F15 — Fail-soft with three distinct French outcomes
- **Priority:** Must · **Persona:** PLR · **Complexity:** Medium · **PRD:** §5.3, §6, §7 Journey D
- **Description:** Distinct friendly French messages for: (a) name not found in active tournament, (b) no active tournament configured, (c) Supabase unreachable/timeout/unexpected error. Never a crash or stack trace to the user.
- **Acceptance criteria:** Each of the three conditions yields its own clear French message; no unhandled exception reaches the user.
- **Edge cases:** Timeout is treated as "unreachable" (ties to F17).

### F16 — Improved "not found" copy (tournament-scoped)
- **Priority:** Should · **Persona:** PLR · **Complexity:** Low · **PRD:** §5.3 (P1), §11.3
- **Description:** The not-found message clarifies the lookup is scoped to the current tournament.
- **Acceptance criteria:** Not-found reply mentions the current-tournament scope; non-breaking vs. v1.

### F17 — Bounded read timeout
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §5.3
- **Description:** Supabase read uses a bounded timeout (comparable to v1's 5s fetch); a timeout is treated as "unreachable" and routed to fail-soft (F15c).
- **Acceptance criteria:** A slow/hung Supabase does not hang the command; it degrades to the unavailable message.
- **Note:** Grouped under F15 in complexity table as part of the fail-soft path.

### F18 — Mandatory immediate deferral
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §5.3, §6
- **Description:** Defer the interaction immediately (before the network read) so the round-trip never risks Discord's 3s ack window; defer ephemeral where appropriate to preserve reply privacy.
- **Acceptance criteria:** `/ots` never fails with a Discord "interaction failed"/timeout under normal Supabase latency.
- **Note:** Grouped under F15 in the complexity table (same command-path work).

> **DM + ephemeral fallback delivery** is preserved verbatim from v1 (§5.3,
> §6). It is not re-numbered as a new feature but is a **Must** acceptance
> criterion of F13/F15: DM the user, fall back to an ephemeral in-channel reply
> if DMs are closed. Verified in the E2E checklist (§9 Day 5).

---

## D. Configuration

### F19 — Env-var config + startup validation
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** §5.4
- **Description:** Load Supabase project URL + service key from env alongside `DISCORD_TOKEN`/`GUILD_ID`; update `.env.example` with placeholders only; validate required env vars at startup with a clear error if missing.
- **Acceptance criteria:**
  - No secret is committed; `.env.example` lists the new vars as placeholders.
  - Missing Supabase config fails fast at boot with a clear log, not on first `/ots`.
- **Technical considerations:** Service key bypasses RLS — held only by the worker.
- **Edge cases:** Partial config (URL but no key, or vice versa) should fail startup.

---

## E. Reliability & contingency

### F20 — Pre-event pre-flight ritual
- **Priority:** Should · **Persona:** ORG · **Complexity:** Medium · **PRD:** §12, §6, §10
- **Description:** Before each event, confirm the Supabase project is not paused (free-tier ~7-day inactivity), the correct tournament is active, and a test `/ots` returns a known player.
- **Acceptance criteria:** Documented checklist exists (in the runbook); rehearsed on Day 6.
- **Technical considerations:** Operational, not code; directly mitigates the free-tier pause risk (locked decision §11.7).
- **Edge cases:** Paused project must be resumed before the event.

### F21 — Keep-alive ping (optional)
- **Priority:** Could · **Persona:** SYS · **Complexity:** Medium · **PRD:** §12 (P1)
- **Description:** Lightweight scheduled ping to keep a free-tier project awake around event dates, if the pre-flight proves insufficient.
- **Acceptance criteria:** When enabled, the project does not pause across the event window.
- **Technical considerations:** Only build if F20 proves insufficient in practice; needs a scheduler.

### F22 — Break-glass fallback + graceful degradation
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Medium · **PRD:** §12, §5.3
- **Description:** Graceful degradation on outage (fail-soft in French + server-side error logging) plus a break-glass path: v1 hardcoded-map code preserved in git history and redeployable for a single event; organizer keeps an exported roster (Studio CSV / source notes).
- **Acceptance criteria:**
  - Outages produce friendly French messages and server-side logs (no crash, operator has signal).
  - A documented procedure exists to reconstruct the roster / redeploy v1 for one event.
- **Technical considerations:** Server-side error logging alongside the existing console heartbeat is part of this (PRD §5.3 P0) — fail-soft must not be fail-silent for the operator.
- **Edge cases:** Supabase down and cannot be resumed in time → break-glass.

---

## F. Dependencies & migration

### F23 — PostgREST access over existing `aiohttp`
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §11.5, §13, §6
- **Description:** Data access via raw PostgREST HTTP over the existing `aiohttp` — no `supabase-py`, keeping `requirements.txt` minimal and reusing the v1 timeout pattern.
- **Acceptance criteria:**
  - No heavy client dependency added.
  - Read works via PostgREST with service key + bounded timeout.
- **Technical considerations:** Third-party integration = Supabase PostgREST endpoint; requires correct auth headers with the service key.
- **Edge cases:** PostgREST error/non-200 responses map to fail-soft (F15c).

### F24 — Migration & data backup
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §13
- **Description:** No automated migration — re-enter any still-relevant `USERNAME_URLS` players in Studio during first setup; delete the dict + scraper in the refactor. Roster backup of record = organizer's source notes and/or a Studio CSV export.
- **Acceptance criteria:**
  - `USERNAME_URLS` and scraper removed from `bot.py`.
  - A backup path for the roster is documented.

---

## G. Out of scope (Won't have — this release)

### F25 — Deferred / excluded features (roadmap flags)
- **Priority:** Won't · **PRD:** §3, §11.8
- These are explicitly out of scope for v2.0 and noted for the future:
  - **(a)** Multiple simultaneously-active tournaments.
  - **(b)** Persistent cross-tournament player identities (players created fresh per tournament).
  - **(c)** Custom backoffice web app, custom auth, or multi-organizer roles.
  - **(d)** Player self-submission / approval workflows.
  - **(e)** Real-time pairings and opponents-only / hidden-until-reveal OTS privacy.
  - **(f)** Live pokepast.es scraping (superseded by stored `team_text`).
  - **(g)** Content validation/normalization of team text (trusted as-is, §11.4); caching layers; multi-guild support; non-French localization.

---

## Dependency & build-order notes

- **Schema first (F1–F4)** gates everything; F3/F4 are the two indexes that must
  exist before the bot's read (F11/F12) and the activation flow (F8) are correct.
- **F23 (PostgREST access)** and **F19 (config)** unblock **F11** (the core
  refactor), which in turn gates **F12–F18**.
- **F14 (render-safety)** and **F15 (fail-soft)** are the highest-value hardening
  on the read path — do not treat as polish.
- **F20/F22 (reliability)** are largely operational/documentation but are
  release-gating for the "survive a live event" goal (PRD G6); F21 is contingent.
- **Highest technical risk:** F11 (core command-path refactor) and F14
  (correct char-accounting + fence escaping).

---

# v3.0 — Challonge Integration (RFC-007–010)

Derived from the v3.0 change-management analysis (chat-based PRD-change review,
2026-07-20). Picks up **F25(e)** ("real-time pairings... deferred") from the v2.0
Won't-have list. Feature IDs continue from v2.0 (`F26` onward); the pre-existing
dangling `F26` reference in the v2.0 Should-priority summary above was a stray/unused
ID with no corresponding feature — corrected when this section was added.

**Goal:** a player runs `/ots <their own username>` and the bot resolves who their
*current opponent* is (via organizer-managed Challonge bracket data, cached in
Supabase) and returns the **opponent's** OTS — no need to already know the
opponent's name. This is an intentional, one-time **behavior change** to `/ots`'s
existing argument semantics (see RFC-009), not an additive mode.

**Locked architecture decisions for v3.0** (do not re-litigate in RFC-008/009/010):
- Single-active-tournament model is retained; each `tournaments` row may optionally
  link to one Challonge tournament via `challonge_tournament_id`.
- `bot.py` never calls the Challonge API directly — it only ever reads Supabase via
  the existing PostgREST pattern (preserves the v2.0 locked decision, PRD §11.5,
  that the bot has zero heavy/new runtime dependencies).
- The Challonge sync job is a **Supabase Edge Function** (TypeScript/Deno), not
  `pg_cron`/`pg_net` — chosen for correctness/debuggability of the JSON-handling and
  upsert logic over plpgsql, even though it's the first non-Python runtime in this
  project.
- The sync is **manually triggered by the organizer** (a documented `curl`/shell
  command, secret-protected), not polled on a schedule — the organizer is the same
  person who validates every pairing result in Challonge, so a trigger immediately
  after each round's results are validated is always safe to treat as fresh. This
  keeps Challonge API call volume trivial relative to their free-tier cap (500
  requests/month, enforced since 2026-07-06) — no cadence-tuning problem exists.
- Player identity is joined by **exact normalized username** between Challonge
  participant names and Supabase `players.ingame_name` — no reconciliation beyond
  the existing trim+lower contract (RFC-001/004); the organizer is responsible for
  keeping the two systems' names in sync.
- If the active tournament has **no** `challonge_tournament_id` set, `/ots` **hard-fails**
  with a distinct French message (no fallback to the old v2.0 arbitrary-lookup
  behavior) — a deliberate simplification, not an oversight.
- A **passive staleness backstop**: if the cache's `fetched_at` is older than **48h**,
  log a server-side warning (operator-only signal, never blocks players) — consistent
  with the v2.0 "fail-soft must not mean fail-silent for the operator" rule (§5.3 P0).

## Summary

| RFC | Scope | Feature IDs |
|-----|-------|-------------|
| **007** | Schema: Challonge link column, two cache tables, RLS, seed/test data | F26–F29 |
| **008** | Supabase Edge Function: secret-protected, full-refresh-on-trigger sync | F30–F31 |
| **009** | `/ots` refactor: opponent-resolution query, expanded fail-soft, copy | F32–F34 |
| **010** | Runbook, staleness backstop, E2E checklist, dry-run, release | F35–F37 |

**Total v3.0 features:** 12 (F26–F37)

### By priority
| Priority | Count | Feature IDs |
|----------|-------|-------------|
| Must     | 11    | F26, F27, F28, F29, F30, F31, F32, F33, F34, F35, F37 |
| Should   | 1     | F36 |
| Could    | 0     | — |
| Won't    | 0     | — *(v3.0 doesn't reopen any v2.0 Won't-have except F25(e), already tracked there)* |

### By complexity
| Complexity | IDs |
|------------|-----|
| Low | F26, F27, F29, F31, F34, F35, F36 |
| Medium | F28, F30, F33, F37 |
| High | F32 |

## H. Data model & sync (RFC-007)

### F26 — `tournaments.challonge_tournament_id` link
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Low
- **Description:** Nullable column on `tournaments` holding the linked Challonge
  tournament identifier (numeric id or url slug, per Challonge API v1). `NULL` means
  "this tournament has no Challonge integration" (drives F34's hard-fail path).
- **Acceptance criteria:** Column exists, nullable, no default; existing rows
  (from v2.0) are unaffected and remain valid with `NULL`.

### F27 — `challonge_participants_cache` table
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low
- **Description:** Caches Challonge participant id → normalized `ingame_name` per
  tournament, refreshed wholesale on each manual trigger (F30).
- **Acceptance criteria:** Unique per `(tournament_id, challonge_participant_id)` and
  per `(tournament_id, ingame_name)`; FK cascades on tournament delete.

### F28 — `challonge_matches_cache` table
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium
- **Description:** Caches Challonge match rows (`state`, `round`, both sides'
  participant ids, `winner_challonge_id`) per tournament, refreshed wholesale on
  each manual trigger. `state = 'open'` is what RFC-009's opponent-resolution query
  filters on.
- **Acceptance criteria:** Unique per `(tournament_id, challonge_match_id)`; FK
  cascades on tournament delete; nullable participant-id columns represent
  byes/not-yet-fed-in slots (mirrors Challonge's own nullability).

### F29 — RLS + idempotent seed/test data for new tables
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low
- **Description:** Same deny-by-default RLS posture as `tournaments`/`players`
  (RFC-003's tracked follow-up); idempotent seed data so RFC-008/009 have fixtures
  to test against without a live Challonge account.
- **Acceptance criteria:** RLS enabled on both new tables, no policies; `schema.sql`
  re-run produces no error/duplicates.

## I. Challonge sync (RFC-008)

### F30 — Full-refresh Edge Function (manual trigger)
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Medium · **PRD:** v3.0 addendum §18.2
- **Description:** A Supabase Edge Function (TypeScript/Deno) that, on
  invocation, calls the Challonge API for the target tournament's participants
  and matches and upserts them wholesale into RFC-007's cache tables.
- **Acceptance criteria:**
  - Exactly 2 Challonge API calls per invocation (participants, matches),
    regardless of tournament size.
  - Cache tables reflect Challonge's current state after invocation — re-running
    produces no duplicate rows, and changed `state` values update in place
    (upsert, not append, per RFC-007's contract).
  - An invalid/missing `challonge_tournament_id` on the target tournament fails
    loudly (a clear error in the function's response/logs), never silently.
- **Technical considerations:** lives under `supabase/functions/` — a new
  directory, a documented exception to RULES §2 ("no new folders"). Uses
  Challonge API v1's static-key HTTP Basic auth (no OAuth/token refresh needed
  for a single-organizer-account integration).
- **Edge cases:** Challonge unreachable/rate-limited/5xx at trigger time → the
  function returns an error and the cache stays at its last successful refresh;
  the upsert must not begin writing until both API calls succeed, so a partial
  failure never leaves one cache table refreshed and the other stale in a
  misleading combination.

### F31 — Secret-protected invocation
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** v3.0 addendum §18.2, §18.4
- **Description:** The Edge Function's manual-trigger endpoint requires a
  shared secret (not the public anon key) in the request, so only the
  organizer can invoke it.
- **Acceptance criteria:** an invocation without the correct secret is
  rejected; the documented `curl`/shell command in the RFC-010 runbook
  includes the secret from the organizer's own notes/env, never committed to
  the repo.
- **Technical considerations:** secret held in the Edge Function's own
  Supabase environment config, entirely separate from `bot.py`'s env vars.
- **Edge cases:** secret rotation has no automated process — a manual
  procedure if ever needed, out of scope for this addendum.

## J. Discord bot / opponent resolution (RFC-009)

### F32 — Opponent-resolution query
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** High · **PRD:** v3.0 addendum §18.3
- **Description:** Given the caller's normalized username, resolve their
  `challonge_participant_id` via `challonge_participants_cache`, find the
  `state = 'open'` row in `challonge_matches_cache` where that id appears on
  either side, and resolve the *other* side's id back to a name.
- **Acceptance criteria:**
  - The happy path resolves correctly against RFC-007's seed fixtures
    (giovlacouture ↔ zou).
  - A name absent from the cache routes to the "requester not found" outcome
    (F33).
  - A participant with no `open` match routes to the "no current match"
    outcome (F33).
- **Technical considerations:** two PostgREST reads against the new cache
  tables, same trim+lower normalization as v2.0's existing lookup; the *final*
  step (opponent name → `team_text`) reuses v2.0's existing
  `fetch_active_player`-style query **verbatim** — the one piece of v2.0 logic
  this addendum doesn't touch.
- **Edge cases:** more than one `open` match for the same participant
  shouldn't happen in a well-formed bracket but isn't schema-prevented — pick
  deterministically (e.g. highest `round`) as a defensive default, not an
  expected case.

### F33 — Expanded fail-soft (7 outcomes) + updated French copy
- **Priority:** Must · **Persona:** PLR · **Complexity:** Medium · **PRD:** v3.0 addendum §18.3
- **Description:** distinct French messages for each of the seven outcomes in
  PRD §18.3, replacing/extending v2.0's three; updated slash-command
  description text reflecting the new "type your own name" meaning.
- **Acceptance criteria:** each of the seven outcomes yields its own clear
  French message; no unhandled exception reaches the user; the command's
  Discord-visible description no longer implies "the player you want to look
  up."
- **Technical considerations:** outcome 4 (no current match) intentionally
  covers bye/eliminated/not-started-yet with **one** generic message (PRD
  §24.7 — a default taken, open for revision).
- **Edge cases:** outcome 5 (opponent resolved but no `team_text` row) must be
  distinguishable **server-side** (logged) from outcome 3 (requester not
  found) even though both may look similarly apologetic to a player — the
  organizer's diagnosis needs the distinction even where the copy doesn't.

### F34 — No-Challonge-link hard-fail
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** Low · **PRD:** v3.0 addendum §18.3, §24.4 · ties to F26
- **Description:** when the active tournament's `challonge_tournament_id IS
  NULL`, `/ots` fails with a distinct French message rather than falling back
  to v2.0's arbitrary-lookup behavior.
- **Acceptance criteria:** a tournament created without a Challonge link
  behaves this way from the moment it's activated; no code path reintroduces
  the old lookup.
- **Technical considerations:** the simplest new branch — a single null-check
  before F32's resolution logic even runs.
- **Edge cases:** none beyond the null-check itself.

## K. Reliability & release (RFC-010)

### F35 — Runbook: linking + trigger procedure
- **Priority:** Must · **Persona:** ORG · **Complexity:** Low · **PRD:** v3.0 addendum §17, §20 (Journeys E/F)
- **Description:** `RUNBOOK.md` gets a new procedure — link a tournament to
  Challonge (`challonge_tournament_id`), keep names identical across both
  systems, and the exact discipline for triggering a refresh (immediately
  after validating a round's results, before any further Challonge change).
- **Acceptance criteria:** a first-time organizer can follow the runbook to
  link a tournament and populate the cache without external help.
- **Technical considerations:** documents the exact `curl`/shell command, with
  the secret redacted/placeholder in the doc itself.
- **Edge cases:** what to do if a trigger is forgotten — re-trigger as soon as
  noticed; F36 covers detection.

### F36 — 48h staleness warning
- **Priority:** Should · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** v3.0 addendum §18.3 (outcome 7), §19
- **Description:** a passive, server-side-only check/log when a tournament's
  cache `fetched_at` exceeds 48h old — never blocks a player, purely an
  operator signal (mirrors v2.0's "fail-soft must not mean fail-silent for the
  operator," RULES §7, F22).
- **Acceptance criteria:** a cache older than 48h produces a server-side log
  entry on the next `/ots` invocation against it; player-visible behavior is
  unaffected.
- **Technical considerations:** a cheap timestamp comparison against
  `MAX(fetched_at)` for the tournament's cache rows, folded into the existing
  read path — no separate scheduled check needed.
- **Edge cases:** a tournament correctly idle between events would log
  repeatedly if `/ots` is invoked against it — acceptable since the warning is
  operator-only and cheap; not worth suppressing repeats for this addendum.

### F37 — E2E checklist, dry-run, release
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Medium · **PRD:** v3.0 addendum §21, §22
- **Description:** mirrors RFC-006's pattern — an in-guild checklist exercising
  all seven fail-soft outcomes (F33/F34) plus the happy path (F32), against a
  real or realistically seeded Challonge tournament, before this addendum ships.
- **Acceptance criteria:** all scenarios pass; release sign-off recorded the
  same way RFC-006's Completion record was.
- **Technical considerations:** needs either a real Challonge test tournament
  or reliance on RFC-007's seed fixtures for the parts that don't require live
  Challonge API calls.
- **Edge cases:** none beyond the thoroughness of the checklist itself.
