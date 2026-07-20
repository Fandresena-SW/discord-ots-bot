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
     SUPABASE_URL et SUPABASE_SERVICE_KEY
  4. pip install -r requirements.txt
  5. Gérer le tournoi actif et les joueurs depuis Supabase Studio
     (voir knowledge/RUNBOOK.md)
  6. python bot.py
"""

from __future__ import annotations

import os
import re
import sys
import aiohttp
import discord
from discord import app_commands
from dotenv import load_dotenv

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
_GUILD_ID_RAW = os.getenv("GUILD_ID")
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")


def validate_config(discord_token: str | None, guild_id_raw: str | None,
                     supabase_url: str | None, supabase_service_key: str | None) -> int:
    """Fail fast at boot if any required config is missing or invalid.

    Prints a clear English operator error naming the missing/invalid var(s)
    (never the values themselves) and exits the process (non-zero) on
    failure. Returns the parsed GUILD_ID on success.
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

    if missing:
        print(f"Config error: missing required env var(s): {', '.join(missing)}")
        sys.exit(1)

    try:
        return int(guild_id_raw)
    except ValueError:
        print("Config error: GUILD_ID must be an integer")
        sys.exit(1)


# Runs at module load (before the @tree.command decorator below reads
# GUILD_ID) so a missing/invalid var fails fast at boot, not on first /ots.
GUILD_ID = validate_config(TOKEN, _GUILD_ID_RAW, SUPABASE_URL, SUPABASE_SERVICE_KEY)

# Discord embed *description* character limit (fence + marker counted against it).
DISCORD_DESC_LIMIT = 4096
# French truncation marker (user-facing text is always French). Appended
# inside the fence so it renders as visible text, not after a broken fence.
TRUNCATION_MARKER = "\n… (équipe tronquée)"

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
                                 normalized_name: str) -> tuple[str, int | None]:
    """Resolve `normalized_name`'s cached Challonge participant id within
    `tournament_id`. Returns ("ok", id), ("requester_not_found", None), or
    ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/challonge_participants_cache"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "ingame_name": f"ilike.{_escape_ilike(normalized_name)}",
        "select": "challonge_participant_id",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_current_opponent: participants query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["challonge_participant_id"]) if rows else ("requester_not_found", None)


async def _fetch_open_matches(session: aiohttp.ClientSession, tournament_id,
                               participant_id: int) -> tuple[str, list[dict]]:
    """Return the (at most one, DB-side highest-`round`-first) `open` match
    rows involving `participant_id`. Returns ("ok", rows) or
    ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/challonge_matches_cache"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "state": "eq.open",
        "or": f"(player1_challonge_id.eq.{participant_id},player2_challonge_id.eq.{participant_id})",
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
    """Resolve a cached Challonge participant id back to its `ingame_name`.
    Returns ("ok", name), ("not_found", None), or ("unavailable", None)."""
    url = f"{SUPABASE_URL}/rest/v1/challonge_participants_cache"
    params = {
        "tournament_id": f"eq.{tournament_id}",
        "challonge_participant_id": f"eq.{participant_id}",
        "select": "ingame_name",
        "limit": "1",
    }
    async with session.get(url, params=params) as resp:
        if resp.status != 200:
            print(f"fetch_current_opponent: participant-name query failed (status {resp.status})")
            return ("unavailable", None)
        rows = await resp.json()
    return ("ok", rows[0]["ingame_name"]) if rows else ("not_found", None)


def pick_opponent_id(own_id: int, matches: list[dict]) -> int | None:
    """Pure logic (RFC-009 §7): given the caller's cached participant id and
    candidate `open` match rows (each with `player1_challonge_id`,
    `player2_challonge_id`, `round`), pick the opponent's id.

    - Empty `matches` -> None (no current match).
    - More than one row -> the highest `round` wins (defensive tie-break;
      the live query already sorts/limits this way, but this function is
      written to resolve it independently so it's unit-testable in isolation).
    - Degenerate rows (own id not actually on either side, both sides equal
      the caller, or the other side is null/bye) -> None, rather than
      crashing or returning a nonsensical opponent.
    """
    if not matches:
        return None
    match = max(matches, key=lambda m: m.get("round") or 0)
    p1, p2 = match.get("player1_challonge_id"), match.get("player2_challonge_id")
    if p1 == own_id and p2 is not None and p2 != own_id:
        return p2
    if p2 == own_id and p1 is not None and p1 != own_id:
        return p1
    return None


async def fetch_current_opponent(normalized_own_name: str) -> tuple[str, dict | None]:
    """Resolve the caller's current opponent via RFC-007's Challonge cache
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
    headers = {
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
    }
    timeout = aiohttp.ClientTimeout(total=5)

    try:
        async with aiohttp.ClientSession(headers=headers, timeout=timeout) as session:
            status, tournament = await _fetch_active_tournament_with_link(session)
            if status != "ok":
                return (status, None)
            tournament_id = tournament["id"]
            if tournament["challonge_tournament_id"] is None:
                return ("no_challonge_link", None)

            status, own_id = await _fetch_participant_id(session, tournament_id, normalized_own_name)
            if status != "ok":
                return (status, None)

            status, matches = await _fetch_open_matches(session, tournament_id, own_id)
            if status != "ok":
                return (status, None)

            opponent_id = pick_opponent_id(own_id, matches)
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
    except Exception as exc:
        print(f"fetch_current_opponent: request error: {exc!r}")
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


@tree.command(
    name="ots",
    description="Découvrez l'OTS de votre adversaire actuel",
    guild=discord.Object(id=GUILD_ID),
)
@app_commands.describe(username="Votre propre nom d'utilisateur dans le tournoi (pas celui de votre adversaire)")
async def ots(interaction: discord.Interaction, username: str):
    await interaction.response.defer(ephemeral=True)

    normalized = normalize_name(username)
    status, player = await fetch_current_opponent(normalized)

    if status == "no_active":
        await interaction.followup.send(
            "⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.",
            ephemeral=True,
        )
        return
    if status == "no_challonge_link":
        await interaction.followup.send(
            "❌ Ce tournoi n'est pas relié à Challonge. Impossible de déterminer votre adversaire actuel.",
            ephemeral=True,
        )
        return
    if status == "requester_not_found":
        await interaction.followup.send(
            f"❌ Aucun participant nommé **{username}** trouvé dans le bracket Challonge de ce tournoi.",
            ephemeral=True,
        )
        return
    if status == "no_current_match":
        await interaction.followup.send(
            "ℹ️ Vous n'avez pas de match en cours pour le moment.",
            ephemeral=True,
        )
        return
    if status == "opponent_no_ots":
        await interaction.followup.send(
            "⚠️ Votre adversaire a été trouvé, mais son OTS n'est pas encore enregistré. Contactez l'organisateur.",
            ephemeral=True,
        )
        return
    if status == "unavailable":
        await interaction.followup.send(
            "⚠️ Service momentanément indisponible. Réessayez dans un instant.",
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


@client.event
async def on_ready():
    await tree.sync(guild=discord.Object(id=GUILD_ID))
    print(f"Bot connecté en tant que {client.user}")


if __name__ == "__main__":
    client.run(TOKEN)
