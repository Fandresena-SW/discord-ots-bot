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


@tree.command(
    name="ots",
    description="Obtenir l'OTS associé à un nom d'utilisateur",
    guild=discord.Object(id=GUILD_ID),
)
@app_commands.describe(username="Le nom d'utilisateur dont vous souhaitez obtenir l'OTS")
async def ots(interaction: discord.Interaction, username: str):
    await interaction.response.defer(ephemeral=True)

    normalized = normalize_name(username)
    status, player = await fetch_active_player(normalized)

    if status == "no_active":
        await interaction.followup.send(
            "⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.",
            ephemeral=True,
        )
        return
    if status == "unavailable":
        await interaction.followup.send(
            "⚠️ Service momentanément indisponible. Réessayez dans un instant.",
            ephemeral=True,
        )
        return
    if status == "not_found":
        await interaction.followup.send(
            f"❌ Aucun joueur nommé **{username}** dans le tournoi en cours.",
            ephemeral=True,
        )
        return

    embed = discord.Embed(
        title=f"OTS de {username}",
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
