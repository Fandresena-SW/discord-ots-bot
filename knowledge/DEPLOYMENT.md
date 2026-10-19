# DEPLOYMENT — Running the bot on a VPS (Contabo-style root VPS, systemd)

- **Status:** Production moved to a new VPS on 2026-10-19 (previously Oracle
  Cloud, now retired). §12 (Challonge sync Edge Function deploy) added by
  RFC-010 and is unaffected by the move.
- **Host in use:** a plain Ubuntu VPS, provisioned with a `root` login.
  Hostname `vmi3677843`, IP `161.97.171.179`.
- **Process model:** the app runs as a **systemd service**
  (`discord-ots-bot`) under an unprivileged user, **`botuser`**, with the repo
  at `/home/botuser/discord-ots-bot`. (The `Procfile` is kept in the repo as a
  portable process-type declaration for a possible PaaS target; it is not
  what production uses.) The Challonge sync Edge Function (§12) is a
  **separate deployment target** (Supabase itself, not the VPS).

This doc captures the exact steps used to stand up the bot, so a redeploy, a
VPS rebuild, or another move doesn't have to rediscover them. The previous
Oracle Cloud setup's pitfalls are kept in §11 for history.

---

## 1. Why a self-managed VPS

The bot is a single lightweight background process (one persistent Discord
Gateway WebSocket + outbound HTTPS to Supabase) with **no inbound traffic**
other than the operator's own SSH. A small always-on VPS is a better fit than
a trial-only PaaS. See `.claude/RULES.md` /
`knowledge/RFCs/RFC-006-Reliability-And-Release.md` for the reliability story
(pre-flight checklist, break-glass, Supabase free-tier pause risk) — this doc
only covers getting the process running.

---

## 2. Provision the VPS

Any Ubuntu **22.04 or 24.04 LTS** image works (Python 3.10+ is required by
the `str | None` hints in `bot.py`; 20.04's Python 3.8 is not enough — see
§7). The provider hands over a public IP and a `root` credential; no cloud
console networking steps are needed.

---

## 3. Connect

```bash
ssh root@161.97.171.179
```

Optionally install your key so you aren't prompted for the password:
`ssh-copy-id root@161.97.171.179`. Day-to-day work (deploys, logs) happens as
`botuser`; root is only needed for the one-time setup below and the service
unit.

---

## 4. Base system setup (as root, once)

```bash
apt update && apt upgrade -y
apt install -y python3 python3-venv python3-pip git ufw

# Unprivileged service user. --disabled-password means it has NO password,
# so it cannot use sudo unless a sudoers rule grants it (see §9).
adduser --disabled-password --gecos "" botuser

# The bot only makes outbound connections; only SSH needs to be open.
ufw allow OpenSSH && ufw --force enable
```

---

## 5. Clone the repo and install dependencies (as `botuser`)

```bash
su - botuser
git clone https://github.com/Fandresena-SW/discord-ots-bot.git
cd discord-ots-bot
python3 -m venv venv
venv/bin/pip install -r requirements.txt
exit
```

If the repo is private, the clone needs credentials (a GitHub deploy key or a
personal access token).

---

## 6. Create `.env` on the server

**Never commit real secrets.** Copy the file from your workstation (so the
values never pass through git or a chat), **from your own machine**:

```bash
scp /path/to/discord-ots-bot/.env root@161.97.171.179:/home/botuser/discord-ots-bot/.env
```

Then, on the VPS as root:

```bash
chown botuser:botuser /home/botuser/discord-ots-bot/.env
chmod 600 /home/botuser/discord-ots-bot/.env
```

Required vars: `DISCORD_TOKEN`, `GUILD_ID`, `SUPABASE_URL`,
`SUPABASE_SERVICE_KEY`, `ORGANIZER_DISCORD_ID` (the bot refuses to start
without all five). See `.env.example` and `knowledge/RUNBOOK.md` §0 for where
the Supabase values come from, and the warning there about using the
**secret** key, never the **publishable** one.

---

## 7. Python-version compatibility note

`bot.py` uses PEP 604 union type hints (`str | None`, etc.) in function
signatures. These are evaluated **eagerly** on Python < 3.10, which raises
`TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'` at
import time on an older interpreter.

The fix committed to the repo is `from __future__ import annotations` at the
top of `bot.py`, which makes all annotations lazy strings, so the file
imports cleanly on Python 3.8+ with no behavior change. On 22.04+/24.04 this
never bites, but the shim is harmless either way.

---

## 8. Run as a systemd service (as root, once)

Create `/etc/systemd/system/discord-ots-bot.service`:

```ini
[Unit]
Description=Discord OTS Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=botuser
WorkingDirectory=/home/botuser/discord-ots-bot
ExecStart=/home/botuser/discord-ots-bot/venv/bin/python3 bot.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`bot.py` loads `.env` via `python-dotenv` from its working directory, so no
`EnvironmentFile=` directive is needed — just a correct `WorkingDirectory`.

```bash
systemctl daemon-reload
systemctl enable --now discord-ots-bot
systemctl status discord-ots-bot --no-pager -l
```

Do this **before** the first `./deploy.sh`: the script's restart step fails
with `Unit discord-ots-bot.service not found` otherwise.

**Never run two instances on the same `DISCORD_TOKEN`** (e.g. a leftover old
host, or a local `python bot.py`): both answer every interaction. Stop the
other one first.

---

## 9. Redeploying a code change

`deploy.sh` (repo root) pulls, reinstalls dependencies into the venv,
restarts the service, and tails the logs. Run it **as `botuser`, without
`sudo` in front** — it calls `sudo systemctl` itself, and running the whole
script as root would make `git pull` create root-owned files.

`botuser` has no password, so it needs a sudoers rule allowing exactly the
two service commands the script runs (as root, once):

```bash
cat > /etc/sudoers.d/botuser <<'SUDOERS'
botuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart discord-ots-bot, /usr/bin/systemctl status discord-ots-bot --no-pager -l
SUDOERS
chmod 440 /etc/sudoers.d/botuser
visudo -c
```

(If `which systemctl` prints a different path, use that path.) Then:

```bash
ssh root@161.97.171.179
su - botuser
cd discord-ots-bot
./deploy.sh        # Ctrl+C to stop the log tail
```

It assumes the service is named `discord-ots-bot` and the venv is at
`<repo>/venv`; adjust `SERVICE_NAME` at the top of the script otherwise.

---

## 10. Monitoring & logs

```bash
systemctl status discord-ots-bot --no-pager  # current state
journalctl -u discord-ots-bot -f             # live tail
journalctl -u discord-ots-bot -n 50          # last 50 lines
```

(Reading the journal as `botuser` may require membership in the
`systemd-journal` group; as root it always works.)

A healthy start shows `discord.client: logging in using static token`
followed by `discord.gateway: Shard ID None has connected to Gateway`. A
crash loop (`Scheduled restart job, restart counter is at N`) means the
process is exiting immediately — check the traceback right above the restart
line first.

---

## 11. Troubleshooting log

**New VPS (2026-10-19):**

- **`./deploy.sh` → `Unit discord-ots-bot.service not found`** — the systemd
  unit (§8) hadn't been created yet. Create it, then redeploy.
- **`sudo` asks for a password as `botuser`** — the user was created with
  `--disabled-password`, so there is none. Add the sudoers rule in §9; do not
  run `sudo ./deploy.sh`.

**Historical — the retired Oracle Cloud (OCI) deployment**, kept so the same
pitfalls aren't rediscovered on another provider:

- **`ssh: ... Unable to negotiate ... no matching host key type found. Their
  offer: ssh-rsa`** — only happens on the **serial console** tunnel command
  (§4), not on normal SSH to the public IP. Fix: add
  `-o HostKeyAlgorithms=+ssh-rsa` to both the outer `ssh` and the inner
  `ProxyCommand` ssh in that specific command.
- **Reserved public IP created but instance still shows no public IP** — the
  IP was reserved but never attached. The reserved-IP's own list/details page
  in some console versions has no reliable "Attach" action; attach it from
  the **instance's Networking tab → VNIC → private IP → edit** instead (§3).
- **`TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'`**
  at `bot.py` import — Python < 3.10 on the host (Ubuntu 20.04's system
  `python3` is 3.8). Fixed at the code level (§7); avoid by provisioning
  22.04+/24.04 in the first place.
- **`add-apt-repository ppa:deadsnakes/ppa` then `apt install python3.11`
  fails with "Unable to locate package"** — on Ubuntu 20.04 the PPA add can
  fail silently (commonly a blocked/unreachable GPG keyserver on cloud
  egress), leaving no new sources file even though the command reported
  success. Rather than debugging PPA/keyserver plumbing, the repo-level fix
  in §7 sidesteps needing a newer Python at all.

---

## 12. Deploying the Challonge sync Edge Function

The v3.0 addendum (RFC-007–010) adds the project's **first non-Python
deployment target**: a Supabase Edge Function
(`supabase/functions/challonge-sync/`, TypeScript/Deno) that the organizer
triggers manually via `curl` (see `knowledge/RUNBOOK.md` §8) to refresh the
Challonge participant/match cache. This is deployed to Supabase itself, not
to the VPS — `bot.py` never talks to Challonge and needs no changes to
support it (RULES §12).

### Prerequisites

- The [Supabase CLI](https://supabase.com/docs/guides/cli) installed locally
  (or on whichever machine you deploy from — this does **not** need to be the
  VPS).
- The local repo linked to the Supabase project (once per clone/machine):
  ```bash
  supabase login
  supabase link --project-ref <project-ref>
  ```
  (`<project-ref>` is the subdomain in the project's `SUPABASE_URL`, e.g.
  `abcdefghijklmnop` from `https://abcdefghijklmnop.supabase.co`.)

### Secrets provisioning (once per environment, never committed)

The function needs two secrets, set directly on the Supabase project — never
in a file tracked by git (mirrors the `.env`-on-the-server posture in §6
above):

```bash
supabase secrets set CHALLONGE_API_KEY=<your Challonge API key>
supabase secrets set CHALLONGE_SYNC_SECRET=<a secret you generate, used by the runbook's curl trigger>
```

`supabase/functions/challonge-sync/.env.example` documents the same two
names for local reference; `.env.local` (used only by `supabase functions
serve` for local dev) is git-ignored, same as the bot's own `.env`.

### Deploy / redeploy

```bash
supabase functions deploy challonge-sync
```

Re-run this any time `supabase/functions/challonge-sync/*.ts` changes — there
is no separate build step and no restart needed on the VPS.

### Verifying a deploy

Run the trigger command documented in `knowledge/RUNBOOK.md` §8 against a
known test tournament (e.g. the RFC-007 seed tournament) and confirm a `200`
with the expected counts:

```bash
curl -X POST "https://<project-ref>.supabase.co/functions/v1/challonge-sync" \
  -H "Content-Type: application/json" \
  -H "x-challonge-sync-secret: <CHALLONGE_SYNC_SECRET>" \
  -d '{"tournament_id": <id Supabase du tournoi de test>}'
```

Expect `{"status":"ok","participants_synced":N,"matches_synced":M,"freeze":{...}}`
— since RFC-012 the response also carries a `freeze` object reporting the
results-freeze attempt (does not affect the cache refresh, which still
succeeds independently). See `knowledge/RUNBOOK.md` §8 step 4 for the
error-shape table (401/400/404/502) if it doesn't come back clean.

### Troubleshooting log

Real issues hit in production, appended here as they happen (not
speculatively — mirrors §11 above's pattern). Empty as of this RFC's
release; the first real incident goes here.

---

## 13. Self-hosted Supabase stack (RFC-015)

The database runs on **this same VPS** as a Docker Compose stack under
`/opt/supabase`, replacing the hosted Supabase project. Everything this
project adds on top of upstream lives in the repo under `deploy/supabase/`;
upstream's compose is **not** vendored — it is fetched by upstream's own
`setup.sh` and pinned by `/opt/supabase/.supabase-version`
(`self-hosted/v0.8.3` at install).

### Layout and what runs

| Piece | Where |
|---|---|
| Project dir (compose, `.env`, volumes) | `/opt/supabase` |
| Our overlay, Caddyfile, scripts | `/opt/supabase/ots/` (copied from `deploy/supabase/`) |
| Nightly backups | `/var/backups/supabase/` |
| Function sources | `/opt/supabase/volumes/functions/challonge-sync/` |

Seven containers: `db` (Postgres 17), `rest` (PostgREST), `meta`, `studio`,
`api-gw` (**Envoy**, upstream's default gateway — not Kong), `functions`
(edge runtime) and `caddy`. Auth, Realtime, Storage, imgproxy and the pooler
are disabled in `docker-compose.ots.yml` (they sit under an unused
`profiles` entry). `COMPOSE_FILE` in `/opt/supabase/.env` layers
`docker-compose.yml : docker-compose.caddy.yml : ots/docker-compose.ots.yml`.

### Exposure (what is and is not public)

- Public: **22, 80, 443** only. Caddy serves `https://161-97-171-179.sslip.io`
  (wildcard DNS to the VPS IP, real Let's Encrypt certificate).
- The gateway is published on **`127.0.0.1:8000` only**; that is the bot's
  `SUPABASE_URL`. **Docker bypasses `ufw`** — a port published as
  `"5432:5432"` would be open to the internet whatever `ufw` says, so every
  published port must carry `127.0.0.1:`.
- Caddy (`deploy/supabase/caddy/Caddyfile`) is an **allow-list**:
  `POST /functions/v1/challonge-sync` is proxied (the function authenticates
  itself with `x-challonge-sync-secret`); `/rest`, `/auth`, `/storage`,
  `/realtime`, every other `/functions/v1/*` path and `/mcp` return 404;
  everything else is Studio behind basic auth. Upstream's own Caddyfile
  proxies `/rest/v1` publicly — do not swap it back in.
- Verify exposure from the **server** (`ss -ltnH`, `iptables -t nat -S DOCKER`),
  not from a laptop on a VPN: a VPN can make every port look open.

### Secrets

All in `/opt/supabase/.env` (`chmod 600`, root only, never committed). Names
that matter:

- `SERVICE_ROLE_KEY` — the **legacy HS256** key. The bot's
  `SUPABASE_SERVICE_KEY` is this value. (Upstream now also issues an opaque
  `sb_secret_…` key; the bot and the function send their key as both `apikey`
  and `Bearer`, which the legacy JWT satisfies with no code change.)
- `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` — Studio and Caddy basic auth.
- `STUDIO_DEFAULT_PROJECT` — the project name Studio displays (`discord-ots-bot`).
  Self-hosted Studio has no UI to rename it; edit this and run
  `docker compose up -d studio`.
- `CHALLONGE_API_KEY`, `CHALLONGE_SYNC_SECRET` — passed to the `functions`
  container by the overlay. There is no `supabase secrets set` on self-hosted.
  After editing: `cd /opt/supabase && docker compose up -d functions`.
- **Generating keys prints them.** `setup.sh` and `utils/*.sh` write secrets
  to stdout; redirect or filter that output, and never run them in a session
  whose output is logged.

### Edge Function deploy

`deploy/supabase/sync-functions.sh [root@<vps>]` copies the function's `.ts`
files (tests excluded) into the functions volume. No restart: edge-runtime
starts a worker per request. The upstream `main` router verifies JWTs only when
`FUNCTIONS_VERIFY_JWT=true`; it is `false` here (the upstream default, and
required — the organizer's `curl` sends no `Authorization` header).

The trigger URL is `https://161-97-171-179.sslip.io/functions/v1/challonge-sync`;
path, headers, body and response are unchanged from §12.

### Database privileges

The self-hosted Postgres image's default ACL grants `anon`/`authenticated`
full privileges on new `public` tables (RLS, enabled with zero policies, is
all that kept them at `200 []`). Migration
`20261019000000_revoke_anon_authenticated_public` revokes that, for existing
tables and future ones. After it, `anon` gets `42501 permission denied`.

### Backups and restore

`deploy/supabase/backup.sh` (systemd timer `ots-backup.timer`, 03:15 UTC,
persistent) writes a custom-format `pg_dump` of `public` + `supabase_migrations`
to `/var/backups/supabase/ots-<UTC-timestamp>.dump`, checks the archive with
`pg_restore --list`, and deletes dumps older than 14 days. The VPS provider's
auto-backups capture that directory; a snapshot of a running Postgres is only
crash-consistent, so the dump is the artifact guaranteed to restore.

Restore into a **fresh** database (the flags matter — without `--clean
--if-exists` the archive's `CREATE SCHEMA public` fails):

```bash
docker exec supabase-db psql -U supabase_admin -d postgres -c "create database restore_test"
docker exec -i supabase-db pg_restore -U supabase_admin -d restore_test \
  --clean --if-exists --no-owner --exit-on-error < /var/backups/supabase/ots-<ts>.dump
```

A restore drill (backup, restore to a scratch DB, compare per-table content
checksums, drop the scratch DB) passed on 2026-10-19.

### Data migration procedure (hosted → self-hosted)

Used for the RFC-015 cutover; reusable for any reload. Postgres is 17 on both
sides, and `supabase_admin` (superuser) is needed for the restore.

1. Stop the bot (no writes in flight).
2. `pg_dump "<hosted session-pooler URL>" -a -n public -Fc --no-owner` run
   through `docker exec supabase-db` (the container has the v17 client). Use
   the **session pooler** string — the direct host is IPv6-only.
3. Truncate every `public` table (`restart identity cascade`) as
   `supabase_admin`, then `pg_restore -a --disable-triggers --no-owner
   --exit-on-error`. **Triggers must be disabled**: `players_autolink_profile`
   would otherwise rewrite imported rows. Truncation is required because the
   tier reference rows already exist from the migration.
4. Compare per-table `md5` of sorted `to_jsonb(row)` on both sides; use
   `to_jsonb`, not `row::text`, because column *position* differs for
   `challonge_participants_cache.challonge_group_player_id` (added by `ALTER`
   on hosted, inline in the baseline migration) — harmless, restore is by name.
5. Point the bot at `http://127.0.0.1:8000` with the self-hosted
   `SERVICE_ROLE_KEY`; restart it.

**Rollback:** restore the previous `.env` values (`SUPABASE_URL`,
`SUPABASE_SERVICE_KEY`) and restart. Clean only while no writes have happened
on the self-hosted side: `/link-organizer`, `/unlink` and synced cache rows
made afterwards do not exist on hosted.

### Operations

```bash
cd /opt/supabase
docker compose ps                       # all seven should be healthy
sh run.sh logs <service>                # follow one service
systemctl list-timers ots-backup.timer  # next backup
```

Upgrade: back up first, then `sh update.sh --dry-run`, `sh update.sh`,
`sh run.sh pull && sh run.sh recreate`. Re-check `docker compose config`
published ports afterwards — an upstream change must not re-publish a port
without `127.0.0.1:`.

### Troubleshooting log (self-hosted)

- **`challonge_*_cache.fetched_at` never advances on re-sync** — pre-existing
  (also true on hosted): the function's `merge-duplicates` upsert never sets
  the column, so it keeps its insert-time default. The F36 staleness warning
  therefore cannot reflect a refresh. Not caused by the migration; fix is to
  include `fetched_at` in the upsert payload.
- **`pg_restore: schema "public" already exists`** — missing `--clean
  --if-exists` (see Backups and restore).
- **A script piped to `ssh host bash -s` stops partway** — a command inside it
  that reads stdin (`docker exec -i`, `ssh`) swallows the rest of the script.
  Redirect its input explicitly (`< file`) or drop `-i`.
- **`read -p` under zsh** — zsh uses `read "VAR?prompt"`; and the `!` prefix
  in Claude Code has no terminal, so interactive prompts return empty. Run
  prompting commands in a real terminal.

---

## References

- `CLAUDE.md` — "Run locally" section, config/env var reference.
- `.env.example` — exact env var names.
- `knowledge/RUNBOOK.md` §0 — Supabase project bootstrap, where the
  `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` values come from.
- `knowledge/RFCs/RFC-006-Reliability-And-Release.md` — pre-flight checklist,
  break-glass procedure, and E2E release gate that apply once the bot is
  running (this doc only covers getting the process up).
- `Procfile` — the portable `worker: python3 bot.py` process-type
  declaration, unused by the current systemd-based deployment but kept for a
  possible future PaaS target.
- `knowledge/RUNBOOK.md` §8 — the organizer's Challonge linking + trigger
  procedure, which references §12 above for the Edge Function's own deploy
  path.
- `knowledge/RFCs/RFC-008-Challonge-Sync-Edge-Function.md`,
  `knowledge/RFCs/RFC-010-Runbook-Staleness-Release.md` — the Edge Function's
  design and this deploy section's origin.
- `supabase/functions/challonge-sync/` — the Edge Function source
  (`index.ts`, `mapping.ts`, `.env.example`) referenced by §12 above.
