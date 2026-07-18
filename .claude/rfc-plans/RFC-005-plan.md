# RFC-005 Implementation Plan — `/ots` Command Refactor: Live Read, Deferral, Embed & Fail-Soft

> **Stack note.** This project is a **single-file Python Discord bot** (`bot.py`),
> not a Flutter/Dart app. The standard plan sections for DB migrations, Dart
> models, Riverpod providers, Flutter screens, routing, and edge functions are
> **Not Applicable** and are marked as such. The load-bearing sections here are
> **Scope**, **Command-Path Design** (the models/providers/screens analog),
> **Implementation Order**, and **Risk Areas**.

---

## 1. SCOPE SUMMARY

RFC-005 is the **atomic swap** that turns v2.0 on: it rewrites the `/ots` command
handler in `bot.py` to (1) defer the interaction immediately (ephemeral) before any
network I/O, (2) normalize the user input with `normalize_name`, (3) perform a
bounded live Supabase read via `fetch_active_player`, (4) branch on the returned
status into three distinct French fail-soft messages or the success path, (5) build
the embed with an optional clickable `pokepaste_url` and a render-safe body via
`render_team_text`, and (6) deliver by DM with an ephemeral fallback on
`discord.Forbidden`. It then **deletes** the v1 `USERNAME_URLS` dict and the
`fetch_pokepaste` scraper entirely (delete, not disable), removes the now-stale
setup comment, and keeps the `import re` (still used by `render_team_text`).

**Out of scope:** no database schema changes, no changes to `fetch_active_player`
/ `normalize_name` / `render_team_text` / `validate_config` / `on_ready` /
command registration — this RFC is wiring, branching, deletion, and French copy only.

---

## 2. DATABASE MIGRATIONS

**Not Applicable.** RFC-005 introduces no schema changes. It consumes RFC-001's
schema (`tournaments`, `players`, the partial unique index on `is_active`, the
`(tournament_id, lower(ingame_name))` unique index, the trim trigger, and RLS)
exactly as-is, through RFC-003's already-landed PostgREST read seam. No new
migration file, no next-number allocation. The seed data in `schema.sql`
(one active tournament + `giovlacouture`, `zou`, `koloina`, with `koloina` having
`pokepaste_url = NULL`) is sufficient to exercise every acceptance path.

---

## 3. DART MODELS

**Not Applicable** (Python bot). The equivalent data structure is the plain
`dict` returned by `fetch_active_player`:
`{"ingame_name": str, "team_text": str, "pokepaste_url": str | None}`. No new
type is introduced; the handler reads `player["team_text"]` and
`player["pokepaste_url"]` directly. No `build_runner` (not a Dart project).

---

## 4. PROVIDERS

**Not Applicable** (no Riverpod). The data-access seam is the existing async
helper `fetch_active_player(normalized_name: str) -> tuple[str, dict | None]`
(`bot.py:167`), which already:
- Queries `tournaments` with `select=id`, `is_active=eq.true`, `limit=1`.
- Queries `players` with `select=ingame_name,team_text,pokepaste_url`,
  `tournament_id=eq.<id>`, `ingame_name=ilike.<escaped>`, `limit=1`.
- Returns exactly one status: `"ok"` | `"not_found"` | `"no_active"` |
  `"unavailable"`, never raising.

**Do not modify this helper.** The handler consumes it as-is. No invalidation
concept applies (each `/ots` is a fresh live read; there is no cache — locked
"Won't build" item).

---

## 5. SCREENS & WIDGETS → COMMAND HANDLER DESIGN

**Not Applicable** as Flutter screens. The single UI surface is the `/ots`
command handler and its Discord embed. This is the core deliverable; the design
below is authoritative and the coder must implement it verbatim in spirit.

**File:** `/Volumes/Data/Perso/discord-ots-bot/bot.py`
**Target:** replace the body of the `ots` coroutine (currently `bot.py:236-269`).
Keep the decorator stack (`@tree.command(... guild=discord.Object(id=GUILD_ID))`
and `@app_commands.describe(...)`, `bot.py:230-235`) unchanged.

### Required linear order inside `ots(interaction, username)`

1. `await interaction.response.defer(ephemeral=True)` — **first line**, before any
   I/O (F18). Every subsequent reply uses `interaction.followup.send(...)`.
2. `normalized = normalize_name(username)` (F12). Title/echo still uses raw
   `username`, never `normalized`.
3. `status, player = await fetch_active_player(normalized)` (F11/F17; bounded 5s
   inside the helper).
4. Branch on `status`, responding **exactly once** per path via `followup`:
   - `"no_active"` → French message (b): no active tournament. (F15b)
   - `"unavailable"` → French message (c): service temporarily unavailable. (F15c)
     RFC-003's helper already emitted the operator log line; do **not** add a
     second broad log here.
   - `"not_found"` → French message (a): not found, **scoped to current
     tournament**. (F15a/F16)
   - `"ok"` → build embed + deliver (steps 5-6). `return` after each non-ok branch
     so control never falls through.
5. Build embed (F13):
   - `title = f"OTS de {username}"` (raw input).
   - `description = render_team_text(player["team_text"])` (F14).
   - `color = 0x3B4CCA`.
   - **Optional URL:** if `player["pokepaste_url"]` is truthy, pass `url=` to
     `discord.Embed(...)`; if `None`/empty, construct the embed **without** the
     `url` kwarg. Do not pass `url=None`. Prefer building the embed then setting
     `embed.url` only when present, or branch the constructor call — keep it boring
     and readable (RULES §10).
6. Deliver (preserve v1 verbatim):
   ```
   try:
       await interaction.user.send(embed=embed)
       await interaction.followup.send("✅ …DM confirmation…", ephemeral=True)
   except discord.Forbidden:
       await interaction.followup.send("⚠️ …voici votre OTS…", embed=embed,
                                       ephemeral=True)
   ```
   Catch **only** `discord.Forbidden` (RULES §7); no broad `except`.

### The four states (loading / error / empty / data)

- **Loading:** the ephemeral deferral (Discord shows "Bot is thinking…"); handled
  by step 1.
- **Error (backend outage):** `status == "unavailable"` → French message (c). No
  stack trace to user; operator log already emitted by the helper.
- **Empty (two distinct sub-states):**
  - `status == "no_active"` → French message (b).
  - `status == "not_found"` (active tournament exists, no matching player, incl.
    empty/whitespace input normalizing to `""`) → French message (a), mentioning
    scope.
- **Data:** `status == "ok"` → embed built + delivered (DM or ephemeral fallback).

### French copy (finalize wording during implementation, keep tone/emoji)

- (a) not-found: `❌ Aucun joueur nommé **{username}** dans le tournoi en cours.`
- (b) no-active: `⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.`
- (c) unavailable: `⚠️ Service momentanément indisponible. Réessayez dans un instant.`
- DM success: keep the existing `✅ Je vous ai envoyé …` tone (v1).
- DM-closed fallback: keep the existing `⚠️ Je n'ai pas pu vous envoyer un DM. Voici votre OTS :` (v1).

Strings may be inline or module-level constants, matching existing style
(v1 used inline; either is acceptable — prefer inline to match current density).

### Navigation

**Not Applicable.** The entry point is the Discord slash command `/ots`, registered
via `@tree.command` and synced to the single guild in `on_ready` (`bot.py:274`).
No web/route navigation.

---

## 6. ROUTING

**Not Applicable.** No `app_router.dart`. The only "route" is the slash-command
registration, which is **unchanged**: `@tree.command(name="ots", ...,
guild=discord.Object(id=GUILD_ID))` (`bot.py:230`) and the `on_ready` sync
(`bot.py:274`). Do not touch either.

---

## 7. EDGE FUNCTIONS

**Not Applicable.** No `supabase/functions/`. All backend interaction is
direct PostgREST HTTP over `aiohttp` from the worker, via `fetch_active_player`
(locked: no `supabase-py`, no edge functions — RULES §1).

---

## 8. IMPLEMENTATION ORDER

Migrations → models → providers → UI collapses (for this Python bot) to a single
ordered edit sequence in `bot.py`. The coder must follow this order:

1. **Rewrite the `ots` handler body** (`bot.py:236-269`) per Section 5: defer →
   normalize → fetch → branch (4 statuses) → build embed (optional URL) → deliver
   with `discord.Forbidden` fallback. Ensure each non-ok branch `return`s and each
   path responds exactly once via `followup`.
2. **Delete `USERNAME_URLS`** dict and its surrounding banner comments
   (`bot.py:71-83`, the `# --- Personnalisez ce dictionnaire ---` /
   `# -------------------------------------` lines included).
3. **Delete `fetch_pokepaste`** function entirely (`bot.py:129-148`).
4. **Update the setup docstring** (`bot.py:12`): remove/replace the
   `5. Modifier USERNAME_URLS ci-dessous …` step (roster is now managed in
   Supabase Studio per RFC-002 runbook; point there or drop the line).
5. **Audit `import re`** (`bot.py:17`): `render_team_text` still uses `re.sub`
   (`bot.py:111`), so `re` **remains used** — **keep the import**. (The RFC's
   "remove if unused" clause does not fire here; confirm and leave it.) Confirm
   `aiohttp` remains used by `fetch_active_player` — it does; keep it.
6. **Confirm** the entrypoint guard `if __name__ == "__main__": client.run(TOKEN)`
   (`bot.py:278-279`) and `on_ready` sync remain intact.
7. **Manual verification** against the RFC-006 E2E surface (happy path with/without
   URL, not-found, no-active, unavailable, DMs-closed, oversized/backtick
   `team_text`). No new unit tests are required by this RFC (no pure-logic changes;
   RFC-004 already covers `normalize_name`/`render_team_text` in `test_bot.py`).

---

## 9. RISK AREAS

The exploration report found **no structural conflicts** — predecessors are cleanly
isolated. The risks are behavioral, per RFC §8:

1. **Atomic single-path refactor (highest risk, F11).** `/ots` is the sole command
   path; any regression is player-facing at a live event. *Strategy:* the network
   seam (RFC-003) and pure logic (RFC-004) are already landed and tested — this
   change is wiring + branching + deletion only. Do not modify the helpers. Verify
   against seed data before considering done.

2. **Null `pokepaste_url`.** Passing `url=None` may render oddly. *Strategy:*
   construct the embed without the `url` kwarg when `pokepaste_url` is falsy (set
   `embed.url` conditionally after construction, or branch the constructor). Test
   with seeded `koloina` (null URL) and `zou`/`giovlacouture` (URL present).

3. **Deferred-then-respond ordering.** After `defer`, exactly one `followup.send`
   per invocation; no double-respond, no silent no-respond. *Strategy:* each
   non-ok branch ends in `return`; the ok path responds once in the try and once
   in the except (mutually exclusive). Review each branch for a terminal response.

4. **Exception narrowness (RULES §7).** *Strategy:* catch only `discord.Forbidden`
   around DM delivery. Do not add a broad `except Exception` in the handler —
   `fetch_active_player` already absorbs network errors into the `"unavailable"`
   sentinel.

5. **Empty / whitespace-only input.** `/ots "   "` → `normalize_name` → `""`.
   *Strategy:* this flows through `fetch_active_player` and returns `"not_found"`
   (no matching player); the not-found branch handles it — no special-casing, no
   crash. Verify.

6. **Title echo vs. normalized lookup.** *Strategy:* embed `title` uses raw
   `username`; lookup uses `normalized`. Keep them distinct exactly as specified.

7. **Delete-don't-disable (RULES §2 / F24).** *Strategy:* fully remove
   `USERNAME_URLS` and `fetch_pokepaste` — no commented code, no dormant fallback.
   The v1 break-glass path lives only in git history (RFC-006 documents recovery).
   Grep the final file to confirm neither identifier remains.

8. **Stale docstring / unused import drift.** *Strategy:* update the setup comment;
   explicitly verify `re` is still used (it is, in `render_team_text`) and keep it,
   rather than blindly deleting per the RFC's conditional clause.
