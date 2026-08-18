"""
Bot Discord - Commande /ots
============================
Setup :
  1. Créer un bot sur https://discord.com/developers/applications
     → Onglet "Bot" : copier le token
     → Activer "Message Content Intent" et "Server Members Intent"
  2. Inviter le bot avec les scopes : bot + applications.commands
     Permission requise : Send Messages
  3. Copier .env.example → .env et renseigner DISCORD_TOKEN, GUILD_ID,
     SUPABASE_URL, SUPABASE_SERVICE_KEY et ORGANIZER_DISCORD_ID
  4. pip install -r requirements.txt
  5. Gérer le tournoi actif et les joueurs depuis Supabase Studio
     (voir knowledge/RUNBOOK.md)
  6. python bot.py
"""

from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timedelta, timezone
import aiohttp
import discord
from discord import app_commands
from dotenv import load_dotenv

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
_GUILD_ID_RAW = os.getenv("GUILD_ID")
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")
_ORGANIZER_DISCORD_ID_RAW = os.getenv("ORGANIZER_DISCORD_ID")


def validate_config(discord_token: str | None, guild_id_raw: str | None,
                     supabase_url: str | None, supabase_service_key: str | None,
                     organizer_discord_id_raw: str | None) -> tuple[int, str]:
    """Fail fast at boot if any required config is missing or invalid.

    Prints a clear English operator error naming the missing/invalid var(s)
    (never the values themselves) and exits the process (non-zero) on
    failure. Returns (GUILD_ID as int, ORGANIZER_DISCORD_ID as text) on
    success.

    ORGANIZER_DISCORD_ID must parse as an integer (it is a Discord snowflake)
    but is returned and stored as TEXT: the int() round-trip normalizes a
    `.env` value carrying whitespace or a trailing newline into something
    that can later compare equal, byte-for-byte, to str(interaction.user.id)
    — a raw os.getenv string would fail is_organizer()'s gate silently and
    forever. It is not a secret (RFC-013 §3.5) and may be logged.
    """
    missing = []
    if not discord_token:
        missing.append("DISCORD_TOKEN")
    if not guild_id_raw:
        missing.append("GUILD_ID")
    if not supabase_url:
        missing.append("SUPABASE_URL")
    if not supabase_service_key:
        missing.append("SUPABASE_SERVICE_KEY")
    if not organizer_discord_id_raw:
        missing.append("ORGANIZER_DISCORD_ID")

    if missing:
        print(f"Config error: missing required env var(s): {', '.join(missing)}")
        sys.exit(1)

    try:
        guild_id = int(guild_id_raw)
    except ValueError:
        print("Config error: GUILD_ID must be an integer")
        sys.exit(1)

    try:
        organizer_discord_id = str(int(organizer_discord_id_raw))
    except ValueError:
        print("Config error: ORGANIZER_DISCORD_ID must be an integer (a Discord user id)")
        sys.exit(1)

    return guild_id, organizer_discord_id


# Runs at module load (before the @tree.command decorator below reads
# GUILD_ID) so a missing/invalid var fails fast at boot, not on first /ots.
GUILD_ID, ORGANIZER_DISCORD_ID = validate_config(
    TOKEN, _GUILD_ID_RAW, SUPABASE_URL, SUPABASE_SERVICE_KEY, _ORGANIZER_DISCORD_ID_RAW
)

# Discord embed *description* character limit (fence + marker counted against it).
DISCORD_DESC_LIMIT = 4096
# French truncation marker (user-facing text is always French). Appended
# inside the fence so it renders as visible text, not after a broken fence.
TRUNCATION_MARKER = "\n… (équipe tronquée)"

# F36: age beyond which a Challonge cache row triggers an operator-only
# staleness warning. Never gates resolution — see is_cache_stale().
STALENESS_THRESHOLD = timedelta(hours=48)

# F76: the eight fail-soft statuses of /ots -> their French copy. "ok" is not
# here: it is the embed path, built separately in the ots() handler. A status
# absent from this table can never fall through to the embed path — the
# handler dispatches via OTS_STATUS_MESSAGES.get(status, ...["unavailable"]).
OTS_STATUS_MESSAGES: dict[str, str] = {
    "no_active": "⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.",
    "no_challonge_link": (
        "❌ Ce tournoi n'est pas relié à Challonge. Impossible de déterminer "
        "votre adversaire actuel."
    ),
    "not_linked": (
        "❌ Votre compte Discord n'est pas encore relié à un joueur. "
        "Contactez l'organisateur pour être enregistré."
    ),
    "not_in_tournament": "ℹ️ Vous n'êtes pas inscrit au tournoi en cours.",
    "requester_not_found": (
        "⚠️ Votre nom de joueur est introuvable dans le bracket Challonge de "
        "ce tournoi. Contactez l'organisateur."
    ),
    "no_current_match": "ℹ️ Vous n'avez pas de match en cours pour le moment.",
    "opponent_no_ots": (
        "⚠️ Votre adversaire a été trouvé, mais son OTS n'est pas encore "
        "enregistré. Contactez l'organisateur."
    ),
    "unavailable": "⚠️ Service momentanément indisponible. Réessayez dans un instant.",
}

intents = discord.Intents.default()
client = discord.Client(intents=intents)
tree = app_commands.CommandTree(client)


def normalize_name(raw: str) -> str:
    """Normalize user input to match the stored, indexed ingame_name.

    Mirrors RFC-001 exactly: the players BEFORE-trigger btrim()s ingame_name
    and the unique index is on lower(ingame_name). Bot-side lookups must apply
    the same transform (strip + lower) or the match contract breaks.
    IMPORTANT: change this and the DB index/trigger together — never one alone.
    """
    return raw.strip().lower()


def render_team_text(team_text: str) -> str:
    """Return an embed description: team_text in a fenced code block, hardened
    so it (a) cannot break out of the fence and (b) never exceeds Discord's
    4096-char description limit (fence + marker counted). Content is trusted;
    only rendering is hardened (PRD §11.4).
    """
    # 1. Neutralize fence-breaking sequences first, on the raw content: any
    # run of >=3 literal backticks could close the code block early. Insert a
    # zero-width space between every backtick in each run so no 3 consecutive
    # backticks survive, while every visible backtick is preserved.
    hardened = re.sub(r"`{3,}", lambda m: "​".join(m.group(0)), team_text)

    # 2. Assemble the full fenced block.
    opening, closing = "```\n", "\n```"
    full = opening + hardened + closing
    if len(full) <= DISCORD_DESC_LIMIT:
        return full

    # 3. Budget-aware truncation: cut the (already-hardened) content so the
    # final assembled string is exactly DISCORD_DESC_LIMIT chars, never more.
    # Note: Discord counts the description in UTF-16 code units, while this
    # counts Python str characters — astral-plane characters (some emoji)
    # count as 2 UTF-16 units there. Char-count is the pragmatic, documented
    # choice here (RFC-004 §8); it must never exceed DISCORD_DESC_LIMIT.
    max_content = DISCORD_DESC_LIMIT - len(opening) - len(closing) - len(TRUNCATION_MARKER)
    return opening + hardened[:max_content] + TRUNCATION_MARKER + closing


def _escape_ilike(value: str) -> str:
    """Escape PostgREST/ILIKE special characters in a filter value.

    Neutralizes '%' and '_' (SQL LIKE wildcards), '*' (PostgREST's wildcard
    alias for '%' in like/ilike filters), and the reserved separators
    ',', '(', ')' used in PostgREST filter syntax — so a crafted
    ingame_name cannot widen an ilike match into a wildcard/multi-value
    query. Backslash itself is escaped first so the added escapes are not
    themselves re-escaped.
    """
    value = value.replace("\\", "\\\\")
    for char in ("%", "_", "*", ",", "(", ")"):
        value = value.replace(char, f"\\{char}")
    return value


def is_organizer(interaction: discord.Interaction) -> bool:
    """F77's second gate (belt-and-braces alongside default_permissions).
    Compares as TEXT — Discord snowflakes exceed 2^53, so an int round-trip
    anywhere in this comparison could silently authorize the wrong account."""
    return str(interaction.user.id) == ORGANIZER_DISCORD_ID


def resolve_binding_conflict(roster_row: dict | None,
                              existing_profile_id: int | None,
                              target_profile_id: int | None,
                              account_slot_taken_by: str | None,
                              confirm_rebind: bool) -> str:
    """Pure: the F59 decision table for /link-organizer. Returns exactly one
    of 'not_found', 'account_slot_taken', 'already_bound_same', 'bind',
    'rebind_needs_confirm', 'rebind'. No I/O.

    Evaluation order is load-bearing:
      1. no roster row at all -> not_found (F59a)
      2. the mentioned account already holds a DIFFERENT roster slot in this
         tournament -> account_slot_taken (F59d) — checked BEFORE the rebind
         branches, since players_tournament_profile_idx would reject the
         write anyway and F40's complaint is the more specific one
      3. the roster row is already bound to the SAME target profile ->
         already_bound_same (F59c) — an idempotent success
      4. the roster row is unbound -> bind
      5. the roster row is bound to a DIFFERENT profile, no confirmation ->
         rebind_needs_confirm (F59b)
      6. same, with confirmation -> rebind (F59b')
    """
    if roster_row is None:
        return "not_found"
    if account_slot_taken_by is not None:
        return "account_slot_taken"
    if existing_profile_id is not None and existing_profile_id == target_profile_id:
        return "already_bound_same"
    if existing_profile_id is None:
        return "bind"
    if not confirm_rebind:
        return "rebind_needs_confirm"
    return "rebind"


def pick_season_roster_row(rows: list[dict],
                            tournament_ids_by_recency: list[int]) -> dict | None:
    """Pure: F71 step 2's tie-break. Given candidate `players` rows drawn from
    several tournaments in the current season, return the one belonging to
    the most recent tournament — recency is supplied by the caller as
    `tournament_ids_by_recency` (most recent first; comes from the
    tournaments query's own `order=event_date.desc.nullslast,id.desc`, so
    null-`event_date` ordering is decided there, not here).

    Rows whose tournament_id is absent from that list are ignored. Empty
    input (or no row from a listed tournament) returns None.
    """
    for tournament_id in tournament_ids_by_recency:
        for row in rows:
            if row["tournament_id"] == tournament_id:
                return row
    return None


def _format_tournament_ids(tournament_ids: list[int]) -> str:
    """Pure: renders a tournament-id list as the RFC-013 §3.7 propagation-log
    shorthand (`[t7,t8,t9]`) instead of Python's default list repr."""
    return "[" + ",".join(f"t{i}" for i in tournament_ids) + "]"


def _service_session() -> aiohttp.ClientSession:
    """The one place the service-key headers and the mandatory 5s bound are
    stated for every helper added from RFC-013 onward. `fetch_active_player`'s
    existing inline headers dict is left exactly as it is (it is reused
    verbatim) — only new code uses this factory."""
    return aiohttp.ClientSession(
        headers={
            "apikey": SUPABASE_SERVICE_KEY,
            "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
        },
        timeout=aiohttp.ClientTimeout(total=5),
    )


async def _supabase_write(session: aiohttp.ClientSession, method: str, path: str,
                           params: dict | None = None,
                           json_body: dict | None = None,
                           prefer: str = "return=representation") -> tuple[str, list[dict] | None]:
    """The single write seam — the write-side twin of the _fetch_* read
    helpers (RFC-013 §3.1). EVERY POST/PATCH/DELETE bot.py makes goes through
    here; never call session.post/patch/delete directly.

    Never raises a status: any network/timeout/non-2xx/parse failure maps to
    ("unavailable", None), logged with method, path and status — never the
    request body, which can carry a display name. ("ok", rows) otherwise,
    where rows is the PostgREST representation (possibly []), so callers can
    count what they changed (F60's mandatory propagation log).
    """
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    headers = {"Prefer": prefer}
    async with session.request(method, url, params=params, json=json_body, headers=headers) as resp:
        if resp.status not in (200, 201, 204):
            print(f"_supabase_write: {method} {path} failed (status {resp.status})")
            return ("unavailable", None)
        if resp.status == 204:
            return ("ok", [])
        text = await resp.text()
        if not text:
            return ("ok", [])
        return ("ok", await resp.json())


async def fetch_profile_id(session: aiohttp.ClientSession,
                            discord_user_id: str) -> tuple[str, int | None]:
    """GET profiles?discord_user_id=eq.<id>&select=id&limit=1.

    discord_user_id is TEXT (Discord snowflakes exceed 2^53). No
    _escape_ilike: this is an `eq.` filter on a digits-only string produced by
    str(...id), never by free text. Exposed for RFC-014's /profile.
    Returns ("ok", id) | ("not_linked", None) | ("unavailable", None).
    """
    url = f"{SUPABASE_URL}/rest/v1/profiles"
    params = {"discord_user_id": f"eq.{discord_user_id}", "select": "id", "limit": "1"}
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_profile_id: profiles query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["id"]) if rows else ("not_linked", None)


async def _fetch_roster_row_for_profile(session: aiohttp.ClientSession, tournament_id,
                                         profile_id: int) -> tuple[str, dict | None]:
    """GET players?tournament_id=eq.<t>&profile_id=eq.<p>&select=ingame_name&limit=1
    — the /ots F76 entry point's roster lookup. Returns ("ok", row) /
    ("not_in_tournament", None) / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/players"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "profile_id": f"eq.{profile_id}",
        "select": "ingame_name",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_opponent_for_profile: players query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]) if rows else ("not_in_tournament", None)


async def _fetch_roster_row_by_name(session: aiohttp.ClientSession, tournament_id,
                                     normalized_name: str) -> tuple[str, dict | None]:
    """F71 step 1 — search the active tournament's roster by normalized name.
    Returns ("ok", row) / ("not_found", None) / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/players"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "ingame_name": f"ilike.{_escape_ilike(normalized_name)}",
        "select": "id,tournament_id,ingame_name,profile_id",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"run_binding: players query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]) if rows else ("not_found", None)


async def _fetch_current_season_id(session: aiohttp.ClientSession) -> tuple[str, int | None]:
    """GET current_season?select=id&limit=1. Returns ("ok", id) /
    ("no_season", None) / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/current_season"
    params = {"select": "id", "limit": "1"}
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"run_binding: current_season query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["id"]) if rows else ("no_season", None)


async def _fetch_season_tournament_ids(session: aiohttp.ClientSession,
                                        season_id: int) -> tuple[str, list[int] | None]:
    """GET tournaments?season_id=eq.<s>&select=id&order=event_date.desc.nullslast,id.desc
    — most-recent-first, so the same list serves both F71's search tie-break
    (pick_season_roster_row) and F60's backfill bound. Returns ("ok", [ids…])
    / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/tournaments"
    params = {
        "season_id": f"eq.{season_id}",
        "select": "id",
        "order": "event_date.desc.nullslast,id.desc",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"run_binding: tournaments (season) query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", [row["id"] for row in rows])


async def _fetch_roster_rows_in_tournaments(session: aiohttp.ClientSession,
                                             tournament_ids: list[int],
                                             normalized_name: str) -> tuple[str, list[dict] | None]:
    """F71 step 2 — search every roster in the current season by normalized
    name (no `limit`; a season's rosters are tens of rows, not thousands).
    Returns ("ok", rows) / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/players"
    ids = ",".join(str(i) for i in tournament_ids)
    params = {
        "tournament_id": f"in.({ids})",
        "ingame_name": f"ilike.{_escape_ilike(normalized_name)}",
        "select": "id,tournament_id,ingame_name,profile_id",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"run_binding: players (season) query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows)


async def _fetch_profile_slot_in_tournament(session: aiohttp.ClientSession, tournament_id,
                                             profile_id: int) -> tuple[str, dict | None]:
    """F59d's input: does the mentioned account already hold a (different)
    roster slot in this tournament? Returns ("ok", row) / ("not_found", None)
    / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/players"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "profile_id": f"eq.{profile_id}",
        "select": "id,ingame_name",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"run_binding: profile-slot query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]) if rows else ("not_found", None)


async def _fetch_profile_discord_id(session: aiohttp.ClientSession,
                                     profile_id: int) -> tuple[str, str | None]:
    """Only to render the *previous* account's mention in F59b's
    rebind_needs_confirm reply. Returns ("ok", discord_user_id) /
    ("not_found", None) / ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/profiles"
    params = {"id": f"eq.{profile_id}", "select": "discord_user_id", "limit": "1"}
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"run_binding: profiles query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["discord_user_id"]) if rows else ("not_found", None)


async def fetch_active_player(normalized_name: str) -> tuple[str, dict | None]:
    """Look up `normalized_name` in the active tournament via PostgREST.

    `normalized_name` must already be trim()+lower()'d by the caller (the
    stored ingame_name is trimmed by a DB trigger and uniquely indexed on
    lower(ingame_name) — see schema.sql); this helper does not normalize,
    it only escapes filter special characters.

    Never raises: any network/timeout/non-200/parse failure maps to
    ("unavailable", None). Returns exactly one of:
      ("ok", {"ingame_name": ..., "team_text": ..., "pokepaste_url": ...|None})
      ("not_found", None)   -- active tournament exists, no matching player
      ("no_active", None)  -- zero active tournaments
      ("unavailable", None) -- timeout / non-200 / network / parse error
    """
    headers = {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
    }
    timeout = aiohttp.ClientTimeout(total=5)

    try:
        async with aiohttp.ClientSession(headers=headers, timeout=timeout) as session:
            status, tournament_id = await _fetch_active_tournament_id(session)
            if status != "ok":
                return (status, None)
            return await _fetch_player_in_tournament(session, tournament_id, normalized_name)
    except Exception as exc:
        print(f"fetch_active_player: request error: {exc!r}")
        return ("unavailable", None)


async def _fetch_active_tournament_id(session: aiohttp.ClientSession) -> tuple[str, int | None]:
    """Return ("ok", id) for the active tournament, ("no_active", None) if
    none is active, or ("unavailable", None) if the query itself failed."""
    url = f"{SUPABASE_URL}/rest/v1/tournaments"
    params = {"is_active": "eq.true", "select": "id", "limit": "1"}
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_active_player: tournaments query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["id"]) if rows else ("no_active", None)


async def _fetch_player_in_tournament(session: aiohttp.ClientSession, tournament_id,
                                       normalized_name: str) -> tuple[str, dict | None]:
    """Query the players table for `normalized_name` within `tournament_id`."""
    url = f"{SUPABASE_URL}/rest/v1/players"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "ingame_name": f"ilike.{_escape_ilike(normalized_name)}",
        "select": "ingame_name,team_text,pokepaste_url",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_active_player: players query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]) if rows else ("not_found", None)


async def _fetch_active_tournament_with_link(session: aiohttp.ClientSession) -> tuple[str, dict | None]:
    """Sibling to `_fetch_active_tournament_id` with a wider `select` (also
    fetches `challonge_tournament_id`) for RFC-009's own needs. Kept separate
    rather than widening that v2.0 helper's contract (RFC-009 §3.2).

    Returns ("ok", {"id": ..., "challonge_tournament_id": ...|None}),
    ("no_active", None), or ("unavailable", None).
    """
    url = f"{SUPABASE_URL}/rest/v1/tournaments"
    params = {"is_active": "eq.true", "select": "id,challonge_tournament_id", "limit": "1"}
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_current_opponent: tournaments query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]) if rows else ("no_active", None)


async def _fetch_participant_id(session: aiohttp.ClientSession, tournament_id,
                                 normalized_name: str) -> tuple[str, dict | None]:
    """Resolve `normalized_name`'s cached Challonge participant id(s) within
    `tournament_id`, alongside that cache row's `fetched_at` (F36 reuses this
    query rather than making a second round-trip). Returns
    ("ok", {"challonge_participant_id": ..., "challonge_group_player_id": ...|None,
    "fetched_at": ...}), ("requester_not_found", None), or ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/challonge_participants_cache"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "ingame_name": f"ilike.{_escape_ilike(normalized_name)}",
        "select": "challonge_participant_id,challonge_group_player_id,fetched_at",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_current_opponent: participants query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]) if rows else ("requester_not_found", None)


def participant_candidate_ids(participant_row: dict) -> set[int]:
    """A participant can be referenced in `challonge_matches_cache` by either
    its stable top-level id or, for group-stage tournaments, a separate
    `challonge_group_player_id` — Challonge keeps both live simultaneously
    once a final bracket is generated after the group stage ends (the
    bracket's matches use the top-level id; already-played group-stage
    matches keep using the group id). Candidate set excludes None."""
    return {
        pid for pid in (
            participant_row["challonge_participant_id"],
            participant_row.get("challonge_group_player_id"),
        ) if pid is not None
    }


def is_cache_stale(fetched_at: datetime, now: datetime) -> bool:
    """Pure logic (RFC-010 §3.2, F36): True if a Challonge cache row's
    `fetched_at` is more than 48h older than `now`. This never gates
    resolution — it only decides whether to emit the operator-only staleness
    warning in `_warn_if_stale`."""
    return now - fetched_at > STALENESS_THRESHOLD


def _warn_if_stale(tournament_id, fetched_at_raw: str) -> None:
    """Log a server-side-only warning (never player-facing, never a branch)
    if the participant cache row backing this request is stale (F36)."""
    fetched_at = datetime.fromisoformat(fetched_at_raw)
    if is_cache_stale(fetched_at, datetime.now(timezone.utc)):
        print(
            f"fetch_current_opponent: Challonge cache stale for tournament "
            f"{tournament_id}: last refreshed {fetched_at_raw} (>48h ago)"
        )


async def _fetch_open_matches(session: aiohttp.ClientSession, tournament_id,
                               own_ids: set[int]) -> tuple[str, list[dict]]:
    """Return the (at most one, DB-side highest-`round`-first) `open` match
    rows involving any id in `own_ids` (group-stage id and/or top-level id —
    see participant_candidate_ids). Returns ("ok", rows) or
    ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/challonge_matches_cache"
    sides = ",".join(
        f"player{side}_challonge_id.eq.{pid}"
        for pid in own_ids
        for side in (1, 2)
    )
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "state": "eq.open",
        "or": f"({sides})",
        "select": "player1_challonge_id,player2_challonge_id,round",
        "order": "round.desc",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_current_opponent: matches query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows)


async def _fetch_participant_name(session: aiohttp.ClientSession, tournament_id,
                                   participant_id: int) -> tuple[str, str | None]:
    """Resolve a cached Challonge id — either a participant's top-level id or
    its group-stage id — back to its `ingame_name`. Returns ("ok", name),
    ("not_found", None), or ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/challonge_participants_cache"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "or": (
            f"(challonge_participant_id.eq.{participant_id},"
            f"challonge_group_player_id.eq.{participant_id})"
        ),
        "select": "ingame_name",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_current_opponent: participant-name query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["ingame_name"]) if rows else ("not_found", None)


def pick_opponent_id(own_ids: set[int], matches: list[dict]) -> int | None:
    """Pure logic (RFC-009 §7, extended for the group-stage/final-bracket
    dual-id-space fix): given the caller's cached candidate id(s) and
    candidate `open` match rows (each with `player1_challonge_id`,
    `player2_challonge_id`, `round`), pick the opponent's id.

    - Empty `matches` -> None (no current match).
    - More than one row -> the highest `round` wins (defensive tie-break;
      the live query already sorts/limits this way, but this function is
      written to resolve it independently so it's unit-testable in isolation).
    - Degenerate rows (no id in `own_ids` actually on either side, both sides
      are in `own_ids`, or the other side is null/bye) -> None, rather than
      crashing or returning a nonsensical opponent.
    """
    if not matches:
        return None
    match = max(matches, key=lambda m: m.get("round") or 0)
    p1, p2 = match.get("player1_challonge_id"), match.get("player2_challonge_id")
    if p1 in own_ids and p2 is not None and p2 not in own_ids:
        return p2
    if p2 in own_ids and p1 is not None and p1 not in own_ids:
        return p1
    return None


async def _resolve_opponent(session: aiohttp.ClientSession, tournament: dict,
                             normalized_own_name: str) -> tuple[str, dict | None]:
    """v3.0's opponent-resolution chain, extracted verbatim (a pure code move,
    RFC-013 §3.2) so it can be shared by both /ots (via
    fetch_opponent_for_profile) and /ots-organizer (via
    fetch_current_opponent): cached participant -> candidate id set (dual-id
    space) -> the open match -> the other side's name -> that player's
    team_text row.

    Resolving the active tournament and its Challonge link is the CALLER's
    job (RULES §15.1 keeps that check first, before this is ever called).

    Returns ("ok", player_dict) | ("requester_not_found" | "no_current_match"
    | "opponent_no_ots" | "unavailable", None).
    """
    tournament_id = tournament["id"]

    status, participant = await _fetch_participant_id(session, tournament_id, normalized_own_name)
    if status != "ok":
        return (status, None)
    own_ids = participant_candidate_ids(participant)
    _warn_if_stale(tournament_id, participant["fetched_at"])

    status, matches = await _fetch_open_matches(session, tournament_id, own_ids)
    if status != "ok":
        return (status, None)

    opponent_id = pick_opponent_id(own_ids, matches)
    if opponent_id is None:
        return ("no_current_match", None)

    status, opponent_name = await _fetch_participant_name(session, tournament_id, opponent_id)
    if status == "unavailable":
        return ("unavailable", None)
    if status == "not_found":
        print(
            "fetch_current_opponent: cache inconsistency: match "
            f"references unknown participant id {opponent_id} "
            f"(tournament {tournament_id})"
        )
        return ("unavailable", None)

    status, player = await fetch_active_player(normalize_name(opponent_name))
    if status == "ok":
        return ("ok", player)
    if status == "not_found":
        print(
            f"fetch_current_opponent: opponent '{opponent_name}' resolved via "
            f"Challonge cache but has no players.team_text row (tournament {tournament_id})"
        )
        return ("opponent_no_ots", None)
    if status == "no_active":
        print(
            "fetch_current_opponent: active tournament was deactivated mid-request "
            "during the final team_text lookup"
        )
        return ("unavailable", None)
    return ("unavailable", None)  # "unavailable" already logged by fetch_active_player itself


async def fetch_current_opponent(normalized_own_name: str) -> tuple[str, dict | None]:
    """UNCHANGED public contract (signature + the same seven statuses). Now
    F78's entry point: /ots-organizer's typed-name lookup (RFC-013 §3.2).
    Resolve the caller's current opponent via RFC-007's Challonge cache
    tables, then reuse `fetch_active_player` verbatim for the final
    `team_text` lookup (RFC-009 §3.2).

    Never raises: any network/timeout/non-200/parse failure maps to
    ("unavailable", None). Returns exactly one of:
      ("ok", player_dict)          -- opponent resolved; player is their OTS row
      ("no_active", None)          -- zero active tournaments
      ("no_challonge_link", None)  -- active tournament has no Challonge link
      ("requester_not_found", None)-- caller absent from cached participants
      ("no_current_match", None)   -- caller found, no open match involves them
      ("opponent_no_ots", None)    -- opponent resolved, but no players row
      ("unavailable", None)        -- any Supabase read failure/timeout
    """
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


async def fetch_opponent_for_profile(discord_user_id: str) -> tuple[str, dict | None]:
    """F76's entry point: /ots resolves the caller from their BOUND profile,
    never from typed input. Nine statuses: fetch_current_opponent's seven
    plus 'not_linked' and 'not_in_tournament'. Never raises (RFC-013 §3.3).

    discord_user_id is TEXT — always str(interaction.user.id).
    """
    try:
        async with _service_session() as session:
            status, tournament = await _fetch_active_tournament_with_link(session)
            if status != "ok":
                return (status, None)
            if tournament["challonge_tournament_id"] is None:
                return ("no_challonge_link", None)

            status, profile_id = await fetch_profile_id(session, discord_user_id)
            if status == "not_linked":
                print(
                    "fetch_opponent_for_profile: no profile bound to discord_user_id "
                    f"{discord_user_id} — /ots refused"
                )
                return ("not_linked", None)
            if status != "ok":
                return (status, None)

            status, row = await _fetch_roster_row_for_profile(session, tournament["id"], profile_id)
            if status != "ok":
                return (status, None)

            status, player = await _resolve_opponent(session, tournament, normalize_name(row["ingame_name"]))
            if status == "requester_not_found":
                print(
                    f"fetch_opponent_for_profile: roster name '{row['ingame_name']}' "
                    f"(profile {profile_id}) absent from challonge_participants_cache "
                    f"for tournament {tournament['id']} — organizer name-discipline gap"
                )
            return (status, player)
    except Exception as exc:
        print(f"fetch_opponent_for_profile: request error: {exc!r}")
        return ("unavailable", None)


async def run_binding(target_discord_user_id: str, display_name: str | None,
                       raw_name: str, confirm_rebind: bool) -> tuple[str, dict]:
    """F58/F59/F60/F61/F71 — the whole /link-organizer network flow. Never
    raises. Returns (status, details) where status is one of 'bind',
    'rebind', 'already_bound_same', 'rebind_needs_confirm',
    'account_slot_taken', 'not_found', 'no_active', 'unavailable', and
    `details` carries what the French reply and the propagation log need.
    """
    details: dict = {
        "name": None,
        "previous_mention": None,
        "other_name": None,
        "profile_id": None,
        "previous_profile_id": None,
        "season_id": None,
        "players_backfilled": 0,
        "results_backfilled": 0,
        "tournament_ids": [],
        "backfill_failed": False,
    }

    try:
        async with _service_session() as session:
            status, active_id = await _fetch_active_tournament_id(session)
            if status != "ok":
                return (status, details)

            status, season_id = await _fetch_current_season_id(session)
            if status == "unavailable":
                return (status, details)
            season_id = season_id if status == "ok" else None
            details["season_id"] = season_id

            season_tournament_ids: list[int] = []
            if season_id is not None:
                status, season_tournament_ids = await _fetch_season_tournament_ids(session, season_id)
                if status != "ok":
                    return (status, details)

            normalized = normalize_name(raw_name)
            if normalized == "":
                return ("not_found", details)

            status, row = await _fetch_roster_row_by_name(session, active_id, normalized)
            if status == "unavailable":
                return (status, details)
            if status == "not_found" and season_id is not None:
                status2, rows = await _fetch_roster_rows_in_tournaments(
                    session, season_tournament_ids, normalized
                )
                if status2 != "ok":
                    return (status2, details)
                row = pick_season_roster_row(rows, season_tournament_ids)
            elif status == "not_found":
                row = None

            if row is not None:
                details["name"] = row["ingame_name"]

            status, target_profile_id = await fetch_profile_id(session, target_discord_user_id)
            if status == "unavailable":
                return (status, details)
            target_profile_id = target_profile_id if status == "ok" else None

            account_slot_taken_by = None
            if row is not None and target_profile_id is not None:
                status, slot = await _fetch_profile_slot_in_tournament(
                    session, row["tournament_id"], target_profile_id
                )
                if status == "unavailable":
                    return (status, details)
                if slot is not None and slot["id"] != row["id"]:
                    account_slot_taken_by = slot["ingame_name"]
            details["other_name"] = account_slot_taken_by

            existing_profile_id = row["profile_id"] if row is not None else None
            decision = resolve_binding_conflict(
                row, existing_profile_id, target_profile_id, account_slot_taken_by, confirm_rebind
            )

            if decision in ("not_found", "account_slot_taken", "already_bound_same", "rebind_needs_confirm"):
                if decision == "already_bound_same":
                    details["profile_id"] = existing_profile_id
                if decision == "rebind_needs_confirm":
                    details["previous_profile_id"] = existing_profile_id
                    status, previous_discord_id = await _fetch_profile_discord_id(session, existing_profile_id)
                    if status == "ok":
                        details["previous_mention"] = f"<@{previous_discord_id}>"
                    else:
                        details["previous_mention"] = f"le profil #{existing_profile_id}"
                return (decision, details)

            # decision in ("bind", "rebind") from here — writes follow.
            if decision == "rebind":
                details["previous_profile_id"] = existing_profile_id

            if target_profile_id is None:
                write_status, rows = await _supabase_write(
                    session, "POST", "profiles",
                    params={"on_conflict": "discord_user_id", "select": "id"},
                    json_body={"discord_user_id": target_discord_user_id, "display_name": display_name},
                    prefer="resolution=merge-duplicates,return=representation",
                )
                if write_status != "ok" or not rows:
                    print(f"run_binding: profile upsert failed for discord_user_id {target_discord_user_id}")
                    return ("unavailable", details)
                target_profile_id = rows[0]["id"]
            details["profile_id"] = target_profile_id

            write_status, rows = await _supabase_write(
                session, "PATCH", "players",
                params={"id": f"eq.{row['id']}", "select": "id"},
                json_body={"profile_id": target_profile_id},
            )
            if write_status != "ok" or not rows:
                print(f"run_binding: players PATCH failed for row {row['id']} -> profile {target_profile_id}")
                return ("unavailable", details)

            players_tournament_ids: list[int] = []
            results_tournament_ids: list[int] = []
            if season_id is not None:
                ids_csv = ",".join(str(i) for i in season_tournament_ids)
                write_status, players_rows = await _supabase_write(
                    session, "PATCH", "players",
                    params={
                        "tournament_id": f"in.({ids_csv})",
                        "ingame_name": f"ilike.{_escape_ilike(normalized)}",
                        "profile_id": "is.null",
                        "select": "id,tournament_id",
                    },
                    json_body={"profile_id": target_profile_id},
                )
                if write_status != "ok":
                    print(f"run_binding: players backfill PATCH failed for profile {target_profile_id}")
                    details["backfill_failed"] = True
                else:
                    details["players_backfilled"] = len(players_rows)
                    players_tournament_ids = sorted({r["tournament_id"] for r in players_rows})

                write_status, results_rows = await _supabase_write(
                    session, "PATCH", "tournament_results",
                    params={
                        "season_id": f"eq.{season_id}",
                        "ingame_name": f"ilike.{_escape_ilike(normalized)}",
                        "profile_id": "is.null",
                        "select": "id,tournament_id",
                    },
                    json_body={"profile_id": target_profile_id},
                )
                if write_status != "ok":
                    print(f"run_binding: tournament_results backfill PATCH failed for profile {target_profile_id}")
                    details["backfill_failed"] = True
                else:
                    details["results_backfilled"] = len(results_rows)
                    results_tournament_ids = sorted({r["tournament_id"] for r in results_rows})

            details["tournament_ids"] = sorted(set(players_tournament_ids) | set(results_tournament_ids))

            rebind_clause = (
                f", rebind_from=profile {details['previous_profile_id']}"
                if decision == "rebind" else ""
            )
            if season_id is None:
                backfill_clause = "season=none, backfill skipped"
            else:
                backfill_clause = (
                    f"players +{details['players_backfilled']} "
                    f"{_format_tournament_ids(players_tournament_ids)}, "
                    f"tournament_results +{details['results_backfilled']} "
                    f"{_format_tournament_ids(results_tournament_ids)}"
                )
            print(
                f"link-organizer: profile {target_profile_id} <- '{normalized}' "
                f"(season {season_id}): {backfill_clause}{rebind_clause}"
            )

            return (decision, details)
    except Exception as exc:
        print(f"run_binding: request error: {exc!r}")
        return ("unavailable", details)


async def run_unlink(discord_user_id: str) -> tuple[str, dict]:
    """F69's command half. Never raises. Returns
    ("ok", {"players": n, "results": m, "profile_id": p}) |
    ("not_linked", {}) | ("unavailable", {})."""
    try:
        async with _service_session() as session:
            status, profile_id = await fetch_profile_id(session, discord_user_id)
            if status == "not_linked":
                return ("not_linked", {})
            if status != "ok":
                return (status, {})

            write_status, players_rows = await _supabase_write(
                session, "PATCH", "players",
                params={"profile_id": f"eq.{profile_id}", "select": "id"},
                json_body={"profile_id": None},
            )
            if write_status != "ok":
                print(f"run_unlink: players PATCH failed for profile {profile_id}")
                return ("unavailable", {})

            write_status, results_rows = await _supabase_write(
                session, "PATCH", "tournament_results",
                params={"profile_id": f"eq.{profile_id}", "select": "id"},
                json_body={"profile_id": None},
            )
            if write_status != "ok":
                print(f"run_unlink: tournament_results PATCH failed for profile {profile_id}")
                return ("unavailable", {})

            write_status, _ = await _supabase_write(
                session, "DELETE", "profiles",
                params={"id": f"eq.{profile_id}"},
            )
            if write_status != "ok":
                print(f"run_unlink: profiles DELETE failed for profile {profile_id}")
                return ("unavailable", {})

            print(
                f"unlink: profile {profile_id} (discord {discord_user_id}) — "
                f"players -{len(players_rows)}, tournament_results anonymized "
                f"{len(results_rows)}, profile deleted"
            )
            return ("ok", {
                "players": len(players_rows),
                "results": len(results_rows),
                "profile_id": profile_id,
            })
    except Exception as exc:
        print(f"run_unlink: request error: {exc!r}")
        return ("unavailable", {})


@tree.command(
    name="ots",
    description="Découvrez l'OTS de votre adversaire actuel",
    guild=discord.Object(id=GUILD_ID),
)
async def ots(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)

    status, player = await fetch_opponent_for_profile(str(interaction.user.id))

    if status != "ok":
        await interaction.followup.send(
            OTS_STATUS_MESSAGES.get(status, OTS_STATUS_MESSAGES["unavailable"]),
            ephemeral=True,
        )
        return

    embed = discord.Embed(
        title=f"OTS de {player['ingame_name']}",
        description=render_team_text(player["team_text"]),
        color=0x3B4CCA,
    )
    if player["pokepaste_url"]:
        embed.url = player["pokepaste_url"]

    try:
        await interaction.user.send(embed=embed)
        await interaction.followup.send(
            "✅ Je vous ai envoyé le lien en message privé !",
            ephemeral=True,
        )
    except discord.Forbidden:
        await interaction.followup.send(
            "⚠️ Je n'ai pas pu vous envoyer un DM. Voici votre OTS :",
            embed=embed,
            ephemeral=True,
        )


@tree.command(
    name="ots-organizer",
    description="[Organisateur] Voir l'adversaire actuel d'un joueur",
    guild=discord.Object(id=GUILD_ID),
)
@app_commands.default_permissions(manage_guild=True)
@app_commands.describe(name="Nom du joueur dans le tournoi")
async def ots_organizer(interaction: discord.Interaction, name: str):
    if not is_organizer(interaction):
        print(f"ots-organizer: refused non-organizer {interaction.user.id}")
        await interaction.response.send_message(
            "❌ Cette commande est réservée à l'organisateur du tournoi.",
            ephemeral=True,
        )
        return

    await interaction.response.defer(ephemeral=True)

    status, player = await fetch_current_opponent(normalize_name(name))
    print(f"ots-organizer: caller {interaction.user.id} queried '{name}' -> status {status}")

    if status == "ok":
        embed = discord.Embed(
            title=f"OTS de {player['ingame_name']}",
            description=render_team_text(player["team_text"]),
            color=0x3B4CCA,
        )
        if player["pokepaste_url"]:
            embed.url = player["pokepaste_url"]
        await interaction.followup.send(
            f"🔎 Diagnostic **{name}** — adversaire actuel : **{player['ingame_name']}**",
            embed=embed,
            ephemeral=True,
        )
        return

    await interaction.followup.send(
        f"🔎 Diagnostic **{name}** — statut : `{status}`. Aucun OTS renvoyé.",
        ephemeral=True,
    )


@tree.command(
    name="link-organizer",
    description="[Organisateur] Relier un compte Discord à un joueur",
    guild=discord.Object(id=GUILD_ID),
)
@app_commands.default_permissions(manage_guild=True)
@app_commands.describe(
    name="Nom du joueur dans le tournoi",
    user="Compte Discord à relier (sélectionnez-le dans la liste)",
    confirm_rebind="Cochez pour remplacer une liaison existante vers un autre compte",
)
async def link_organizer(interaction: discord.Interaction, name: str,
                          user: discord.User, confirm_rebind: bool = False):
    if not is_organizer(interaction):
        print(f"link-organizer: refused non-organizer {interaction.user.id}")
        await interaction.response.send_message(
            "❌ Cette commande est réservée à l'organisateur du tournoi.",
            ephemeral=True,
        )
        return

    await interaction.response.defer(ephemeral=True)

    status, details = await run_binding(str(user.id), user.display_name, name, confirm_rebind)

    if status == "bind":
        reply = f"✅ **{details['name']}** est désormais relié à {user.mention}."
    elif status == "rebind":
        reply = (
            f"✅ **{details['name']}** est désormais relié à {user.mention} "
            "(liaison précédente remplacée)."
        )
    elif status == "already_bound_same":
        reply = f"✅ **{details['name']}** est déjà relié à {user.mention}. Rien à changer."
    elif status == "rebind_needs_confirm":
        reply = (
            f"⚠️ **{details['name']}** est déjà relié à {details['previous_mention']}. "
            "Relancez la commande avec `confirm_rebind` pour remplacer cette liaison."
        )
    elif status == "account_slot_taken":
        reply = f"❌ {user.mention} est déjà relié à **{details['other_name']}** dans ce tournoi."
    elif status == "not_found":
        reply = f"❌ Aucun joueur nommé **{name}** dans le tournoi actif ni dans la saison en cours."
    elif status == "no_active":
        reply = "⚠️ Aucun tournoi actif pour le moment. Impossible de relier un joueur."
    else:
        reply = "⚠️ Service momentanément indisponible. Réessayez dans un instant."

    if status in ("bind", "rebind") and details.get("backfill_failed"):
        reply += "\n⚠️ Liaison faite, mais l'historique n'a pas pu être rattaché — voir les logs."

    await interaction.followup.send(reply, ephemeral=True)


@tree.command(
    name="unlink",
    description="Supprimer la liaison entre votre compte Discord et votre profil joueur",
    guild=discord.Object(id=GUILD_ID),
)
@app_commands.describe(confirm="Confirmez : cela désactivera aussi votre commande /ots")
async def unlink(interaction: discord.Interaction, confirm: bool):
    await interaction.response.defer(ephemeral=True)

    if not confirm:
        await interaction.followup.send(
            "⚠️ **Attention :** supprimer votre liaison désactivera aussi la commande "
            "`/ots` — vous ne pourrez plus voir l'OTS de votre adversaire tant que "
            "l'organisateur ne vous aura pas relié à nouveau. Relancez la commande avec "
            "`confirm` si c'est bien ce que vous voulez.",
            ephemeral=True,
        )
        return

    status, result = await run_unlink(str(interaction.user.id))

    if status == "not_linked":
        await interaction.followup.send(
            "ℹ️ Votre compte Discord n'est relié à aucun profil joueur. Rien à supprimer.",
            ephemeral=True,
        )
        return
    if status == "unavailable":
        await interaction.followup.send(
            "⚠️ Service momentanément indisponible. Réessayez dans un instant.",
            ephemeral=True,
        )
        return

    await interaction.followup.send(
        "✅ Liaison supprimée. Vos résultats passés restent au classement sous votre nom "
        "de joueur, mais la commande `/ots` ne fonctionnera plus tant que l'organisateur "
        "ne vous aura pas relié à nouveau.",
        ephemeral=True,
    )


@client.event
async def on_ready():
    await tree.sync(guild=discord.Object(id=GUILD_ID))
    print(f"Bot connecté en tant que {client.user}")


if __name__ == "__main__":
    client.run(TOKEN)
