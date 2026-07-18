# CLAUDE.md

Guidance for working in this repository.

## What this is

A single-guild Discord bot that serves Pokémon **OTS** (Open Team Sheet) team
lists. Users run `/ots <username>`; the bot looks the username up in a hardcoded
map, fetches that player's team from a pokepast.es link, scrapes the six Pokémon
sets, and DMs them back as an embed (falling back to an ephemeral in-channel
reply if the user's DMs are closed). User-facing text is in **French**.

> The above describes the **current (v1)** behavior. An approved **v2.0**
> reworks the organizer side — see [Planned direction](#planned-direction-v20)
> and `knowledge/PRD.md`.

## Docs & knowledge base

All notes, documentation, and planning artifacts for this project live in the
**`knowledge/`** folder at the repo root. Put any new design, planning, or
reference doc there (do not scatter them across the repo root).

- `knowledge/PRD.md` — the approved PRD for the v2.0 Supabase backoffice.
- `knowledge/FEATURES.md` — feature breakdown (MoSCoW) derived from the PRD.
- `.claude/RULES.md` — development guardrails / locked-decision rules for v2.0
  (kept in `.claude/`, not `knowledge/`).

## Stack & layout

- **Python 3**, `discord.py>=2.3.0`, `python-dotenv` (`aiohttp` comes in
  transitively via discord.py).
- The entire app is one file: **`bot.py`** (~117 lines). No packages/modules.
- Other files: `requirements.txt`, `Procfile`, `.env.example`, `.gitignore`.
- No CI (`.github/workflows/` is empty) and no tests.

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env   # then fill in DISCORD_TOKEN and GUILD_ID
python bot.py
```

Deployment target is a Procfile worker: `worker: python3 bot.py`
(Heroku/Railway/Render-style background process).

## Config

Loaded from `.env` via `python-dotenv`:

- `DISCORD_TOKEN` — bot token (never commit this; `.env` is git-ignored).
- `GUILD_ID` — target server ID. The `/ots` command is synced only to this
  guild in `on_ready`, so slash-command changes appear immediately for that
  server (no global-sync propagation delay).

## Key mechanics (`bot.py`)

- `USERNAME_URLS` (`bot.py:28`) maps `username → pokepast.es URL`. **Add or
  change players by editing this dict.** Lookups are case-insensitive
  (`username.lower()`).
- `fetch_pokepaste()` (`bot.py:46`) GETs the paste (5s timeout) and
  **regex-scrapes** `<pre>...</pre>` blocks — it is not a real HTML parser, so
  it's sensitive to pokepast.es markup changes. Returns `[]` on any
  error/non-200 (fails soft; the embed just shows an empty description).
- Embed (`bot.py:90`): title `OTS de {username}`, clickable `url`, code-block
  description, color `0x3B4CCA`.

## Planned direction (v2.0)

Approved and targeted for release by **2026-07-25**. Full details in
`knowledge/PRD.md`; summary below.

**Goal:** replace the hardcoded `USERNAME_URLS` map (which forces a code edit +
redeploy per roster change) with a **Supabase-backed** data source. Organizers
manage teams in **Supabase Studio**; the bot reads live on every `/ots`. The
**player-facing `/ots` flow stays unchanged** (French UI, DM + ephemeral
fallback, embed format, fail-soft).

**Backlog (build order, per PRD §9 timeline):**

1. **Supabase schema** — `tournaments` (`id`, `name`, `is_active`, `created_at`)
   and `players` (`id`, `tournament_id` FK, `ingame_name`, `team_text`,
   `pokepaste_url` nullable, `created_at`). Constraints: `ingame_name` unique
   **case-insensitive per tournament**; **partial unique index on
   `is_active = true`** to enforce exactly one active tournament.
2. **Config** — add Supabase project URL + **service key** (worker-only, never
   committed) to env vars; update `.env.example`.
3. **`bot.py` refactor** — remove `USERNAME_URLS` and the `fetch_pokepaste()`
   scraper; on each `/ots`, query the active tournament's player live from
   Supabase. Build embed from stored `team_text` (rendered verbatim,
   **trust-as-is** — no validation) with the clickable title URL set to
   `pokepaste_url` **only if present**.
4. **Fail-soft + improved copy** — keep graceful French handling for
   not-found / no active tournament / Supabase unreachable; add an improved
   "not found" message noting lookups are scoped to the current tournament.
5. **Test & deploy** — E2E in-guild (happy path, not-found, no active
   tournament, Supabase down, DMs-closed, URL vs. no-URL embeds); organizer
   dry-run (20-player setup < 5 min); deploy to the Procfile worker.

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
