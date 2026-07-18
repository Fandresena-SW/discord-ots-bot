# RFC-003 Implementation Plan — Configuration & PostgREST Data-Access Seam

> **Stack note:** This project is a single-file **Python 3** Discord bot (`bot.py`),
> not a Flutter app. The standard plan skeleton (Migrations / Dart Models /
> Providers / Screens / Routing / Edge Functions) does **not** map to this RFC.
> Those sections are retained below and marked **N/A** with the reason, and the
> substantive work is captured in the Python-specific sections (Config, Data-Access
> Seam). The coder must not invent Flutter/Supabase-migration artifacts for this RFC.

---

## 1. SCOPE SUMMARY

RFC-003 adds the **configuration layer** and the **single async data-access seam**
that lets the bot talk to Supabase, **without wiring it into `/ots`**. Concretely, in
`bot.py`: (a) read `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` from env next to the
existing `DISCORD_TOKEN`/`GUILD_ID`; (b) add a `validate_config()` that fails fast at
boot (clear English operator error naming any missing var, non-zero exit) **before**
`client.run()`, folding the currently-unguarded `int(GUILD_ID)` into it; (c) implement
one never-raising async helper `fetch_active_player(normalized_name)` that reads the
active tournament's matching player via **raw PostgREST over the existing `aiohttp`**
(no `supabase-py`), with a 5s bounded timeout and a sentinel `(status, player)`
contract; (d) move `client.run()` under an `if __name__ == "__main__":` guard so
`bot.py` is import-safe for later RFCs. `.env.example` already contains the two
placeholders (added in RFC-001) and needs no change.

**Explicitly out of scope:** touching the `/ots` command handler or deleting
`USERNAME_URLS`/`fetch_pokepaste` — that atomic swap is RFC-005. No new migrations,
no new dependencies, no user-facing (French) copy.

---

## 2. DATABASE MIGRATIONS

**N/A.** RFC-003 creates no migrations, tables, columns, RLS policies, indexes,
triggers, or Postgres functions. It **consumes** the RFC-001 schema already present in
`/Volumes/Data/Perso/discord-ots-bot/schema.sql`:

- Tables read: `tournaments` (`id`, `is_active`), `players` (`tournament_id`,
  `ingame_name`, `team_text`, `pokepaste_url`).
- Index the read must remain compatible with: `players_tournament_name_idx`
  (`unique (tournament_id, lower(ingame_name))`) and `tournaments_one_active_idx`
  (partial unique on `is_active` where `is_active = true`).
- Trigger already in place: `players_trim_ingame_name` -> `trim_ingame_name()`
  (`btrim` + reject empty). This is why the caller normalizes with `trim()` before
  querying (see Risk Areas).

RLS note: the service key **bypasses RLS**; no policy work is in scope here.

---

## 3. DART MODELS

**N/A.** No Dart / no `@freezed` / no `build_runner`. The in-Python data shape returned
by the seam is a plain `dict` with keys `ingame_name`, `team_text`, `pokepaste_url`
(strings; `pokepaste_url` may be `None`). No money fields, no model classes — RULES §2
forbids introducing structural layers beyond the one thin seam.

---

## 4. PROVIDERS

**N/A (Riverpod).** The Python analogue is the **single data-access helper**, specified
here since it is the substantive deliverable.

### Helper: `fetch_active_player(normalized_name: str) -> tuple[str, dict | None]`

- **File:** `/Volumes/Data/Perso/discord-ots-bot/bot.py` (added below `fetch_pokepaste`,
  above the `@tree.command` block, mirroring v1's helper placement).
- **Contract:** never raises. Returns exactly one of:
  - `("ok", {"ingame_name": ..., "team_text": ..., "pokepaste_url": ...|None})`
  - `("not_found", None)` — active tournament exists, no matching player.
  - `("no_active", None)` — zero active tournaments.
  - `("unavailable", None)` — timeout / non-200 / network / JSON-parse error.
- **Input:** `normalized_name` is assumed already `trim()`+`lower()`'d by the caller
  (RFC-004/005 own `normalize_name`). This helper does **not** normalize; it only
  escapes filter special chars.
- **Auth headers on every request:** `apikey: <SUPABASE_SERVICE_KEY>` and
  `Authorization: Bearer <SUPABASE_SERVICE_KEY>`.
- **Two-step, index-served query (explicit columns — no `SELECT *`):**
  1. `GET {SUPABASE_URL}/rest/v1/tournaments?is_active=eq.true&select=id&limit=1`
     - HTTP != 200 / error -> `("unavailable", None)`.
     - Empty array -> `("no_active", None)`.
     - Take `rows[0]["id"]`.
  2. `GET {SUPABASE_URL}/rest/v1/players?tournament_id=eq.{id}&ingame_name=ilike.{escaped}&select=ingame_name,team_text,pokepaste_url&limit=1`
     - HTTP != 200 / error -> `("unavailable", None)`.
     - Empty array -> `("not_found", None)`.
     - One (or defensively, first) row -> `("ok", row)`.
- **Pagination:** `limit=1` on both queries (defensive; uniqueness makes >1
  impossible). No `.range()` — single-row reads.
- **Timeout (F17 mechanism):** wrap each request with
  `aiohttp.ClientTimeout(total=5)` (reuse the exact v1 pattern). A short-lived
  `aiohttp.ClientSession` per call is acceptable (RULES §2, v1 parity) — do **not**
  add a global session/pool.
- **Broad catch -> sentinel:** wrap the network/JSON work in `try/except Exception`;
  on any failure return `("unavailable", None)` (mirrors `fetch_pokepaste` returning
  `[]`).
- **Operator logging seam:** on the `unavailable` branch, `print(...)` a diagnostic to
  the console (alongside the existing heartbeat) with the failing status code and/or
  `repr(exc)` — but **never** the service key and **never** a full `team_text` dump
  (RULES §6/§7). English log text (RULES §3). (The French user message is RFC-005.)
- **Invalidation:** N/A (no cache; every `/ots` reads live — RULES §9 "Won't" forbids
  caching).

### Escaping helper (small, pure)

- Add a tiny helper (e.g. `_escape_ilike(value: str) -> str`) that neutralizes
  PostgREST/`LIKE` wildcards so a crafted `ingame_name` cannot become a wildcard or
  multi-value match:
  - Escape `LIKE` wildcards `%` and `_` with a leading backslash.
  - Neutralize PostgREST's `*` wildcard alias (PostgREST maps `*`->`%` in `like`/`ilike`).
  - Guard the PostgREST reserved separators `,` `(` `)` `\` defensively.
- Let `aiohttp` handle URL-encoding by passing filters via the `params=` argument
  (dict) rather than hand-building the query string — do not double-encode.
- Keep it boring and readable (RULES §10). This helper is a candidate for a lightweight
  unit test but RFC-003 does not mandate one (pure-logic tests land with RFC-004).

---

## 5. SCREENS & WIDGETS

**N/A.** No UI. Output surface is a Discord embed (RULES §8: no web UI, accessibility
N/A). The four UI states are irrelevant; the analogous four **statuses** of the seam
are specified in §4. This RFC intentionally does **not** touch the `/ots` handler that
renders anything.

---

## 6. ROUTING

**N/A.** No `app_router.dart`. Discord command registration is unchanged: `/ots`
stays registered to the single guild via `@tree.command(..., guild=discord.Object(id=GUILD_ID))`
(`bot.py:69`) and synced in `on_ready` (`bot.py:113`). RFC-003 adds no commands and
changes no routes.

---

## 7. EDGE FUNCTIONS

**N/A.** No `supabase/functions/`. Data access is raw PostgREST HTTP from the worker
(RULES §1). No DB triggers/pg_cron/edge functions are added.

---

## 8. IMPLEMENTATION ORDER

All work is in `/Volumes/Data/Perso/discord-ots-bot/bot.py`. Order:

1. **Config reads.** Keep `TOKEN = os.getenv("DISCORD_TOKEN")` (bot.py:24). Add
   `SUPABASE_URL = os.getenv("SUPABASE_URL")` and
   `SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")` next to it. **Stop**
   eagerly parsing `GUILD_ID` with a bare `int(os.getenv("GUILD_ID"))` at module scope
   (bot.py:25) — read it as a raw string first; parse to int inside/after
   `validate_config()` so a missing value produces the clear error, not a `TypeError`.
2. **`validate_config()`.** New function near the top. Checks all four vars are present
   and non-empty; validates `GUILD_ID` parses as int. On any failure: `print` a clear
   English message naming the missing/invalid var(s) (never echo values) and
   `sys.exit(1)` (add `import sys`). Assign the parsed int to the module-level
   `GUILD_ID` used by the command decorator.
   - **Ordering constraint:** the `@tree.command(..., guild=discord.Object(id=GUILD_ID))`
     decorator evaluates `GUILD_ID` at **import time**, so `GUILD_ID` must already be a
     valid int by that line. Resolve by running `validate_config()` (which parses
     `GUILD_ID`) at module load, right after `load_dotenv()` and the raw env reads,
     **before** the decorator. See Risk Areas for the exact sequencing decision.
3. **`_escape_ilike()` helper** (pure) — see §4.
4. **`fetch_active_player()`** — the async seam per §4. Place it below
   `fetch_pokepaste` (do not remove `fetch_pokepaste` — RFC-005 owns that).
5. **Entrypoint guard.** Move `client.run(TOKEN)` (bot.py:117) into
   `if __name__ == "__main__":`. This makes `bot.py` import-safe for RFC-004 tests.
6. **Manual smoke test** against RFC-002 seed data covering all four statuses + a forced
   timeout (wrong URL / offline). Remove any scaffolding before finishing (RULES §10 —
   no stubs/dead code left in the tree).
7. **Verify `requirements.txt` untouched** (`aiohttp` is transitive; do not add it).
   Verify `.env.example` already has both placeholders (it does) — no change.

---

## 9. RISK AREAS

1. **`GUILD_ID` eager-parse vs. fail-fast ordering (bot.py:25).**
   The `@tree.command` decorator (bot.py:69) reads `GUILD_ID` at import time, so
   `GUILD_ID` must be a valid int by then — this executes *before* any
   `if __name__ == "__main__":` block. **Strategy:** call `validate_config()` at
   **module load**, right after `load_dotenv()` and the raw env reads, so the clear boot
   error fires before the decorator runs and before `client.run()`. `validate_config()`
   both checks presence of all four vars and parses/assigns `GUILD_ID`. Do **not** rely
   solely on a `__main__`-guarded call for the `GUILD_ID` parse. This satisfies "fail
   fast at boot, not on first `/ots`" (F19) while keeping the decorator working.

2. **Import-safety for RFC-004 (`client.run` at module level, bot.py:117).**
   Importing `bot.py` today starts the bot. **Strategy:** move `client.run(TOKEN)` under
   `if __name__ == "__main__":`. Sanctioned by the exploration report as a small,
   necessary RFC-003 change. Note the trade-off: because `validate_config()` runs at
   module load (Risk 1), importing `bot.py` still requires the four env vars to be set
   or it will `sys.exit`. That is acceptable — RFC-004's pure-logic tests will either set
   the vars or import only the pure helpers; arranging that is RFC-004's concern, not a
   reason to weaken the boot-time validation here.

3. **PostgREST case-insensitive match vs. functional index `players_tournament_name_idx`
   (F6 tie-in).** The unique index is on `lower(ingame_name)`; stored names are
   **trimmed but not lowercased** (trigger only `btrim`s), so a case-insensitive match
   is required. PostgREST cannot cleanly express `lower(ingame_name) = value` without a
   computed column or an RPC — and RFC-003 adds **no** DB objects. **Strategy:** use
   escaped `ingame_name=ilike.{value}` (correct case-insensitive match; caller already
   lowercased). Satisfy the F6 check by running `EXPLAIN`/observed query against seeded
   data. **Expectation to record:** on the tiny seed table Postgres will legitimately
   choose a seq scan regardless of indexes, and `ILIKE` does not use a `lower()` btree
   index anyway. F6 is a **"Should"** (RULES §9), not a hard release gate — prioritize
   correct case-insensitive matching. If true index-served lookup is later required at
   scale, that needs a Postgres function/RPC, which is an RFC-001 schema change and thus
   **out of RFC-003 scope**: flag it, do not silently add it. If EXPLAIN shows a seq
   scan, record the decision in `knowledge/` per RULES §10.

4. **`ilike` wildcard / separator injection.** Unescaped `%`, `_`, `*`, `,` in the name
   could turn the match into a wildcard/multi-value query. **Strategy:** `_escape_ilike()`
   per §4, plus `limit=1` defensively so even a widened match returns a single row.

5. **Normalization drift (RFC-001 trigger `btrim` vs. bot filter).** The stored value is
   trimmed; the lookup must pass a `trim()`'d value or the index contract breaks.
   **Strategy:** document the contract in the helper's docstring — caller passes
   `trim()+lower()` (RFC-004/005), this seam does not re-normalize, only escapes. Do not
   change one side without the other (RULES §4).

6. **Paused free-tier project returns HTML/non-JSON body.** Parsing would raise.
   **Strategy:** the broad `try/except` around JSON decode maps it to
   `("unavailable", None)` — exactly the intended degradation path.

7. **Secret leakage in logs.** **Strategy:** the `unavailable` diagnostic logs status
   code / `repr(exc)` only; never the service key, never full `team_text` (RULES §6/§7).
   Auth headers are built from the module constant, never printed.

8. **Dependency creep.** **Strategy:** reuse `aiohttp` (already imported at bot.py:17);
   do not add `supabase-py` or a second HTTP client; leave `requirements.txt` untouched
   (RULES §1).
