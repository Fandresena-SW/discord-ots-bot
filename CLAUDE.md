# CLAUDE.md

Guidance for working in this repository.

## What this is

A single-guild Discord bot that serves Pokémon **OTS** (Open Team Sheet) team
lists. Users run `/ots <username>`; the bot live-reads that player's row from
the active tournament in **Supabase** and DMs back an embed of the stored
`team_text` (falling back to an ephemeral in-channel reply if the user's DMs
are closed). User-facing text is in **French**.

> This is the **v2.0** behavior, shipped 2026-07-18 (see
> [Planned direction](#planned-direction-v20), `knowledge/PRD.md`, and
> `knowledge/RFCs/RFCS.md`). The original v1 (hardcoded `USERNAME_URLS` map +
> pokepast.es scraper) was replaced by RFC-005 and lives only in git history
> (see the break-glass procedure in `knowledge/RUNBOOK.md` §6 if it's ever
> needed again).

## Docs & knowledge base

All notes, documentation, and planning artifacts for this project live in the
**`knowledge/`** folder at the repo root. Put any new design, planning, or
reference doc there (do not scatter them across the repo root).

- `knowledge/PRD.md` — the approved PRD for the v2.0 Supabase backoffice.
- `knowledge/FEATURES.md` — feature breakdown (MoSCoW) derived from the PRD.
- `knowledge/RUNBOOK.md` — organizer runbook for Supabase Studio workflows
  (create/activate a tournament, player CRUD, fast bulk setup; extended by
  RFC-006 with pre-flight, break-glass/contingency, and roster-backup
  procedures).
- `knowledge/E2E-CHECKLIST.md` — the RFC-006 release-gate artifact (9
  scenarios); rows are recorded pass/fail as the checklist is actually
  executed in the guild.
- `knowledge/DEPLOYMENT.md` — how the bot is actually deployed and run in
  production (Oracle Cloud VM, systemd service, redeploy steps,
  troubleshooting log).
- `.claude/RULES.md` — development guardrails / locked-decision rules for v2.0
  (kept in `.claude/`, not `knowledge/`).

## Stack & layout

- **Python 3**, `discord.py>=2.3.0`, `python-dotenv` (`aiohttp` comes in
  transitively via discord.py).
- The entire app is one file: **`bot.py`** (~280 lines, grown from the original
  ~117 as the v2.0 RFCs land). No packages/modules.
- `schema.sql` (repo root) — the Supabase DDL: `tournaments`/`players` tables,
  constraints, indexes, trigger, RLS (RFC-001/003).
- `test_bot.py` (repo root) — stdlib `unittest`, covers the pure logic functions
  below (RFC-004). Run with `python -m unittest test_bot`.
- Other files: `requirements.txt`, `Procfile`, `.env.example`, `.gitignore`.
- No CI (`.github/workflows/` is empty).

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env   # then fill in DISCORD_TOKEN and GUILD_ID
python bot.py
```

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
- `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` — added for the v2.0 backoffice
  (RFC-001/003) and **wired into `/ots` on every invocation** (RFC-005) via
  `fetch_active_player()` (`bot.py:133`), the live PostgREST read seam. Service
  key is worker-only, never committed.
- All four vars above are validated at boot by `validate_config()` (`bot.py`) —
  missing/invalid config fails fast before `client.run()`, not on first `/ots`.

## Key mechanics (`bot.py`)

- `/ots` (`bot.py:202`) **defers** the interaction immediately (ephemeral,
  before any I/O), then `normalize_name()`s the raw input (strip + lower,
  `bot.py:78`) to match the DB's trimmed/lower-indexed `ingame_name`.
- `fetch_active_player()` (`bot.py:133`) does a bounded (5s) live PostgREST
  read against Supabase: active tournament lookup, then a case-insensitive
  player lookup scoped to that tournament. It **never raises** — every
  network/timeout/non-200 error collapses to a single `"unavailable"`
  sentinel — and returns exactly one status: `"ok"`, `"not_found"`,
  `"no_active"`, or `"unavailable"`.
- The command branches on that status into three distinct French fail-soft
  `followup` replies (no active tournament / service unavailable / player not
  found in the current tournament) or, on `"ok"`, builds the embed: title
  `OTS de {username}` (raw input, not normalized), description via
  `render_team_text()` (fenced, hardened, size-capped, `bot.py:89`), color
  `0x3B4CCA`, and a clickable `url` set to `pokepaste_url` **only when
  present** (never `url=None`).
- Delivery (`bot.py:235`) DMs the embed to the user, falling back to an
  ephemeral in-channel reply with the same embed on `discord.Forbidden`
  (DMs closed) — unchanged from v1.

## Planned direction (v2.0)

Approved and targeted for release by **2026-07-25**. Full details in
`knowledge/PRD.md`; summary below.

**Goal:** replace the hardcoded `USERNAME_URLS` map (which forces a code edit +
redeploy per roster change) with a **Supabase-backed** data source. Organizers
manage teams in **Supabase Studio**; the bot reads live on every `/ots`. The
**player-facing `/ots` flow stays unchanged** (French UI, DM + ephemeral
fallback, embed format, fail-soft).

**Backlog (build order, per PRD §9 timeline).** Full RFC-level status and
dependency graph: `knowledge/RFCs/RFCS.md`.

1. ✅ **Supabase schema** — `tournaments` (`id`, `name`, `is_active`, `created_at`)
   and `players` (`id`, `tournament_id` FK, `ingame_name`, `team_text`,
   `pokepaste_url` nullable, `created_at`). Constraints: `ingame_name` unique
   **case-insensitive per tournament**; **partial unique index on
   `is_active = true`** to enforce exactly one active tournament. *(RFC-001)*
2. ✅ **Config** — add Supabase project URL + **service key** (worker-only, never
   committed) to env vars; update `.env.example`. *(RFC-003, plus the
   `fetch_active_player()` PostgREST read seam and RFC-004's pure
   `normalize_name`/`render_team_text` helpers — wired into `/ots` by item 3
   below.)*
3. ✅ **`bot.py` refactor** — removed `USERNAME_URLS` and the `fetch_pokepaste()`
   scraper; on each `/ots`, query the active tournament's player live from
   Supabase. Build embed from stored `team_text` (rendered verbatim,
   **trust-as-is** — no validation) with the clickable title URL set to
   `pokepaste_url` **only if present**. *(RFC-005)*
4. ✅ **Fail-soft + improved copy** — graceful French handling for
   not-found / no active tournament / Supabase unreachable; the "not found"
   message notes lookups are scoped to the current tournament. *(RFC-005)*
5. ✅ **Reliability, contingency & release** — pre-flight (F20), break-glass
   + graceful-degradation verification (F22), roster backup guidance (F24),
   and the E2E release-gate checklist are documented (`knowledge/RUNBOOK.md`
   §5–§7, `knowledge/E2E-CHECKLIST.md`) and **live-verified**: all 9 E2E
   scenarios pass, the 20-player dry-run ran under 1 minute (target < 5
   min), and the production deployment is confirmed healthy. Deploy target
   is the OCI systemd service, not the Procfile worker (see
   `knowledge/DEPLOYMENT.md`). *(RFC-006.)*

**v2.0 is now fully shipped** — all six RFCs (001–006) are complete.

**Decisions locked** (PRD §11): DB partial unique index for single-active;
service key held only by the worker; improved not-found copy approved;
team text trusted as-is.

**Out of scope for v2.0:** multiple active tournaments, cross-tournament player
identities, custom backoffice web app / multi-organizer roles, player
self-submission, real-time pairings and opponents-only / hidden-until-reveal
privacy, and pokepast.es scraping (superseded by stored `team_text`).

## Conventions

- Keep user-facing strings in **French**.
- Prefer keeping everything in `bot.py` unless a change clearly warrants
  splitting it out — this is deliberately a tiny single-file bot.
- Do not hardcode or echo the real token anywhere; use env vars only.
- Put notes/docs/planning files in **`knowledge/`** (see Docs & knowledge base).
