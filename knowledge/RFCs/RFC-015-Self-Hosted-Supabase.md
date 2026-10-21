# RFC-015 — Self-Hosted Supabase on the Production VPS

- **Status:** ✅ **Complete 2026-10-21.** Cut over 2026-10-19; soak ended 2026-10-21** (closed by the owner, five
  days ahead of the planned 2026-10-26) — the bot runs on the self-hosted database;
  the `/root/mig` rollback material, including the hosted `.env` backup, is deleted. All
  acceptance criteria are met: see the Completion record.
- **Implementation order:** infrastructure RFC, **independent of the v4.0
  feature chain** — depends on RFC-001…013 being complete (the schema it
  migrates), does **not** depend on RFC-014 and may land before or after it.
  It adds no `F`-numbered feature.
- **Complexity:** Medium–High (operational, not code-heavy)
- **Later change:** RFC-016 (2026-10-19) moved the public Caddy out of this stack into a
  shared `/opt/edge`; §3.1/§4 below describe the original, in-stack Caddy.
- **Features covered:** — (platform change; no user-visible behavior)
- **Grounding:** `knowledge/DEPLOYMENT.md` (VPS move, 2026-10-19),
  `knowledge/RUNBOOK.md` §0/§8, `supabase/config.toml`,
  `supabase/functions/challonge-sync/index.ts`, `.claude/RULES.md`
- **Builds upon:** RFC-001/003/007/011 (schema as migrations), RFC-008/012
  (the Edge Function and its freeze), RFC-013 (`bot.py`'s read/write seam)
- **Built upon by:** —

---

## 1. Summary

Replace the hosted Supabase project with a **self-hosted Supabase stack
(Docker Compose) on the same VPS that already runs the bot**, migrate the
production data, and cut the bot and the `challonge-sync` Edge Function over
to it. The hosted project is kept untouched as a fallback until the cutover
is verified.

This is an infrastructure change, not a code change: `bot.py` already reaches
Supabase only through `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` and the
PostgREST path `/rest/v1/...`, which self-hosted Supabase serves identically.
The expected code diff is **zero lines of `bot.py`** and **zero lines of
`index.ts` logic** (see §3.7 for the one thing to verify in each).

What actually changes is *who owns the operational burden*: backups, upgrades,
TLS, secrets and uptime stop being Supabase's problem and become this
project's. The RFC exists mainly to make that burden explicit and bounded.

## 2. Motivation and honest trade-offs

**Gains**

- No dependency on the hosted free tier (its inactivity pause and project
  limits — RFC-006's "Supabase free-tier pause risk" disappears).
- Bot ↔ database traffic becomes loopback (`localhost`), removing a network
  hop and an external failure mode from every `/ots`.
- Full database access (direct `psql`, no 500 MB cap, no pooler quirks).

**Costs and new risks (accepted by choosing this)**

- **Single point of failure.** Bot *and* database now share one VPS. A VPS
  outage takes both down; before, they failed independently.
- **Backups become ours.** Hosted backups/PITR no longer exist. Without a
  tested backup + restore, a disk failure loses every tournament, profile and
  frozen result — and frozen points are explicitly *not* recomputable
  (RFC-012: history is never restated).
- **Upgrades and security patching are ours** (Postgres, PostgREST, Kong,
  Studio, edge-runtime, the OS).
- **Resource footprint.** The full stack is ~12 containers; the bot needs
  almost nothing, so this RFC deliberately runs a **trimmed** stack (§3.2).
  The VPS (7.8 GiB RAM, 4 vCPU) has ample headroom — see §7.1.

This RFC does not reopen any `RULES`/`CLAUDE.md` locked decision: the service
key still lives only on the worker, `bot.py` still never talks to Challonge,
refresh is still organizer-triggered, `bot.py`'s data access is still one thin
seam. See §6.

## 3. Technical approach

### 3.1 Topology

```
Internet ──443──▶ Caddy (TLS, 161-97-171-179.sslip.io) ──▶ Kong 127.0.0.1:8000
                                                             ├─ /functions/v1/*  → edge-runtime
                                                             ├─ /rest/v1/*       → PostgREST
                                                             └─ /                → Studio (basic auth)
bot.py ──────────────▶ http://127.0.0.1:8000  (loopback, never leaves the box)
```

- **Only 80/443 are public** (Caddy). Everything else binds `127.0.0.1`.
- **Docker bypasses `ufw`.** A port published as `"5432:5432"` is reachable
  from the internet regardless of ufw rules. Every published port in the
  compose file must be written `127.0.0.1:<port>:<port>`. This is the most
  likely way a self-hosted install ends up with an open Postgres; the
  implementation must verify it from outside (§5).
- **Hostname without a domain:** `161-97-171-179.sslip.io` (wildcard DNS →
  the VPS IP) gets a real Let's Encrypt certificate via Caddy. If a real
  domain is bought later, the change is the Caddy site address plus the URLs
  in `RUNBOOK.md` §8; nothing in the bot depends on it (the bot uses
  loopback).
- **Public surface is an allow-list, not "whatever Kong exposes":** Caddy
  forwards only `/functions/v1/challonge-sync` (secret-header protected by the
  function itself) and the Studio paths (behind basic auth). `/rest/*`,
  `/auth/*`, `/storage/*`, `/realtime/*` are **blocked at Caddy** — the bot
  uses loopback and nothing else needs them from outside.

### 3.2 Which Supabase services run

The project uses: Postgres, PostgREST (`/rest/v1`), Edge Functions (one
function), and Studio (organizer workflows, `RUNBOOK.md`). It does **not** use
Auth, Realtime, Storage, or image transformation.

Run the **minimum**: `db`, `kong`, `rest`, `meta` (Studio's schema API),
`studio`, `functions` (edge-runtime). Omit `auth`, `realtime`, `storage`,
`imgproxy`, `analytics`/`vector` and the Supavisor pooler unless the
implementation finds Studio will not start without one (it is known to
tolerate a missing analytics service with log-viewer errors). This is a
**verify-during-implementation** item, not an assumption — record what was
actually omitted in the Completion record.

Rationale: fewer containers = less RAM, fewer patch targets, and a smaller
attack surface. Nothing here is hard to add back later.

### 3.3 Secrets and keys (generated fresh, never reused from hosted)

The self-hosted stack needs its own `JWT_SECRET`, `ANON_KEY`,
`SERVICE_ROLE_KEY`, Postgres password, and Studio/dashboard credentials.

- Generate them on the VPS (the Supabase self-hosting docs ship a key
  generator); store in `/opt/supabase/.env`, `chmod 600`, owned by root. Never
  committed, never pasted into chat or a doc.
- `SERVICE_ROLE_KEY` becomes the bot's new `SUPABASE_SERVICE_KEY`; the stack's
  internal URL (`http://127.0.0.1:8000`) becomes the bot's `SUPABASE_URL`.
- The Edge Function's two secrets, `CHALLONGE_API_KEY` and
  `CHALLONGE_SYNC_SECRET`, are **carried over unchanged** (the organizer's
  saved `curl` keeps working apart from the host) and passed to the
  `functions` service through the compose `environment:` block — there is no
  `supabase secrets set` on a self-hosted stack.
- `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are injected into the
  `functions` container by the standard compose file, which preserves the
  assumption documented at the top of `index.ts`.

### 3.4 Schema and data migration

Migrations remain the only schema delivery path (CLAUDE.md convention).

1. **Schema:** apply `supabase/migrations/*` to the self-hosted database
   (`supabase db push --db-url postgresql://…` from a machine with the CLI, or
   `psql -f` in order). Because every migration is idempotent and the
   explicit-grants migration exists, this yields a database the bot can read
   (no reliance on platform-default privileges). **Never apply `seed.sql`.**
2. **Data:** `pg_dump --data-only --schema=public` from the hosted project,
   restored with triggers disabled for the load
   (`session_replication_role = replica`) so the `players` trigger and the
   freeze-related constraints cannot rewrite imported rows. Dump **only
   `public`**; do not import hosted `auth`/`storage`/`supabase_*` schemas.
3. **Verify** with the invariant checks in `supabase/verification.sql` plus
   row-count parity per table (hosted vs self-hosted) and a spot-check of one
   `tournament_results` row's stored `points` and resolved tier multiplier.
4. **Identity columns/sequences:** reset sequences after the load so new rows
   don't collide with imported ids.

The hosted project is **not modified** by any of this (read-only dump).

### 3.5 Edge Function on self-hosted

- The function files (`index.ts`, `mapping.ts`, `points.ts`) are copied into
  the stack's functions volume (`volumes/functions/challonge-sync/`) — the
  self-hosted analogue of `supabase functions deploy`. A small script in the
  repo (not a manual copy) performs the sync so redeploys are repeatable;
  `DEPLOYMENT.md` §12 gets a self-hosted variant.
- **JWT verification must be off for this function.** The organizer's `curl`
  sends only `x-challonge-sync-secret`, no `Authorization` header — the
  function authenticates itself (RFC-008 §3.2; `config.toml` already marks
  `[functions.challonge-sync]` for this). On self-hosted, the `main` router
  verifies JWTs by default; the compose/main config must disable that for
  this function or every trigger fails 401 before reaching the code.
- The trigger URL changes from
  `https://<project-ref>.supabase.co/functions/v1/challonge-sync` to
  `https://161-97-171-179.sslip.io/functions/v1/challonge-sync`; the path,
  headers, body, and response shape are unchanged. `RUNBOOK.md` §8 is
  updated.

### 3.6 Backups (the load-bearing deliverable)

- A **nightly `pg_dump`** (custom format, `public` schema + roles needed to
  restore) via a systemd timer, retained **14 days** with rotation, written
  outside the Docker volume so a bad `docker compose down -v` cannot take the
  backups with it.
- **Off-box copy:** the VPS subscription includes **provider auto-backups**
  (VM-level snapshots), which cover the dump directory and so give an
  off-disk copy at no extra cost. Decision 2026-10-19: rely on these instead
  of a separate backup destination. Two caveats keep the nightly `pg_dump` in
  place rather than replacing it with snapshots alone:
  1. A snapshot of a **running** Postgres is only crash-consistent; the
     logical `pg_dump` is the artifact that is guaranteed restorable. The
     snapshot is the safety net *for the dumps*, not a substitute for them.
  2. Snapshot frequency, retention and restore procedure are the provider's
     and **unverified** here. The implementation records them in the
     Completion record (and confirms a snapshot actually contains the dump
     directory). It remains a single-provider copy: a provider-level loss
     takes the VPS and its backups together. If that risk matters later, add
     a periodic `rsync`/object-storage copy; nothing here blocks it.
- **A restore must be demonstrated once** (restore the latest dump into a
  scratch database and run `verification.sql`) before the hosted project is
  decommissioned. An untested backup is treated as no backup.
- `RUNBOOK.md` §7 (roster backup) is updated to point at this, and the
  break-glass procedure in RFC-006's runbook sections gets the self-hosted
  equivalent.

### 3.7 Code changes (expected: none, to be confirmed)

- **`bot.py`:** none expected. `validate_config()` only checks the vars are
  present; there is no `https://` or hosted-domain assumption. Confirm the
  5 s bounded `aiohttp` session still behaves over plain `http://127.0.0.1`
  (it should; a loopback hop is faster than the old HTTPS one).
- **`index.ts`:** none expected. Confirm `Deno.env.get("SUPABASE_URL")`
  inside edge-runtime resolves to an address the function can reach (the
  compose-internal `http://kong:8000`, not the public hostname).
- Anything that does turn out to need a code change is recorded in the
  Completion record as a deviation, not slipped in.

### 3.8 Cutover and rollback

**Window:** outside any live tournament, with the organizer told not to
trigger a sync meanwhile (sync is human-triggered, so this is controllable).

1. Stand up the stack, apply migrations, restore data, verify (§3.4).
2. Deploy the Edge Function; run the sync trigger against a known test
   tournament and confirm a `200` with the expected counts (`DEPLOYMENT.md`
   §12's verification step, against the new host).
3. Stop the bot; set the new `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`; start it.
4. In-guild smoke test: `/ots` (bound player), `/ots-organizer <name>`, and
   `/link-organizer` (exercises the write path through `_supabase_write`).
5. Keep the hosted project running and untouched for a **soak period**
   (7 days, ≥ one real round of play).

**Rollback:** revert the two env vars and restart the bot — takes seconds.
**Caveat:** any writes made on the self-hosted DB after cutover
(`/link-organizer`, `/unlink`, synced cache/freeze rows) do **not** exist on
hosted. Rolling back after real use therefore needs a reverse data copy, or
accepting that loss. This is why rollback is only clean *early*; the soak
period should be short on risk tolerance and the decision to decommission
hosted must be explicit.

## 4. Files / deliverables

| File | Change |
|------|--------|
| `deploy/supabase/` (new) | compose file (trimmed), `.env.example` (names only), Caddyfile, backup script + systemd timer, functions-sync script |
| `knowledge/DEPLOYMENT.md` | new section: self-hosted stack install, ports, Caddy, backups, upgrades; §12 gets the self-hosted function deploy |
| `knowledge/RUNBOOK.md` | §0 (where `SUPABASE_URL`/key come from), §7 (backup), §8 (new trigger URL), Studio URL + basic-auth note |
| `knowledge/RFCs/RFCS.md`, `CLAUDE.md`, `PRD.md` | status trackers per the four-places convention |
| `.env.example` | note that `SUPABASE_URL` may be a loopback address |
| `bot.py`, `index.ts` | **no change expected** (§3.7) |

`deploy/` is a **new top-level folder**, which is a deviation from "no new
folders" (RULES §2) in the same spirit as `supabase/` (RFC-008): it holds
operational config, not application code. Approved 2026-10-19 (§7.3).

## 5. Acceptance criteria

1. From outside the VPS (e.g. `nmap`/`nc` from a laptop), **only 22, 80 and
   443 are reachable**; 5432, 8000, 3000 and any pooler port are closed.
2. Hostname serves a valid Let's Encrypt certificate; `/rest/*` is **not**
   reachable publicly; Studio prompts for basic auth.
3. Row-count parity hosted vs self-hosted for every `public` table; the
   `verification.sql` invariants pass; one frozen result's `points` matches.
4. `challonge-sync` returns `200` with the expected counts against a test
   tournament via the public URL, with no `Authorization` header.
5. `/ots`, `/ots-organizer` and `/link-organizer` work in-guild against the
   self-hosted DB; `journalctl -u discord-ots-bot` shows no errors.
6. The stack and the bot both come back after a **VPS reboot** without manual
   steps (`restart: unless-stopped` + enabled systemd units).
7. A backup has run on schedule, been captured by a provider snapshot, **and been restored** to
   a scratch database with `verification.sql` passing.
8. Hosted project untouched; the 4 status trackers updated.

## 6. Locked decisions touched

- *Service key lives only on the worker* — **preserved** (new key, same
  worker-only placement; the function gets it via the platform-style env
  injection, as before).
- *`bot.py` never talks to Challonge* / *refresh is organizer-triggered* —
  **unchanged**.
- *`bot.py`'s data access is one thin seam* — **unchanged**; only the URL it
  points at moves.
- *Grant explicitly / schema via migrations / no fixtures in migrations* —
  **relied upon**: the explicit-grants migration is what lets this schema
  rebuild into a self-hosted DB.
- **New operational facts this introduces** (not previously locked):
  single-host SPOF, owner-managed backups, owner-managed patching. These are
  recorded here so they are a decision, not a surprise.

## 7. Open questions (need an owner's answer before implementation)

1. **VPS capacity — ✅ resolved 2026-10-19.** Measured on the VPS: 4 vCPU,
   7.8 GiB RAM (454 MiB used with the bot running), 96 GB disk (94 GB free),
   **no swap**, **Docker not installed**. Comfortably enough for the trimmed
   stack (§3.2); even the full stack would fit. Implementation still adds a
   modest swapfile (2 GB) as OOM insurance, and installs Docker Engine +
   the Compose plugin from Docker's apt repository (not the snap, whose
   confinement complicates bind mounts and `127.0.0.1` port publishing).
2. **Off-box backup destination — ✅ resolved 2026-10-19.** Provider
   auto-backups (§3.6); snapshot cadence/retention to be verified at
   implementation.
3. **`deploy/` folder — ✅ approved 2026-10-19.** New top-level `deploy/`
   folder accepted as a RULES §2 exception (operational config, not
   application code, same spirit as `supabase/`).
4. **Soak length — ✅ resolved 2026-10-19: 7 days.** The hosted project stays
   running and untouched for 7 days after cutover (covering at least one real
   round of play); decommissioning it afterwards is an explicit, separate
   decision, not automatic.
5. **Studio exposure.** Basic auth + Studio's own login is specified; if
   the organizer only ever works from a laptop, an SSH tunnel with Studio
   not public at all is strictly safer. Decision recorded 2026-10-19:
   HTTPS + basic auth (convenience from a phone).

## 8. Risks

| Risk | Mitigation |
|------|-----------|
| Docker publishes a DB port past ufw | Compose binds `127.0.0.1`; external port scan is an acceptance gate (§5.1) |
| Backup exists but doesn't restore | Restore drill is an acceptance gate (§5.7) |
| Provider snapshot is crash-consistent only / retention unknown | Nightly logical `pg_dump` stays the restorable artifact; provider cadence/retention recorded at implementation (§3.6) |
| VPS outage now takes bot **and** DB | Accepted; off-box backups bound the data loss, a rebuild runbook bounds downtime |
| Edge Function 401s on self-hosted | §3.5: JWT verification explicitly disabled for it; covered by acceptance 4 |
| Import trips triggers/constraints and rewrites history | Load with triggers disabled; verify frozen `points` parity (§3.4) |
| sslip.io certificate rate-limited / third-party DNS dependency | Low impact (only the public Studio + curl URL); fix is buying a domain |
| Out-of-memory kills the bot | Trimmed stack, swap, `restart:` policies; check `free -h` under load during soak |

## Completion record

**Cutover: 2026-10-19.** Hosted project untouched and kept as the fallback;
soak runs **7 days, until 2026-10-26**. Decommissioning it is a separate,
explicit decision.

**Stack as built** (upstream `self-hosted/v0.8.3`, pinned in
`/opt/supabase/.supabase-version`): `db` (Postgres 17.6), `rest`, `meta`,
`studio`, `api-gw` (**Envoy** — upstream's default gateway; the RFC's Kong
wording predates that), `functions`, `caddy`. Omitted via an unused profile:
`auth`, `realtime`, `storage`, `imgproxy`, `supavisor`. Studio and the stack
start and run fine without them. Resident memory ~1.2 GiB on a 7.8 GiB, 4 vCPU,
96 GB VPS; a 2 GB swapfile was added.

**Deviations from §3, all recorded:**
- **Gateway is Envoy, not Kong** (§3.1/§3.2 wording) — same role, upstream's
  current default; Kong remains an upstream option.
- **Provisioning used upstream's `setup.sh`** plus our overlay, not a hand-built
  compose. `deploy/supabase/` holds only our deltas.
- **Added migration `20261019000000_revoke_anon_authenticated_public`** (not in
  the RFC): the self-hosted image's default ACL grants anon/authenticated full
  privileges on new `public` tables; RLS alone kept them at `200 []`. Revoked
  explicitly, existing and default. Applied to self-hosted only, never pushed to
  hosted. Anon now gets `42501`.
- **Upstream's Caddyfile publicly proxies `/rest/v1`**; replaced with an
  allow-list (§3.1).
- **Keys:** the bot and function use the legacy HS256 `SERVICE_ROLE_KEY`, not the
  new opaque `sb_secret_…` key — both send it as `apikey` and `Bearer`, so no code
  change was needed.
- **Secrets leaked into the build session's transcript once** (key generator
  output); every secret was regenerated before first start. Never re-run the
  key scripts unfiltered.
- No code change was needed in `bot.py` or `index.ts` (§3.7 held).

**Acceptance (§5):**

| # | Criterion | Status |
|---|---|---|
| 1 | Only 22/80/443 public | ✅ proven **server-side** (`ss -ltnH`: only 22/80/443 non-loopback; `iptables` DNAT only 80/443/8000, the last `-d 127.0.0.1`). A client-side port scan was unusable (ProtonVPN made every port look open). |
| 2 | Valid cert; `/rest/*` blocked; Studio auth | ✅ cert verifies, `/rest/v1`, `/auth/v1`, other function paths → 404, Studio → 401 without auth |
| 3 | Data parity + invariants | ✅ per-table row counts **and content checksums** identical on all 5 non-empty tables (3 tables empty on both sides); 2 passes (rehearsal + cutover). Schema diff vs hosted: only a column's *position*. `verification.sql` was not run. |
| 4 | `challonge-sync` 200 via public URL, no `Authorization` | ✅ tournament 4: 200, 8 participants, 14 matches, writes confirmed on self-hosted only (pg_stat counters) |
| 5 | `/ots`, `/ots-organizer`, `/link-organizer` in-guild | ✅ 2026-10-21: `/link-organizer` confirmed valid by the owner. Earlier (2026-10-19): `/ots` and `/ots-organizer` ✅; `/link-organizer` was run but returned "Aucun tournoi actif" (no active tournament), so it exercised the **read** path only; the **write** path through the bot is still unexercised until a tournament is active. Database-level write path verified (service_role insert + link, rolled back). |
| 6 | Survives a VPS reboot | ✅ 2026-10-19: rebooted; back in ~44 s; docker, bot, backup timer, swap and ufw returned unaided; all 7 containers up (6 healthy + caddy, which has no healthcheck); bot reconnected to the gateway; only 22/80/443 public; data intact; function and Studio auth unchanged. Note: the bot unit orders only `After=network-online.target`, so it started a few seconds before the DB was healthy — `/ots` in that window fails soft ("unavailable") and recovers within a minute. |
| 7 | Backup ran, captured by snapshot, **restored** | ✅ backup ✅, restore drill ✅ (scratch DB identical to live, 4 ledger rows). 2026-10-21: provider snapshot verified by the owner and runs **daily**. |
| 8 | Hosted untouched; 4 trackers updated | ✅ hosted read-only throughout; trackers updated this date |

**Findings worth keeping:**
- `challonge_*_cache.fetched_at` never advances on re-sync (the function's
  `merge-duplicates` upsert never sets it) — pre-existing, also true on hosted;
  the F36 staleness warning cannot reflect a refresh. Not fixed here.
- `pg_restore` of our archive into a fresh DB needs `--clean --if-exists`.
- Docker bypasses `ufw`; every published port must be `127.0.0.1:`-bound.

**Still to do:** nothing. Marked ✅ Complete 2026-10-21.

**Done 2026-10-21:** soak closed early by the owner; `/root/mig` deleted (including
`bot.env.hosted.bak`); `/link-organizer` confirmed valid by the owner (criterion 5
now ✅, write path included); the hosted Supabase project is **paused**, not deleted; provider snapshot verified
(daily), closing criterion 7. The `.env`-swap rollback to hosted no longer has its backup.
