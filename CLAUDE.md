# CLAUDE.md

Guidance for working in this repository.

## What this is

A single-guild Discord bot that serves Pokémon **OTS** (Open Team Sheet) team
lists. Current version: **v3.0**, shipped 2026-07-31.

A player runs `/ots` (no argument); the bot infers the caller from a Discord
account the organizer bound once (`/link-organizer`), works out **who their
current opponent is** from a Supabase-cached copy of the tournament's
**Challonge** bracket, then DMs back an embed of that opponent's stored
`team_text` (falling back to an ephemeral in-channel reply if the user's DMs
are closed). User-facing text is in **French**.

> **`/ots` takes no argument — RFC-013 removed it.** This is the single most
> common thing to get wrong when reading this repo now: v3.0's `/ots <name>`
> meant "I am `<name>`, who am I playing?", but that let anyone type any
> roster name and scout the whole field's team sheets before being paired.
> v4.0 closes that leak: the caller is always inferred from their **own bound
> Discord account**, never from typed input. The only surviving typed-name
> lookup is `/ots-organizer <name>`, a separate organizer-only debug command
> (F78) — never an optional argument on `/ots`.

## Docs & knowledge base

All notes, documentation, and planning artifacts for this project live in the
**`knowledge/`** folder at the repo root. Put any new design, planning, or
reference doc there (do not scatter them across the repo root).

- `knowledge/PRD.md` — the approved PRD. §14–§26 specify the current
  Challonge-backed behavior; §1–§13 specify the Supabase data layer it builds
  on.
- `knowledge/PRD.v4.final.md` — **the authoritative v4.0 spec.** Specified and
  decided 2026-07-31: a ranking system plus a **breaking `/ots` change** that
  closes a v3.0 team-sheet scouting leak. §31.7 is the section to read first;
  §37 is the locked-decision table. Numbering continues from `PRD.md`
  (§27–§41, F38–F78, G11–G17, Journey I–Q, RFC-011–014). **In build:**
  RFC-011 (ranking schema), RFC-012 (points engine & sync freeze) and
  RFC-013 (identity binding & `/ots` refactor) are all ✅ complete and live
  in production as of 2026-08-18; RFC-014 remains.
- `knowledge/FEATURES.md` — feature breakdown (MoSCoW), F1–F78, in three
  appended release sections (v2.0 F1–F25, v3.0 F26–F37, v4.0 F38–F78). Its
  v4.0 section carries the supersession table for what v4.0 invalidates in the
  sections above it.
- `knowledge/RFCs/` — one file per RFC (001–010) plus `RFCS.md`, the master
  index with status, dependency graph, and tracked follow-ups. **`RFCS.md` is
  the fastest way to orient**; read it before the individual RFCs.
- `knowledge/RUNBOOK.md` — organizer runbook for Supabase Studio workflows:
  create/activate a tournament, player CRUD, fast bulk setup (§1–§4);
  pre-flight, contingency, and roster backup (§5–§7); **the Challonge workflow
  (§8)** — linking a tournament, name discipline across both systems, and the
  manual refresh trigger.
- `knowledge/E2E-CHECKLIST-v3.md` — the release gate for current behavior, 9
  scenarios, 9/9 `PASS`, signed off 2026-07-31. French.
- `knowledge/DEPLOYMENT.md` — how the bot is actually deployed and run in
  production (VPS, systemd service, redeploy steps, troubleshooting
  log); **§12 covers deploying the `challonge-sync` Edge Function**, which is a
  completely separate deploy path from the bot.
- `.claude/RULES.md` — development guardrails / locked-decision rules (kept in
  `.claude/`, not `knowledge/`).

## Stack & layout

- **Python 3**, `discord.py>=2.3.0`, `python-dotenv` (`aiohttp` comes in
  transitively via discord.py).
- The bot is one file: **`bot.py`** (~510 lines). No packages/modules.
- **`supabase/functions/challonge-sync/`** — the one exception to the
  single-file rule: a TypeScript/Deno Supabase Edge Function holding *all*
  Challonge API I/O. `index.ts` (HTTP handler, fetch, upsert), `mapping.ts`
  (pure Challonge-JSON → cache-row mapping), `mapping_test.ts`. **`bot.py` never
  talks to Challonge** — it only ever reads Supabase. That boundary is a locked
  decision, not an accident.
- **`supabase/migrations/`** — the schema, as tracked migrations. This replaced
  the hand-applied root `schema.sql` on 2026-08-16; that file is now a stub that
  redirects here, and **must not be applied**. Three migrations so far:
  `..._baseline_v2_v3_schema.sql` (RFC-001/003/007 DDL, marked applied on
  production via `migration repair` rather than executed),
  `..._rfc011_ranking_schema.sql` (v4.0 ranking/identity DDL plus the
  `tournament_tiers` reference rows), and `..._explicit_service_role_grants.sql`.
  Every migration is still individually idempotent — that is what makes the
  baseline-repair safe.
- **`supabase/seed.sql`** — test fixtures only, applied by `supabase db reset`
  on local/dev and **never** shipped by `db push`. Keeping fixtures inside the
  applied schema is what caused the 2026-08-16 apply failure; do not move them
  back. Reference data (the tiers) belongs in its migration, not here.
- **`supabase/verification.sql`** — the commented invariant self-checks that
  used to sit at the bottom of `schema.sql`. Not part of any apply path.
- `test_bot.py` (repo root) — stdlib `unittest`, 30 tests covering the pure
  logic functions below.
- `deploy.sh` — pull + restart the systemd service; run **on the production VM
  over SSH**, not locally.
- Other files: `requirements.txt`, `Procfile`, `.env.example`, `.gitignore`.
- No CI (`.github/workflows/` is empty) — tests are run by hand.

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env   # then fill in all four vars (see Config below)
python bot.py

python -m unittest test_bot                                  # 30 tests
deno test supabase/functions/challonge-sync/mapping_test.ts  # 7 tests
```

Note `bot.py` imports `aiohttp`, so `test_bot.py` cannot be run against a bare
system Python — use the venv where `requirements.txt` is installed.

`Procfile` declares the process type (`worker: python3 bot.py`) for a
Heroku/Railway/Render-style PaaS, but **production actually runs on a
self-managed VPS (moved from Oracle Cloud on 2026-10-19) as a systemd service** — see
`knowledge/DEPLOYMENT.md` for the full setup, redeploy, and troubleshooting
steps.

## Config

Loaded from `.env` via `python-dotenv`:

- `DISCORD_TOKEN` — bot token (never commit this; `.env` is git-ignored).
- `GUILD_ID` — target server ID. The `/ots` command is synced only to this
  guild in `on_ready`, so slash-command changes appear immediately for that
  server (no global-sync propagation delay).
- `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` — the live PostgREST seam (now read
  **and write** — see RFC-013's `_supabase_write`). The service key bypasses
  RLS (every table is deny-by-default with no policies), so it is
  worker-only and never committed.
- `ORGANIZER_DISCORD_ID` (RFC-013) — the organizer's Discord user id, gating
  `/link-organizer` and `/ots-organizer` (F77). **Not a secret** — a public
  Discord snowflake, safe to log — but required: the bot refuses to start
  without it.
- All five vars above are validated at boot by `validate_config()`
  (`bot.py:38`) — missing/invalid config fails fast before `client.run()`, not
  on first `/ots`.

**The Edge Function has its own, separate secrets** (set via `supabase secrets
set`, *not* in `.env` — see `knowledge/DEPLOYMENT.md` §12):
`CHALLONGE_SYNC_SECRET` (shared secret gating the HTTP trigger),
`CHALLONGE_API_KEY`, `SUPABASE_URL`, and `SUPABASE_SERVICE_ROLE_KEY`. Note the
last one is spelled differently from the bot's `SUPABASE_SERVICE_KEY`.

## Key mechanics (`bot.py`)

- `/ots` **takes no argument** (RFC-013/F76 — the security fix). It **defers**
  the interaction immediately (ephemeral, before any I/O), then calls
  `fetch_opponent_for_profile(str(interaction.user.id))` — the caller is
  always their own **bound profile**, never typed input.
- `fetch_opponent_for_profile()` is `/ots`'s entry point. Within one bounded
  (5s) session it: resolves the active tournament and its
  `challonge_tournament_id`; looks up the caller's `profiles` row by
  `discord_user_id`; finds their roster row (`players.profile_id`) in the
  active tournament; then hands off to `_resolve_opponent()` — the extracted
  v3.0 chain (cached participant → candidate id set → `open` match → opponent
  name → `fetch_active_player()`'s `team_text` read). It **never raises** and
  returns one of **nine** statuses: v3.0's seven (`"ok"`, `"no_active"`,
  `"no_challonge_link"`, `"requester_not_found"`, `"no_current_match"`,
  `"opponent_no_ots"`, `"unavailable"`) plus two new ones —
  `"not_linked"` (no bound profile) and `"not_in_tournament"` (bound, but not
  on this tournament's roster).
- `fetch_current_opponent()` keeps its **exact original signature and seven
  statuses**, unchanged — it is now `/ots-organizer`'s entry point (F78), the
  organizer-only typed-name debug lookup that survives from v3.0. It never
  touches `profiles`, which is exactly why it also works on unbound players.
- **The dual-id trap.** A Challonge participant can be referenced in the matches
  cache by *either* its top-level `challonge_participant_id` *or*, in
  group-stage tournaments, a separate `challonge_group_player_id` — both stay
  live simultaneously once a final bracket is generated (group matches use the
  group id, bracket matches use the top-level id). `participant_candidate_ids()`
  builds the candidate set and `pick_opponent_id()` matches against **the
  whole set**. Reducing either back to a single id silently breaks opponent
  resolution for one phase of the tournament. See the long comments in
  `schema.sql` and `mapping.ts`.
- `is_cache_stale()` / `_warn_if_stale()` emit an **operator-only** `print()`
  when the cache row backing a request is >48h old. This never gates
  resolution, never changes the reply, and is never player-facing.
- `/ots` branches on the status into **eight** distinct French fail-soft
  `followup` replies (via the `OTS_STATUS_MESSAGES` table), or on `"ok"`
  builds the embed: title `OTS de {opponent's stored ingame_name}`,
  description via `render_team_text()` (fenced, hardened, size-capped), color
  `0x3B4CCA`, and a clickable `url` set to `pokepaste_url` **only when
  present** (never `url=None`).
- Delivery DMs the embed to the user, falling back to an ephemeral in-channel
  reply with the same embed on `discord.Forbidden` (DMs closed).
- **`/link-organizer <name> <user> [confirm_rebind]`** (F58/F59/F60/F61/F71,
  organizer-gated) binds a Discord account to a roster row, backfills that
  season's `players`/`tournament_results` rows for the same normalized name
  (bounded to `profile_id is null`, never stealing an already-attributed
  row), and logs the propagation. **`/unlink <confirm>`** (F69) is the
  player's own erasure path — clears roster links, anonymizes frozen
  results, deletes the profile — no organizer gate, since erasing your own
  data can't require asking someone else.
- `bot.py`'s **first write path**: every `POST`/`PATCH`/`DELETE` goes through
  the single `_supabase_write()` seam, the write-side twin of the read-only
  `_fetch_*` helpers. The freeze (points, `final_rank`, standings) still
  lives entirely in the `challonge-sync` Edge Function — `bot.py` only ever
  writes profile/attribution columns.

## Key mechanics (`challonge-sync` Edge Function)

- Organizer-triggered only — a secret-protected HTTP `curl` the organizer runs
  **after validating each round in Challonge** (`RUNBOOK.md` §8). There is no
  polling and no schedule; refresh cadence is entirely a human discipline, and
  that is a deliberate decision to stay inside Challonge's 500 req/month cap.
- Refreshes both cache tables **by upsert, never append**, so a re-trigger
  reflects Challonge's current state without accumulating stale rows.
- Read-only against Challonge — the bot never writes scores or any mutation.
- **Community-owned tournaments must be linked by numeric id, not URL slug.**
  Challonge's v1 API resolves slugs only within the requesting key's *personal*
  namespace, so a community tournament's browser-address-bar slug 404s even for
  its own organizer. Verified live; documented in `RUNBOOK.md` §8.

## Locked decisions

Do not relitigate these without an explicit decision to reopen them:

- **Single active tournament** enforced by a DB partial unique index, not
  application code. Activation is a two-step switch (deactivate, then
  activate) — the unique violation on a one-step attempt is expected behavior.
- **`ingame_name` uniqueness is per-tournament and case-insensitive**, enforced
  by a functional index; the bot must trim+lower input to match.
- **`team_text` is trusted as-is** — rendered verbatim, never validated.
- **The service key lives only on the worker**, never client-side.
- **`bot.py` never talks to Challonge**; all Challonge I/O is in the Edge
  Function.
- **Refresh is organizer-triggered, never polled** (Challonge free-tier cap).
- **No fallback to arbitrary-name lookup** when a tournament has no Challonge
  link — `/ots` hard-fails with a distinct message instead.
- **`bot.py`'s data access is one thin seam, reads and (since RFC-013) writes
  alike** — `_supabase_write()` is the single write twin of the `_fetch_*`
  read helpers; nothing calls `session.post`/`patch`/`delete` directly.

## Planned direction (v4.0 — specified and decided, in build)

A **ranking system** *and* a security fix to `/ots`, specified in
`knowledge/PRD.v4.final.md`. **Fully decided as of 2026-07-31** — nothing is
open for exploration. **In build:** RFC-011 (ranking schema), RFC-012
(points engine & sync freeze, including the hosted `challonge-sync` deploy)
and RFC-013 (identity binding & `/ots` refactor — `/ots` now takes no
argument in production, verified in-guild and deployed 2026-08-18) are all
✅ complete; RFC-014 (ranking read commands & release) remains. Read
**§31.7** (the `/ots` refactor) first, then **§37** (the locked-decision
table). Reopening a §37 decision is a scope change, not a judgement call.

> ⚠️ **v4.0 is a breaking change to `/ots`, not an additive release.**
> `/ots` loses its argument and infers the caller from a bound Discord profile.
> This closes a real leak found during v3.0: because `/ots <name>` returns *that
> person's opponent's* team sheet, anyone could walk the roster and scout the
> whole field before being paired. Consequence: the identity binding is an
> **authorization boundary**, not leaderboard bookkeeping — which is why binding
> is organizer-only, with no self-service claim command.
>
> Typed-name lookup survives **only** as `/ots-organisateur <name>`, a separate
> organizer-gated command for live debugging (F78). Two rules about it that a
> future reader must not "simplify": it is **never** an optional argument on
> `/ots` (an optional parameter puts the leak one faulty conditional away from
> every player, whereas a separate command fails closed), and it is **never**
> opened to non-organizers.

The shape: identity keyed on **Discord account**, bound **once per human** by the
organizer via `/link-organizer <name> <@user>` (later tournaments' roster rows
auto-link by normalized name, so it is never repeated); placement pulled from
Challonge's `final_rank` and **frozen** when a tournament closes; points computed
at freeze time and **stored**, so later rule changes never restate history;
standings summed per season.

The decisions most likely to surprise a reader:

- **Points are a fixed placement table × a tier multiplier** — 100 / 70 / 50 /
  30 / 15 / 5. The bucket edges (1, 2, 3, 5, 9, 17) are deliberately aligned to
  single-elim elimination rounds so Challonge's tied ranks pay their members
  equally. **Do not "simplify" this to a linear formula** — it opens holes at
  ranks 4 and 6–8. Verified against real data.
- **Event weight is a `tournament_tiers` lookup**, not a numeric column, and
  frozen results snapshot the *resolved multiplier* — so repricing a tier never
  restates history.
- **Season-points ties break on turnout first** (most events played), then best
  finish. An event winner can rank below someone who attended more and won
  nothing. Intentional.
- **The freeze lives in the Edge Function**, in TypeScript, because `bot.py` has
  no write path and giving it one is the bigger break.
- **Two new env vars** — `RANKING_CHANNEL_ID` (ranking commands are
  channel-restricted) and `ORGANIZER_DISCORD_ID` (authorizes
  `/link-organizer`). Both broke the PRD's own "zero new env vars" promise; it
  records the breaks rather than hiding them. Neither is a secret.
- **An unbound player cannot use `/ots` at all.** That is intended, but it moves
  the failure to round 1 of an event. Pre-flight must verify every roster row has
  a `profile_id`, and `/link-organizer` must be runnable from a phone in
  seconds — not a Studio procedure.

Two things to know before touching it:

- **This reopens cross-tournament player identities**, which both PRDs list as
  out of scope. That is intentional and is the core of the release — but it
  means those "out of scope" lists are no longer reliable on that one point.
- **Two traps that live data confirmed, before anyone writes freeze code:**
  `final_rank` has **ties and gaps** (`1,2,3,3,5,5,5,5,9…` — ranks 4, 6, 7, 8
  simply don't exist), and `participants[].active` is **false for every
  group-stage non-qualifier**, so filtering on it silently drops nearly half the
  field. Also: deriving "tournament complete" from "all cached matches complete"
  **fires at the group-stage boundary**, before the final bracket exists — F68
  adds a conditional third Challonge call instead, which amends this repo's
  "exactly 2 API calls" rule. See `PRD.v4.final.md` F54, F68, F74, and its §31.5
  freeze algorithm.

**Out of scope, and staying that way:** multiple simultaneously-active
tournaments, a custom backoffice web app / multi-organizer roles, player
self-submission of teams, hidden-until-reveal privacy, multi-guild support,
non-French localization, and content validation of `team_text`.

## Conventions

- Keep user-facing strings in **French**.
- Prefer keeping everything in `bot.py` unless a change clearly warrants
  splitting it out — this is deliberately a tiny single-file bot. The
  `challonge-sync` Edge Function is the one justified exception (it isolates a
  third-party API and a second language from the bot's runtime).
- Keep new logic **pure and unit-tested where possible**. `normalize_name`,
  `render_team_text`, `participant_candidate_ids`, `pick_opponent_id`,
  `is_cache_stale`, and `mapping.ts` all follow this: no I/O, tested directly,
  network paths kept thin around them.
- **Never let `/ots` raise.** Every failure mode collapses to a named status and
  a distinct French message. New failure modes get new statuses, not exceptions.
- Do not hardcode or echo the real token anywhere; use env vars only.
- Put notes/docs/planning files in **`knowledge/`** (see Docs & knowledge base).
- **Schema changes are migrations now.** Add a new file under
  `supabase/migrations/`; never edit an already-applied one, and never resurrect
  the root `schema.sql`. Apply with `supabase db reset` (local, rebuilds from
  zero and runs `seed.sql`) or `supabase db push` (production, migrations only).
- **Keep each migration individually idempotent** anyway — `if not exists` /
  `add column if not exists` / guarded inserts. The ledger already prevents
  re-runs; idempotency is what lets a migration be marked applied on an
  environment that already has its objects, which is how production was
  baselined.
- **Never put test fixtures in a migration.** Reference data (e.g.
  `tournament_tiers`) belongs in the migration that needs it; test data goes in
  `supabase/seed.sql` and never reaches production.
- **Grant explicitly.** The schema must not rely on Supabase's platform-default
  privileges — a current CLI grants no `SELECT` on `public`, so an implicitly-
  granted schema rebuilds into a database the bot cannot read (HTTP 403 with RLS
  and the service key both correct). `service_role` gets DML; `anon` and
  `authenticated` get nothing.
- When a release ships, update the status in **all four** places that track it:
  the RFC's own Completion record, `RFCS.md`, `PRD.md`, and this file.
