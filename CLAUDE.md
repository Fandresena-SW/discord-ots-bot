# CLAUDE.md

Guidance for working in this repository.

## What this is

A single-guild Discord bot that serves Pokémon **OTS** (Open Team Sheet) team
lists. A player runs `/ots <their own username>`; the bot works out **who their
current opponent is** from a Supabase-cached copy of the tournament's
**Challonge** bracket, then DMs back an embed of that opponent's stored
`team_text` (falling back to an ephemeral in-channel reply if the user's DMs are
closed). User-facing text is in **French**.

> This is the **v3.0** behavior, shipped 2026-07-31 (see
> [Release history](#release-history), `knowledge/PRD.md` §14–§26, and
> `knowledge/RFCs/RFCS.md`).
>
> **The argument's meaning changed in v3.0** and this is the single most
> common thing to get wrong when reading this repo: in v2.0 `/ots <name>`
> looked up *that named player's* OTS; in v3.0 it means *your own* name and
> returns *your opponent's* OTS. This was an intentional, confirmed one-time
> UX break (PRD §17/§24 item 4), not a regression to fix.
>
> The original v1 (hardcoded `USERNAME_URLS` map + pokepast.es scraper) was
> replaced by RFC-005 and lives only in git history (see the break-glass
> procedure in `knowledge/RUNBOOK.md` §6 if it's ever needed again).

## Docs & knowledge base

All notes, documentation, and planning artifacts for this project live in the
**`knowledge/`** folder at the repo root. Put any new design, planning, or
reference doc there (do not scatter them across the repo root).

- `knowledge/PRD.md` — the approved PRD. §1–§13 cover the v2.0 Supabase
  backoffice; §14–§26 are the v3.0 Challonge-integration addendum.
- `knowledge/PRD.v4.md` — **draft for discussion, nothing approved**: a
  ranking system (persistent identity, seasons, frozen results, ranking
  points). Numbering continues from `PRD.md` (§27+, F38+, G11+, Journey I+,
  RFC-011+). Its §33 lists ten still-open questions.
- `knowledge/FEATURES.md` — feature breakdown (MoSCoW) derived from the PRD,
  v2.0 (F1–F25) and v3.0 (F26–F37).
- `knowledge/RFCs/` — one file per RFC (001–010) plus `RFCS.md`, the master
  index with status, dependency graph, and tracked follow-ups. **`RFCS.md` is
  the fastest way to orient**; read it before the individual RFCs.
- `knowledge/RUNBOOK.md` — organizer runbook for Supabase Studio workflows
  (create/activate a tournament, player CRUD, fast bulk setup; §5–§7 add
  pre-flight, break-glass/contingency, and roster-backup procedures from
  RFC-006; **§8 adds the v3.0 Challonge workflow** — linking a tournament,
  name discipline across both systems, and the manual refresh trigger).
- `knowledge/E2E-CHECKLIST.md` — the RFC-006 v2.0 release gate (9 scenarios),
  closed and signed off.
- `knowledge/E2E-CHECKLIST-v3.md` — the RFC-010 v3.0 release gate (9
  scenarios), 9/9 `PASS`, signed off 2026-07-31. Written in French, unlike the
  v2.0 one. Does not supersede `E2E-CHECKLIST.md` — the two are separate
  records for separate releases.
- `knowledge/DEPLOYMENT.md` — how the bot is actually deployed and run in
  production (Oracle Cloud VM, systemd service, redeploy steps, troubleshooting
  log); **§12 covers deploying the `challonge-sync` Edge Function**, which is a
  completely separate deploy path from the bot.
- `.claude/RULES.md` — development guardrails / locked-decision rules
  (kept in `.claude/`, not `knowledge/`).

## Stack & layout

- **Python 3**, `discord.py>=2.3.0`, `python-dotenv` (`aiohttp` comes in
  transitively via discord.py).
- The bot is one file: **`bot.py`** (~510 lines, grown from the original ~117
  through the v2.0 and v3.0 RFCs). No packages/modules.
- **`supabase/functions/challonge-sync/`** — the one exception to the
  single-file rule: a TypeScript/Deno Supabase Edge Function holding *all*
  Challonge API I/O (RFC-008). `index.ts` (HTTP handler, fetch, upsert),
  `mapping.ts` (pure Challonge-JSON → cache-row mapping), `mapping_test.ts`.
  **`bot.py` never talks to Challonge** — it only ever reads Supabase. That
  boundary is a locked decision (PRD §11.5), not an accident.
- `schema.sql` (repo root) — the full Supabase DDL, idempotent and applied by
  hand in the Studio SQL editor: `tournaments`/`players` (RFC-001/003) plus
  `challonge_participants_cache`/`challonge_matches_cache` (RFC-007),
  constraints, indexes, triggers, RLS, seed fixtures, and a commented
  verification block.
- `test_bot.py` (repo root) — stdlib `unittest`, 30 tests covering the pure
  logic functions below. Run with `python -m unittest test_bot`.
- `deploy.sh` — pull + restart the systemd service; run **on the production
  VM over SSH**, not locally.
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
  `bot.py:85`) to match the DB's trimmed/lower-indexed `ingame_name`. The
  argument is **the caller's own name** (see the warning under "What this is").
- `fetch_current_opponent()` (`bot.py:353`) is the v3.0 read path and drives
  the whole command. Within one bounded (5s) session it: resolves the active
  tournament and its `challonge_tournament_id`; looks the caller up in
  `challonge_participants_cache`; finds their `open` match; picks the opponent;
  resolves that id back to a name; and finally calls `fetch_active_player()`
  for the opponent's `team_text`. It **never raises** — every
  network/timeout/non-200 error collapses to `"unavailable"` — and returns
  exactly one of: `"ok"`, `"no_active"`, `"no_challonge_link"`,
  `"requester_not_found"`, `"no_current_match"`, `"opponent_no_ots"`,
  `"unavailable"`.
- `fetch_active_player()` (`bot.py:140`) still exists and is still the
  `players`-table read, but it is **no longer called directly by `/ots`** — it
  is now the last step inside `fetch_current_opponent()`, called with the
  *opponent's* name.
- **The dual-id trap.** A Challonge participant can be referenced in the
  matches cache by *either* its top-level `challonge_participant_id` *or*, in
  group-stage tournaments, a separate `challonge_group_player_id` — both stay
  live simultaneously once a final bracket is generated (group matches use the
  group id, bracket matches use the top-level id). `participant_candidate_ids()`
  (`bot.py:243`) builds the candidate set and `pick_opponent_id()`
  (`bot.py:328`) matches against **the whole set**. Reducing either back to a
  single id silently breaks opponent resolution for one phase of the
  tournament. See the long comments in `schema.sql` and `mapping.ts`.
- `is_cache_stale()` / `_warn_if_stale()` (`bot.py:258`, `bot.py:266`) emit an
  **operator-only** `print()` when the cache row backing a request is >48h old.
  This never gates resolution, never changes the reply, and is never
  player-facing.
- The command branches on the status into **six** distinct French fail-soft
  `followup` replies, or on `"ok"` builds the embed: title
  `OTS de {opponent's stored ingame_name}` (note: the opponent's DB name, not
  the caller's raw input — that changed in v3.0), description via
  `render_team_text()` (fenced, hardened, size-capped, `bot.py:96`), color
  `0x3B4CCA`, and a clickable `url` set to `pokepaste_url` **only when
  present** (never `url=None`).
- Delivery DMs the embed to the user, falling back to an ephemeral in-channel
  reply with the same embed on `discord.Forbidden` (DMs closed) — unchanged
  from v1.

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
  its own organizer. Verified live; documented in `RUNBOOK.md` §8 and RFC-010.

## Release history

Full RFC-level status, dependency graph, and tracked follow-ups:
`knowledge/RFCs/RFCS.md`.

**v1** — hardcoded `USERNAME_URLS` dict + a pokepast.es scraper. Every roster
change meant a code edit and a redeploy. Git history only.

**v2.0 — Supabase backoffice. ✅ Shipped 2026-07-18** (RFC-001–006, PRD
§1–§13). Replaced the hardcoded map with live Supabase reads so organizers
manage rosters in Studio. Introduced `tournaments`/`players`, the DB-enforced
invariants (single active tournament via a partial unique index; per-tournament
case-insensitive unique `ingame_name`), the pure `normalize_name` /
`render_team_text` helpers, and the fail-soft French outcome set.
*Locked decisions (PRD §11):* single-active enforced in the DB, not the app;
service key worker-only; **`team_text` trusted as-is, never validated**.

**v3.0 — Challonge integration. ✅ Shipped 2026-07-31** (RFC-007–010, PRD
§14–§26). Players stopped needing to know their opponent's name: the organizer
runs the bracket in Challonge, an Edge Function caches it into Supabase, and
`/ots <your own name>` resolves your current opponent. The release gate
(`knowledge/E2E-CHECKLIST-v3.md`) passed 9/9 live during a real event.
*Locked decisions:* Edge Function over `pg_cron`/`pg_net`; organizer-triggered
refresh, never polled; `bot.py` never talks to Challonge; **no fallback to
v2.0's arbitrary-name lookup** when a tournament has no Challonge link — `/ots`
hard-fails distinctly instead.

## Planned direction (v4.0 — draft, nothing approved)

A **ranking system**: persistent player identity, seasons, frozen tournament
results, and ranking points. Drafted in `knowledge/PRD.v4.md` as a discussion
document — no RFC has been written and no decision is locked.

The shape currently proposed: identity keyed on **Discord account** (claimed by
the player via a `/link`-style command, not typed by an organizer); placement
pulled from Challonge's `final_rank` and **frozen** when a tournament closes;
points computed as `f(placement, weight)` at freeze time and **stored**, so
later rule changes never restate history; standings summed per season.

Two things to know before touching it:

- **This reopens `cross-tournament player identities`**, which is listed as
  out of scope in both PRD §3 and §16. That is intentional and is the core of
  the release — but it means the "out of scope" lists in the older PRDs are no
  longer a reliable guide on that one point.
- **`PRD.v4.md` §33 lists ten unresolved questions**, including the points
  curve itself. Do not start implementing from this document as if it were
  settled; several answers change the schema.

**Still out of scope, across all releases:** multiple simultaneously-active
tournaments, a custom backoffice web app / multi-organizer roles, player
self-submission of teams, hidden-until-reveal privacy, multi-guild support,
non-French localization, content validation of `team_text`, and pokepast.es
scraping.

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
- **Never let `/ots` raise.** Every failure mode collapses to a named status
  and a distinct French message. New failure modes get new statuses, not
  exceptions.
- Do not hardcode or echo the real token anywhere; use env vars only.
- Put notes/docs/planning files in **`knowledge/`** (see Docs & knowledge base).
- `schema.sql` must stay **idempotent** — it is re-run by hand against live
  environments, so use `if not exists` / `add column if not exists` / guarded
  inserts.
- When a release ships, update the status in **all four** places that track it:
  the RFC's own Completion record, `RFCS.md`, `PRD.md`, and this file. They
  drifted once already.
