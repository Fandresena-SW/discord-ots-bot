# RFC-016 — Shared Public Edge for Multiple Self-Hosted Supabase Stacks

- **Status:** ✅ **Implemented 2026-10-19.** Reboot test waived by the owner; the first
  second-project join is still to be exercised (see Completion record)
- **Implementation order:** infrastructure RFC, independent of the v4.0 feature
  chain — depends on RFC-015 (the stack it re-homes), does not touch `bot.py`
- **Complexity:** Medium (operational)
- **Features covered:** — (platform change; no user-visible behavior)
- **Grounding:** RFC-015; `knowledge/DEPLOYMENT.md` §13; the second-project handover
  at `~/.claude/handovers/supabase-second-project-handover.md`
- **Builds upon:** RFC-015 · **Built upon by:** the second project's migration

---

## 1. Summary

RFC-015 put the first project's Supabase stack on the VPS with its own Caddy inside
that stack's compose. A second self-hosted project (`atelier-textile-flutter`, a
user-facing Flutter app) is planned for the same VPS. Ports 80 and 443 can be bound by
only one process, so the proxy cannot live inside either stack. This RFC extracts it
into a **standalone compose project (`/opt/edge`) on a shared Docker network `edge`**,
with **one Caddy site file per project**.

Decided by the owner 2026-10-19: standalone edge (not "keep it in stack #1 and add a
site block"), with a few seconds of public-ingress gap accepted during the swap.

## 2. Why standalone, not "Caddy stays in stack #1"

| | Standalone `/opt/edge` (chosen) | Caddy stays in stack #1 |
|---|---|---|
| Restarting/upgrading stack #1 | does not affect other projects' public URLs | takes every project's URL down |
| Upstream `update.sh` | cannot overwrite our edge config | may overwrite the caddy overlay |
| Blast radius of a bad site file | the shared edge (mitigated by validate-before-reload) | same |
| Work now | one extra compose project | smaller |

## 3. Design

- **Network:** external Docker network `edge`, created once. Each stack attaches its
  **gateway and Studio only**. `db`, `rest`, `meta`, `functions` stay on the stack's
  private default network.
- **Addressing by container name.** Docker adds the *service name* as an alias on every
  network a container joins; two stacks on `edge` would both answer to `studio` /
  `api-gw`. Caddy therefore proxies to unique **container names**
  (`supabase-envoy`, `supabase-studio`). Upstream hard-codes `supabase-*`, so a second
  stack must override every `container_name` and set its own `COMPOSE_PROJECT_NAME`.
- **Site files:** `/opt/edge/sites/<project>.caddy`, imported by the Caddyfile; per-site
  variables in `/opt/edge/.env` under a project prefix.
- **Certificates preserved:** the edge reuses the existing named volumes
  `supabase_caddy_data` / `supabase_caddy_config` (`external: true`). `sslip.io` is not
  on the Public Suffix List (checked), so its certificates share Let's Encrypt's
  per-registered-domain limits with every other user; re-requesting could have failed.
- **Stack #1 changes:** the upstream `docker-compose.caddy.yml` overlay is dropped from
  `COMPOSE_FILE`; `docker-compose.ots.yml` now attaches `api-gw` and `studio` to `edge`
  and keeps the gateway published on `127.0.0.1:8000`.

## 4. Files

| File | Change |
|------|--------|
| `deploy/edge/docker-compose.yml`, `Caddyfile`, `sites/ots.caddy`, `env.edge.example` | new |
| `deploy/supabase/docker-compose.ots.yml` | caddy block removed; `api-gw`/`studio` join `edge` |
| `deploy/supabase/caddy/` | removed (moved to `deploy/edge/sites/ots.caddy`) |
| `deploy/supabase/env.ots.example` | `COMPOSE_FILE` without the caddy overlay; `PROXY_DOMAIN` dropped |
| `knowledge/DEPLOYMENT.md` §13 | shared-edge section; six-plus-one container count; ops commands |
| `bot.py`, `index.ts`, migrations | **no change** |

## 5. Not done here (proposed, awaiting a decision)

- **`backup.sh` is still single-database** (`supabase-db`, `public` + ledger,
  prefix `ots-`). A second database needs its own job or a parameterised script.
- **No host-level guard against a mistaken published port.** A rule in Docker's
  `DOCKER-USER` chain would stop a stray `5432:5432` in any stack from reaching the
  internet. Not built: a wrong firewall rule can lock the VPS out.

## 6. Risks

| Risk | Mitigation |
|---|---|
| A broken site file takes the whole edge down on reload | Validate with a throwaway `caddy validate` container before applying (documented) |
| Another stack addresses an upstream by service name | Documented rule; handover calls it out; container names are unique |
| Public gap during the swap | Accepted; measured below |
| Gateway recreation briefly interrupts the bot's DB reads | Fail-soft `"unavailable"` for seconds; measured below |
| Certificate re-issued and rate-limited | Volumes reused; serial verified identical before/after |

## Completion record

**Done 2026-10-19**, in separately confirmed steps: create network `edge` → stage
`/opt/edge` and validate (compose + `caddy validate` in a throwaway container) →
validate the merged stack-#1 config without applying → apply (recreated `api-gw` and
`studio` onto `edge`) → swap Caddy → verify.

**Measured:**
- Public gap during the Caddy swap: **~4 s** (first successful 401 after start).
- Gateway recreation: healthy again within ~10 s.
- Certificate: serial `055BCF5F…`, expiry 2027-01-17 — **identical before and after**
  (kept, not re-issued).

**Verified after the swap:** Studio 401 without auth, **proxies correctly with auth**
(through `supabase-studio`), 401 with a wrong password; `/rest`, `/auth`, `/storage`,
`/realtime`, `/mcp` and other function paths → 404; `POST challonge-sync` → 401 without
the secret and 404 "tournament not found" with it (function reachable through the new
edge); non-loopback listeners still only 22/80/443; `db` is on `supabase_default` only;
0 errors in the edge log; bot active.

**Closed:**
- **Old `supabase-caddy` container removed** (2026-10-19) after the edge had served for
  ~18 minutes; `docker rm` without `-v`, so the `supabase_caddy_data` /
  `supabase_caddy_config` volumes the edge depends on were left intact (verified: 2 of 2
  present; public URL still 401 with a valid certificate afterwards). The rollback path
  to the in-stack Caddy no longer exists as a one-command step.
- **Reboot persistence of the new edge: not tested — waived by the owner.** `edge-caddy`
  has `restart: unless-stopped` and the Docker daemon is enabled, which is the same
  mechanism RFC-015's reboot test exercised for the previous topology; it was not
  re-verified for this one.

**Still open:**
- Nothing else has joined `edge` yet; the multi-tenant behavior (two stacks on `edge`,
  no alias confusion) is reasoned from Docker's documented behavior, **not yet
  exercised**. The first project to join should record its result here.
