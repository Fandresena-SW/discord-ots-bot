# RFC-003 — Configuration & PostgREST Data-Access Seam

- **Status:** Ready for implementation
- **Implementation order:** 3 of 6
- **Complexity:** Medium
- **Features covered:** F19, F23, F17 (timeout *mechanism*; routing lands in RFC-005)
- **PRD refs:** §5.4, §5.3, §6, §11.5, §13, §9 (Day 2)
- **Builds upon:** RFC-001 (schema to read), RFC-002 (seeded data to test against)
- **Built upon by:** RFC-005 (command handler calls the read helper)

---

## 1. Summary

Add the **configuration** and the **single data-access seam** the bot uses to talk
to Supabase — without yet wiring it into the `/ots` command. Specifically: load the
Supabase project URL + **service key** from env vars alongside the existing
`DISCORD_TOKEN`/`GUILD_ID`, validate them at startup (fail fast at boot), update
`.env.example` with placeholders, and implement one thin async helper that reads the
active tournament's matching player via **raw PostgREST over the existing
`aiohttp`** (no `supabase-py` — locked §11.5), with a **bounded timeout** and a
sentinel-based error contract. This helper is the *only* structural concession
allowed (RULES §2) — analogous to v1's `fetch_pokepaste`.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F19** | Load Supabase URL + service key from env; validate required env vars at startup with a clear error; update `.env.example` (placeholders only); partial config fails startup. |
| **F23** | Data access via raw PostgREST HTTP over `aiohttp`; correct auth headers with the service key; no heavy client dependency. |
| **F17** (mech) | The read uses a bounded timeout (~5s, matching v1); a timeout resolves to the "unreachable" sentinel. (Fail-soft *routing* to the French message is RFC-005.) |

## 3. Technical approach

### 3.1 Configuration (F19)

- Read two new env vars at module load, next to `TOKEN`/`GUILD_ID`:
  - `SUPABASE_URL` — project base URL.
  - `SUPABASE_SERVICE_KEY` — service key, **worker-only**, bypasses RLS (RULES §6).
- **Startup validation:** after `load_dotenv()`, verify all required vars
  (`DISCORD_TOKEN`, `GUILD_ID`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`) are present
  and non-empty. If any is missing/partial, print a clear English operator error
  naming the missing var(s) and exit (non-zero) **before** `client.run()` — a fast,
  obvious boot failure, not a confusing first-`/ots` failure. Never echo secret
  values, only names.
- Update **`.env.example`** with `SUPABASE_URL=` and `SUPABASE_SERVICE_KEY=`
  placeholders (no real values). `.env` stays git-ignored.
- Keep `GUILD_ID` int-parse but guard it (a missing/empty `GUILD_ID` currently
  raises `TypeError` on `int(None)` — fold it into the same clear validation).

### 3.2 Data-access helper (F23 + F17 mechanism)

Implement one async helper in `bot.py`. Proposed contract:

```python
# Sentinels distinguish the three fail-soft branches RFC-005 must render.
class OtsLookup:
    """Result of an active-tournament player lookup."""
    # exactly one of these states:
    #   ("ok", player_dict)        -> match found
    #   ("not_found", None)        -> active tournament exists, no such player
    #   ("no_active", None)        -> zero active tournaments
    #   ("unavailable", None)      -> timeout / non-200 / network / parse error
```

Recommended: a small typed return — e.g. return a tuple `(status, player)` where
`status` ∈ {`"ok"`, `"not_found"`, `"no_active"`, `"unavailable"`} and `player` is a
dict (`ingame_name`, `team_text`, `pokepaste_url`) or `None`. Keep it boring and
readable (RULES §10); do **not** build a repository/service layer.

```python
async def fetch_active_player(normalized_name: str) -> tuple[str, dict | None]:
    """Look up `normalized_name` (already trim()+lower()'d) in the active
    tournament via PostgREST. Never raises: maps every failure to
    ("unavailable", None). Returns one of the four statuses above."""
```

- **Auth headers:** `apikey: <service_key>` and `Authorization: Bearer
  <service_key>` on every PostgREST request.
- **Query shape (two-step, explicit and index-served per RFC-001 F6):**
  1. `GET {SUPABASE_URL}/rest/v1/tournaments?is_active=eq.true&select=id&limit=1`
     - Empty array → `("no_active", None)`.
  2. `GET {SUPABASE_URL}/rest/v1/players?tournament_id=eq.{id}
     &ingame_name=ilike.{normalized_name}&select=ingame_name,team_text,pokepaste_url&limit=1`
     - **Match contract:** because stored names are trimmed (RFC-001 trigger) and
       the caller passes an already `trim()+lower()`'d value, use a
       case-insensitive equality. Prefer `ilike.` with the value escaped, **or** a
       `lower()`-based filter, whichever PostgREST expresses cleanly against the
       functional index — validate the planner still uses
       `players_tournament_name_idx` (RFC-001 F6). Escape `%`/`_`/`,` in the value so
       an `ilike` cannot be turned into a wildcard/multi-value match.
     - Empty array → `("not_found", None)`; one row → `("ok", row)`.
- **Timeout (F17 mechanism):** wrap requests in `aiohttp.ClientTimeout(total=5)`
  (reuse the v1 pattern). Any `asyncio.TimeoutError`/`aiohttp` error/non-200/JSON
  error → `("unavailable", None)`.
- **Error logging seam:** on the `unavailable` path, log server-side (console,
  alongside the heartbeat) with enough detail to diagnose (status code / exception
  repr) but **never** the service key and never a full `team_text` dump (RULES §6/§7).
  *(The user-facing French message is RFC-005; the operator log lives here so the
  seam that knows the failure detail is the one that logs it.)*
- **Session handling:** match v1's simple pattern (a short-lived
  `aiohttp.ClientSession` per call is acceptable given hobby-scale traffic); do not
  introduce a global session/pool unless clearly warranted.

### 3.3 What this RFC does NOT do

- Does **not** modify the `/ots` command handler yet (still calls the v1 path).
  The helper is added and independently exercised; the atomic swap is RFC-005.
- Does **not** delete `USERNAME_URLS`/`fetch_pokepaste` yet (RFC-005/F24) — but adds
  no new dead code either.

## 4. Data models / schema changes

None (consumes RFC-001). Adds runtime config + one helper function.

## 5. Interfaces / API contracts exposed

- **Env contract:** `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` required at boot.
- **`fetch_active_player(normalized_name) -> (status, player|None)`** — the seam
  RFC-005 consumes. Never raises. Four statuses map 1:1 to RFC-005's fail-soft
  branches (F15) + the happy path.
- **PostgREST endpoints used:** `/rest/v1/tournaments`, `/rest/v1/players`.

## 6. Acceptance criteria

- [ ] **F19:** With all env vars set, the bot boots; `.env.example` lists `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` as placeholders; **no secret committed**.
- [ ] **F19:** Missing or partial Supabase config (URL but no key, or vice versa; also missing `GUILD_ID`) fails fast at boot with a clear log naming the missing var — not on first `/ots`.
- [ ] **F23:** The helper reads a known seeded player through PostgREST using service-key headers; returns `("ok", {...})` with `ingame_name`/`team_text`/`pokepaste_url`. No `supabase-py` added; `requirements.txt` unchanged except as strictly needed (expected: unchanged — `aiohttp` is already transitive).
- [ ] **F23:** No active tournament → `("no_active", None)`; unknown name in active tournament → `("not_found", None)`.
- [ ] **F17:** A forced timeout / unreachable host / non-200 → `("unavailable", None)`, and a diagnostic (no secrets) is logged server-side.
- [ ] The helper **never raises** to its caller under any of the above.
- [ ] `EXPLAIN`/observed query confirms the name filter uses `players_tournament_name_idx` (F6 tie-in).

## 7. Implementation details

- **File:** `bot.py` only. Add config reads + `validate_config()` near the top; add
  `fetch_active_player()` as the single network seam.
- **Escaping:** implement a tiny helper to escape PostgREST filter special chars
  (`%`, `_`, `,`, and the `ilike` wildcards) in `normalized_name`.
- **Smoke test (manual):** a throwaway `asyncio.run(fetch_active_player("<seeded>"))`
  snippet (or a temporary `on_ready` log line) to confirm all four statuses against
  the RFC-002 seeded data. Remove any scaffolding before finishing (RULES §10: no
  stubs/dead code).
- **Requirements:** confirm `aiohttp` is available transitively; only add it
  explicitly to `requirements.txt` if a direct import warrants pinning — otherwise
  leave `requirements.txt` untouched (dependency policy, RULES §1).

## 8. Edge cases & risks

- **Partial config** must fail startup (not just missing-both).
- **`int(GUILD_ID)`** on empty/None currently throws at import — route through the
  new validation.
- **`ilike` wildcard injection** via unescaped `%`/`_` — escape the value.
- **Multiple rows returned** (should be impossible given RFC-001 uniqueness) — use
  `limit=1` defensively and treat >1 as the single first row.
- **Non-JSON / HTML error body** from a paused free-tier project → caught, mapped to
  `unavailable` (this is exactly the §12 pause scenario).
- **Risk:** query normalization drifting from RFC-001's index (F4). Mitigation: the
  caller passes `trim()+lower()` (RFC-004/005) and the filter matches `lower()`.

## 9. Applicable rules (RULES.md)

- §1 (no `supabase-py`; reuse `aiohttp`; minimal `requirements.txt`). §2 (single
  file; one thin data seam only). §6 (service key worker-only, never logged/committed;
  validate config at boot). §7 (fail-soft-to-user is RFC-005, but *loud-to-operator*
  logging starts here; catch broadly in the seam and return a sentinel). §3 (English
  identifiers/logs). §10 (no stubs left behind).

## 10. Testing strategy

- **Manual smoke** against RFC-002 seeded data covering all four statuses + a forced
  timeout (e.g. wrong URL / offline).
- **Startup validation** verified by unsetting each var and confirming the boot-time
  error.
- No unit tests here (network + config are integration concerns); the **pure** logic
  that *is* unit-tested lives in RFC-004.
