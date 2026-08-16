# FEATURES — OTS Bot (v2.0 → v4.0)

**Document map.** Three release sections, appended in order, feature IDs never
reused:

| Release | IDs | Source PRD | Status |
|---------|-----|------------|--------|
| v2.0 — Supabase backoffice | F1–F25 | `PRD.md` §1–§13 | ✅ shipped |
| v3.0 — Challonge integration | F26–F37 | `PRD.md` §14–§26 | ✅ shipped 2026-07-31 |
| v4.0 — Ranking + `/ots` identity binding | F38–F78 | `PRD.v4.final.md` §27–§41 | 📋 specified, not built |

> ⚠️ **v4.0 supersedes parts of the sections above it.** `/ots` loses its
> argument (F76), which strikes the typed-name scenarios from
> `E2E-CHECKLIST-v3.md`; and v2.0's **F25(b)** Won't-have (persistent
> cross-tournament identities) is **deliberately reopened**. Read the v4.0
> section's supersession notes before treating an earlier entry as current.

---

# v2.0 — Supabase backoffice

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
    → ⚠️ **REOPENED by v4.0** (`PRD.v4.final.md` §29): `profiles` + `players.profile_id`
    (F38/F39) is the core of that release. This line is no longer current; the rest of
    the F25 list is.
  - **(c)** Custom backoffice web app, custom auth, or multi-organizer roles.
  - **(d)** Player self-submission / approval workflows.
  - **(e)** Real-time pairings and opponents-only / hidden-until-reveal OTS privacy.
    → Picked up in two steps: real-time pairings by v3.0 (F26–F37); *opponents-only*
    by v4.0's F76, which makes `/ots` structurally incapable of returning anyone but
    the caller's own opponent. **Hidden-until-reveal remains Won't.**
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

---

# v4.0 — Ranking System & `/ots` Identity Binding (RFC-011–014)

Derived from **`knowledge/PRD.v4.final.md`** (v4.0, 2026-07-31) — the authoritative
v4.0 spec, which already assigns feature IDs. This section mirrors those IDs
verbatim; it does not renumber, and it mints no new ones (§39 states this document
"gains F38–F78"). Feature IDs continue from F37; PRD sections from §26; goals from
G10; journeys from Journey H; RFCs from RFC-010.

**Status:** ✅ **Specified and decided.** No RFC written, no code exists. Every
decision is locked for build (§37) — reopening one is a scope change, not a
judgement call.

## What v4.0 is

v2.0 made the roster live; v3.0 made pairings live. Both are **within-event**: all
knowledge is scoped to the single `is_active` tournament and stops meaning anything
when that event ends. v4.0 adds the **across-event** dimension, and fixes a leak.

1. **A persistent ranking.** Results accumulate over a season, so players have a
   reason to return and the organizer gets a standings table they don't maintain by
   hand. Two views of one record: per player, and per tournament.
2. **A team-sheet leak fix.** Because v3.0's `/ots <name>` means "I am *name*, who
   am I playing?" and returns *that person's opponent's* sheet, any player could
   walk the roster and scout the whole field before being paired. v4.0 removes the
   argument entirely; the caller is inferred from a bound Discord account.

These ship together because the second **depends on** the first: inferring "who is
calling" requires a persistent identity, which is the same identity the ranking
needs. The ranking pays for the schema; the leak fix is why that schema has to be
trustworthy.

> ⚠️ **v4.0 is a breaking change, not an additive release.** It removes the argument
> from the project's only player-facing command. The `players`↔Discord binding is
> therefore an **authorization boundary**, not leaderboard bookkeeping: a false
> binding buys silent, instant access to a sheet its holder is not entitled to, and
> no after-the-fact correction can un-see it. This is why binding is
> organizer-established with **no self-service claim command** (§31.6), and why
> typed-name lookup survives only as the separately-gated F78.

**The central trade-off.** v4.0 exchanges *disposable* data for *durable* data.
Every table so far is either re-derivable (the Challonge caches) or cheaply
retypable (a 20-row roster). `profiles` and `tournament_results` are neither: a lost
season of standings cannot be reconstructed, and a wrong one cannot be quietly
corrected without players noticing. F48, F50, F67, F69 and F72 exist to manage that.

## Supersession & amendment notes (read before building)

v4.0 is the first release that **invalidates** prior entries rather than only adding
to them. Per PRD §39:

| Document | What v4.0 changes |
|---|---|
| **This file, F25(b)** | "Persistent cross-tournament player identities" Won't-have is **reopened** — it is the core of v4.0 (F38/F39). Annotated in place above. |
| **This file, F25(e)** | *Opponents-only* OTS privacy is delivered by F76. Hidden-until-reveal stays Won't. |
| **`.claude/RULES.md` §18** and **`PRD.md` §21** | The flat "exactly 2 Challonge calls per invocation" invariant becomes "2, plus a conditional 3rd" (F68). **Both must be reworded in RFC-012** or the release gate contradicts the code. |
| **`E2E-CHECKLIST-v3.md`** | Scenarios keyed to a typed `/ots` argument are superseded by F76 and must be **struck**, not left silently failing. |
| **`RUNBOOK.md`** | Gains §9 (season setup, tiering, binding, freeze, correcting a bad freeze). |
| **`DEPLOYMENT.md`** | Gains the two new non-secret env vars. |
| **`schema.sql`** | F48's `on delete restrict` breaks the file's uniform-cascade pattern **and** breaks the RFC-007 verification block's "delete the test tournament" cleanup. |

## Locked architecture decisions for v4.0

Do not re-litigate these in RFC-011–014 (PRD §37 is the authoritative table):

- **Points are a fixed placement table × a tier multiplier** — 100/70/50/30/15/5 —
  *not* a linear formula. Bucket edges (1, 2, 3, 5, 9, 17) are deliberately aligned
  to single-elim elimination rounds so Challonge's tied ranks pay their members
  equally, automatically. Verified against real data (F51).
- **Event weight is a `tournament_tiers` lookup**, not a free numeric column, and
  frozen results snapshot the **resolved multiplier**, never `tier_id` (F45, F67).
- **The freeze lives in the Edge Function**, in TypeScript, because `bot.py` has no
  write path at all and giving it one is the larger architectural break (F52).
- **Completion is never derived from cached matches alone** — a conditional third
  Challonge call confirms it (F68).
- **Corrections require an explicit `refreeze: true` flag** (F72); the default
  freeze is one-way (F56).
- **The bracket, not the roster, decides who earned a result** — `tournament_results`
  keys on `(tournament_id, challonge_participant_id)` with `player_id` nullable (F47).
- **Identity binding is organizer-only, one-time per person**, with forward
  auto-link by normalized name (F58, F60).
- **`/ots` takes no argument**; typed-name lookup survives only as a separate
  organizer-gated command (F76, F78).
- **Authorization is a single `ORGANIZER_DISCORD_ID`** plus
  `default_member_permissions` — no Discord role model (F77).
- **Season-points ties break on turnout first**, then best finish (F70).
- **Season date bounds use `daterange(..., '[]')`; no `btree_gist`** (F42).

## Summary

**Total v4.0 features:** 41 (F38–F78), plus 11 explicit Won't-haves (§29, unnumbered).

| RFC | Scope | Feature IDs | Complexity |
|-----|-------|-------------|------------|
| **011** | Ranking schema — profiles, seasons, tiers, results, invariants, snapshot | F38–F50, F66, F67, F69 (DDL) | Medium |
| **012** | Points engine & sync freeze | F51–F57, F68, F72, F74 | High |
| **013** | Identity binding, `/ots` refactor, debug lookup | F58–F61, F69 (commands), F71, F76, F77, F78 | High |
| **014** | Ranking read commands, runbook §9, E2E checklist, release | F62–F65, F70, F73, F75 | Medium |

### By priority

Mapping per PRD §31: **P0 → Must**, **P1 → Should**, **P2 → Could**, §29
out-of-scope → **Won't**. v4.0 declares no P2s.

| Priority | Count | Feature IDs |
|----------|-------|-------------|
| Must   | 36 | F38, F39, F40, F41, F43, F44, F45, F46, F47, F48, F49, F50, F51, F52, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63, F66, F67, F68, F69, F70, F71, F72, F73, F74, F75, F76, F77 |
| Should | 5  | F42, F53, F64, F65, F78 |
| Could  | 0  | — |
| Won't  | 11 | §29 out-of-scope (section V below; no IDs minted) |

### By category

| Category | IDs | Count |
|----------|-----|-------|
| L. Data model — identity | F38–F40 | 3 |
| M. Data model — seasons, tiers, event metadata | F41–F46, F66 | 7 |
| N. Data model — frozen results | F47–F50, F67 | 5 |
| O. Points engine | F51–F53 | 3 |
| P. Challonge sync — the freeze | F54–F57, F68, F72, F74 | 7 |
| Q. Identity binding | F58–F61, F69, F71, F77 | 7 |
| R. The `/ots` refactor | F76, F78 | 2 |
| S. Ranking read commands | F62–F65, F70, F75 | 6 |
| T. Configuration | *(no new IDs — folded into F75/F77/F19)* | 0 |
| U. Release gate | F73 | 1 |
| V. Out of scope (Won't) | *(unnumbered)* | 11 |

### By complexity

| Complexity | IDs |
|------------|-----|
| Low | F38, F39, F40, F41, F43, F44, F46, F48, F49, F50, F52, F53, F55, F57, F61, F64, F66, F74, F75, F77 |
| Medium | F42, F45, F47, F51, F54, F58, F59, F62, F63, F65, F67, F69, F71, F72, F73, F78 |
| High | F56, F60, F68, F70, F76 |

### Personas

ORG = organizer · PLR = player · **UNB = the unbound player** (PRD Persona C — an
*operational state*, not a preference: someone the organizer has not bound yet, whose
one bad moment is round 1) · SYS = system/internal.

## L. Data model — identity (RFC-011)

### F38 — `profiles` table
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** §31.1
- **Description:** `id`, `discord_user_id` (not null, **unique**), `created_at`, and
  optionally a `display_name` snapshot for Studio readability. **The only table in
  the schema not scoped to a tournament** — that is the whole point of the release.
- **Acceptance criteria:**
  - Two profiles cannot hold the same `discord_user_id`.
  - Table survives an idempotent `schema.sql` re-run with no error or duplicate.
- **Technical considerations:** `discord_user_id` is the **first genuinely personal
  data this project stores** (G17) — it carries a stated retention posture and a
  working erasure path (F69) *before* release, not after. Store the snowflake as
  text, not an integer: Discord ids exceed 2^53 and JS/JSON handling in the Edge
  Function would lose precision.
- **Edge cases:** `display_name` is a snapshot and will drift as users rename
  themselves — never resolve identity through it.

### F39 — `players.profile_id`
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low · **PRD:** §31.1
- **Description:** Nullable FK from each per-tournament roster row to `profiles`.
- **Acceptance criteria:**
  - Column is nullable with no default; every existing v2.0/v3.0 row remains valid.
  - Purely additive — no existing query needs rewriting.
- **Technical considerations:** **Nullable is load-bearing, not laziness.** Roster
  rows exist before bindings do, and some rows never get one (F57, F70).
- **Edge cases:** A null here is exactly the UNB persona — it must be a first-class
  state everywhere except `/ots` (F76).

### F40 — One roster slot per person per event
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low · **PRD:** §31.1
- **Description:** Unique index on `(tournament_id, profile_id) where profile_id is
  not null`, so one person cannot hold two roster slots in the same event.
- **Acceptance criteria:**
  - Binding a profile to a second roster row in the same tournament is rejected at
    the DB level (surfaces as F59's fourth conflict rule).
  - Many null `profile_id` rows in one tournament remain legal.
- **Technical considerations:** Mirrors the existing `players_tournament_name_idx`
  contract on the name axis — the partial-index-as-invariant pattern this schema
  already uses for single-active and per-tournament name uniqueness.

## M. Data model — seasons, tiers & event metadata (RFC-011)

### F41 — `seasons` table
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §31.2
- **Description:** `id`, `name`, `starts_on`, `ends_on`. Created once per season by
  the organizer in Studio (Journey I).
- **Acceptance criteria:** A season row can be created in Studio with no other setup;
  nothing else changes until the first event of that season is created.

### F42 — Non-overlapping season ranges as a DB invariant
- **Priority:** Should · **Persona:** SYS · **Complexity:** Medium · **PRD:** §31.2
- **Description:** `exclude using gist (daterange(starts_on, ends_on, '[]') with &&)`
  — consistent with this schema enforcing invariants in the database rather than in
  application code.
- **Acceptance criteria:**
  - Inserting a season overlapping an existing one fails with a constraint error.
  - Adjacent seasons (one ending the day before the next starts) are accepted.
  - F66's "current season" query can rely on at-most-one.
- **Technical considerations:**
  - **Build the range with explicit `'[]'` bounds.** `daterange`'s default is
    half-open `[)`, which would make `ends_on` exclusive and contradict its name.
  - **No new Postgres extension.** Range types ship a native GiST operator class;
    `btree_gist` would only be needed to mix a scalar `with =` column into the
    constraint, and single-guild scope means there is none.
- **Edge cases:** P1 rather than P0 — F66 still needs a defined answer when the
  constraint is absent, so don't let F66 assume it.

### F43 — `tournaments.event_date`
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §31.2
- **Description:** The date the event actually happened.
- **Acceptance criteria:** Set by the organizer at tournament creation; season
  assignment reads this, not `created_at`.
- **Technical considerations:** **`created_at` cannot serve this purpose** — it is
  row-creation time, which diverges whenever an organizer sets a tournament up in
  advance, and season assignment depends on this being right.

### F44 — `tournaments.season_id`
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §31.2
- **Description:** Nullable FK to `seasons`. **`NULL` means the event counts toward
  no ranking** (test tournaments, exhibitions).
- **Acceptance criteria:** A null here makes the freeze a no-op that writes nothing
  and leaves `completed_at` null (F55).
- **Edge cases:** `season_id is null` is also the **guard that keeps test
  tournaments deletable** under F48 — see that entry.

### F45 — `tournament_tiers` lookup + `tournaments.tier_id`
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Medium · **PRD:** §31.2
- **Description:** `id`, `name`, `multiplier`, plus a **not-null** `tournaments.tier_id`
  FK. Seeded with **Hebdo 1.0, Mensuel 2.0, Majeur 3.0** via guarded inserts.
- **Acceptance criteria:**
  - Studio presents a typo-proof dropdown rather than a free numeric field.
  - Guarded inserts make a `schema.sql` re-run produce no duplicate tiers.
  - Picking the tier is one of only two new fields at event setup (§34).
- **Technical considerations:**
  - A lookup rather than a free numeric column so "what counts as a major" is an
    explicit, reviewable decision — **the only place organizer discretion enters the
    ranking.**
  - **The not-null FK is the migration wrinkle in an otherwise purely-additive DDL:**
    adding a not-null column to a populated `tournaments` table needs a default or a
    backfill, and `schema.sql`'s idempotent-apply contract must survive it.
- **Edge cases:** Repricing a tier later must not restate history — that is F67's
  multiplier snapshot, not this table's job.

### F46 — `tournaments.completed_at`
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low · **PRD:** §31.2
- **Description:** Nullable timestamp set by the freeze. **Non-null means "results
  are frozen."**
- **Acceptance criteria:**
  - Set **only** when a freeze actually runs (F55).
  - Non-null + no `refreeze` flag ⇒ the freeze step is skipped (F56/F72).
- **Technical considerations:**
  - **Deliberately not a status enum, and deliberately independent of `is_active`**,
    which remains load-bearing for the `/ots` read path
    (`tournaments_one_active_idx`, RFC-001/005/009). A lifecycle enum alongside
    `is_active` would create two overlapping notions of tournament state.
  - A frozen tournament may remain active; `/ots` then reports v3.0's existing
    `no_current_match`, which is the correct answer. Deactivation stays the
    organizer's normal two-step switch (F8).
- **Edge cases:** Do not infer "frozen" from `is_active = false`, or vice versa —
  the two are orthogonal by design.

### F66 — "Current season" as a defined, single-query concept
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** Low · **PRD:** §31.2
- **Description:** The unique `seasons` row whose `[starts_on, ends_on]` contains
  today. F42 guarantees at most one.
- **Acceptance criteria:** Two states get their **own French copy**, distinct from
  each other and from an error:
  - **today falls in no season** (between seasons, or before the first exists);
  - **the current season has no frozen results yet** (opening weeks — an empty
    leaderboard is **normal, not an error**).
- **Technical considerations:** Both read commands (F62/F63) and the binding backfill
  (F60) resolve the season through this one definition — implement it once.
- **Edge cases:** Inclusive bounds mean an event on `ends_on` still counts.

## N. Data model — frozen results (RFC-011)

### F47 — `tournament_results` table
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Medium · **PRD:** §31.3
- **Description:** `tournament_id`, `challonge_participant_id`, `player_id`
  (**nullable**), `profile_id` (nullable), `ingame_name` (snapshot), `final_rank`,
  `awarded_points`, `frozen_at`, `freeze_count`. **Unique on
  `(tournament_id, challonge_participant_id)`.**
- **Acceptance criteria:**
  - Every bracket entrant gets a row; roster-only names get none.
  - A re-freeze updates rows in place rather than duplicating them (F72).
- **Technical considerations:**
  - **The bracket, not the roster, decides who earned a result.** Placement is a fact
    about the bracket. Tournament 3 had **14 bracket entrants against 16 roster
    rows**: the two roster-only names must earn nothing, and a bracket entrant with no
    roster row must still be recorded.
  - `ingame_name` is **denormalized on purpose** — history must stay readable if the
    roster row is later edited, renamed, or deleted.
  - `profile_id` is nullable and **backfillable**, so an unbound player's result
    freezes correctly and binding later attributes their history (F60).
- **Edge cases:** The dual-id trap applies here too — key on
  `challonge_participant_id` (the top-level id), and be explicit about it, since
  group-stage rows elsewhere in the cache use `challonge_group_player_id`.

### F67 — Frozen results snapshot every points input
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §31.3
- **Description:** Also captured at freeze time: `season_id`, **`multiplier`** (the
  resolved numeric value, *not* `tier_id`), `formula_version`, `participant_count`.
- **Acceptance criteria:**
  - Standings sum over `tournament_results.season_id`, **never** over a join to
    `tournaments` — editing `tournaments.season_id` after a freeze must not relocate a
    frozen result into another season.
  - Repricing a tier does not change any already-frozen `awarded_points`.
- **Technical considerations:**
  - **Snapshotting `multiplier` rather than `tier_id` is load-bearing, not prudent.**
    Tiers are shared rows: repricing "Majeur" from 3.0 to 2.5 next season would
    otherwise silently restate every Majeur ever frozen.
  - `participant_count` costs one integer and keeps field-size scaling answerable
    later without a schema change **and** a Challonge re-fetch.
  - This snapshot is also why **season rollover needs no ceremony** — standings are
    reconstructible from the frozen rows alone (§37).
- **Edge cases:** Any query that reaches `tournaments` for a points input is a bug,
  even when it currently returns the right answer.

### F48 — `on delete restrict` on `tournament_results.tournament_id`
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** §31.3
- **Description:** **`on delete restrict`, not `on delete cascade`** — the one
  non-additive change in the release, and a deliberate break from every other FK in
  `schema.sql`.
- **Acceptance criteria:**
  - Deleting a tournament with frozen results fails.
  - The FK **carries an explicit comment saying it does not cascade**, because a
    future reader will otherwise assume it does.
- **Technical considerations:** Durability over convenience — frozen results are the
  one place in this system where data loss is unacceptable.
- **Edge cases / operational consequence:**
  - The "delete the test tournament" cleanup in `schema.sql`'s RFC-007 verification
    block **stops working once anything is frozen.** Test tournaments must either
    never be frozen (`season_id is null` is the guard, enforced by F55) or get an
    explicit results-purge step. Covered in runbook §9.
  - It also blocks the naive erasure path for a profile with results — which is
    exactly why **F69 anonymizes rather than deletes.**

### F49 — RLS on all new tables
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low · **PRD:** §31.3
- **Description:** RLS enabled, deny-by-default, no policies — identical posture to
  every other table (`PRD.md` §18.1).
- **Acceptance criteria:** RLS enabled on `profiles`, `seasons`, `tournament_tiers`,
  `tournament_results`; no policies; access is service-key-only.

### F50 — Frozen history is correctable only deliberately
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §31.3
- **Description:** A correction must be an **explicit action** that overwrites prior
  values and leaves a record; it must **never** be a side effect of a routine sync.
- **Acceptance criteria:**
  - No routine trigger path can alter a frozen row (F56).
  - Corrections are recorded via `frozen_at` + `freeze_count` (F72).
- **Technical considerations:** This is **durability plus an audit trail, not
  tamper-evidence** (G13) — an operator with the service key can still edit Studio
  rows, and v4.0 does not try to prevent that. Don't oversell it in the runbook.
- **Note:** F50 is the requirement; **F72 is the mechanism.**

## O. Points engine (RFC-012)

### F51 — Placement table × tier multiplier
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** Medium · **PRD:** §31.4
- **Description:** `awarded_points = multiplier × table(final_rank)`, evaluated
  **once**, at freeze time, and **stored**:

  | Placement | Base points |
  |---|---|
  | 1st | 100 |
  | 2nd | 70 |
  | 3rd–4th | 50 |
  | 5th–8th | 30 |
  | 9th–16th | 15 |
  | 17th and below | 5 (participation floor) |

- **Acceptance criteria:**
  - Reproduces tournament 3's verified vector: 100 / 70 / 50·50 / 30·30·30·30 / 15×6,
    **total 480**, with no tied rank paying unequally.
  - A rank of 17+ pays the floor, never zero.
  - Points are written to `awarded_points` and never recomputed on read.
- **Technical considerations:**
  - **Bucket edges sit on 1 / 2 / 3 / 5 / 9 / 17 — exactly where single-elim tie ranks
    land.** That alignment is what makes tied placements pay their members equally,
    *automatically*, given `final_rank`'s ties and gaps (F54).
  - **Do not "simplify" this into a linear formula.** `multiplier × (N − rank + 1)`
    opens holes at ranks 4 and 6–8 on that same tournament and pays only three points
    between 2nd and 5th.
  - **No field-size term:** `multiplier` already encodes how big a deal the event was,
    and a second scaling axis makes the number unexplainable to a player who asks why
    they got 30.
- **Edge cases:** Ranks 4, 6, 7, 8 **do not exist** in real data — the table must be
  a range ladder, not an index lookup.

### F52 — Points formula as pure, unit-tested, I/O-free logic
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low · **PRD:** §31.4, §32
- **Description:** Lives in `supabase/functions/challonge-sync/points.ts`, tested by a
  new `points_test.ts` joining the existing `mapping_test.ts` Deno suite — the same
  pattern as `normalize_name`, `render_team_text`, `pick_opponent_id`, `is_cache_stale`
  and `mapping.ts`.
- **Acceptance criteria:**
  - No I/O in the module; every bucket boundary and both tie/gap behaviors covered.
  - `deno test supabase/functions/challonge-sync/` green.
- **Technical considerations:** It sits in the Edge Function because that is where
  `final_rank` arrives **and because `bot.py` has no write path at all** — giving it
  one would be a larger architectural break than one pure function in TypeScript.
- **Note:** PRD §32 calls this "the single most test-worthy function in the release:
  pure, where the product's meaning lives, and the only new code whose bugs stay
  invisible until someone disputes a standing."

### F53 — `formula_version` on every frozen result
- **Priority:** Should · **Persona:** SYS/ORG · **Complexity:** Low · **PRD:** §31.4
- **Description:** Stored alongside each frozen result (part of F67's snapshot) so a
  future rule change is **auditable** and old results are **explicable** rather than
  merely immutable.
- **Acceptance criteria:** Every frozen row carries the version that produced it; a
  version bump identifies exactly which rows a re-freeze would affect (§38).

## P. Challonge sync — the freeze (RFC-012)

> **The seam to watch.** The same Edge Function now has **two write modes with
> opposing semantics**: the cache tables refresh by upsert and are designed to be
> re-run constantly; the freeze is one-way and must not be. PRD §31.5 states plainly
> that "that seam is where bugs will live."

### F54 — `mapParticipant` carries `final_rank`
- **Priority:** Must · **Persona:** SYS · **Complexity:** Medium · **PRD:** §31.5
- **Description:** Extend the existing pure mapping to carry `final_rank` from
  `participants.json`. **Verified live 2026-07-31** against tournament id 3 (Challonge
  `18251698`; 14 players, 4-round Swiss group stage plus a top-8 single-elim final,
  `state = 'complete'`, `group_stages_enabled = true`).
- **Acceptance criteria:** Three verified facts constrain the build and must each have
  a test:
  - `final_rank` is **non-null for every participant**, including those who never
    reached the final bracket.
  - Ranks are **competition-style with ties and gaps** — `1, 2, 3, 3, 5, 5, 5, 5, 9,
    10, 11, 12, 13, 14`. Ranks 4, 6, 7, 8 do not exist. **`final_rank` is not a dense
    1..N sequence and nothing may treat it as one.**
  - Group-stage non-qualifiers are ranked **distinctly** (9–14), not collapsed to a
    shared 9th — Challonge breaks those ties itself, presumably via the
    `tie_break_points` field in the same payload.
- **Technical considerations:** `group_player_ids` is a JSON **array**. Every
  participant here had exactly one entry, matching `challonge_group_player_id`'s
  single-column shape — **but that is not guaranteed, so log defensively if the array
  is ever longer.**
- **Edge cases:** Known unknown (§37): whether `final_rank` is null *before*
  completion is unverifiable from a completed bracket. F68 was written not to depend
  on the answer; F55/step 6 refuses loudly if a null ever appears.

### F74 — `participants[].active` must never filter the field
- **Priority:** Must · **Persona:** SYS · **Complexity:** Low · **PRD:** §31.5
- **Description:** A **prohibition**, not a behavior: freeze the whole participant
  list, with no `active` filter.
- **Acceptance criteria:**
  - A frozen group-stage tournament contains **every** entrant, including
    non-qualifiers (E2E scenario 12).
  - The trap is commented **at the mapping site**, the way the dual-id trap already is
    in `mapping.ts` (an explicit RFC-012 obligation, §40).
- **Technical considerations:** The live check found `active: false` on **all six**
  group-stage non-qualifiers and `true` on the eight who advanced. The field tracks
  *still advancing*, **not** *validly entered* — so the natural-looking "skip inactive
  participants" filter silently drops **43 % of that tournament's field**, and
  precisely the lower-placed players the participation floor exists to reward.
- **Edge cases:** If a genuine DQ/forfeit signal is ever needed, **it is not this
  field** (§37 known unknown 2).

### F55 — Freeze requires `season_id`; `completed_at` only on an actual freeze
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §31.5
- **Description:** The freeze runs only when the tournament has a non-null
  `season_id`, and `completed_at` is set **only when the freeze actually runs**.
- **Acceptance criteria:**
  - A complete tournament with no season **writes nothing** and leaves `completed_at`
    null, reporting why.
  - The organizer can then set `season_id` in Studio and trigger again; the freeze
    runs normally (Journey O). **Nothing is lost.**
- **Technical considerations:** This is what makes a forgotten `season_id`
  **recoverable rather than permanently lossy** under F56's one-way rule — the single
  cheapest safety property in the freeze.
- **Edge cases:** Also the guard that keeps test tournaments deletable under F48.

### F56 — Default freeze is idempotent and one-way
- **Priority:** Must · **Persona:** SYS/ORG · **Complexity:** High · **PRD:** §31.5
- **Description:** Re-triggering on an already-frozen tournament **does not rewrite
  results.** Overriding requires F72's explicit flag; there is no other path.
- **Acceptance criteria:**
  - Re-trigger with no flag: cache refreshes normally, results untouched, response
    **says skipped** (E2E scenario 13).
  - No routine path can reach a frozen row (F50).
- **Technical considerations:** **This is the opposite of the cache tables'
  refresh-by-upsert model**, which is designed to be re-run constantly. Complexity is
  High not for line count but because two opposing write semantics now share one
  function, one trigger, and one response payload.
- **Edge cases:** A trigger that refreshes the cache *and* skips the freeze must
  report **both** outcomes distinctly — "skipped" must never read as "failed."

### F68 — Completion confirmed by a conditional third Challonge call
- **Priority:** Must · **Persona:** SYS · **Complexity:** High · **PRD:** §31.5
- **Description:** Keep the two unconditional calls. When — **and only when** — every
  cached match reads `complete`, call `/tournaments/{id}.json` and freeze only if
  `state == 'complete'`.
- **Acceptance criteria:**
  - **Triggering at the group-stage boundary freezes nothing**: the third call reports
    a non-complete state and the freeze is refused. *(E2E scenario 11 — "the single
    most important row in that table.")*
  - Call count is 2 per invocation, plus 1 when the completion check is armed
    (≈ once per event).
- **Technical considerations:**
  - **Completion must not be derived from the cached matches alone.** In a group-stage
    tournament the final bracket's matches **do not exist in `matches.json` until the
    group stage is finalized**, so "all cached matches are complete" fires at the
    group-stage boundary, **while half the event is unplayed** — and under F56 that
    freeze is one-way.
  - `progress_meter: 100` and a non-null Challonge-side `completed_at` corroborate.
  - Cost: a 7-round event goes from ~14 calls to ~15 against Challonge's 500/month
    cap.
  - **This is a conscious amendment to `.claude/RULES.md` §18 and `PRD.md` §21**,
    which both state a flat "exactly 2 calls per invocation". **Both must be reworded
    as part of RFC-012**, or the release gate contradicts the code.
- **Edge cases:** The third call failing is not completion — treat it as
  in-progress and leave `completed_at` null.

### F57 — Bracket entrants without a roster row still freeze
- **Priority:** Must · **Persona:** UNB/SYS · **Complexity:** Low · **PRD:** §31.5
- **Description:** A bracket participant with **no `players` row** (v3.0's
  `opponent_no_ots` case) still gets a frozen result.
- **Acceptance criteria:** Placement and points are recorded with `player_id` null and
  the `ingame_name` snapshot taken from the Challonge participant.
- **Technical considerations:** Placement and points are **independent of whether an
  OTS was submitted** — which is why F47 keys on `challonge_participant_id` and leaves
  `player_id` nullable.

### F72 — Two-mode freeze (`refreeze`)
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Medium · **PRD:** §31.5
- **Description:**
  - **Default** (`{"tournament_id": X}`): if `completed_at` is non-null, the freeze
    step is skipped and the response says so. Cache refresh proceeds normally.
  - **Explicit** (`{"tournament_id": X, "refreeze": true}`): recompute and overwrite
    **every** `tournament_results` row for that tournament, update `frozen_at`,
    increment `freeze_count`.
- **Acceptance criteria:**
  - Journey N works end-to-end: fix the cause, re-trigger with the flag, standings
    self-correct on the next read.
  - `freeze_count` increments; nothing is retained about the superseded values beyond
    the incremented count.
- **Technical considerations:** **The flag *is* the safety property** — an organizer
  cannot corrupt frozen history by muscle-memory `curl`, and can correct it by adding
  six characters they had to look up in the runbook. Deliberately not automatic even
  when `formula_version` changes: a bulk re-freeze across a season **visibly changes
  published standings** and is an organizer decision (§38).
- **Edge cases:** A re-freeze after a roster rename produces a *different*
  `ingame_name` snapshot — expected, and the reason F60's propagation is logged.

### Freeze algorithm (per trigger) — in order, short-circuiting

PRD §31.5. This ordering is itself a requirement; RFC-012 should test each exit.

| Step | Condition | Outcome |
|---|---|---|
| 1 | always | Fetch `participants.json` + `matches.json` (2 calls); upsert both caches as v3.0 does |
| 2 | `completed_at` non-null, no `refreeze` | **skip** — report skipped (F56) |
| 3 | `season_id` is null | **skip** — leave `completed_at` null, report no-season (F55) |
| 4 | any cached match not `complete` | **skip** — report in-progress |
| 5 | all complete → 3rd call; `state != 'complete'` | **skip** — report not-yet-complete *(the group-stage boundary, F68)* |
| 6 | any participant has a null `final_rank` | **refuse and log loudly** — Challonge's shape changed; a partial freeze is worse than none |
| 7 | otherwise | **freeze**: for **every** participant (no `active` filter, F74), compute `multiplier × table(final_rank)`, write `tournament_results` with F67's snapshot, set `frozen_at`, set `completed_at`, set/increment `freeze_count` |

> **Unnumbered P0 (§31.5), easy to miss:** the freeze targets an **explicit
> `tournament_id` supplied in the trigger body**, exactly as the RFC-008 sync already
> does. It does **not** use the active tournament, so a tournament may be deactivated
> before being frozen (E2E scenario 16). **Runbook §9 must say so, because organizers
> will assume otherwise.** No feature ID is minted for this — treat it as an
> acceptance criterion of F56/F72.

## Q. Identity binding (RFC-013)

> Binding **authorizes access to opponent team sheets** (§31.7), so it is preventive:
> established by the organizer, **never asserted by a player. There is no
> self-service claim command.**

### F58 — `/link-organizer <ingame_name> <@user>`
- **Priority:** Must · **Persona:** ORG · **Complexity:** Medium · **PRD:** §31.6
- **Description:** Organizer-only binding command. The Discord account arrives as a
  **native user mention**, so Discord supplies the account object and **no id is ever
  typed: the organizer *selects*** (G14).
- **Acceptance criteria:**
  - Creates the `profiles` row if the account has none, then sets `profile_id` on the
    matching `players` row; French confirmation.
  - **One-time per person, not per event** — F60's forward auto-link carries it into
    every later tournament.
  - Runnable from a phone in seconds (Persona C, §38).
- **Technical considerations:** `bot.py` gains its **first write path** here — until
  now it has been read-only against Supabase. Keep the write surface as narrow as the
  command needs.
- **Edge cases:** All conflict branches are F59's.

### F59 — Binding conflict rules
- **Priority:** Must · **Persona:** ORG · **Complexity:** Medium · **PRD:** §31.6
- **Description:** Five outcomes, **each with distinct French copy, all addressed to
  the organizer** (not the player):
  1. in-game name not found on any searched roster → **reject**;
  2. name already bound to a **different** account → **reject unless** the command
     carries an explicit rebind confirmation (F61);
  3. name already bound to **this same** account → **idempotent success**, not an
     error;
  4. this account already bound to a **different** name in this tournament →
     **reject** (F40);
  5. no active tournament, or Supabase unavailable → **standard fail-soft**, in
     French.
- **Acceptance criteria:** Every branch is exercised by tests (§35 step 3) and by E2E
  scenarios 2–6.
- **Edge cases:** Rule 3 must be genuinely idempotent — organizers will re-run the
  command to *verify* a binding, and §38 recommends exactly that as a pre-flight probe
  of the `ORGANIZER_DISCORD_ID` gate.

### F60 — Propagation: backfill on bind + auto-link forward
- **Priority:** Must · **Persona:** ORG/PLR/SYS · **Complexity:** High · **PRD:** §31.6
- **Description:** Two rules plus a logging obligation.
  - **Backfill on bind** — set `profile_id` across existing `players` **and
    `tournament_results`** rows whose normalized name matches, **bounded to the current
    season**, so a binding recovers recent history without a name collision costing
    years of it.
  - **Auto-link forward** — a roster row created in a *later* tournament links
    automatically to the profile already holding that normalized name. **This is what
    makes binding one-time.**
  - **Every propagation is logged server-side** — profile, normalized name, season, row
    count, tournament ids.
- **Acceptance criteria:**
  - Bind, then check history: prior in-season results attributed, backfill logged
    (E2E 8).
  - Bind, then create a roster row in a **new** tournament: `profile_id` auto-links
    and `/ots` works **without rebinding** (E2E 9).
  - Steady state is ~14 initial bindings, then **1 per newcomer** (§34).
- **Technical considerations:**
  - The trust auto-link adds is **nil**: the organizer typing "Sen" into a roster is
    already the assertion `/ots` has depended on since v3.0.
  - **This is the one operation in v4.0 that can silently move another player's
    results *and* another player's team-sheet access** — which is why the log is
    mandatory, and why F61 is useless without it.
  - Complexity is High because it writes across two tables, is scoped by a
    season-resolution query (F66), and depends on the roster name discipline
    assumption (§36) being real.
- **Edge cases:** Two humans sharing a normalized name is the failure this design
  cannot detect — the season bound caps the damage; the log is how it is found.

### F61 — Rebinding is a command, not a Studio procedure
- **Priority:** Must · **Persona:** ORG · **Complexity:** Low · **PRD:** §31.6
- **Description:** Rebinding is the **same command plus an explicit confirmation.**
- **Acceptance criteria:**
  - Without confirmation, a cross-account rebind is refused (F59 rule 2); with it, it
    rebinds **and logs** (E2E 6).
  - The fix is runnable **from a phone in ten seconds**, mid-event.
- **Technical considerations:** When a bad binding blocks a player from `/ots` at a
  live event, a Studio procedure is not a fix — this is the release's primary
  contingency lever (§38).
- **Edge cases:** **Clearing a binding entirely remains a Studio edit** — deliberately
  not a command.

### F71 — Binding is not scoped to the active tournament
- **Priority:** Must · **Persona:** ORG/UNB · **Complexity:** Medium · **PRD:** §31.6
- **Description:** The command searches the **active roster first, then any roster in
  the current season**.
- **Acceptance criteria:** A player sitting out the current event — or being bound
  ahead of one they are about to enter — can still be bound (E2E 5).
- **Technical considerations:** The search order matters: active-first keeps the common
  case a single query, and makes the name-collision window as small as the season bound
  allows (F60).

### F69 — Erasure (`/unlink`)
- **Priority:** Must · **Persona:** PLR · **Complexity:** Medium · **PRD:** §31.6, §32
- **Description:** Clears `profile_id` from the caller's `players` rows and deletes
  their `profiles` row. Their `tournament_results` rows are **anonymized, not
  deleted** — `profile_id` set null, `ingame_name` snapshot retained.
- **Acceptance criteria:**
  - **Player-runnable, and must be:** erasure of your own personal data cannot require
    asking someone else. This is the **only** new non-organizer write command.
  - Requires an **explicit French confirmation naming the consequence**: it also
    **revokes the caller's `/ots` access** — otherwise a curious player disables
    themselves mid-event and blames the bot. Restoring requires F58.
  - After `/unlink`, frozen results stay **counted in leaderboard totals** (E2E 33).
  - Re-binding later starts a **new** profile (Journey Q).
- **Technical considerations:** Deletion of results is blocked by F48 anyway **and
  would corrupt other players' historical context** — anonymize-in-place is the only
  correct shape.
- **Retention posture (G17):** `discord_user_id` is held as long as the profile exists
  and is erasable by the player at any time. **In-game names in frozen results are
  tournament records, retained indefinitely.**

### F77 — Organizer authorization (belt and braces)
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Low · **PRD:** §31.6, §32
- **Description:** Gates F58, F61 and F78 on **both** `default_member_permissions`
  (Discord hides the command from non-organizers) **and** an explicit
  `interaction.user.id == ORGANIZER_DISCORD_ID` check.
- **Acceptance criteria:**
  - A non-organizer invoking either command is refused **and** the command is absent
    from their command list (E2E 7, 29).
  - `ORGANIZER_DISCORD_ID` is validated at boot by `validate_config()` (F19).
- **Technical considerations:**
  - Redundancy is justified **because these commands grant team-sheet access.**
  - **Fail-closed:** where the check can fail, it must fail toward denying the
    organizer a tool rather than granting a player access (§32).
  - No Discord role model is introduced; **a single id is the whole authorization
    model**, matching the "just me" persona.
- **Edge cases:** §38 — a **valid-but-wrong** id passes boot validation and locks the
  operator out of *both* organizer surfaces at once, since they share one gate. The
  mitigation is operational: pre-flight runs `/link-organizer` once, idempotently, on
  an already-bound player.

## R. The `/ots` refactor (RFC-013)

> **This is the release's breaking change and its security goal.** §35 step 3 gates
> on "typed-name form **provably absent** from `/ots`."

### F76 — `/ots` takes no argument and infers the caller
- **Priority:** Must · **Persona:** PLR/SYS · **Complexity:** High · **PRD:** §31.7
- **Description:** Resolve `interaction.user.id` → `profiles` → the caller's `players`
  row in the active tournament → **v3.0's existing opponent resolution, unchanged.**
- **Acceptance criteria:**
  - **The command accepts no argument at all** — *not* "rejects one." E2E scenario 25
    proves the leak is closed; §34 pairs it with scenario 29 and states that **a suite
    passing with either failing means the release's security goal was not met.**
  - Happy path: bound player, open match → opponent's OTS by DM (E2E 24).
  - **Two new fail-soft statuses**, French, distinct, never raising:
    - `not_linked` — no profile for this account; direct them to the organizer;
    - `not_in_tournament` — bound, but no roster row in the active event.
  - v3.0's seven statuses are otherwise unchanged, for a total of **nine**, each with
    its own French message and none raising (E2E 28).
- **Technical considerations:**
  - **`fetch_current_opponent()` keeps its shape**; only the entry point changes.
    Everything from `participant_candidate_ids()` downward — dual-id handling,
    `pick_opponent_id()`, the embed, DM delivery with ephemeral fallback,
    `render_team_text()` hardening — is **reused verbatim.**
  - Because F78 keeps the name path alive, the refactor is best framed as **"extract
    the resolution core, give it two thin entry points"** — which keeps the existing
    `test_bot.py` name-path coverage meaningful rather than deleting it.
  - `/ots` must remain usable **everywhere** and must not acquire F75's channel check.
- **Edge cases:**
  - **Accepted consequence: an unbound player cannot use `/ots` at all.** That is the
    point, but it **moves the failure to round 1**, which is why G16 (100 % bound
    before round 1) and pre-flight are load-bearing rather than advisory.
  - **No operational fallback exists** (§38): pairings can be announced by hand, team
    sheets cannot. Break-glass is redeploying the previous `bot.py` from git, which
    restores `/ots <name>` **and the scouting leak with it** — accept that trade
    knowingly rather than discovering it under pressure.

### F78 — `/ots-organizer <ingame_name>`
- **Priority:** Should · **Persona:** ORG · **Complexity:** Medium · **PRD:** §31.7
- **Description:** Organizer-only debug lookup resolving an *arbitrary* player's
  current opponent, exactly as v3.0's `/ots` did — so the organizer can **reproduce a
  player's complaint instead of taking their word for it** (Journey P).
- **Acceptance criteria:**
  - **Ephemeral reply**, never DM and never public: a diagnostic, not a delivery.
  - **Not channel-restricted** — debugging happens wherever the problem is reported.
  - **Bypasses the binding requirement by design** (E2E 31), since diagnosing unbound
    players is its purpose.
  - **Every invocation logged** with caller, queried name, and resolved status.
  - Refused for non-organizers **and absent from their command list** (E2E 29, F77).
- **Technical considerations:**
  - **A separate command, never an optional argument on `/ots`.** The reason is
    **fail-direction**: an optional parameter puts the typed-name path **one faulty
    conditional away from every player**, whereas a separate command guarded at
    registration **fails closed** — a broken auth check costs the organizer their debug
    tool and nothing else. A visible-but-unusable parameter would also undo F76's
    ergonomic win.
  - **P1, not P0:** the release ships without it and **it must never delay a security
    fix** — but ship it in the same RFC, because *"an organizer who cannot debug will
    improvise something worse."*
- **Edge cases:** Never open this to non-organizers, and never "simplify" it back into
  an `/ots` parameter. Both are called out in `CLAUDE.md` as things a future reader
  must not do.

## S. Ranking read commands (RFC-014)

### F62 — Season leaderboard (`/standings`)
- **Priority:** Must · **Persona:** PLR/ORG · **Complexity:** Medium · **PRD:** §31.8
- **Description:** Profiles **and unbound players** ranked by summed `awarded_points`
  in the current season. Ordering and limits per F70.
- **Acceptance criteria:**
  - Public reply within the configured channel (F75).
  - Sums over `tournament_results.season_id`, never a join to `tournaments` (F67).
  - Correct against Challonge's final bracket after each freeze (§34).
- **Technical considerations:** Single indexed query over a table bounded by
  (players × events per season); **defers immediately, before any I/O** — F18's rule is
  not `/ots`-specific (§32).

### F70 — Leaderboard render contract
- **Priority:** Must · **Persona:** PLR/ORG · **Complexity:** High · **PRD:** §31.8, §32
- **Description:** The full rendering and ordering specification for F62.
- **Acceptance criteria:**
  - **Ordering:** `sum(awarded_points)` desc → **most events played** desc → best
    single `final_rank` asc → `profile_id` asc (stability only, **never
    player-visible**).
  - **Equal points always display the same rank number**; sort keys decide row order
    only.
  - **Unbound players are shown and ranked** by in-game name with **no Discord
    mention**; bound profiles render as a mention.
  - **No participation floor** — one event is enough to appear.
  - **Cap at top 25**, with a French footer stating the **total ranked count** when
    truncated **and** directing unbound players to the organizer.
  - The rendered block is **hard-capped to Discord's 4096-character description
    limit** (E2E 18).
- **Technical considerations:**
  - **Turnout breaks ties before peak performance**, so a player who attended more and
    won nothing can outrank an event winner on equal points. **Intentional** — runbook
    §9 states it plainly so the organizer can answer for it.
  - The char cap is a **correctness requirement, not presentation polish**: an
    oversized description is **rejected by Discord outright**, which presents to a
    player as the command silently failing. Same discipline as `render_team_text`
    (F14) — and **the footer carries two things, both counting against the budget.**
  - This is the **second** place in the project emitting variable-length text into an
    embed; F14's lesson transfers directly.
- **Edge cases:** Empty season (F66's second state) is normal, not an error; a
  25-row cap with long French footer text is the worst case for the char budget.

### F63 — Per-player history (`/profile`)
- **Priority:** Must · **Persona:** PLR · **Complexity:** Medium · **PRD:** §31.8
- **Description:** One row per tournament entered — event name, date, placement,
  points — for the current season.
- **Acceptance criteria:**
  - **Self-only in v4.0**; **no target-user argument.**
  - Replies **ephemerally**, unlike `/standings` (E2E 21).
  - An unbound caller gets a distinct French message pointing at the organizer
    (E2E 22).
  - G11's measure: a player who entered 3 events sees all 3 — teams, placements,
    points — in one command.
- **Technical considerations:** Defers before I/O, same 5s bounded-read budget.
- **Edge cases:** No target-user argument is a **privacy decision**, not an omission —
  don't add one as a convenience.

### F64 — Per-tournament standings
- **Priority:** Should · **Persona:** ORG/PLR · **Complexity:** Low · **PRD:** §31.8
- **Description:** A third command, or an argument to F63 — "everyone who played this
  event," the second of PRD §27's two views of one record.
- **Acceptance criteria:** Reuses F70's render contract where it applies.
- **Technical considerations:** **Cheap: same table, different filter.**

### F65 — Ranking commands fail soft in French, and never raise
- **Priority:** Should · **Persona:** PLR/SYS · **Complexity:** Medium · **PRD:** §31.8, §32
- **Description:** Every ranking command handles the same outcome classes as the rest
  of the bot: `unavailable`, no current season, profile not bound, wrong channel.
- **Acceptance criteria:**
  - **Never let a ranking command raise** — same rule as `/ots`; new failure modes get
    **new named statuses, not exceptions.**
  - Supabase unreachable during `/standings` → French fail-soft, no exception
    (E2E 23).
  - **A ranking outage must never affect `/ots`** — the new commands are independent
    read paths (§32).
  - §34 target: **0** ranking-command failures reaching a player as a crash.
- **Edge cases:** "No current season" and "season with no results yet" are **two
  messages, not one** (F66).

### F75 — Ranking commands restricted to one configured channel
- **Priority:** Must · **Persona:** ORG/PLR · **Complexity:** Low · **PRD:** §31.8
- **Description:** `/standings` and `/profile` work **only** in the channel named by
  `RANKING_CHANNEL_ID`; invoked elsewhere they refuse with their own French message.
  `/standings` replies **publicly** within that channel.
- **Acceptance criteria:**
  - Elsewhere: distinct French refusal, **no standings leaked** (E2E 19).
  - **`/ots` is unaffected and must stay unaffected** — it keeps working everywhere and
    DMs as before.
- **Technical considerations:** **The channel check must not be implemented anywhere
  the `/ots` path can reach.** Put it on the ranking commands, not in shared
  middleware.

## T. Configuration (RFC-013/014 — no new feature IDs)

PRD §31.9 adds no numbered features; these requirements attach to F19 (startup
validation), F75 and F77. Listed separately because they are easy to lose.

- **Two new environment variables, neither a secret:** `RANKING_CHANNEL_ID` (F75) and
  `ORGANIZER_DISCORD_ID` (F77). Both are Discord snowflakes and **may safely appear in
  logs and documentation, unlike every other var in `.env`.**
- **Both validated at boot by `validate_config()`** alongside the existing four (F19).
  `ORGANIZER_DISCORD_ID` especially: *"a bot that starts with a wrong organizer id has
  silently locked its operator out of the only commands that can unblock a player
  mid-event."* Boot must refuse on missing **or malformed** (E2E 34).
- **`.env.example` gains two placeholder lines**; `DEPLOYMENT.md` documents both.
- **No new secrets.** The freeze reuses the Edge Function's existing Supabase and
  Challonge credentials; the read commands reuse `bot.py`'s existing service-key path.
- **`on_ready` guild sync registers six commands** — `/ots` (F76),
  `/ots-organizer` (F78), `/link-organizer` (F58), `/unlink` (F69), `/standings`
  and `/profile` (F75). **Two of the six must be invisible to non-organizers**
  (E2E 35).
- §34 targets: **0** new secrets, services, runtimes, Python deps, or Postgres
  extensions; **2** new env vars, both non-secret.

## U. Release gate (RFC-014)

### F73 — `E2E-CHECKLIST-v4.md`
- **Priority:** Must · **Persona:** ORG/SYS · **Complexity:** Medium · **PRD:** §41
- **Description:** The primary release gate — **36 scenarios**, French, mirroring the
  v2.0 (F37) and v3.0 (9/9) pattern. Must pass in full before deploy.
- **Acceptance criteria:**
  - All 36 scenarios pass; sign-off recorded the way RFC-006's Completion record was.
  - **Scenario 1** re-runs `E2E-CHECKLIST-v3.md` **minus the scenarios keyed to a
    typed `/ots` name** — those are superseded by F76 and **struck** from that
    document, not left silently failing.
  - Four status trackers updated per the `CLAUDE.md` convention: the RFC's Completion
    record, `RFCS.md`, `PRD.md`, `CLAUDE.md`.
- **The rows that carry the most weight:**
  - **11 — trigger at the group-stage boundary. Nothing frozen.** PRD calls it *"the
    single most important row in this table"* (F68).
  - **25 + 29 together** — the security goal. `/ots` accepts no argument at all, and
    `/ots-organizer` is refused and hidden for non-organizers. **Passing with
    either one failing means the release's security goal was not met** (§34).
  - **12** — every entrant present including non-qualifiers, tied ranks paying equally,
    nobody dropped for `active: false` (F74).
  - **36** — pre-flight catches a null `profile_id` **before round 1, not during it**
    (G16).
- **Technical considerations:** Needs a completed **group-stage** Challonge
  tournament to exercise scenarios 11 and 12 — tournament 3 (`18251698`) is the
  verified fixture.

## V. Out of scope (Won't have — v4.0)

From `PRD.v4.final.md` §29. **No feature IDs are minted here**, deliberately: §39
scopes this document's v4.0 additions to F38–F78, so a future PRD can continue
cleanly from F78 rather than colliding with a placeholder.

- **(a)** **Elo, Glicko, or any per-match rating.** v4.0 is a points-accumulation
  ladder driven by final placements only — a materially different product and data
  model.
- **(b)** **Retroactive import of past tournaments.** The ranking starts empty at the
  first season boundary after ship.
- **(c)** **Historical-season browsing.** Both read commands serve the current season
  only.
- **(d)** **Ranking-aware seeding** — it would invert the dependency between the bot
  and Challonge.
- **(e)** **Multiple concurrent seasons**, and reopening a closed season.
- **(f)** **Automatic detection of tournament completion.** The freeze rides the
  organizer's existing manual trigger; no polling, no schedule.
- **(g)** **A player-facing dispute or appeal flow.** Corrections go through the
  organizer (Journey N).
- **(h)** **A web leaderboard, avatars, or any surface outside Discord.**
- **(i)** **A Discord role model.** Authorization is a single organizer id (F77).
- **(j)** **Cross-guild or global rankings** — still single-guild.
- **(k)** Everything already out of scope in `PRD.md` §3 and §16 — i.e. **F25(a),
  (c), (d), (f), (g)** above, and the hidden-until-reveal half of **F25(e)** — **with
  one deliberate exception: persistent cross-tournament identities (F25(b)), listed
  as out of scope in both prior releases, is the core of this one.**

---

## v4.0 dependency & build-order notes

- **Strictly sequential**, same discipline as v2.0 and v3.0 (§35). Each RFC depends
  on the previous. **Nothing is blocked** — every decision this design needs is in
  §37.
- **Step 0 is already done:** the Challonge `final_rank` verification (F54, F74)
  completed 2026-07-31 against tournament 3. **Do not re-derive those three facts from
  first principles** — and do not assume `final_rank` is dense.
- **RFC-011 (schema) gates everything.** F38–F40 gate the binding and the `/ots`
  refactor; F41/F44/F45 gate the freeze; F47/F67 gate both the freeze and the read
  commands. F42 is P1 but F66 must not *assume* it.
- **RFC-012 carries two obligations beyond its features** (§40): reword the
  call-count invariant in `RULES.md` §18 and `PRD.md` §21 (F68), and **comment F74's
  `active` trap at the mapping site** the way the dual-id trap already is in
  `mapping.ts`.
- **RFC-013 carries the release's only breaking change and its security goal.** If it
  grows unwieldy, the natural split is RFC-013 (identity) / RFC-015 (`/ots` refactor)
  — **but they share a schema seam and a release announcement, so keep them together
  unless the reviewer objects.**
- **Highest technical risk, in order:**
  1. **F68** (group-stage completion boundary) — a wrong answer here freezes half an
     event's results one-way.
  2. **F76** (`/ots` refactor) — the only player-facing contract change, with no
     operational fallback.
  3. **F60** (propagation) — the one operation that can silently move another
     player's results *and* team-sheet access.
  4. **F56/F72** (two opposing write semantics in one Edge Function).
  5. **F70** (char cap + tie-break ordering; F14's failure mode, second occurrence).
- **Announcing the `/ots` change is a release requirement**, as v3.0's was (§36) — it
  is the one item on this list that no RFC will remind anyone about.
