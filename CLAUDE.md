# CLAUDE.md

Guidance for working in this repository.

## What this is

A single-guild Discord bot that serves Pokémon **OTS** (Open Team Sheet) team
lists. Current version: **v3.0**, shipped 2026-07-31.

A player runs `/ots <their own username>`; the bot works out **who their current
opponent is** from a Supabase-cached copy of the tournament's **Challonge**
bracket, then DMs back an embed of that opponent's stored `team_text` (falling
back to an ephemeral in-channel reply if the user's DMs are closed). User-facing
text is in **French**.

> **The argument is the caller's OWN name, not the opponent's.** This is the
> single most common thing to get wrong when reading this repo — `/ots zou`
> means "I am zou, who am I playing?", and returns *someone else's* team.

## Docs & knowledge base

All notes, documentation, and planning artifacts for this project live in the
**`knowledge/`** folder at the repo root. Put any new design, planning, or
reference doc there (do not scatter them across the repo root).

- `knowledge/PRD.md` — the approved PRD. §14–§26 specify the current
  Challonge-backed behavior; §1–§13 specify the Supabase data layer it builds
  on.
- `knowledge/PRD.v4.final.md` — **the authoritative v4.0 spec.** Specified and
  decided 2026-07-31, not yet built: a ranking system plus a **breaking `/ots`
  change** that closes a v3.0 team-sheet scouting leak. §31.7 is the section to
  read first; §37 is the locked-decision table. Numbering continues from
  `PRD.md` (§27–§41, F38–F78, G11–G17, Journey I–Q, RFC-011–014).
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
  production (Oracle Cloud VM, systemd service, redeploy steps, troubleshooting
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
- `schema.sql` (repo root) — the full Supabase DDL, idempotent and applied by
  hand in the Studio SQL editor: `tournaments`, `players`,
  `challonge_participants_cache`, `challonge_matches_cache`, plus constraints,
  indexes, triggers, RLS, seed fixtures, and a commented verification block.
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
self-managed Oracle Cloud VM as a systemd service** — see
`knowledge/DEPLOYMENT.md` for the full setup, redeploy, and troubleshooting
steps.

## Config

Loaded from `.env` via `python-dotenv`:

- `DISCORD_TOKEN` — bot token (never commit this; `.env` is git-ignored).
- `GUILD_ID` — target server ID. The `/ots` command is synced only to this
  guild in `on_ready`, so slash-command changes appear immediately for that
  server (no global-sync propagation delay).
- `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` — the live PostgREST read seam. The
  service key bypasses RLS (every table is deny-by-default with no policies),
  so it is worker-only and never committed.
- All four vars above are validated at boot by `validate_config()`
  (`bot.py:37`) — missing/invalid config fails fast before `client.run()`, not
  on first `/ots`.

**The Edge Function has its own, separate secrets** (set via `supabase secrets
set`, *not* in `.env` — see `knowledge/DEPLOYMENT.md` §12):
`CHALLONGE_SYNC_SECRET` (shared secret gating the HTTP trigger),
`CHALLONGE_API_KEY`, `SUPABASE_URL`, and `SUPABASE_SERVICE_ROLE_KEY`. Note the
last one is spelled differently from the bot's `SUPABASE_SERVICE_KEY`.

## Key mechanics (`bot.py`)

- `/ots` (`bot.py:435`) **defers** the interaction immediately (ephemeral,
  before any I/O), then `normalize_name()`s the raw input (strip + lower,
  `bot.py:85`) to match the DB's trimmed/lower-indexed `ingame_name`.
- `fetch_current_opponent()` (`bot.py:353`) drives the whole command. Within one
  bounded (5s) session it: resolves the active tournament and its
  `challonge_tournament_id`; looks the caller up in
  `challonge_participants_cache`; finds their `open` match; picks the opponent;
  resolves that id back to a name; and finally calls `fetch_active_player()`
  (`bot.py:140`, the `players`-table read) for the **opponent's** `team_text`.
  It **never raises** — every network/timeout/non-200 error collapses to
  `"unavailable"` — and returns exactly one of: `"ok"`, `"no_active"`,
  `"no_challonge_link"`, `"requester_not_found"`, `"no_current_match"`,
  `"opponent_no_ots"`, `"unavailable"`.
- **The dual-id trap.** A Challonge participant can be referenced in the matches
  cache by *either* its top-level `challonge_participant_id` *or*, in
  group-stage tournaments, a separate `challonge_group_player_id` — both stay
  live simultaneously once a final bracket is generated (group matches use the
  group id, bracket matches use the top-level id). `participant_candidate_ids()`
  (`bot.py:243`) builds the candidate set and `pick_opponent_id()`
  (`bot.py:328`) matches against **the whole set**. Reducing either back to a
  single id silently breaks opponent resolution for one phase of the tournament.
  See the long comments in `schema.sql` and `mapping.ts`.
- `is_cache_stale()` / `_warn_if_stale()` (`bot.py:258`, `bot.py:266`) emit an
  **operator-only** `print()` when the cache row backing a request is >48h old.
  This never gates resolution, never changes the reply, and is never
  player-facing.
- The command branches on the status into **six** distinct French fail-soft
  `followup` replies, or on `"ok"` builds the embed: title
  `OTS de {opponent's stored ingame_name}`, description via `render_team_text()`
  (fenced, hardened, size-capped, `bot.py:96`), color `0x3B4CCA`, and a
  clickable `url` set to `pokepaste_url` **only when present** (never
  `url=None`).
- Delivery DMs the embed to the user, falling back to an ephemeral in-channel
  reply with the same embed on `discord.Forbidden` (DMs closed).

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

## Planned direction (v4.0 — specified and decided, not yet built)

A **ranking system** *and* a security fix to `/ots`, specified in
`knowledge/PRD.v4.final.md`. **Fully decided as of 2026-07-31** — no RFC has been
written and no code exists, but nothing is open for exploration. Read **§31.7**
(the `/ots` refactor) first, then **§37** (the locked-decision table). Reopening
a §37 decision is a scope change, not a judgement call.

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
- `schema.sql` must stay **idempotent** — it is re-run by hand against live
  environments, so use `if not exists` / `add column if not exists` / guarded
  inserts.
- When a release ships, update the status in **all four** places that track it:
  the RFC's own Completion record, `RFCS.md`, `PRD.md`, and this file.
