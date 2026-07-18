# DEPLOYMENT — Running the bot on a cloud VM (Oracle Cloud Free Tier)

- **Status:** Production deployment documented (2026-07-18).
- **Host in use:** Oracle Cloud Infrastructure (OCI) **Always Free** compute
  instance, Ubuntu, region `eu-paris-1`.
- **Process model:** the app is started as a **systemd service** on the VM
  (not the Heroku/Railway/Render-style `Procfile` worker described in
  `CLAUDE.md`'s "Run locally" section — the `Procfile` is kept in the repo as
  a portable process-type declaration in case a PaaS target is used later, but
  the current production deployment is this self-managed VM).

This doc captures the exact steps used to stand up the bot on OCI, so a
redeploy, a VM rebuild, or a move to a fresh instance doesn't have to
rediscover the same pitfalls (public IP attachment, the Python-version trap
on older Ubuntu images, the console-vs-SSH host-key confusion).

---

## 1. Why Oracle Cloud

The bot is a single lightweight background process (one persistent Discord
Gateway WebSocket + outbound HTTPS to Supabase) with **no inbound traffic**
other than the operator's own SSH. Railway's free tier is trial-only; OCI's
**Always Free** tier includes a real compute instance for free indefinitely,
which is a better fit for a process that just needs to stay up. See
`.claude/RULES.md` / `knowledge/RFCs/RFC-006-Reliability-And-Release.md` for
the reliability story once deployed (pre-flight checklist, break-glass,
Supabase free-tier pause risk) — this doc only covers getting the process
itself running.

---

## 2. Provision the instance

1. OCI Console → **Compute → Instances → Create instance**.
2. **Image: use Ubuntu 22.04 or 24.04 LTS**, not 20.04 ("focal"). 20.04 ships
   Python 3.8 as the system `python3`, which cannot import `bot.py` as-written
   without the compatibility shim described in §7 below — 22.04+ ships Python
   3.10+ and needs no workaround. (Oracle's "Autonomous Linux" image also
   works but has less predictable package-manager behavior than plain Ubuntu;
   prefer stock Ubuntu.)
3. Shape: any **Always Free**-eligible shape (e.g. `VM.Standard.A1.Flex` or
   the free `VM.Standard.E2.1.Micro`) is sufficient for this workload.
4. Keep the generated SSH key pair — you'll need it for every future
   connection (`ssh -i <key> ubuntu@<public-ip>`).

---

## 3. Attach a public IP

A freshly created instance often has **no public IP** yet (shows `-` on the
instance's Details tab under "Public IP address").

1. Reserve one: **Networking → IP Management → Reserved public IPs → Reserve
   public IP address**. Reserved (not ephemeral) so it survives instance
   stop/start.
2. Attaching it from the **reserved IP's own page** does not expose an
   "Attach" action reliably in every console version. The dependable path is
   from the **instance side**: instance → **Networking** tab → primary VNIC
   → the **Public IPv4 address** row → its edit/pencil icon → select the
   existing reserved IP (or create+attach in one step if offered there).
3. Confirm: the instance's **Details** tab now shows the public IP instead
   of `-`.
4. Make sure the subnet's **Security List** (or attached NSG) allows inbound
   TCP/22 (SSH) — default OCI "quick create" VCNs from the instance wizard
   usually already do.

---

## 4. Connect

```bash
ssh -i "/path/to/your-key.key" ubuntu@<public-ip>
```

**Do not confuse this with the OCI serial console connection** (the
`ocid1.instanceconsoleconnection...` / `instance-console.<region>.oci...`
tunnel command shown under Instance Access → console connection). That path
is for troubleshooting an **unresponsive** instance via a VNC-over-SSH tunnel
to port 5900, and its older host requires `-o HostKeyAlgorithms=+ssh-rsa` on
modern OpenSSH clients to negotiate at all. Normal SSH directly to the
instance's public IP (above) does not need that flag.

---

## 5. Install dependencies and clone the repo

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv git

git clone https://github.com/Fandresena-SW/discord-ots-bot.git
cd discord-ots-bot
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
deactivate
```

---

## 6. Create `.env` on the server

**Never commit real secrets.** Create the file directly on the VM, not via
git:

```bash
nano .env
```

```
DISCORD_TOKEN=...
GUILD_ID=...
SUPABASE_URL=...
SUPABASE_SERVICE_KEY=...
```

```bash
chmod 600 .env
```

See `.env.example` and `knowledge/RUNBOOK.md` §0 for where `SUPABASE_URL` /
`SUPABASE_SERVICE_KEY` come from (Supabase Project Settings → API), and the
warning there about using the **secret** key, never the **publishable** one.

---

## 7. Python-version compatibility note

`bot.py` uses PEP 604 union type hints (`str | None`, etc.) in function
signatures. These are evaluated **eagerly** on Python < 3.10, which raises
`TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'` at
import time on an interpreter older than 3.10 (this is exactly what Ubuntu
20.04's system Python 3.8 does).

The fix committed to the repo is `from __future__ import annotations` at the
top of `bot.py`, which makes all annotations lazy strings — never evaluated
at runtime — so the file imports cleanly on Python 3.8+ with no behavior
change. If you provision on 22.04+/24.04 (Python 3.10+ by default) this
never bites, but the shim is harmless either way and means the repo isn't
silently pinned to a specific host's Python version.

---

## 8. Run as a systemd service

```bash
sudo nano /etc/systemd/system/discord-ots-bot.service
```

```ini
[Unit]
Description=Discord OTS Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/discord-ots-bot
ExecStart=/home/ubuntu/discord-ots-bot/venv/bin/python3 bot.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`bot.py` loads `.env` via `python-dotenv` from its working directory, so no
`EnvironmentFile=` directive is needed — just a correct `WorkingDirectory`.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now discord-ots-bot
sudo systemctl status discord-ots-bot
```

---

## 9. Redeploying a code change

```bash
ssh -i "/path/to/your-key.key" ubuntu@<public-ip>
cd discord-ots-bot
git pull
sudo systemctl restart discord-ots-bot
sudo systemctl status discord-ots-bot   # confirm "active (running)"
```

If `requirements.txt` changed, reinstall into the venv before restarting:

```bash
source venv/bin/activate
pip install -r requirements.txt
deactivate
```

---

## 10. Monitoring & logs

```bash
sudo systemctl status discord-ots-bot        # current state
journalctl -u discord-ots-bot -f             # live tail
journalctl -u discord-ots-bot -n 50          # last 50 lines
```

A healthy start shows `discord.client: logging in using static token`
followed by `discord.gateway: Shard ID None has connected to Gateway`. A
crash loop (`Scheduled restart job, restart counter is at N`) means the
process is exiting immediately — check the traceback right above the restart
line first.

---

## 11. Troubleshooting log

Real issues hit during the initial OCI deployment, kept here so they aren't
rediscovered from scratch on the next VM:

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
