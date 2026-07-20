# PRD — OTS Bot Backoffice (Supabase-backed team management)

**Product:** discord-ots-bot
**Version:** 2.0 (incremental evolution of the existing v1 bot)
**Author:** Product Management (with Fandresena RANDRIA)
**Date:** 2026-07-18
**Target release:** within 1 week (by 2026-07-25)
**Status:** ✅ Shipped (2026-07-18) — all six RFCs (001–006) complete; see
`knowledge/RFCs/RFCS.md` and RFC-006's Completion record for the release
sign-off.

> **v3.0 in design:** a Challonge-based opponent-resolution feature is being
> added on top of this shipped v2.0 base. See the **[v3.0 Addendum —
> Challonge Integration](#v30-addendum--challonge-integration)** at the end of
> this document. Everything above this point describes v2.0 exactly as
> shipped and is not modified by v3.0.

---

## 1. Overview

The discord-ots-bot is a single-guild Discord bot used during Pokémon VGC
tournaments. Players run `/ots <in-game name>` and receive the referenced
player's Open Team Sheet (OTS) — the full six-Pokémon set list — as a French
Discord embed, delivered by DM (with an ephemeral in-channel fallback).

Today the bot works well for players, but the **organizer side is broken by
design**: player→team mappings live in a hardcoded `USERNAME_URLS` dict in
`bot.py`, and every roster change requires editing code and redeploying the
worker. This does not scale to the 20+ participant tournaments the server now
runs.

This release **replaces the hardcoded map with a Supabase-backed data source**.
Organizers manage tournaments and player teams directly in **Supabase Studio**
(the built-in table editor), and the bot reads live from Supabase on every
command. **The player-facing experience is unchanged.** The value proposition:
**zero code redeploys to update teams**, and one organizer can stand up a full
tournament roster in minutes.

**The central trade-off this release makes:** it exchanges an in-process,
zero-dependency lookup for a live network read. That is the right call for
maintainability, but it introduces a runtime dependency on Supabase during live
events. The reliability requirements (§6), contingency plan (§12), and
free-tier handling (§10, §12) exist specifically to manage that trade-off.

---

## 2. Goals and Objectives

| # | Goal | Measure |
|---|------|---------|
| G1 | Eliminate code changes for roster updates | Zero redeploys required to add/edit/remove a player or team |
| G2 | Fast tournament setup | Organizer sets up a 20-player tournament in **under 5 minutes**, starting from team info already collected in their own notes app |
| G3 | Players self-serve reliably | Players continue to view opponent OTS via `/ots` with no regression in behavior (verified by the §11-linked E2E checklist) |
| G4 | Keep organizers and players in sync | A team edit in Studio is reflected on the very next `/ots` lookup (live reads) |
| G5 | Ship on time | Delivered and running on the production worker by 2026-07-25 |
| G6 | Survive a live event | No unplanned bot outage during a tournament attributable to the backend swap (free-tier pause pre-empted, contingency ready — see §12) |

---

## 3. Scope

### In scope (v1 of the backoffice)
- A Supabase schema modeling **tournaments** and **players/teams**.
- Exactly **one active tournament** at a time (flag-driven).
- **Organizer-only** data entry via **Supabase Studio** (no custom web app).
- Team data entered as **full Showdown/pokepaste export text**, stored directly.
- An **optional pokepaste URL** field per player for the clickable embed title.
- Bot refactor: read the **active tournament's players live from Supabase** on
  every `/ots`, replacing the `USERNAME_URLS` dict and the pokepast.es scraper.
- Preserve all current player-facing behavior (see §6).
- **Render-safety** for stored team text at embed time (truncation + code-fence
  neutralization — see §5.3). This is output hardening, not content validation,
  and does not conflict with the "trust team text as-is" decision (§11.4).
- A **contingency/break-glass path** for a Supabase outage during a live event
  (see §12).

### Explicitly out of scope (this release)
- Multiple simultaneously-active tournaments.
- Persistent player identities across tournaments (players are **created fresh
  per tournament**).
- A custom backoffice web app, custom auth, or multi-organizer roles.
- Player self-submission / approval workflows (organizer enters everything).
- Real-time **pairings** and **opponents-only / hidden-until-reveal** privacy
  logic (acknowledged as desirable, deferred — see §11).
- Live scraping of pokepast.es (superseded by direct text storage).
- **Content** validation/normalization of team text (trusted as-is, §11.4).
- Caching layers, multi-guild support, non-French localization.

---

## 4. User Personas / Target Audience

**Deployment:** the user's own Discord server only (single guild).

### Persona A — Tournament Organizer (primary, "just me")
- Runs VGC tournaments of 20+ participants on the server.
- Already collects each player's team (Showdown export) in a personal notes app.
- Needs to publish and update rosters quickly without touching code.
- Comfortable working in **Supabase Studio** tables.
- Sole holder of the Supabase account and the worker's service key.
- **Success = "set up the whole tournament in one sitting, edit freely, no deploys."**

### Persona B — Tournament Player (end user)
- Competes in the current tournament.
- Uses `/ots <opponent in-game name>` in Discord to view an opponent's team.
- Expects the current fast, French, DM-based experience to keep working.
- **Success = "type the name, get the team, no friction."**

---

## 5. Functional Requirements

Priority: **P0** = must ship for release; **P1** = strongly desired; **P2** = nice-to-have.

### 5.1 Data model (Supabase)
- **P0** A `tournaments` table with at least: `id`, `name`, `is_active`
  (boolean, default `false`), `created_at`.
- **P0** A `players` table with at least: `id`, `tournament_id` (FK →
  `tournaments`, `on delete cascade`), `ingame_name` (text), `team_text`
  (Showdown export, text), `pokepaste_url` (text, nullable), `created_at`.
- **P0** Exactly one tournament may be active at a time, **enforced at the
  database level** via a **partial unique index** on `is_active` where
  `is_active = true`. Activating a new tournament requires deactivating the
  previous one first (see Journey A / §5.2); the bot resolves "the active
  tournament" as the single row where `is_active = true`.
- **P0** `ingame_name` is **unique within a tournament, case-insensitive and
  whitespace-trimmed**, so a lookup never returns more than one player.
  - **On write:** `ingame_name` is trimmed (leading/trailing whitespace removed)
    at the **database level** via a `BEFORE INSERT OR UPDATE` trigger, so pasted
    Studio values are stored clean regardless of how they were entered.
  - Uniqueness is a unique index on `(tournament_id, lower(ingame_name))` (or a
    `citext` column); because the stored value is already trimmed, `lower()` on
    it is sufficient.
  - The bot's lookup query must apply the **same normalization** — `trim()` then
    `lower()` — to the user's input before matching (§5.3, §11.8).
- **P0** The active-tournament + name lookup must be **indexed** for the read
  path: at minimum the unique index above serves it; confirm the planner uses it.
- **P1** Sensible defaults and column ordering in Studio so a row can be filled
  quickly (paste name + team text, optionally a URL). `is_active` defaults
  `false`; timestamps auto-populate.

### 5.2 Backoffice (Supabase Studio)
- **P0** Organizer can create a tournament and mark it active.
- **P0** Activating a tournament is a **deliberate two-step** when another is
  active: set the current active tournament `is_active = false`, then set the new
  one `is_active = true`. (The partial unique index will reject a second active
  row with a constraint error — this is expected and documented, not a bug.)
- **P0** Organizer can add, edit, and delete players (name, team text, optional
  pokepaste URL) for the active tournament.
- **P0** No code change or redeploy is required for any of the above.
- **P1** Workflow supports pasting ~20 players from a notes app in under 5 min.
- **P2** A short organizer runbook (in `knowledge/`) covering: create/activate
  a tournament, the two-step switch, and resuming a paused free-tier project.

### 5.3 Discord bot (`/ots <username>`)
- **P0** The interaction is **deferred immediately** (before the Supabase read)
  so the network round-trip never risks Discord's 3s ack window. Defer as
  ephemeral where appropriate to preserve the current privacy of the reply path.
- **P0** On each invocation, the bot queries Supabase **live** for the active
  tournament's player matching `ingame_name`, applying `trim()` then `lower()`
  to the user's input so it matches the stored normalized value (§5.1, §11.8).
- **P0** The Supabase read uses a **bounded timeout** (comparable to the v1 5s
  fetch timeout); a timeout is treated as "Supabase unreachable" (fail-soft).
- **P0** On match, build the existing embed:
  - Title `OTS de {username}`.
  - **Clickable title URL** = the player's `pokepaste_url` **if present**;
    otherwise no link (embed still renders).
  - Description = the stored `team_text` in a code block.
  - Color `0x3B4CCA`.
- **P0** **Render-safety on `team_text`** (output hardening, not content
  validation):
  - If the rendered description would exceed Discord's embed description limit
    (4096 chars, accounting for code-fence characters), **truncate** with a clear
    French truncation marker rather than letting Discord reject the message.
  - **Neutralize** any code-fence-breaking sequence (e.g. a literal ` ``` `) in
    `team_text` so it cannot break out of / corrupt the code block.
- **P0** Delivery unchanged: **DM the user**, fall back to an **ephemeral
  in-channel reply** if DMs are closed.
- **P0** **Fail-soft** preserved. Distinct friendly **French** outcomes for:
  - username not found in the active tournament,
  - no active tournament configured,
  - Supabase unreachable / timeout / unexpected error.
  Never a crash or a stack trace to the user.
- **P0** All user-facing strings remain in **French**.
- **P0** On any Supabase error or timeout, **log the failure server-side**
  (console, alongside the existing heartbeat) with enough detail for the
  organizer to diagnose — while still showing the user only the friendly
  message. Fail-soft must not mean fail-silent for the operator.
- **P1** Improved "not found" French message clarifying that the lookup is
  scoped to the **current tournament** (proposed improvement, non-breaking).

### 5.4 Configuration
- **P0** Supabase connection loaded from environment variables alongside
  existing `DISCORD_TOKEN` / `GUILD_ID`: project URL + a **service key held only
  by the worker** (not the anon key). Nothing secret committed. `.env.example`
  updated with the new variables (placeholder values only).
- **P0** The bot validates required env vars are present at startup and logs a
  clear error if Supabase config is missing (fast, obvious failure at boot
  rather than a confusing runtime failure on first `/ots`).

---

## 6. Non-Functional Requirements

- **Compatibility / no regression:** all current player-facing behavior is
  preserved — French UI, single-guild sync, `/ots` command flow, DM +
  ephemeral fallback, and embed format (title, code-block body, color).
- **Performance:** live Supabase read per command; acceptable latency for 20+
  players and occasional concurrent lookups. Because a network read now happens
  on every invocation, **deferral is mandatory** (§5.3), not conditional.
- **Reliability:** the bot must not crash on Supabase errors; it degrades
  gracefully (§5.3) and logs operationally (§5.3). See §12 for the live-event
  contingency, since removing the hardcoded map makes Supabase a single point of
  failure during events.
- **Availability (free tier):** Supabase free-tier projects **pause after ~7
  days of inactivity** and require manual resume. This is a first-class release
  risk given bursty tournament usage — mitigations in §10 and §12.
- **Security:** secrets in env vars only. The bot uses a **Supabase service
  key** held solely by the private worker (never shipped to clients, never
  committed); Studio access is limited to the organizer's Supabase account. Note
  the service key **bypasses RLS**; since OTS data is public-by-nature within the
  tournament this is acceptable, but tables should not be exposed via a public
  anon endpoint without RLS.
- **Maintainability:** stay true to the repo ethos — keep logic in **`bot.py`**
  unless a change clearly warrants splitting; the app remains small. Data access
  is via **raw PostgREST over the existing `aiohttp`** (see §13) to avoid pulling
  in a heavy client dependency.
- **Observability:** retain the existing console heartbeat; add structured error
  logging for the Supabase read path (§5.3).
- **Deployment:** unchanged target — Procfile worker (`worker: python3 bot.py`).

---

## 7. User Journeys

### Journey A — Organizer sets up a tournament (before an event)
1. Opens Supabase Studio. (If the project is paused from inactivity, resumes it
   first — see §12 pre-flight.)
2. Creates a tournament row (`name`). If a prior tournament is still active,
   first sets its `is_active = false`, then sets the new one `is_active = true`
   (the two-step switch — §5.2). The DB rejects two active rows by design.
3. Opens the `players` table, and for each of ~20 players pastes their in-game
   name and Showdown team export (and optionally a pokepaste URL) from their
   notes app.
4. Done in under 5 minutes — no code, no deploy. Rows are live immediately.

### Journey B — Organizer fixes a team mid-tournament
1. A player corrects their set. Organizer edits that player's `team_text` in
   Studio.
2. The very next `/ots` lookup returns the updated team. No redeploy.

### Journey C — Player looks up an opponent (unchanged)
1. Player runs `/ots <opponent in-game name>` in the server.
2. Bot defers, resolves the active tournament, finds the player, builds the
   embed (with render-safety applied).
3. Player receives it by DM (or ephemeral reply if DMs are closed).
4. If the name isn't found, the bot replies with a friendly French message
   noting the lookup is scoped to the current tournament.

### Journey D — Supabase is unreachable during an event (failure path)
1. Player runs `/ots <name>`; the Supabase read times out or errors.
2. Bot replies with a friendly French "service temporarily unavailable" message
   (fail-soft) and **logs the error server-side** for the organizer.
3. Organizer sees the log / reports, and follows the §12 contingency.

---

## 8. Success Metrics

| Metric | Target | How measured |
|--------|--------|--------------|
| Code redeploys needed to update a roster | **0** | Organizer edits in Studio only |
| Time to set up a 20-player tournament (from notes app) | **< 5 minutes** | Timed Day-6 dry-run |
| Player-facing regressions vs. v1 | **0** | §5/§11 E2E checklist all-pass |
| Roster edit → visible via `/ots` | **Next lookup** (live) | Journey B test |
| Unplanned event outages from the backend swap | **0** | Post-event review; §12 readiness |
| Ready on production worker | **By 2026-07-25** | Deployed + monitored (Day 7) |

---

## 9. Timeline (1 week)

| Day | Milestone |
|-----|-----------|
| Day 1 | Finalize Supabase schema (`tournaments`, `players`), constraints (case-insensitive unique name per tournament via `lower()`/`citext`, single-active partial unique index), and Studio column setup. Confirm the read-path query uses the index. |
| Day 2 | Provision Supabase project; add env vars + update `.env.example`; add startup env validation; seed a test tournament with sample players. Confirm the PostgREST read works via `aiohttp` (§13). |
| Day 3–4 | Refactor `bot.py`: remove `USERNAME_URLS` + scraper; add deferred, timeout-bounded live Supabase read for the active tournament; build embed with optional URL and render-safety (truncation + fence neutralization); preserve DM/ephemeral + fail-soft; add server-side error logging. |
| Day 5 | End-to-end test in the guild: happy path, not-found, no active tournament, Supabase down/timeout, DMs-closed fallback, optional-URL vs. no-URL embeds, oversized/backtick-containing team text. |
| Day 6 | Organizer dry-run: time a real 20-player setup in Studio (validate < 5 min); rehearse the two-step activation switch and the §12 resume/contingency; fix rough edges. |
| Day 7 | Deploy to production worker; monitor first live use. Buffer. |

---

## 10. Assumptions

- Supabase **free tier** is sufficient for the data volume and read frequency —
  **with the caveat** that free-tier projects pause after ~7 days of inactivity
  and must be manually resumed before an event (mitigation in §12). If reliable
  always-on is required, upgrading to a paid tier is the fallback.
- The organizer already has team data in Showdown export format in their notes.
- Studio is an acceptable admin surface (no custom UI needed for v1).
- Discord's interaction model and the existing token/guild config are unchanged.
- Data access via **raw PostgREST over `aiohttp`** is acceptable and preferred
  over adding `supabase-py` (decision locked — see §11.5, §13).
- There is no meaningful existing production data to migrate; current
  `USERNAME_URLS` entries are re-entered in Studio if still relevant (§13).

---

## 11. Resolved Decisions & Open Questions

### Resolved (locked for build)
1. **Single-active enforcement — DECIDED:** enforced at the **database level**
   via a partial unique index on `is_active = true`. (See §5.1.)
2. **Supabase key type — DECIDED:** the bot uses a **service key held only by
   the worker** (not the anon key). (See §5.4, §6.)
3. **"Not found" copy — APPROVED:** the improved French message clarifying that
   lookups are scoped to the current tournament is approved for build. (See
   §5.3 P1.)
4. **Team text CONTENT validation — DECIDED:** none. The organizer's pasted
   Showdown export is **trusted as-is** (no content validation or
   normalization). This is distinct from **render-safety** (§5.3 P0:
   truncation + code-fence neutralization), which is required so untrusted-length
   or fence-breaking text cannot break the embed. Content is trusted; rendering
   is still hardened.
5. **Data access library — DECIDED:** **raw PostgREST over the existing
   `aiohttp`**, not `supabase-py`. Keeps the dependency footprint tiny and reuses
   the v1 timeout pattern. (See §13.)
6. **Case-insensitive uniqueness — DECIDED:** unique index on
   `(tournament_id, lower(ingame_name))`; bot queries with matching `lower()`
   normalization. (See §5.1.)
7. **Free-tier vs. paid — DECIDED:** stay on the **Supabase free tier** for v1,
   with the mandatory pre-event pre-flight ritual (§12) covering the ~7-day
   inactivity pause. The §12 keep-alive and break-glass measures make this
   acceptable for an event-driven, hobby-scale bot. Upgrade to a paid tier only
   if a paused project actually causes an incident. (See §6, §12.)
8. **Name normalization (trimming) — DECIDED:** `ingame_name` is
   **whitespace-trimmed on both write and lookup**. Write-side trimming is
   enforced at the DB level (a `BEFORE INSERT OR UPDATE` trigger) so Studio
   pastes are stored clean; the bot applies `trim()` then `lower()` to user
   input before matching. This prevents a stray trailing space from making a
   player un-findable. (See §5.1, §5.3.)

### Still open
9. **Deferred features to revisit post-v1:** real-time pairings and
   opponents-only / hidden-until-reveal OTS privacy; multiple concurrent
   tournaments; persistent cross-tournament player identities; player
   self-submission. Explicitly out of scope now, flagged for the roadmap.

---

## 12. Contingency & Rollback (live-event reliability)

Removing the hardcoded `USERNAME_URLS` map makes Supabase a **single point of
failure** during a live tournament. These measures manage that risk:

- **Pre-event pre-flight (P0 operational step):** before each event, the
  organizer opens Studio to confirm the project is **not paused** (free-tier
  inactivity), the correct tournament is active, and a test `/ots` returns a
  known player. Add this to the organizer runbook (§5.2 P2).
- **Keep-alive (P1, optional):** a lightweight scheduled ping to keep a free-tier
  project awake during the days around an event, if the pre-flight proves
  insufficient in practice.
- **Break-glass fallback (P1):** the v1 hardcoded-map code path is preserved in
  git history and can be redeployed for a single event if Supabase is down and
  cannot be resumed in time. The organizer keeps an exported copy of the active
  roster (Studio CSV export or the source notes) so it can be reconstructed.
- **Graceful degradation (P0):** during any outage the bot fails soft in French
  and logs server-side (§5.3) — no crashes, clear operator signal.

## 13. Dependencies & Migration

- **Runtime dependency:** Supabase project (Postgres + PostgREST). Data access
  from the bot via **PostgREST HTTP over the existing `aiohttp`** (locked,
  §11.5). No new heavy client library; `requirements.txt` stays minimal.
- **New env vars:** Supabase project URL + service key (§5.4); reflected in
  `.env.example` with placeholders only.
- **Skills required:** basic Supabase Studio usage (table create/edit, toggling
  `is_active`), SQL for the two indexes (partial unique on `is_active`; unique on
  `(tournament_id, lower(ingame_name))`).
- **Migration:** no automated migration. Any still-relevant `USERNAME_URLS`
  players are re-entered in Studio as part of the first tournament setup
  (Journey A). The scraper and dict are deleted in the Day 3–4 refactor.
- **Data backup:** roster lives only in Supabase; the organizer's source notes
  and/or a Studio CSV export serve as the backup of record (see §12).

---

# v3.0 Addendum — Challonge Integration

**Status:** 🚧 In design — RFC-007 (schema) ✅ complete (2026-07-20);
RFC-008–010 (Edge Function, `/ots` refactor, release) drafted but not yet
implemented. See `knowledge/RFCs/RFCS.md` §"v3.0 — Challonge Integration" and
`knowledge/FEATURES.md` §"v3.0 — Challonge Integration" for the RFC/feature
breakdown this addendum is implemented through.

**Origin:** this addendum consolidates a chat-based change-management review
(2026-07-20) that evaluated two options for adding live opponent-pairing
lookups — self-hosting the open-source `bracket` (evroon/bracket) app, and
integrating the hosted Challonge API — before Challonge was selected. It exists
to close the "no formal PRD" gap flagged in RFC-007, the same way §1–§13 above
document v2.0.

## 14. Overview (v3.0)

v2.0 gave organizers a Supabase-backed roster and gave players `/ots <name>` to
look up **any named player's** OTS — but a player still has to already *know*
their opponent's name (asked in-channel, read off a printed bracket, etc.).
v3.0 removes that friction: the organizer runs their actual bracket in
**Challonge** (a hosted, non-free tournament-bracket SaaS) as they already
would, and the bot resolves **"who is this player's current opponent"** from a
Supabase-cached copy of that Challonge data — so a player only ever needs to
type **their own name**.

**The central trade-off this addendum makes:** it adds a second, external,
metered SaaS dependency (Challonge) on top of the v2.0 Supabase dependency.
Two design choices exist specifically to contain that: the Challonge-facing
sync logic is isolated in a new Supabase Edge Function so `bot.py` itself never
gains a new runtime dependency (§18.2), and the sync is **organizer-triggered**,
not polled, so Challonge API call volume stays trivial relative to their
free-tier cap regardless of event frequency (§18.2, §19).

## 15. Goals and Objectives (v3.0)

| # | Goal | Measure |
|---|------|---------|
| G7 | Players resolve their current opponent without already knowing their name | `/ots <own-username>` returns the opponent's OTS directly |
| G8 | Zero new runtime dependency in `bot.py` | All Challonge I/O lives in the RFC-008 Edge Function; `bot.py` only reads Supabase (unchanged from v2.0's G1-adjacent PRD §11.5 decision) |
| G9 | Stay comfortably inside Challonge's free API tier | Realistic per-event API call volume stays far under their 500 requests/month cap (enforced since 2026-07-06), by construction of the manual-trigger design, not by careful cadence-tuning |
| G10 | No player-facing crash or silent staleness | Every new failure mode (§18.3) gets a distinct French message; cache staleness beyond 48h logs a server-side warning, never a player-facing failure |

## 16. Scope (v3.0)

### In scope
- A nullable link (`tournaments.challonge_tournament_id`) from a Supabase
  tournament to a Challonge tournament (RFC-007, shipped as this addendum's
  first RFC).
- Two Supabase cache tables mirroring Challonge's participants and matches,
  refreshed wholesale by upsert on each organizer trigger (RFC-007/008).
- A Supabase Edge Function (TypeScript/Deno) that performs all Challonge API
  calls and writes the cache tables; invoked manually by the organizer via a
  secret-protected HTTP call, immediately after they finish validating each
  round's results in Challonge (RFC-008).
- An `/ots` **behavior change** (not an additive mode): the single argument's
  meaning flips from "name of the player to look up" to "your own name," and
  the bot resolves and returns your **current opponent's** OTS (RFC-009).
- An expanded, French, fail-soft outcome set covering the new Challonge-backed
  failure modes (§18.3).
- A passive, server-side-only staleness warning (48h threshold) so a forgotten
  refresh trigger surfaces to the organizer, never to players (RFC-010).
- Runbook updates covering: linking a tournament to Challonge, keeping names
  identical across both systems, and when/how to trigger a refresh (RFC-010).

### Explicitly out of scope (this addendum)
- Any automatic/scheduled Challonge polling (rejected in favor of manual
  trigger — see §24).
- Any reconciliation between Challonge participant names and Supabase
  `players.ingame_name` beyond the existing trim+lower match contract — the
  organizer is solely responsible for keeping the two systems' names identical
  (inherited limitation, §24).
- Fallback to v2.0's "arbitrary name lookup" `/ots` behavior for tournaments
  without a Challonge link — `/ots` hard-fails distinctly instead (§24, F34).
- Self-hosting `bracket` (evroon/bracket) or any other bracket engine —
  evaluated and rejected (AGPL-3.0 licensing exposure, no "current match"
  signal in its data model, and a second full-stack service to operate; see
  the chat history behind this addendum for the full comparison).
- Writing match results, scores, or any Challonge mutation from the bot —
  strictly read-only, same posture as v2.0's Supabase reads.
- Everything already out of scope for v2.0 (§3) that this addendum doesn't
  explicitly reopen: multiple simultaneously-active tournaments, persistent
  cross-tournament identities, a custom backoffice web app/auth/multi-organizer
  roles, player self-submission, content validation of `team_text`, caching
  layers beyond what §18.1 introduces, multi-guild support, non-French
  localization.

## 17. User Personas (v3.0 additions)

### Persona A — Tournament Organizer (extended)
- Now also runs the actual bracket in **Challonge** (a paid/non-free account,
  separate from Supabase) and is responsible for keeping player names identical
  across both systems.
- New responsibility: after validating each round's results in Challonge —
  and **before making any further change there** — triggers a Supabase cache
  refresh (a documented `curl`/shell command). This ordering is the entire
  correctness model for cache freshness (§19); there is no automatic refresh.
- **Success = "validate a round in Challonge, hit refresh, players immediately
  get correct opponent lookups — no extra bookkeeping."**

### Persona B — Tournament Player (extended)
- Now runs `/ots <their own username>` instead of needing to already know (and
  correctly type) their opponent's name.
- **Must unlearn the v2.0 command's old meaning** — this is a one-time,
  intentional UX break communicated via pre-event announcement, not a
  regression to silently absorb (see §24, Feature Modification classification
  in the chat-based change analysis behind this addendum).

## 18. Functional Requirements (v3.0)

Priority: **P0** = must ship for this addendum; **P1** = strongly desired;
**P2** = nice-to-have. (Same scheme as v2.0 §5.)

### 18.1 Data model (Supabase) — RFC-007

- **P0** `tournaments.challonge_tournament_id` — nullable text, no default.
  `NULL` means no Challonge integration for that tournament (drives §18.3's
  hard-fail path).
- **P0** `challonge_participants_cache` — Challonge participant id ↔ normalized
  `ingame_name`, per tournament; same trim+lower contract as `players`
  (reusing RFC-001's `trim_ingame_name()` trigger, not a second implementation).
- **P0** `challonge_matches_cache` — Challonge match rows (`state` constrained
  to `pending`/`open`/`complete`, `round`, both sides' participant ids,
  winner), per tournament.
- **P0** Both cache tables are refreshed by **upsert**, never append — a
  re-trigger must reflect Challonge's current state without accumulating
  stale/duplicate rows.
- **P0** RLS enabled (deny-by-default, no policies) on both new tables, same
  posture as `tournaments`/`players`.

### 18.2 Challonge sync (Supabase Edge Function) — RFC-008

- **P0** All Challonge API calls happen in a **Supabase Edge Function**
  (TypeScript/Deno) — chosen over a `pg_cron`+`pg_net` SQL-only job because
  correct JSON handling and upsert logic is materially easier to write and
  debug in TypeScript than in plpgsql against `pg_net`'s async
  request/response model. This is the **first non-Python runtime component**
  in this project; it requires a new `supabase/functions/` directory (a
  documented, deliberate exception to RULES §2's "no new folders," not a
  silent violation — RULES.md needs a v3.0 note when RFC-008 lands).
- **P0** The Edge Function performs a **full refresh** (participants + matches,
  2 Challonge API calls) on every invocation — no incremental/delta sync. This
  is deliberately simple because trigger volume is inherently low (§19), not
  because incremental sync was too hard.
- **P0** Invocation is **manually triggered by the organizer** — a documented
  `curl`/shell command, protected by a secret (not the public anon key) — never
  a scheduled/cron poll. **This is load-bearing, not a convenience**: it is
  what keeps Challonge API usage far under their free-tier cap regardless of
  how many events run in a month (§19).
- **P0** `bot.py` never calls the Challonge API directly, at any point —
  preserves v2.0's locked decision (§11.5) that the bot has zero new runtime
  dependencies. This is unchanged and non-negotiable for this addendum.

### 18.3 Discord bot (`/ots <own-username>`) — RFC-009

- **P0** The command's argument **changes meaning** from v2.0: the caller types
  their **own** username; the bot resolves their current opponent via the
  cache tables and returns the **opponent's** OTS (title, embed, DM/ephemeral
  delivery — otherwise unchanged from v2.0 §5.3).
- **P0** If the active tournament's `challonge_tournament_id` is `NULL`, `/ots`
  **hard-fails** with a distinct French message — no fallback to v2.0's
  arbitrary-lookup behavior (a deliberate simplification, confirmed default,
  not an oversight).
- **P0** Opponent resolution: normalize the caller's input (same trim+lower as
  v2.0), find their `challonge_participant_id` in the cache, then the row in
  `challonge_matches_cache` with `state = 'open'` where that id appears on
  either side; the *other* side's participant id resolves back to a name,
  which is looked up in `players.team_text` exactly like v2.0's existing read
  path (unchanged code path — this is the one piece of v2.0 logic this
  addendum reuses verbatim).
- **P0** Fail-soft — **distinct French outcomes**, expanded from v2.0's three
  to (at least) seven:
  1. no active tournament (unchanged from v2.0)
  2. active tournament has no Challonge link (`challonge_tournament_id IS NULL`)
  3. requester's username not found in the cached Challonge participants
  4. requester found, but no `open` match involves them right now (bye,
     eliminated, or their round hasn't started) — **one generic message**
     covers all three sub-cases (a default taken in this addendum, not
     separately confirmed — flagged as an open item in §24 if the organizer
     wants them distinguished later)
  5. opponent resolved from Challonge, but no matching `players.team_text` row
     exists (a name-sync gap between Challonge and Supabase)
  6. Supabase read unavailable/timeout (unchanged from v2.0)
  7. *(operator-only, not player-facing)* cache older than 48h — logged
     server-side, never blocks the player (§19, RFC-010)
- **P0** All user-facing strings remain **French**, matching v2.0's tone
  (✅/⚠️/❌ conventions).

### 18.4 Configuration — RFC-008/010

- **P0** New secrets: the Edge Function's own Challonge API credentials (a
  static API key, per Challonge API v1's HTTP Basic auth — no OAuth/token
  refresh needed for this single-organizer-account use case) and the shared
  secret protecting the Edge Function's manual-trigger invocation. Neither is
  ever held by `bot.py` — consistent with §18.2's "bot never calls Challonge"
  rule.
- **P0** `knowledge/DEPLOYMENT.md` gets a new section for deploying/updating
  the Edge Function (`supabase functions deploy ...`) — this project's first
  deployment target beyond the single VM/systemd Python worker.

## 19. Non-Functional Requirements (v3.0)

- **Cache freshness (new NFR):** freshness is **organizer-defined**, not
  time-defined — the cache is correct exactly when the organizer has triggered
  a refresh after their most recent Challonge validation and before their next
  Challonge change. There is no automatic expiry/TTL check blocking reads; the
  only staleness signal is the 48h operator-only warning (§18.3.7), which is a
  safety net for a forgotten trigger, not a correctness mechanism.
- **Cost/rate-limit containment:** Challonge's free API tier caps usage at 500
  requests/month (enforced since 2026-07-06); the manual-trigger design keeps
  realistic usage (rounds-per-event × 2 calls) far under that cap without any
  cadence-tuning. Paid-tier pricing, if this cap is ever approached, is not
  published and would need checking directly at `connect.challonge.com` before
  relying on it.
- **Reliability:** unchanged posture from v2.0 (§6) — the bot must not crash on
  any Supabase error, including the new cache-table reads; every new failure
  mode degrades to a distinct French message (§18.3).
- **Security:** Challonge credentials and the trigger secret are held only by
  the Edge Function's environment, never by `bot.py` or any client — same
  "worker/operator-only secret" posture as the existing Supabase service key
  (v2.0 §6).
- **Maintainability:** this addendum is the first deliberate exception to the
  v2.0 "single Python file, no new folders" ethos (RULES §2) — contained to one
  new `supabase/functions/` directory, not a general relaxation of that rule.

## 20. User Journeys (v3.0)

### Journey E — Organizer links a tournament to Challonge (setup)
1. Organizer creates and configures the tournament in Challonge as normal
   (their own account, their own bracket format).
2. In Supabase Studio, sets the corresponding `tournaments` row's
   `challonge_tournament_id` to that Challonge tournament's id/slug.
3. Runs the Edge Function's manual trigger once to populate the cache tables
   for the first time.

### Journey F — Organizer validates a round (steady state, the common case)
1. Organizer validates the round's results in Challonge (as they would
   regardless of this integration).
2. **Before making any further change in Challonge**, organizer runs the
   documented trigger command. The cache now reflects the just-validated round.
3. Players immediately get correct current-opponent lookups via `/ots`.

### Journey G — Player looks up their opponent (unchanged shape, changed meaning)
1. Player runs `/ots <their own username>`.
2. Bot defers, resolves the active tournament's Challonge link, finds the
   player's `open` match in the cache, resolves the opponent's name, and looks
   up their `team_text` exactly as v2.0's read path already does.
3. Player receives the opponent's OTS by DM (or ephemeral reply if DMs are
   closed) — delivery mechanics unchanged from v2.0.

### Journey H — Failure paths (expanded from v2.0's Journey D)
1. Any of §18.3's seven outcomes short-circuits to its own French message.
2. Server-side logging covers both true errors (Supabase unreachable) and the
   operator-only staleness warning — never surfaced to the player either way.

## 21. Success Metrics (v3.0)

| Metric | Target | How measured |
|--------|--------|--------------|
| Challonge API calls per event | Far under the 500/month free-tier cap | Rounds-per-event × 2, by construction of the manual-trigger design |
| `bot.py` new runtime dependencies | **0** | All Challonge I/O lives in the RFC-008 Edge Function |
| Distinct fail-soft outcomes covered | **7** (§18.3) | RFC-010's E2E checklist, mirroring RFC-006's pattern |
| Forgotten-refresh detection | Logged within 48h, never player-facing | RFC-010's staleness-warning verification |
| Player-facing regression vs. the *new* `/ots` contract | 0 (post-announcement) | RFC-010 E2E checklist; the *v2.0* contract is intentionally superseded, not preserved (§17) |

## 22. Timeline

Unlike v2.0's fixed 1-week sprint (§9, hard target 2026-07-25), **no delivery
date has been set for v3.0** as of this addendum. Recommended sequencing
(strictly sequential, same discipline as v2.0):

| Step | Milestone |
|------|-----------|
| RFC-007 | Schema + cache tables — **drafted** (2026-07-20) |
| RFC-008 | Edge Function (manual-trigger, full-refresh sync) |
| RFC-009 | `/ots` opponent-resolution refactor + expanded fail-soft |
| RFC-010 | Runbook, staleness backstop, E2E checklist, dry-run, release |

A hard release date should be set once RFC-008/009 are scoped in detail — not
assumed from v2.0's cadence, since this addendum's scope (a new external SaaS
dependency, a new runtime) is not directly comparable in size to any single
v2.0 RFC.

## 23. Assumptions

- The organizer already has (or will create) a Challonge account and is
  willing to accept it as a second, non-free, external dependency alongside
  Supabase.
- The organizer will reliably trigger a cache refresh immediately after
  validating each round's results and before making any further Challonge
  change — the entire cache-correctness model depends on this discipline
  (§19); there is no technical enforcement of it.
- Player usernames can realistically be kept identical between Challonge and
  Supabase by the organizer alone, with no reconciliation tooling.
- Supabase Edge Functions are an acceptable, Supabase-native extension of the
  "no custom backoffice web app" locked decision (v2.0 PRD §11, F25c) — i.e.
  a backend sync job is not the kind of thing that decision was meant to
  prohibit.

## 24. Resolved Decisions & Open Questions (v3.0)

### Resolved (locked for build)
1. **Bracket engine — DECIDED:** Challonge (hosted SaaS), not self-hosting
   `bracket`/evroon-bracket. Rationale: Challonge's `Match.state` field
   directly answers "what is the current match," which `bracket`'s data model
   cannot without heuristics; Challonge needs no self-hosting; AGPL-3.0
   licensing risk is avoided entirely.
2. **Sync architecture — DECIDED:** a Supabase Edge Function (TypeScript/Deno),
   not `pg_cron`/`pg_net`. Rationale: correctness/debuggability of JSON
   handling and upserts outweighs the minimal-runtime ethos here.
3. **Sync trigger — DECIDED:** manual, organizer-triggered (documented
   secret-protected `curl`/shell command), not scheduled polling. Rationale:
   the organizer already knows the exact moment a round's results are final
   (they validate them), and this keeps Challonge API usage trivial without
   any cadence-tuning problem.
4. **No-link fallback — DECIDED:** `/ots` hard-fails distinctly when the active
   tournament has no `challonge_tournament_id`; it does **not** revert to
   v2.0's arbitrary-lookup behavior.
5. **Staleness backstop — DECIDED:** 48h threshold, server-side warning log
   only, never a player-facing block.
6. **Identity join — DECIDED:** exact normalized-username match between
   Challonge and `players.ingame_name` (same trim+lower contract as
   RFC-001/004); no automated reconciliation beyond that.

### Still open
7. **Bye/eliminated/not-yet-started copy granularity:** §18.3 outcome 4
   currently defaults to **one generic** "no current match" message covering
   all three sub-cases. This is a default taken for this addendum, not a
   separately confirmed decision — revisit if the organizer wants them
   distinguished once real usage surfaces a need.
8. **PRD-to-code traceability for RFC-008/009/010:** this addendum specifies
   their requirements (§18.2–§18.4) ahead of their own RFC documents being
   drafted, mirroring how v2.0's PRD preceded RFC-001–006. Each RFC should
   still restate its own acceptance criteria rather than only pointing back
   here (same convention RFC-007 followed).
9. **Formal release date:** not yet set (§22) — should be fixed once RFC-008
   is scoped.

## 25. Contingency & Rollback (v3.0)

- **Challonge itself unreachable at trigger time:** the organizer's trigger
  attempt fails or times out; the cache simply keeps serving the last
  successful refresh. This is inherent to the manual-trigger design, not a new
  failure mode requiring special handling — the organizer retries the trigger
  once Challonge is reachable again.
- **Feature proves problematic mid-event:** since there is no fallback to
  v2.0's arbitrary-lookup behavior (§24.4), the break-glass path for this
  addendum is **operational, not technical**: the organizer announces pairings
  manually in-channel for the affected round, the same way a pre-v1 tournament
  would have, while the underlying issue is diagnosed — mirroring v2.0's own
  break-glass philosophy (§12) rather than introducing a new code path.
- **Organizer decides to stop using Challonge for a tournament:** unset
  `challonge_tournament_id` on that `tournaments` row; `/ots` immediately
  starts hard-failing with the "no Challonge link" message for it (§18.3.2) —
  a clean, reversible, single-column rollback.

## 26. Dependencies & Migration (v3.0)

- **New runtime dependency:** Challonge (hosted SaaS) — a static API key held
  only by the RFC-008 Edge Function, never by `bot.py` or any client.
- **New deployment target:** a Supabase Edge Function — `knowledge/DEPLOYMENT.md`
  needs a new section (RFC-010) for its deploy/update procedure, this
  project's first deployment target beyond the VM/systemd Python worker.
- **New env vars / secrets:** Challonge API credentials and the Edge
  Function's trigger secret (RFC-008); none of these are added to `bot.py`'s
  own configuration (§18.2, §18.4).
- **Migration:** none required — this addendum is purely additive (one
  nullable column, two new tables); every existing v2.0 `tournaments`/`players`
  row remains valid and unaffected with `challonge_tournament_id IS NULL`.
- **Data backup:** unchanged from v2.0 (§12) for `players`/`tournaments`; the
  new cache tables are, by design, disposable/re-derivable from Challonge at
  any time via a re-trigger — they are not a backup-of-record for anything.
