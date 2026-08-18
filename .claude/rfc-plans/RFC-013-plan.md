# RFC-013 — Identity Binding, `/ots` Refactor & Organizer Debug Lookup — Implementation Plan

**Plan status:** ready for implementation
**Source of truth:** `knowledge/RFCs/RFC-013-Identity-Binding-And-OTS-Refactor.md`
(acceptance criteria §6), `knowledge/RFCs/implementation-prompt-RFC-013.md`
(scope limits), `knowledge/PRD.v4.final.md` §31.6/§31.7/§31.9/§37/§38/§41,
`knowledge/FEATURES.md` §Q/§R, `.claude/RULES.md` §1–§25.

The coder executes this plan. Every architectural choice below is made here.
Where this plan takes a decision the RFC left implicit, it is marked
**[PLAN DECISION]** with its rationale; those are the only places where
judgement was applied, and each one is repeated in §10.

---

## 1. SCOPE SUMMARY

RFC-013 removes `/ots`'s argument and infers the caller from a Discord account
the organizer bound once, so the command can only ever reveal *that caller's
own* opponent — closing the v3.0 roster-scouting leak (**F76**). Supporting it:
`/link-organizer <name> <user> [confirm_rebind]` binds an account to a roster
row, organizer-gated on both `default_permissions` and an explicit
`ORGANIZER_DISCORD_ID` check (**F58**, **F77**), with five distinct French
conflict outcomes (**F59**), an explicit rebind confirmation (**F61**), a search
that spans the active roster *then* the current season (**F71**), and a
current-season-bounded, fully-logged backfill of `players` +
`tournament_results` (**F60**, command half); `/unlink <confirm>` is the
player's own erasure path, which clears roster links, anonymizes frozen results
and deletes the profile (**F69**, command half); `/ots-organizer <name>` keeps
v3.0's typed-name resolution alive as an organizer-only, ephemeral debug lookup
(**F78**). `bot.py` gains its **first write path**, through exactly one seam.

**Explicitly out of scope** (implementation prompt §Scope Limitation):
`/standings`, `/profile`, `RANKING_CHANNEL_ID`, `RUNBOOK.md` §9,
`E2E-CHECKLIST-v4.md`, `DEPLOYMENT.md`'s env-var section (all RFC-014); any
migration/DDL (RFC-011 owns every v4.0 object, including the forward auto-link
trigger this RFC only *verifies*); anything under `supabase/functions/`; a
self-service claim command; and an optional name argument on `/ots` under any
justification.

---

## 2. LOCKED DECISIONS THIS RFC MUST HONOR

| Locked decision | Where | How this plan honors it |
|---|---|---|
| **Single file.** All logic stays in `bot.py`; no new folder/module/package. | RULES §2, prime directive | Everything lands in `bot.py`, `test_bot.py`, `.env.example`. New surface: 3 pure functions + 1 message table, 1 session factory, 1 write seam, a handful of narrow async helpers, 4 command handlers. No class, no registry, no config object. |
| **Zero new Python dependencies.** | RULES §1, RFC §9 | `discord.User`, `app_commands.default_permissions` and `aiohttp`'s verbs are already available. `requirements.txt` is not touched. |
| **Data access is a thin, single seam.** | RULES §2 | **Deliberate amendment (RFC §3.1):** the read seam gains **one write twin**, `_supabase_write(session, method, path, params, json_body, prefer)`. One function, not a layer, not a repository. Recorded in RULES §26 (new). |
| **The freeze stays in TypeScript** even though `bot.py` now writes. | PRD §31.4/§37, RFC §3.1 | No freeze/points/`tournament_results`-*computation* code enters `bot.py`. Its only writes: one `profiles` row, `players.profile_id`, and `tournament_results.profile_id` (attribution only — never `awarded_points`, `final_rank`, `multiplier`, `season_id`). |
| **`bot.py` never talks to Challonge.** | RULES §12, CLAUDE.md | No new HTTP host. Every request in this RFC is PostgREST on `SUPABASE_URL`. |
| **No-Challonge-link hard-fail comes first.** | RULES §15.1, RFC §3.3 step 1 | `fetch_opponent_for_profile` resolves the active tournament and its link **before** touching `profiles`. An unlinked tournament returns `no_challonge_link`, never a binding message. |
| **trim+lower normalization is reused, never reimplemented.** | RULES §4, §14 | `normalize_name` is the only normalizer, now on a third axis (binding). `_escape_ilike` is the only filter escaper — mandatory on every `ingame_name` filter, read or write. |
| **`/ots` steps 4–6 (embed, render-safety, DM + ephemeral fallback) preserved verbatim.** | RULES §5, §15.5 | Embed title `OTS de {opponent}`, `render_team_text` description, color `0x3B4CCA`, `url` only when `pokepaste_url` is truthy, DM then `discord.Forbidden` → ephemeral. Copied unchanged from today's handler. |
| **Never fail-silent to the operator; never raise to the player.** | RULES §7/§17 | Seven statuses → nine on `/ots`; all four commands are never-raise; every new failure path prints an English operator log. |
| **User-facing strings are French; identifiers/commands/params/logs are English.** | RULES §3/§13, PRD §31.9 | Commands `ots`, `ots-organizer`, `link-organizer`, `unlink`; params `name`, `user`, `confirm_rebind`, `confirm`. Every reply/description French with the existing ✅/⚠️/❌/ℹ️ tone. |
| **`ORGANIZER_DISCORD_ID` is a new env var and is *not* a secret.** | RULES §6 amended, PRD §31.9 | Validated at boot by `validate_config` (F19); may be logged; `.env.example` gets a placeholder **and a comment saying it is the first non-secret var in the file**. |
| **Discord snowflakes are text everywhere.** | RFC-011 (`profiles.discord_user_id text`), RFC §8 | `str(interaction.user.id)` / `str(user.id)` at every boundary; `is_organizer` compares strings; the only `int()` is the boot-time *validation* of `ORGANIZER_DISCORD_ID`. |
| **Erasure stays `delete from profiles where id = …`-simple and player-runnable.** | RULES §21, F69 | `/unlink` has **no organizer gate**; `confirm` is a required boolean (no UI components — this repo has none and this RFC adds none). Results are anonymized, never deleted (F48 forbids it anyway). |
| **Auto-link forward is the DB trigger's job, not the bot's.** | RULES §24, RFC §3.7 | Zero auto-link code in `bot.py`. `/link-organizer` always passes an explicit `profile_id`, which `autolink_player_profile()` deliberately never second-guesses. |
| **Backfill is bounded to the current season and can never steal an attributed row.** | PRD §37, RFC §3.7 | Both PATCHes carry `profile_id=is.null` **and** an `_escape_ilike`'d exact `ilike`; the `players` one is additionally bounded by `tournament_id=in.(<season's tournaments>)`. Do not widen either. |
| **`/ots-organizer` is a separate command, never an optional `/ots` argument; never opened to non-organizers.** | PRD §37, RFC §3.4, RULES §20 | Two registered commands, two signatures. `/ots` takes no parameter at all — that is the proof, not a runtime check. |
| **Two `open` matches → highest `round` wins.** | RULES §15.4 | `pick_opponent_id` reused verbatim; not revisited. |
| **A frozen tournament may still be active** → `/ots` answers `no_current_match`. | RULES §22 / F46 | No "tournament is over" status is added. |
| **F25(b) "cross-tournament identities" Won't-have is deliberately reopened.** | RULES §9, PRD §29 | Named as an amendment in RULES §26; no attempt to preserve the old constraint. |

**Deliberate amendments this RFC documents** (both must be written into RULES,
not left as drift): RULES §2's read-only seam gains a write twin; RULES §15.2's
"normalize the caller's own input" becomes "resolve the caller's bound profile"
for `/ots`, with the typed-name path surviving only under F78. Both go in the new
RULES §26 (see §8).

---

## 3. SCHEMA CHANGES (`schema.sql` / `supabase/migrations/`)

**N/A — zero DDL.** RFC-011 owns every object this RFC touches (`profiles`,
`players.profile_id`, `players_tournament_profile_idx`, `tournament_results`,
`current_season`, `players_autolink_profile`,
`resolve_profile_for_ingame_name`) and
`20260816000100_explicit_service_role_grants.sql` already grants `service_role`
**select, insert, update, delete** on `profiles`, `players`,
`tournament_results` and `select` on `current_season` — so this RFC's writes
need no new privilege. **Do not add a migration.** If the coder concludes a
column or index is missing, that is a signal RFC-011 was under-specified: stop
and raise it (RFC §4), do not append DDL here, and never edit an
already-applied migration.

Objects read/written, with the exact identifiers to use:

| Object | Used for | Columns touched |
|---|---|---|
| `profiles` | GET by `discord_user_id`; POST on bind; DELETE on unlink | `id`, `discord_user_id` (text), `display_name` |
| `players` | roster search (active + in-season), F40 slot check, bind PATCH, backfill PATCH, unlink PATCH | reads `id, tournament_id, ingame_name, profile_id`; writes `profile_id` only |
| `tournaments` | active tournament + Challonge link; the current season's tournament ids | reads `id, challonge_tournament_id, event_date, season_id` |
| `current_season` (view) | the season bound for backfill and the F71 search | reads `id` |
| `tournament_results` | backfill PATCH, unlink anonymize PATCH | reads `id, tournament_id`; writes `profile_id` only |
| `challonge_participants_cache`, `challonge_matches_cache` | the unchanged v3.0 chain | read-only, via the existing `_fetch_*` helpers |

---

## 4. `bot.py` CHANGES

The order below **is** the required file order; it matches RFC §7.2 and the
file's existing top-down flow (config → constants → pure → read helpers →
resolution → commands → `on_ready`).

### 4.1 Config block (replaces lines 31–68)

```python
TOKEN = os.getenv("DISCORD_TOKEN")
_GUILD_ID_RAW = os.getenv("GUILD_ID")
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")
_ORGANIZER_DISCORD_ID_RAW = os.getenv("ORGANIZER_DISCORD_ID")


def validate_config(discord_token: str | None, guild_id_raw: str | None,
                    supabase_url: str | None, supabase_service_key: str | None,
                    organizer_discord_id_raw: str | None) -> tuple[int, str]:
    """... Returns (GUILD_ID as int, ORGANIZER_DISCORD_ID as text)."""
```

- **Pure** (no I/O; `print` + `sys.exit` only) → **must be unit-tested**.
- `ORGANIZER_DISCORD_ID` joins the existing four in the `missing` list, so the
  boot error still names every missing var on one line.
- It must **parse as an integer** but is **returned and stored as text**:
  `return int(guild_id_raw), str(int(organizer_discord_id_raw))`, with the two
  parses in **separate `try` blocks** so each error names the right var; the new
  message is
  `"Config error: ORGANIZER_DISCORD_ID must be an integer (a Discord user id)"`.
  **[PLAN DECISION]** the `int()` round-trip is what normalizes a `.env` value
  carrying whitespace or a trailing newline into something that can compare
  equal to `str(interaction.user.id)`; a raw `os.getenv` string would fail the
  F77 gate silently and forever.
- Never print any other var's value. The organizer id *may* be logged
  (PRD §31.9) but do not add a success print — PRD §38's pre-flight probe is the
  real check.
- Module line becomes:
  `GUILD_ID, ORGANIZER_DISCORD_ID = validate_config(TOKEN, _GUILD_ID_RAW, SUPABASE_URL, SUPABASE_SERVICE_KEY, _ORGANIZER_DISCORD_ID_RAW)`
  keeping the existing comment about why it runs at module load.
- Update the module docstring's setup step 3 to name **five** vars.

### 4.2 New module constant (beside `DISCORD_DESC_LIMIT` / `STALENESS_THRESHOLD`)

```python
# F76: the eight fail-soft statuses of /ots -> their French copy. "ok" is not
# here: it is the embed path. A status absent from this table can never fall
# through to the embed (see the /ots handler's .get(...) fallback).
OTS_STATUS_MESSAGES: dict[str, str] = { ... }   # exact copy in §5.1
```

**[PLAN DECISION]** a dict rather than today's `if` chain. It is *smaller* than
the chain it replaces, and RFC §10.1 mandates a table test asserting all nine
statuses map to distinct messages with none falling through — only expressible
against a table.

### 4.3 Pure functions (append after `_escape_ilike`, before `fetch_active_player`)

```python
def is_organizer(interaction: discord.Interaction) -> bool:
    """F77's second gate. Compares as TEXT — snowflakes exceed 2^53, so an int
    round-trip anywhere in this comparison can silently authorize the wrong
    account."""
    return str(interaction.user.id) == ORGANIZER_DISCORD_ID
```
Pure (reads one module constant, no I/O) → **unit-tested**.

```python
def resolve_binding_conflict(roster_row: dict | None,
                             existing_profile_id: int | None,
                             target_profile_id: int | None,
                             account_slot_taken_by: str | None,
                             confirm_rebind: bool) -> str:
    """Pure: the F59 decision table. Returns exactly one of
    'not_found', 'account_slot_taken', 'already_bound_same', 'bind',
    'rebind_needs_confirm', 'rebind'. No I/O."""
```
Evaluation order is **load-bearing** and must be implemented exactly:

1. `roster_row is None` → `"not_found"` (F59a)
2. `account_slot_taken_by is not None` → `"account_slot_taken"` (F59d) —
   **before** the rebind branches, because `players_tournament_profile_idx`
   would reject the write anyway and F40 is the more specific complaint
3. `existing_profile_id is not None and existing_profile_id == target_profile_id`
   → `"already_bound_same"` (F59c — an idempotent **success**)
4. `existing_profile_id is None` → `"bind"`
5. `not confirm_rebind` → `"rebind_needs_confirm"` (F59b)
6. else → `"rebind"` (F59b′)

Step 3 implies `target_profile_id is not None`; when the mentioned account has
no profile yet, `target_profile_id is None` and a bound roster row therefore
falls to 5/6 — correct, that *is* a cross-account rebind.

```python
def pick_season_roster_row(rows: list[dict],
                           tournament_ids_by_recency: list[int]) -> dict | None:
    """Pure: F71 step 2's tie-break. Given candidate players rows from several
    tournaments in the current season, return the one from the most recent
    tournament (the caller supplies the id order). Rows from tournaments outside
    that list are ignored; empty input returns None."""
```
Pure → **unit-tested**. **[PLAN DECISION]** a 5-line pure function instead of an
inline sort or a PostgREST embedded `order=tournaments(event_date).desc`: "most
recent `event_date` first" is a real decision (including how a null `event_date`
orders), and the embedded-order syntax is a PostgREST-version dependency this
repo has never taken. Recency comes from the tournaments query's own
`order=event_date.desc.nullslast,id.desc`.

### 4.4 Network seam (append after the pure block, before `fetch_active_player`)

```python
def _service_session() -> aiohttp.ClientSession:
    """The one place the service-key headers and the 5s bound are stated for
    every helper added from RFC-013 onward (RULES §5 step 2, RFC-013 §7.4)."""
    return aiohttp.ClientSession(
        headers={"apikey": SUPABASE_SERVICE_KEY,
                 "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}"},
        timeout=aiohttp.ClientTimeout(total=5),
    )
```
**[PLAN DECISION]** RFC §5 promises RFC-014 "the existing `_headers()`/timeout
conventions" — no such helper exists today; the headers dict is duplicated
inline twice. One factory carrying **both** the headers and the mandatory 5s
bound is the smaller, safer reading of that promise than a bare `_headers()`
plus a repeated timeout literal. **`fetch_active_player`'s existing inline dict
is left exactly as it is** (RFC §5 lists that function as reused verbatim); only
new code and `fetch_current_opponent` — which this RFC restructures anyway
(§4.6) — use the factory.

```python
async def _supabase_write(session: aiohttp.ClientSession, method: str, path: str,
                          params: dict | None = None,
                          json_body: dict | None = None,
                          prefer: str = "return=representation") -> tuple[str, list[dict] | None]:
    """The single write seam — the write-side twin of the _fetch_* read helpers
    (RFC-013 §3.1, RULES §26). EVERY POST/PATCH/DELETE bot.py makes goes through
    here; never call session.post/patch/delete directly.

    Non-2xx or an unparseable body -> ("unavailable", None) after logging
    method, path and status (never the request body — it can carry a display
    name). ("ok", rows) otherwise, rows being the PostgREST representation
    (possibly []), so callers can count what they changed for F60's mandatory
    propagation log.
    """
```
- Implementation: `url = f"{SUPABASE_URL}/rest/v1/{path}"`;
  `async with session.request(method, url, params=params, json=json_body, headers={"Prefer": prefer})`;
  accept `200/201/204`; parse JSON only when a body is present (`204` /
  `return=minimal` → `("ok", [])`).
- **Network helper — never raises a status, returns a named one.** It does *not*
  own a `try/except`: each command-level helper wraps its whole session in one,
  exactly as `fetch_current_opponent` does today. **[PLAN DECISION]** one
  `except Exception` per command-level helper matches the existing file and
  avoids two swallowing layers that would hide which step failed.
- **[PLAN DECISION]** the parameter is named `json_body`, not RFC §3.1's sketch
  `json`, to avoid shadowing; positional order is otherwise identical.

```python
async def fetch_profile_id(session: aiohttp.ClientSession,
                           discord_user_id: str) -> tuple[str, int | None]:
    """GET profiles?discord_user_id=eq.<id>&select=id&limit=1.
    ("ok", id) | ("not_linked", None) | ("unavailable", None).
    Exposed for RFC-014's /profile (RFC-013 §5). discord_user_id is TEXT."""
```
No `_escape_ilike`: this is an `eq.` filter on a digits-only string produced by
`str(...id)`, never by free text.

### 4.5 Roster/profile read helpers (append after `fetch_profile_id`)

All are **network helpers**: they take a session, never raise on their own
(failures surface as `("unavailable", …)`), and return a named status.

| Helper | Request | Returns |
|---|---|---|
| `_fetch_roster_row_for_profile(session, tournament_id, profile_id)` | `GET players?tournament_id=eq.<t>&profile_id=eq.<p>&select=ingame_name&limit=1` | `("ok", row)` / `("not_in_tournament", None)` / `("unavailable", None)` |
| `_fetch_roster_row_by_name(session, tournament_id, normalized_name)` | `GET players?tournament_id=eq.<t>&ingame_name=ilike.<_escape_ilike(name)>&select=id,tournament_id,ingame_name,profile_id&limit=1` | `("ok", row)` / `("not_found", None)` / `("unavailable", None)` |
| `_fetch_current_season_id(session)` | `GET current_season?select=id&limit=1` | `("ok", id)` / `("no_season", None)` / `("unavailable", None)` |
| `_fetch_season_tournament_ids(session, season_id)` | `GET tournaments?season_id=eq.<s>&select=id&order=event_date.desc.nullslast,id.desc` | `("ok", [ids…])` / `("unavailable", None)` |
| `_fetch_roster_rows_in_tournaments(session, tournament_ids, normalized_name)` | `GET players?tournament_id=in.(<ids>)&ingame_name=ilike.<esc>&select=id,tournament_id,ingame_name,profile_id` (no `limit`; a season's rosters are tens of rows) | `("ok", rows)` / `("unavailable", None)` |
| `_fetch_profile_slot_in_tournament(session, tournament_id, profile_id)` | `GET players?tournament_id=eq.<t>&profile_id=eq.<p>&select=id,ingame_name&limit=1` | `("ok", row)` / `("not_found", None)` / `("unavailable", None)` — F59d's input |
| `_fetch_profile_discord_id(session, profile_id)` | `GET profiles?id=eq.<p>&select=discord_user_id&limit=1` | `("ok", did)` / `("not_found", None)` / `("unavailable", None)` — only to render the *previous* account's mention in F59b |

`_fetch_roster_row_for_profile` and `_fetch_profile_slot_in_tournament` differ
only in `select` and status vocabulary; keep both, named for their callers'
intent, rather than one helper with a mode flag.

### 4.6 The resolution core: extract, do not rewrite (RFC §3.2)

Insert `_resolve_opponent` **immediately before** `fetch_current_opponent`, then
rewrite `fetch_current_opponent`'s body as a thin wrapper.
`participant_candidate_ids`, `is_cache_stale`, `_warn_if_stale`,
`_fetch_participant_id`, `_fetch_open_matches`, `_fetch_participant_name`,
`pick_opponent_id`, `fetch_active_player`, `_fetch_active_tournament_id`,
`_fetch_player_in_tournament` and `_fetch_active_tournament_with_link` are **not
edited at all** — the extraction is a **pure code move** of today's lines
383–426.

```python
async def _resolve_opponent(session: aiohttp.ClientSession, tournament: dict,
                            normalized_own_name: str) -> tuple[str, dict | None]:
    """v3.0's opponent-resolution chain, verbatim, shared by both entry points
    (RFC-013 §3.2): cached participant -> candidate id set (dual-id space) ->
    the open match -> the other side's name -> that player's team_text row.

    ("ok", player) | ("requester_not_found" | "no_current_match" |
    "opponent_no_ots" | "unavailable", None). Resolving the active tournament
    and its Challonge link is the CALLER's job (RULES §15.1 keeps it first).
    """
```
- Body = today's lines 383–426 unchanged: the `_fetch_participant_id` call,
  `participant_candidate_ids`, `_warn_if_stale`, `_fetch_open_matches`,
  `pick_opponent_id`, `_fetch_participant_name` with its cache-inconsistency
  log, and the `fetch_active_player(normalize_name(opponent_name))` tail with
  its three status mappings and logs.
- **Keep the existing log prefixes literally (`fetch_current_opponent: …`)**
  even though the code now also serves `/ots`. **[PLAN DECISION]**: E2E-v3
  scenario 8 asserts the exact string `fetch_current_opponent: Challonge cache
  stale for tournament <id>: …`, and `DEPLOYMENT.md`'s troubleshooting log greps
  these prefixes. Renaming buys nothing and invalidates a signed-off gate row.
- The `fetch_active_player` tail now runs **inside** the caller's still-open
  session (today the outer session closes first). Functionally identical —
  `fetch_active_player` opens its own session and `ClientTimeout(total=5)` is
  per-request — and it is what lets one shared core serve both entry points
  without duplicating the tail's status mapping. **[PLAN DECISION]**, listed in
  §10 so a reviewer does not read it as an accident.

```python
async def fetch_current_opponent(normalized_own_name: str) -> tuple[str, dict | None]:
    """UNCHANGED public contract (signature + the same seven statuses). Now
    F78's entry point: /ots-organizer's typed-name lookup. RFC-013 §3.2."""
    try:
        async with _service_session() as session:
            status, tournament = await _fetch_active_tournament_with_link(session)
            if status != "ok":
                return (status, None)
            if tournament["challonge_tournament_id"] is None:
                return ("no_challonge_link", None)
            return await _resolve_opponent(session, tournament, normalized_own_name)
    except Exception as exc:
        print(f"fetch_current_opponent: request error: {exc!r}")
        return ("unavailable", None)
```
Keep its docstring's seven-status list verbatim.

```python
async def fetch_opponent_for_profile(discord_user_id: str) -> tuple[str, dict | None]:
    """F76's entry point. Nine statuses: fetch_current_opponent's seven plus
    'not_linked' and 'not_in_tournament'. Never raises. RFC-013 §3.3."""
```
Order, in one bounded session, exactly as RFC §3.3:

1. `_fetch_active_tournament_with_link` → `no_active` / `unavailable`;
   `challonge_tournament_id is None` → `no_challonge_link`. **Stays first**
   (RULES §15.1) — before any `profiles` read.
2. `fetch_profile_id(session, discord_user_id)` → `not_linked` (log:
   `fetch_opponent_for_profile: no profile bound to discord_user_id {id} — /ots refused`)
   / `unavailable`.
3. `_fetch_roster_row_for_profile(session, tournament_id, profile_id)` →
   `not_in_tournament` / `unavailable`.
4. `_resolve_opponent(session, tournament, normalize_name(row["ingame_name"]))`.
   On `requester_not_found`, log before returning:
   `fetch_opponent_for_profile: roster name '{name}' (profile {pid}) absent from challonge_participants_cache for tournament {tid} — organizer name-discipline gap`.
   (RFC §3.3: `not_linked` and `requester_not_found` are precisely the two
   statuses that point at an organizer action and must therefore log.)
5. One `except Exception` wrapper → log + `("unavailable", None)`.

`normalize_name` is applied to the **stored** roster name, not to user input —
the row is already trimmed by the DB trigger, but normalizing keeps the `ilike`
contract identical across both entry points.

### 4.7 Binding helper (append after `fetch_opponent_for_profile`)

```python
async def run_binding(target_discord_user_id: str, display_name: str,
                      raw_name: str, confirm_rebind: bool) -> tuple[str, dict]:
    """F58/F59/F60/F61/F71 — the whole /link-organizer network flow. Never
    raises. Returns (status, details) where status is one of 'bind', 'rebind',
    'already_bound_same', 'rebind_needs_confirm', 'account_slot_taken',
    'not_found', 'no_active', 'unavailable', and details carries what the French
    reply and the propagation log need."""
```
`details` keys (each optional, defaulting to `None`/`0`/`False`): `name` (the
resolved row's **stored** `ingame_name`), `previous_mention`, `other_name`,
`profile_id`, `previous_profile_id`, `season_id`, `players_backfilled`,
`results_backfilled`, `tournament_ids`, `backfill_failed`.

Steps, in one `_service_session()` inside one `try/except`:

1. `_fetch_active_tournament_id(session)` — the v2.0 helper, **reused verbatim**
   → `no_active` (F59e, its own copy) / `unavailable`.
2. `_fetch_current_season_id(session)` → `season_id`, or `None` on `no_season`
   (**not fatal**: RFC §3.7 "zero rows: skip backfill, still bind");
   `unavailable` → return.
3. If `season_id` is not None: `_fetch_season_tournament_ids(session, season_id)`
   **once** — the same list serves both the F71 search and the backfill.
   `unavailable` → return.
4. `normalized = normalize_name(raw_name)`; if it is `""` →
   `("not_found", …)` with no query at all (mirrors the DB's "empty after trim
   is rejected" contract, RULES §4).
5. F71 search: `_fetch_roster_row_by_name(session, active_id, normalized)`; if
   `not_found` **and** `season_id` is not None,
   `_fetch_roster_rows_in_tournaments(...)` then
   `pick_season_roster_row(rows, tournament_ids)`. The result may be `None`.
6. `fetch_profile_id(session, target_discord_user_id)` → `target_profile_id`
   (`None` on `not_linked`); `unavailable` → return.
7. F59d input: only when the roster row **and** `target_profile_id` both exist,
   `_fetch_profile_slot_in_tournament(session, row["tournament_id"], target_profile_id)`;
   `account_slot_taken_by = slot["ingame_name"] if slot and slot["id"] != row["id"] else None`.
8. `decision = resolve_binding_conflict(row, row and row["profile_id"], target_profile_id, account_slot_taken_by, confirm_rebind)`.
9. Non-write decisions (`not_found`, `account_slot_taken`,
   `already_bound_same`, `rebind_needs_confirm`) return immediately. For
   `rebind_needs_confirm`, first call `_fetch_profile_discord_id(session, row["profile_id"])`
   and set `details["previous_mention"] = f"<@{did}>"`, falling back to
   `f"le profil #{row['profile_id']}"` when that lookup misses.
   **`already_bound_same` performs zero writes** — **[PLAN DECISION]**: F59c's
   copy is literally "rien à changer", and PRD §38 makes this path the
   idempotent pre-flight probe of `ORGANIZER_DISCORD_ID`; a probe must not
   rewrite rows. Nothing is lost by it: RFC-012's freeze already resolves
   `profile_id` from the roster row, so a bound player's later results are
   attributed at freeze time.
10. Writes, in RFC §3.6's order, **all** through `_supabase_write`:
    a. `target_profile_id is None` →
       `POST profiles?on_conflict=discord_user_id&select=id` with
       `json_body={"discord_user_id": target_discord_user_id, "display_name": display_name}`
       and `prefer="resolution=merge-duplicates,return=representation"` →
       `target_profile_id = rows[0]["id"]`. **[PLAN DECISION]** the upsert form
       rather than a bare POST: `profiles_discord_user_id_idx` turns a
       double-invocation race into a 409 that would otherwise surface to the
       organizer as `unavailable` mid-event; merge-duplicates makes it idempotent
       and refreshes the (deliberately drifting) `display_name` snapshot.
       `display_name` is **never** an identity key.
    b. `PATCH players?id=eq.<row id>&select=id` with `{"profile_id": pid}` —
       zero rows or non-2xx → `("unavailable", …)` + log; the binding did not
       happen, so do not report success.
    c. Backfill, only when `season_id` is not None (RFC §3.7):
       - `PATCH players?tournament_id=in.(<season ids>)&ingame_name=ilike.<_escape_ilike(normalized)>&profile_id=is.null&select=id,tournament_id`
       - `PATCH tournament_results?season_id=eq.<sid>&ingame_name=ilike.<esc>&profile_id=is.null&select=id,tournament_id`
       both with `{"profile_id": pid}` and `prefer="return=representation"` so
       the row counts and tournament ids are known. A backfill failure is
       **logged and non-fatal**: the binding itself succeeded, so keep the
       success status, set `details["backfill_failed"] = True`, and still attempt
       the second PATCH. (The realistic cause is
       `players_tournament_profile_idx`: the profile already holds a slot under a
       different name in one of the season's tournaments.)
11. Propagation log — **mandatory**, one line, exactly RFC §3.7's shape:
    ```
    link-organizer: profile 12 <- 'sen' (season 2): players +3 [t7,t8,t9], tournament_results +2 [t7,t8], rebind_from=profile 9
    ```
    Omit the `rebind_from=` clause when the decision was `bind`; print
    `season=none, backfill skipped` in place of the counts when there is no
    current season. Never log a `team_text`, a token or the service key; Discord
    ids and profile ids **are** logged (PRD §31.9) and F60 requires them.

### 4.8 Unlink helper (append after `run_binding`)

```python
async def run_unlink(discord_user_id: str) -> tuple[str, dict]:
    """F69's command half. Never raises. ("ok", {"players": n, "results": m,
    "profile_id": p}) | ("not_linked", {}) | ("unavailable", {})."""
```
One session, one `try/except`, RFC §3.8's order:

1. `fetch_profile_id(session, discord_user_id)` → `not_linked` (a normal
   outcome, not an error) / `unavailable`.
2. `PATCH players?profile_id=eq.<pid>&select=id` with `{"profile_id": None}` —
   **all** tournaments, unbounded by season (erasure is unbounded; backfill is
   bounded — two different operations with different reasons, RFC §3.8).
3. `PATCH tournament_results?profile_id=eq.<pid>&select=id` with
   `{"profile_id": None}` — anonymize, **never delete**; the `ingame_name`
   snapshot keeps the row counting on the leaderboard (E2E 33).
4. `DELETE profiles?id=eq.<pid>` with `prefer="return=representation"`.
5. Any non-2xx → `("unavailable", …)` + log. A partial run is safe and
   self-healing: `on delete set null` on both FKs means re-running `/unlink`
   completes it, and nothing else reads a dangling profile.
6. Log: `unlink: profile {pid} (discord {id}) — players -{n}, tournament_results anonymized {m}, profile deleted`.

### 4.9 Command handlers (replace lines 429–497, in this order)

`/ots` (rewritten) → `/ots-organizer` → `/link-organizer` → `/unlink`, then the
unchanged `on_ready` / `client.run`. Exact signatures, gating and copy in §5.

---

## 5. COMMANDS

### 5.1 `/ots` (F76) — rewritten

```python
@tree.command(name="ots",
              description="Découvrez l'OTS de votre adversaire actuel",
              guild=discord.Object(id=GUILD_ID))
async def ots(interaction: discord.Interaction):
```
- **No parameter, and no `@app_commands.describe`.** Discord itself must reject
  `/ots zou`; the signature is the proof (E2E 25). Deleting the `username`
  parameter and its `describe` line **is** the security fix.
- Defer **ephemeral**, first statement, before any I/O.
- **No authorization gating** — every guild member may run it; the binding *is*
  the authorization.
- Body: `status, player = await fetch_opponent_for_profile(str(interaction.user.id))`,
  then
  ```python
  if status != "ok":
      await interaction.followup.send(
          OTS_STATUS_MESSAGES.get(status, OTS_STATUS_MESSAGES["unavailable"]),
          ephemeral=True)
      return
  ```
  The `.get(...)` fallback is the "no tenth status ever reaches the embed path"
  guard RFC §10.1 asks to be tested.
- Then the **verbatim** v3.0 embed + DM/`discord.Forbidden` block (today's lines
  478–497).

| Status | New? | French message (exact) |
|---|---|---|
| `no_active` | — | `⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.` |
| `no_challonge_link` | — | `❌ Ce tournoi n'est pas relié à Challonge. Impossible de déterminer votre adversaire actuel.` |
| `not_linked` | **new** | `❌ Votre compte Discord n'est pas encore relié à un joueur. Contactez l'organisateur pour être enregistré.` |
| `not_in_tournament` | **new** | `ℹ️ Vous n'êtes pas inscrit au tournoi en cours.` |
| `requester_not_found` | **reworded** | `⚠️ Votre nom de joueur est introuvable dans le bracket Challonge de ce tournoi. Contactez l'organisateur.` |
| `no_current_match` | — | `ℹ️ Vous n'avez pas de match en cours pour le moment.` |
| `opponent_no_ots` | — | `⚠️ Votre adversaire a été trouvé, mais son OTS n'est pas encore enregistré. Contactez l'organisateur.` |
| `unavailable` | — | `⚠️ Service momentanément indisponible. Réessayez dans un instant.` |
| `ok` | — | DM the embed, then `✅ Je vous ai envoyé le lien en message privé !`; on `discord.Forbidden` → `⚠️ Je n'ai pas pu vous envoyer un DM. Voici votre OTS :` + embed, ephemeral (both unchanged from v3.0) |

The `requester_not_found` copy **must not echo a name** — the player typed none.

### 5.2 `/ots-organizer` (F78)

```python
@tree.command(name="ots-organizer",
              description="[Organisateur] Voir l'adversaire actuel d'un joueur",
              guild=discord.Object(id=GUILD_ID))
@app_commands.default_permissions(manage_guild=True)
@app_commands.describe(name="Nom du joueur dans le tournoi")
async def ots_organizer(interaction: discord.Interaction, name: str):
```
- **Gate 1** `default_permissions(manage_guild=True)` — Discord hides it from
  ordinary members (E2E 29/35). **Gate 2** `is_organizer(interaction)` as the
  **first statement of the body**, refusing via
  `interaction.response.send_message(..., ephemeral=True)` **before** the defer
  and before any I/O, plus
  `print(f"ots-organizer: refused non-organizer {interaction.user.id}")`. Both
  gates are required; either alone is a single point of failure on a command that
  grants team-sheet access.
- Then defer **ephemeral**. Never DM, never public. **Not** channel-restricted.
- `status, player = await fetch_current_opponent(normalize_name(name))` — the
  unchanged v3.0 entry point, which is exactly why it **works on unbound
  players** (E2E 31): it never touches `profiles`.
- **Log every invocation** after resolution:
  `print(f"ots-organizer: caller {interaction.user.id} queried '{name}' -> status {status}")`.
- The reply reports the status **verbatim** rather than dressing it up
  (RFC §3.4) — one f-string, no second message table:

| Outcome | Ephemeral reply |
|---|---|
| not the organizer | `❌ Cette commande est réservée à l'organisateur du tournoi.` |
| `ok` | `🔎 Diagnostic **{name}** — adversaire actuel : **{player['ingame_name']}**` plus the same embed as `/ots` (same three lines: title, `render_team_text`, `0x3B4CCA`, `url` only when `pokepaste_url` is set) |
| any of the other six statuses | `🔎 Diagnostic **{name}** — statut : `{status}`. Aucun OTS renvoyé.` |

The organizer must be able to tell `requester_not_found` from
`no_current_match` (different fixes), which is why the raw token is shown.

### 5.3 `/link-organizer` (F58, F59, F61, F71)

```python
@tree.command(name="link-organizer",
              description="[Organisateur] Relier un compte Discord à un joueur",
              guild=discord.Object(id=GUILD_ID))
@app_commands.default_permissions(manage_guild=True)
@app_commands.describe(
    name="Nom du joueur dans le tournoi",
    user="Compte Discord à relier (sélectionnez-le dans la liste)",
    confirm_rebind="Cochez pour remplacer une liaison existante vers un autre compte",
)
async def link_organizer(interaction: discord.Interaction, name: str,
                         user: discord.User, confirm_rebind: bool = False):
```
- `user: discord.User` — **not `Member`** (RFC §8: the picker must also resolve
  an account that is not currently a guild member; never touch member-only
  attributes). This is what makes G14 true: no Discord id is ever typed.
- Same two gates as §5.2, same order (`is_organizer` first, refuse before the
  defer, log the refusal), then defer **ephemeral**.
- `status, details = await run_binding(str(user.id), user.display_name, name, confirm_rebind)`.
  **Bind the mentioned account, never `interaction.user`.**

| Status | F59 rule | French reply |
|---|---|---|
| `bind` | — | `✅ **{details['name']}** est désormais relié à {user.mention}.` |
| `rebind` | b′ | `✅ **{details['name']}** est désormais relié à {user.mention} (liaison précédente remplacée).` |
| `already_bound_same` | c | `✅ **{details['name']}** est déjà relié à {user.mention}. Rien à changer.` |
| `rebind_needs_confirm` | b | `⚠️ **{details['name']}** est déjà relié à {details['previous_mention']}. Relancez la commande avec `confirm_rebind` pour remplacer cette liaison.` |
| `account_slot_taken` | d | `❌ {user.mention} est déjà relié à **{details['other_name']}** dans ce tournoi.` |
| `not_found` | a | `❌ Aucun joueur nommé **{name}** dans le tournoi actif ni dans la saison en cours.` |
| `no_active` | e | `⚠️ Aucun tournoi actif pour le moment. Impossible de relier un joueur.` |
| `unavailable` | e | `⚠️ Service momentanément indisponible. Réessayez dans un instant.` |
| *(suffix)* | — | when `details['backfill_failed']` on `bind`/`rebind`, append `\n⚠️ Liaison faite, mais l'historique n'a pas pu être rattaché — voir les logs.` |

`not_found` echoes the organizer's **typed** `name` (they need to see their
typo); the success cases echo the **stored** `ingame_name` so the organizer sees
which roster row was actually hit. Dispatch via `.get(status, <unavailable copy>)`,
mirroring `/ots`, so no status can fall through.

### 5.4 `/unlink` (F69)

```python
@tree.command(name="unlink",
              description="Supprimer la liaison entre votre compte Discord et votre profil joueur",
              guild=discord.Object(id=GUILD_ID))
@app_commands.describe(confirm="Confirmez : cela désactivera aussi votre commande /ots")
async def unlink(interaction: discord.Interaction, confirm: bool):
```
- **No organizer gate, no `default_permissions`** — erasure of your own data
  cannot require asking someone else (F69). Visible to everyone.
- Defer **ephemeral** first, then handle `confirm=False` with **no I/O at all**.
- `confirm` is a **required boolean parameter**, not a button/`View`: this repo
  has no UI-component machinery and this RFC adds none.

| Case | French reply |
|---|---|
| `confirm=False` | `⚠️ **Attention :** supprimer votre liaison désactivera aussi la commande `/ots` — vous ne pourrez plus voir l'OTS de votre adversaire tant que l'organisateur ne vous aura pas relié à nouveau. Relancez la commande avec `confirm` si c'est bien ce que vous voulez.` (verbatim from RFC §3.8; **must not be softened**) |
| `not_linked` | `ℹ️ Votre compte Discord n'est relié à aucun profil joueur. Rien à supprimer.` |
| `ok` | `✅ Liaison supprimée. Vos résultats passés restent au classement sous votre nom de joueur, mais la commande `/ots` ne fonctionnera plus tant que l'organisateur ne vous aura pas relié à nouveau.` |
| `unavailable` | `⚠️ Service momentanément indisponible. Réessayez dans un instant.` |

### 5.5 `on_ready`

Unchanged code. After this RFC the guild sync registers **four** commands
(`/ots`, `/ots-organizer`, `/link-organizer`, `/unlink`), two of them hidden
from ordinary members; RFC-014 brings the final six. Guild-scoped sync is what
makes the removal of `/ots`'s parameter appear immediately.

---

## 6. EDGE FUNCTION CHANGES

**N/A.** RFC-013 touches nothing under `supabase/functions/`. It only *reads*
what RFC-012's freeze wrote (`tournament_results`) and what RFC-008's sync wrote
(the two cache tables). **Challonge API calls per invocation stay exactly 2 plus
a conditional 3rd** (F68, RULES §18) — this RFC adds zero Challonge traffic and
must not imply otherwise in any doc it edits.

---

## 7. TESTS

### 7.1 Mandatory `test_bot.py` edit, before anything else

Add `os.environ.setdefault("ORGANIZER_DISCORD_ID", "1234567890123456789")` to the
env-fixture block (lines 19–22) and extend that module docstring. Without it,
`import bot` runs the extended `validate_config` and all 30 existing tests fail
at import. Use a value **above 2^53** so the whole suite exercises the
text-comparison contract by default.

### 7.2 New `unittest` coverage (all pure, no network)

| Test class | Cases |
|---|---|
| `ValidateConfigTests` | missing `ORGANIZER_DISCORD_ID` → `SystemExit`; non-numeric (`"abc"`) → `SystemExit`; valid → returns `(int, str)` with the organizer id as **text**; a whitespace-padded value (`" 123 \n"`) normalizes to `"123"`; a snowflake above 2^53 survives byte-exact; each of the four pre-existing vars missing still exits (regression); a non-numeric `GUILD_ID` still exits with the **GUILD_ID** message, not the organizer one. Wrap calls in `contextlib.redirect_stdout(io.StringIO())` to keep suite output clean. |
| `IsOrganizerTests` | exact match; mismatch; an id above 2^53 that a float/int comparison would collapse (`"9007199254740993"` vs `9007199254740992`); an `int` interaction id equal to the configured text value still matches (proves `str()` is applied). Patch the constant with `unittest.mock.patch.object(bot, "ORGANIZER_DISCORD_ID", …)`; stub the interaction with `types.SimpleNamespace(user=types.SimpleNamespace(id=…))`. |
| `ResolveBindingConflictTests` | one per F59 branch: `roster_row=None` → `not_found`; unbound row → `bind`; same profile → `already_bound_same` (both `confirm_rebind` values); different profile without confirm → `rebind_needs_confirm`; with confirm → `rebind`; account slot taken → `account_slot_taken` **even when** the row is also bound elsewhere and `confirm_rebind=True` (precedence); `target_profile_id=None` on a bound row → `rebind_needs_confirm` / `rebind`. |
| `PickSeasonRosterRowTests` | empty rows → `None`; empty id list → `None`; one row → that row; rows from two tournaments → the one whose `tournament_id` comes first in the recency list; a row from a tournament absent from the list is ignored (and yields `None` when it is the only one). |
| `OtsStatusMessagesTests` | keys are exactly the eight failure statuses; every message is non-empty and **distinct** (`len(set(values)) == 8`); every status `fetch_opponent_for_profile` can return is a key; an unknown status resolves through `.get(status, OTS_STATUS_MESSAGES["unavailable"])` to the `unavailable` copy — the "no tenth status reaches the embed" guard (RFC §10.1). |

Expected total: 30 existing + ~22 new. Every one of the 30 existing tests must
pass **unchanged** — `normalize_name`, `render_team_text`,
`participant_candidate_ids`, `pick_opponent_id` and `is_cache_stale` are not
edited, and the name-path coverage keeps its meaning because F78 keeps that path
alive.

### 7.3 Network-dependent branches — manual in-guild verification only

Not unit-tested (this repo has no HTTP mocking and RFC §10.2 keeps
RFC-005/009's posture): `_supabase_write`, `fetch_profile_id`, every `_fetch_*`
helper, `fetch_opponent_for_profile`, `run_binding`, `run_unlink`, all four
handlers, DM delivery, and the F60 backfill counts. Verify against RFC-011's
seed fixtures plus a real Discord account, covering E2E 2–9 and 24–32:

- bind; re-bind same account (idempotent, **zero writes**); rebind to another
  account without then with `confirm_rebind`; unknown name; a name present only
  on an earlier in-season roster (F71); a non-organizer attempt.
- bind, then check `tournament_results` attribution and read the propagation log
  line; then create a roster row for the same name in a **new** tournament in
  Studio and confirm RFC-011's trigger auto-links it and `/ots` works with no
  rebind (E2E 9).
- `/ots` happy path (DM), `not_linked`, `not_in_tournament`,
  `requester_not_found`, `no_current_match`, DMs closed.
- `/ots-organizer` as organizer, as non-organizer, on an **unbound** player.
- `/unlink` unconfirmed → confirmed → `/ots` returns `not_linked` → organizer
  restores in one command.
- boot with `ORGANIZER_DISCORD_ID` missing, and with a malformed value.
- the command list a non-organizer sees contains **neither** organizer command.

**The two rows that are the release's security gate** (PRD §34, RFC §10.3): E2E
25 — `/ots` **accepts no argument at all** in the Discord client (not "rejects
one") — and E2E 29 — `/ots-organizer` is refused for *and absent from the
command list of* a non-organizer. A suite passing with either of these failing
means the release's security goal was not met.

Both Deno suites (`mapping_test.ts`, `points_test.ts`) are untouched and must
still pass.

---

## 8. DOCUMENTATION

1. **`.env.example`** — append:
   ```
   # Identifiant Discord de l'organisateur (clic droit sur votre nom → Copier
   # l'identifiant). Autorise /link-organizer et /ots-organizer.
   # ⚠️ Première variable NON SECRÈTE de ce fichier : c'est un identifiant
   # Discord public, sans danger dans les logs et la documentation — mais elle
   # est OBLIGATOIRE, le bot refuse de démarrer sans elle.
   ORGANIZER_DISCORD_ID=123456789012345678
   ```
2. **`.claude/RULES.md`** — add a **new §26** to the v4.0 addendum, *"Write path,
   authorization and the amended `/ots` entry point (RFC-013)"*, stating: the
   read seam's **one** write twin `_supabase_write` (and that the freeze still
   belongs in TypeScript — §3.1's distinction is not reopened); §15.2's entry
   point is now the caller's **bound profile**, with §15.1's no-link-first
   ordering and §15.3–5 unchanged, and the typed-name path surviving only as
   F78; seven fail-soft statuses become **nine** and four commands are under the
   never-raise rule; F77's two gates and the non-secret, boot-validated
   `ORGANIZER_DISCORD_ID`; backfill's three-part mitigation (current season only,
   `profile_id is null`, mandatory `_escape_ilike` — which now guards a
   **write**) plus the mandatory propagation log; no self-service claim command
   and never an optional name argument on `/ots`; and F25(b)'s deliberate
   reopening. Also add a one-line **"Amended by RFC-013 — see §26"** pointer at
   the head of §15 and on §2's data-access bullet, so a reader who stops there
   is not misled.
3. **`knowledge/E2E-CHECKLIST-v3.md`** (RFC §7.1 — this RFC's obligation, not
   RFC-014's): **strike, do not delete**, the two rows that become impossible to
   execute — row 1 (happy path driven by two typed names) and row 4
   (`requester_not_found`, whose expected text echoes the typed name). Wrap each
   `Scénario` cell in `~~…~~` and add to its **Notes** cell:
   `⛔ Supersédé par RFC-013 / F76 — /ots n'accepte plus d'argument ; re-testé par E2E-CHECKLIST-v4 (RFC-014), scénarios 24–28.`
   Keep their `PASS` history intact. Add **one** reading-convention line to the
   preamble: in rows 2, 3, 5, 6, 7, 8 and 9, `/ots <joueur>` now reads as "`/ots`
   run by the Discord account bound to that player (F76)" — those rows stay
   valid. Update the prerequisite line's "les 30 tests" to the real
   post-implementation count and function list.
4. **`CLAUDE.md`** — minimal correction, **not** a release update. The file's most
   prominent warning ("The argument is the caller's OWN name") becomes false the
   moment this ships, and it is the first thing the next reader or agent reads.
   Edit only: the "What this is" paragraph's `/ots <their own username>` claim
   and that warning block; the `/ots` bullets under "Key mechanics" (no argument,
   nine statuses, the two new ones, `fetch_opponent_for_profile` as the entry
   point, `/ots-organizer` as the typed-name survivor); the Config section (five
   env vars, `ORGANIZER_DISCORD_ID` non-secret and boot-validated); one line in
   "Locked decisions" for the write seam. **Leave** the `v3.0` version banner,
   the "Planned direction (v4.0 … not yet built)" framing and all four status
   trackers to RFC-014 — RFC-012's precedent is that per-RFC commits do not move
   the release status. Flagged in §10 as an addition beyond RFC-013's own doc
   list, justified by RULES §10 ("keep the docs in sync").
5. **`knowledge/RFCs/RFCS.md`** — flip RFC-013's row from `📝 Draft` to the
   in-progress/complete marker used by the RFC-011/012 rows.
6. **`knowledge/RFCs/RFC-013-*.md`** — fill the **Completion record** (status,
   deliverables, verification actually performed, deviations, follow-ups) once
   in-guild verification is done. Never record a `PASS` that was not run.

**Explicitly NOT this RFC's docs:** `DEPLOYMENT.md` (both env vars, RFC-014),
`RUNBOOK.md` §9 (RFC-014), `E2E-CHECKLIST-v4.md` (RFC-014, F73),
`FEATURES.md`'s status table (RFC-014), `PRD.md` / `PRD.v4.final.md`. RFC §3.5's
deploy note ("the RFC-013 deploy fails fast unless `ORGANIZER_DISCORD_ID` is set
first") is carried here by `.env.example`'s comment and later by RFC-014's
`DEPLOYMENT.md` update — restate it in the Completion record so it is not lost
between the two RFCs.

---

## 9. IMPLEMENTATION ORDER

Schema first (none), then pure logic, then the network code that uses it, then
commands, then docs — RFC-004-before-RFC-005 discipline: every pure decision is
green in isolation before a single network path is written.

1. **`.env.example`** + the `test_bot.py` env-fixture line (§7.1). First,
   because without it the suite cannot import `bot` after step 2.
2. **Config**: extend `validate_config` to five parameters / `tuple[int, str]`;
   update the module-level call, the module docstring and the comment (§4.1).
3. **Pure logic + its tests**: `is_organizer`, `resolve_binding_conflict`,
   `pick_season_roster_row`, `OTS_STATUS_MESSAGES` (§4.2, §4.3) and the five new
   test classes (§7.2). **Gate: `python -m unittest test_bot` fully green
   (30 + ~22) before any network code is written.**
4. **Network seam**: `_service_session`, `_supabase_write`, `fetch_profile_id`
   (§4.4). No caller yet.
5. **Extraction only, zero behavior change**: add `_resolve_opponent`, rewrite
   `fetch_current_opponent` as its wrapper (§4.6). **Gate: the suite is still
   green and `/ots` — still carrying its argument at this point — still works
   in-guild.** This is the de-risking step: the v3.0 chain is proven intact
   before the entry point moves.
6. **Roster/profile read helpers** (§4.5), then `fetch_opponent_for_profile`
   (§4.6) with its two mandatory logs.
7. **Rewrite `/ots`** (§5.1): delete the `username` parameter and its
   `describe`, dispatch through `OTS_STATUS_MESSAGES`, keep the embed/DM block
   verbatim. **Gate: `grep -n "username" bot.py` finds nothing on the `/ots`
   path, and the Discord client offers no argument after the guild sync.**
8. **`/ots-organizer`** (§5.2) — the cheapest command, and it restores the
   organizer's ability to debug everything that follows.
9. **`run_binding`** + `/link-organizer` (§4.7, §5.3), in this sub-order: search
   (F71) → conflict dispatch (F59) → writes (F58/F61) → backfill (F60) →
   propagation log. Verify each F59 branch in-guild as it lands.
10. **`run_unlink`** + `/unlink` (§4.8, §5.4).
11. **Round out the tests** if any pure helper's shape shifted during
    implementation; re-run `python -m unittest test_bot` and both Deno suites.
12. **Docs** (§8) in this order: `.claude/RULES.md` §26 + the two pointers →
    `E2E-CHECKLIST-v3.md` strike → `CLAUDE.md` minimal correction → `RFCS.md`
    status.
13. **In-guild verification** of §7.3, **including E2E 25 and 29**, then fill the
    Completion record with what was actually run.

---

## 10. RISK AREAS

1. **The F77 gate is a single point of failure for both organizer surfaces.** A
   wrong-but-valid `ORGANIZER_DISCORD_ID` locks the operator out of the only
   commands that unblock a player mid-event (PRD §38); `validate_config` catches
   malformed, never wrong. *Strategy:* both gates as specified; the boot value
   normalized through `int()` so whitespace in `.env` cannot break the
   comparison; comparison strictly as text; and the pre-flight probe — run
   `/link-organizer` once on an already-bound player and expect F59c's
   idempotent success — recorded in the Completion record's verification list.
2. **Snowflake precision.** `profiles.discord_user_id` is text and ids exceed
   2^53. *Strategy:* `str(interaction.user.id)` / `str(user.id)` at every
   boundary; the only `int()` is boot-time validation; the test fixture id is
   deliberately above 2^53 and `IsOrganizerTests` includes the
   `9007199254740993` case.
3. **`_escape_ilike` now guards a *write* that grants team-sheet access.** A
   crafted `ingame_name` could otherwise widen an `ilike` PATCH into a wildcard
   that moves another player's results *and* their team sheet. *Strategy:* reuse
   the existing function verbatim on **every** `ingame_name` filter (both
   backfill PATCHes, both roster searches); never build a filter string by hand;
   never use `ilike.*…*` anywhere in this RFC.
4. **Backfill can move another person's history** — two people using the same
   in-game name in one season is the failure case. *Strategy:* the three-part
   mitigation, all mandatory and none negotiable: bounded to `current_season`,
   filtered on `profile_id=is.null`, fully logged (profile, normalized name,
   season, per-table row counts, tournament ids). Do **not** widen the season
   bound "for convenience". A rebind deliberately does **not** move rows already
   attributed to the old profile; the `rebind_from=` log clause is how the
   organizer finds them for a manual Studio fix.
5. **`tournament_results.ingame_name` is stored untrimmed** (RFC-011's comment;
   RFC-012 writes Challonge's `p.name` verbatim). An exact `ilike` on a
   normalized name therefore misses a frozen row whose Challonge name carries
   padding. *Strategy:* accept it — widening the filter is exactly the hole in
   risk 3 — and make it visible: the propagation log prints the row count, so a
   surprising `tournament_results +0` is the organizer's cue to fix that row in
   Studio. Record it in the Completion record as a known limitation, not a
   defect.
6. **The dual-id trap.** `participant_candidate_ids` must keep returning **both**
   `challonge_participant_id` and `challonge_group_player_id`; reducing it to one
   id silently breaks resolution for one phase of a group-stage tournament.
   *Strategy:* step 5's extraction is a pure code move — that function,
   `pick_opponent_id`, `_fetch_open_matches` and `_fetch_participant_name` are
   not edited at all, and their existing 12 tests stay green.
7. **Shared-core log prefixes.** `_resolve_opponent` and the `_fetch_*` helpers
   keep printing `fetch_current_opponent: …` even when serving `/ots`.
   *Strategy:* deliberate — E2E-v3 scenario 8 and `DEPLOYMENT.md`'s
   troubleshooting entries assert those literal strings. `/ots`-specific context
   is carried by `fetch_opponent_for_profile`'s own two log lines.
8. **The nested session in `_resolve_opponent`'s tail.** `fetch_active_player`
   now runs while the caller's session is still open (today it closes first).
   *Strategy:* accepted **[PLAN DECISION]** — per-request timeouts make it
   behaviorally identical, and it is what lets one shared core serve both entry
   points; named here so a reviewer does not read it as an accident.
9. **`fetch_current_opponent`'s public contract must not drift.** Its signature
   and seven statuses are an acceptance criterion and `/ots-organizer` depends on
   them. *Strategy:* the wrapper in §4.6 is the only edit; its docstring's status
   list stays verbatim; no status is added or removed.
10. **An unbound player cannot use `/ots` at all**, which moves the failure to
    round 1 of a live event. *Strategy:* out of code's reach by design; what this
    RFC owes it is that `/link-organizer` is genuinely phone-runnable (native
    user picker, no id typing, one ephemeral reply, no Studio step) and that
    `not_linked` names the remedy ("Contactez l'organisateur") **and** logs the
    Discord id so the organizer can bind without asking twice.
11. **No operational fallback if the refactor fails mid-event.** Break-glass is
    redeploying the previous `bot.py` from git, which **restores `/ots <name>`
    and the scouting leak with it**. *Strategy:* accept knowingly (PRD §38) and
    record it in the Completion record so it is not rediscovered under pressure.
    Do **not** build a feature flag or a dormant fallback branch — RULES §2
    ("delete, don't disable") forbids exactly that shape.
12. **The `/ots` change must be announced.** No RFC will remind anyone; it is a
    release requirement (PRD §36) formally owned by RFC-014. *Strategy:* name it
    as an outstanding release obligation in RFC-013's Completion record.
13. **Command-registration surface.** Guild-scoped sync makes the parameter
    removal immediate, but a stale client cache can still render the old
    signature. *Strategy:* verify E2E 25 in a client that has resynced (or after
    a client restart), and verify `default_permissions` visibility from a
    genuinely non-organizer account rather than by inspection.
14. **F59d overlaps `players_tournament_profile_idx`.** The step-7 pre-check and
    the DB unique index enforce the same rule; a race can still trip the index.
    *Strategy:* the pre-check exists for the *message* (F40's complaint names the
    other roster row); the index remains the enforcement, and a 409 from either
    PATCH degrades to `unavailable` + a log, never a traceback.
15. **A backfill failure must not report a failed binding.** The bind PATCH and
    the two backfill PATCHes are separate statements with different consequences.
    *Strategy:* step 10b failing → `unavailable` (nothing was bound); step 10c
    failing → keep the success status, set `backfill_failed`, append the French
    suffix, log loudly. Never the other way round.
16. **`/unlink` during an event is self-inflicted denial of service.**
    *Strategy:* the confirmation copy is the only mitigation; use it **verbatim**
    from RFC §3.8 — it must not be softened, shortened, or moved behind a button.
17. **Scope pressure toward "just add an optional name back to `/ots`".**
    *Strategy:* forbidden by PRD §37 and RULES §20; if it comes up during
    implementation it is a scope change to escalate, not a judgement call. Two
    commands, two signatures, fail-closed.
18. **`CLAUDE.md` is edited even though RFC-013's own doc list does not name it**
    (§8 item 4). *Strategy:* strictly limited to the `/ots` contract, the config
    var count and one locked-decision line; the version banner and the four
    status trackers stay untouched for RFC-014. Flagged here rather than done
    silently.
