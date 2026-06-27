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
import datetime
import discord
from discord import app_commands
from discord.ext import tasks
from dotenv import load_dotenv

load_dotenv()

TOKEN = os.getenv("DISCORD_TOKEN")
GUILD_ID = int(os.getenv("GUILD_ID"))

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

    try:
        await interaction.user.send(f"🔗 OTS de **{username}** : {url}")
        await interaction.response.send_message(
            "✅ Je vous ai envoyé le lien en message privé !",
            ephemeral=True,
        )
    except discord.Forbidden:
        await interaction.response.send_message(
            f"⚠️ Je n'ai pas pu vous envoyer un DM. OTS de **{username}** : {url}",
            ephemeral=True,
        )


@tasks.loop(minutes=1)
async def heartbeat():
    print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] Bot en ligne — {len(client.guilds)} serveur(s)")


@client.event
async def on_ready():
    await tree.sync(guild=discord.Object(id=GUILD_ID))
    print(f"Bot connecté en tant que {client.user}")
    heartbeat.start()


client.run(TOKEN)
