# PRD — OTS Bot Backoffice (Supabase-backed team management)

**Product:** discord-ots-bot
**Version:** 2.0 (incremental evolution of the existing v1 bot)
**Author:** Product Management (with Fandresena RANDRIA)
**Date:** 2026-07-18
**Target release:** within 1 week (by 2026-07-25)
**Status:** Draft for build (v2 — hardened after PM review)

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
