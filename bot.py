"""
Bot Discord - Commande /ots
============================
Setup :
  1. Créer un bot sur https://discord.com/developers/applications
     → Onglet "Bot" : copier le token
     → Activer "Message Content Intent" et "Server Members Intent"
  2. Inviter le bot avec les scopes : bot + applications.commands
     Permission requise : Send Messages
  3. Copier .env.example → .env et renseigner DISCORD_TOKEN et GUILD_ID
  4. pip install -r requirements.txt
  5. Modifier USERNAME_URLS ci-dessous avec vos propres entrées
  6. python bot.py
"""

import os
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

# --- Personnalisez ce dictionnaire ---
USERNAME_URLS: dict[str, str] = {
    "giovlacouture": "https://pokepast.es/6b0e9bdcbf2c6a73",
    "zou":           "https://pokepast.es/091b94622a4ef357",
    "jornojovanna":  "https://pokepast.es/e86a5b005eed0d00",
    "koloina":       "https://pokepast.es/75f754ff0ccdd506",
    "kantooo":       "https://pokepast.es/e66188e1925d05e9",
    "bidoof":        "https://pokepast.es/f935327c7b11cc8a",
    "handsome":      "https://pokepast.es/799b45fcf33b66a4",
    "mazino":        "https://pokepast.es/ce0f3bc348b29fa0",
    "anonymespy":    "https://pokepast.es/20c9539a01265a52",
}
# -------------------------------------

intents = discord.Intents.default()
client = discord.Client(intents=intents)
tree = app_commands.CommandTree(client)


async def fetch_pokepaste(url: str) -> list[str]:
    import re
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status != 200:
                    return []
                html = await resp.text()
    except Exception:
        return []

    sets = []
    for pre in re.findall(r"<pre>(.*?)</pre>", html, re.DOTALL):
        clean = re.sub(r"<[^>]+>", "", pre)
        lines = [line.rstrip() for line in clean.split("\n")]
        while lines and not lines[-1]:
            lines.pop()
        if lines:
            sets.append("\n".join(lines))

    return sets[:6]


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
    url = USERNAME_URLS.get(username.lower())

    if url is None:
        await interaction.response.send_message(
            f"❌ Nom d'utilisateur non reconnu : **{username}**.",
            ephemeral=True,
        )
        return

    await interaction.response.defer(ephemeral=True)

    sets = await fetch_pokepaste(url)
    description = "```\n" + "\n\n".join(sets) + "\n```" if sets else ""

    embed = discord.Embed(
        title=f"OTS de {username}",
        url=url,
        description=description,
        color=0x3B4CCA,
    )

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
