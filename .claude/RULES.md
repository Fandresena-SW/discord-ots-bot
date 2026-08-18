# RULES — discord-ots-bot development guidelines

Guardrails for AI-assisted and human development on this repo. Derived from
`knowledge/PRD.md` (v2) and `knowledge/FEATURES.md`. These rules encode
**locked decisions** — treat them as binding unless the PRD is formally changed.

> **Prime directive:** this is a deliberately tiny, single-file bot. Bias toward
> the smallest change that satisfies the requirement. Do **not** introduce
> layers, abstractions, packages, or dependencies the PRD does not call for.
> "Enterprise-grade structure" is an anti-goal here.

---

## 1. Technology stack

| Concern | Choice | Notes |
|---------|--------|-------|
| Language | **Python 3.11+** | asyncio-based; matches the Procfile worker (`worker: python3 bot.py`). |
| Discord | **`discord.py`** (keep existing `>=2.3.0` floor; run the latest stable 2.x) | App commands / `CommandTree`, `discord.Intents.default()`, single-guild sync in `on_ready`. |
| Config | **`python-dotenv`** (`>=1.0.0`) | Loads `.env` locally; real env vars in production. |
| HTTP / data access | **`aiohttp`** (transitive via discord.py) → **Supabase PostgREST** | Data access is raw PostgREST HTTP over `aiohttp`. **Do NOT add `supabase-py`** (locked, PRD §11.5 / F23). |
| Backend | **Supabase (Postgres + PostgREST)**, free tier | Studio is the only admin UI. Auth via **service key**, worker-only. |

**Dependency policy:**
- `requirements.txt` stays minimal. Adding any new dependency requires an explicit
  justification tied to a PRD requirement; default answer is **no**.
- Reuse `aiohttp` (already present) for all HTTP; do not pull a second HTTP client.
- Keep the repo's existing `>=` version style; do not hard-pin without reason.

---

## 2. Architecture & code organization

- **Single file.** All logic lives in `bot.py` unless a change *clearly* warrants
  a split (PRD §6). If you believe a split is warranted, say why and propose it —
  do not split silently.
- **No new folders/packages/modules** for this release. Docs/planning artifacts
  go in `knowledge/` (repo convention).
- **Data access is a thin, single seam.** Isolate Supabase reads in one small
  async helper (analogous to the current `fetch_pokepaste`) so the command
  handler stays readable and the network boundary is one place. This is the
  *only* structural concession — not a repository/service-layer pattern.
  *Amended by RFC-013 — see §26: the seam gains one write twin.*
- **Delete, don't disable.** The v2 refactor must fully remove `USERNAME_URLS`
  and `fetch_pokepaste` (the scraper) — no commented-out dead code, no dormant
  fallback branches in the live path. (The v1 break-glass fallback lives in git
  history, per PRD §12 — not in the working tree.)

---

## 3. Naming & style conventions

- **Python:** PEP 8, 4-space indent, `snake_case` for functions/variables,
  `UPPER_SNAKE` for module constants, type hints on function signatures (match
  the existing `-> list[str]` style).
- **User-facing strings are FRENCH. Always.** (PRD §5.3, §6.) No exceptions.
  Match the existing tone and emoji usage (✅ / ⚠️ / ❌).
- **Internal identifiers, comments-for-devs, logs, and DB columns are English**
  (`tournaments`, `players`, `ingame_name`, `team_text`, `pokepaste_url`,
  `is_active`, `created_at`) — exactly as specified in the PRD/features; do not
  rename them.
- Keep comments sparse and purposeful, matching current density.

---

## 4. Data handling & the database contract

These invariants are **enforced in the database**, not just in code. Honor them
on both sides.

- **Single active tournament:** partial unique index on `is_active` where
  `is_active = true`. The bot resolves the active tournament as the sole
  `is_active = true` row (F3). Activation is a two-step switch (deactivate old →
  activate new); the constraint error on a one-step attempt is *expected*, not a
  bug to "fix" (F8).
- **Player name normalization (F4/F12, locked §11.8):**
  - Stored `ingame_name` is **trimmed** via a `BEFORE INSERT OR UPDATE` trigger.
  - Uniqueness: unique index on `(tournament_id, lower(ingame_name))`.
  - The bot lookup applies **`trim()` then `lower()`** to user input — matching
    the stored normalization exactly. If you change one side, change both.
  - A name that is empty after trimming is rejected.
- **`team_text` content is trusted as-is** (no content validation/normalization,
  §11.4) — **but rendering is hardened** (see §5, F14). "Trust the content" never
  means "emit it unhardened."
- **`pokepaste_url` is nullable** and drives optional embed linking — null is a
  first-class case, not an error.
- FK `players.tournament_id → tournaments` with `on delete cascade`.

---

## 5. The `/ots` command path (behavioral contract)

Preserve v1 player-facing behavior with zero regression (PRD §6). Required order
and rules:

1. **Defer immediately**, before any network I/O (F18) — every invocation now
   does a live read, so the 3s Discord ack window is always at risk. Defer
   ephemeral to preserve reply privacy.
2. **Bounded timeout** on the Supabase read (~5s, matching v1) (F17). A timeout
   is treated as "Supabase unreachable."
3. **Normalize** input (`trim` + `lower`) and query the active tournament's
   player (F11/F12).
4. **Build the embed** exactly as v1: title `OTS de {username}`; clickable title
   URL = `pokepaste_url` **only if present**; description = `team_text` in a code
   block; color `0x3B4CCA` (F13).
5. **Render-safety on `team_text` (F14, P0):**
   - Truncate so the description stays within Discord's 4096-char limit
     (account for the code-fence characters), with a clear **French** truncation
     marker rather than letting Discord reject the message.
   - Neutralize any code-fence-breaking sequence (literal ` ``` `) so it cannot
     break out of / corrupt the code block.
6. **Delivery:** DM the user; on `discord.Forbidden` (DMs closed) fall back to an
   **ephemeral in-channel reply**. Unchanged from v1.

**Fail-soft is mandatory and must be specific (F15):** three *distinct* friendly
French outcomes — (a) name not found in the active tournament (mention the
scope, F16), (b) no active tournament configured, (c) Supabase
unreachable/timeout/error. Never surface a crash or stack trace to a user.

---

## 6. Security

- **Secrets via environment only.** Never hardcode, never commit, never echo the
  `DISCORD_TOKEN` or the Supabase service key. `.env` stays git-ignored;
  `.env.example` gets **placeholder** values only (add the Supabase URL + key
  placeholders — F19).
- The Supabase **service key is worker-only** and **bypasses RLS** — do not ship
  it anywhere client-side, and do not expose the tables via a public anon
  endpoint without RLS (PRD §6).
- **Never log secrets.** Error logs (§7) must not include the token or service
  key. Avoid dumping full `team_text` into logs unnecessarily.
- **Validate config at startup** (F19): missing/partial Supabase config fails
  fast at boot with a clear log — not on the first `/ots`.

---

## 7. Error handling & logging

- **Fail-soft to the user, loud to the operator.** Fail-soft (§5) must not be
  fail-silent: on any Supabase error/timeout, **log server-side** (console,
  alongside the existing heartbeat) with enough detail to diagnose (F22 / PRD
  §5.3). The user still sees only the friendly French message.
- Catch narrowly where you can (e.g. `discord.Forbidden` for DM fallback);
  the network-read helper may catch broadly and return a sentinel that routes to
  fail-soft (mirrors v1's `fetch_pokepaste` returning `[]`).
- No unhandled exception may reach the interaction response.

---

## 8. Testing & quality gates

This repo has **no test suite** today, and that is acceptable given its size —
but quality is still gated:

- **The E2E in-guild checklist is the primary release gate** (PRD §9 Day 5):
  happy path, not-found, no active tournament, Supabase down/timeout, DMs-closed
  fallback, URL vs. no-URL embeds, **and oversized / backtick-containing
  `team_text`**. All must pass before deploy.
- **Automated tests are welcome for pure logic** — specifically the
  render-safety (truncation + fence neutralization, F14) and input normalization
  (trim + lower, F12) functions, which are pure and cheaply testable. If you
  extract these into small pure functions, add lightweight tests. Do not build
  test infrastructure beyond what these need.
- **Organizer dry-run gate** (PRD §9 Day 6): a real 20-player Studio setup timed
  under 5 minutes (G2/F10).
- **Accessibility / responsive design: N/A** — output is a Discord embed
  rendered by Discord clients; there is no web UI to make accessible or
  responsive. Do not add UI frameworks.

---

## 9. Implementation priorities (MoSCoW) & build order

Follow the FEATURES.md priorities and the PRD §9 timeline.

- **Must (ship for release):** schema + DB invariants (F1–F4), config +
  PostgREST access (F19, F23), the core live-read refactor (F11), lookup +
  embed + render-safety + fail-soft (F12–F18), migration/cleanup (F24), and the
  break-glass/degradation reliability path (F22).
- **Should:** indexed read verification (F6), 20-player workflow (F10), improved
  not-found copy (F16), pre-event pre-flight ritual (F20).
- **Could:** Studio defaults/column ordering (F5), keep-alive ping (F21).
- **Won't (do not build):** multiple active tournaments, cross-tournament
  identities, custom web app/auth/roles, self-submission, hidden-until-reveal,
  pokepaste scraping, content validation, caching, multi-guild, non-French
  localization (F25). If asked to build one of these, stop and confirm it's a
  scope change. **Real-time pairings (F25e), previously Won't-have, has been
  picked up by v3.0 / RFC-009** (see §20 below) — it is no longer out of
  scope.

**Recommended sequence:** schema & indexes/trigger → config + PostgREST helper →
core refactor (F11) → normalization/embed/render-safety/fail-soft → cleanup
(delete dict + scraper) → E2E checklist → dry-run → deploy.

**Quality thresholds that must be met before deploy:** zero player-facing
regressions vs. v1; all three fail-soft branches verified; render-safety verified
against oversized + fence-breaking input; no secret committed or logged;
`USERNAME_URLS` and scraper fully removed.

---

## 10. General working agreements

- **Follow the requirements precisely.** The locked decisions in PRD §11 are not
  suggestions. Do not "improve" them silently (e.g. don't add `supabase-py`,
  don't add content validation, don't make a second tournament active).
- **No TODOs, placeholders, or stubbed paths** in delivered code. A feature is
  either implemented and verified, or explicitly deferred in the docs — never a
  silent half-implementation.
- **Completeness over cleverness.** Prefer readable, boring code that matches the
  existing style over clever abstractions. The next reader is an organizer who
  maintains a hobby bot.
- **Handle uncertainty by asking, not guessing.** If a requirement is ambiguous
  or a change would touch a locked decision, out-of-scope item, or the DB
  contract, **stop and ask a specific question** before proceeding. When a
  reasonable default clearly exists and is low-risk, take it and state what you
  chose and why.
- **Keep the docs in sync.** If an implementation detail forces a decision the
  PRD/FEATURES don't cover, record it in `knowledge/` and reference it — don't
  let code and docs drift.
- **Respect the fail-soft ethos everywhere:** a player at a live event should
  never see a crash; an organizer should always have a log to diagnose from.

---

# v3.0 Addendum — Challonge Integration

Guardrails for RFC-007–010 (the Challonge-based opponent-resolution feature).
Derived from `knowledge/PRD.md` §14–26 (v3.0 addendum) and `knowledge/FEATURES.md`
§"v3.0 — Challonge Integration" (F26–F37). **Sections 1–10 above remain fully
binding** — this addendum only adds or narrowly amends what v3.0 changes.
Same locked-decision posture: treat these as binding unless the PRD v3.0
addendum is formally changed.

> **v3.0 prime directive:** the tiny-single-file ethos (prime directive above)
> still holds for `bot.py`. The *one* deliberate exception is an isolated Supabase Edge
> Function for Challonge I/O (§12 below) — it does not license any other new
> component, dependency, or abstraction.

---

## 11. Technology stack (v3.0 additions)

| Concern | Choice | Notes |
|---------|--------|-------|
| Bracket data source | **Challonge API v1** (hosted SaaS) | HTTP Basic auth, static API key — no OAuth/token refresh. Read-only from this project's side; never write/mutate Challonge data. |
| Sync runtime | **Supabase Edge Function (TypeScript/Deno)** | The **first non-Python runtime component** in this repo. Chosen over `pg_cron`/`pg_net` because correct JSON handling + upsert logic is materially easier in TypeScript (PRD §18.2, §24.2 — locked). |
| Sync trigger | **Manual, secret-protected HTTP call** (organizer-run `curl`/shell), never a scheduled poll | Load-bearing for staying under Challonge's 500 req/month free-tier cap (PRD §19, §24.3 — locked), not a convenience choice. |

**Dependency policy (v3.0 addition):** the Edge Function may use whatever
minimal Deno/TypeScript stdlib or Supabase-provided runtime APIs it needs to
call Challonge and upsert into Postgres — this is a separate runtime from
`bot.py` and is **not** subject to §1's "no new Python dependency" policy, but
the same minimalism spirit applies: no framework, no ORM, no second HTTP
client library beyond `fetch`.

---

## 12. Architecture & code organization (v3.0 exception)

- **New folder, explicitly permitted:** `supabase/functions/` (Edge Function
  source). This is a **documented exception to §2's "no new folders/packages"**,
  scoped narrowly to Challonge sync code — it does not open the door to
  splitting `bot.py` itself or adding other new directories.
- **`bot.py` gains zero new runtime dependencies.** It never calls the
  Challonge API, directly or indirectly, at any point — it only ever reads the
  RFC-007 cache tables via the existing PostgREST/`aiohttp` seam (§1 above),
  exactly like it reads `tournaments`/`players` today. This is locked (PRD
  §18.2, §24 item 3) — do not "simplify" by having the bot call Challonge
  directly, even for a quick fix.
- **Cache tables are the only interface between the two runtimes.** The Edge
  Function writes; `bot.py` reads. Neither side reaches into the other's
  runtime or shares code.
- **Full refresh, not incremental sync.** The Edge Function always re-fetches
  and upserts *all* participants + matches for the target tournament (2
  Challonge API calls total) on every trigger — never a delta/partial sync.
  This is a deliberate simplicity choice given low trigger volume (PRD §18.2),
  not a shortcut to revisit under normal circumstances.

---

## 13. Naming & style (v3.0 additions)

- New DB identifiers — `challonge_tournament_id`, `challonge_participants_cache`,
  `challonge_matches_cache`, `challonge_participant_id`, `challonge_match_id`,
  `fetched_at` — are English, `snake_case`, consistent with existing
  `tournaments`/`players` naming. Do not rename.
- `state` on `challonge_matches_cache` mirrors Challonge's own vocabulary
  verbatim: `pending` / `open` / `complete`. Do not translate or remap these
  values — they are an external contract, not internal UI copy.
- Edge Function source: standard TypeScript/Deno conventions (the ecosystem's
  own idioms, not Python's) — this is the one place PEP 8 doesn't apply.
- User-facing `/ots` strings stay **French**, unchanged posture from §3 —
  including all newly-added fail-soft messages (§17 below) and the updated
  slash-command description reflecting the "type your own name" meaning.

---

## 14. Data handling & the Challonge cache contract

- **Reuse, don't reinvent, the trim+lower identity contract.**
  `challonge_participants_cache.ingame_name` reuses RFC-001's
  `trim_ingame_name()` trigger function verbatim — do not write a second
  normalization implementation for this table.
- **Upsert semantics are mandatory, not incidental:** both cache tables are
  refreshed via `on conflict (...) do update` on every trigger — a re-trigger
  must never accumulate duplicate or stale rows. If you touch the Edge
  Function's write logic, preserve this exactly.
- **All-or-nothing per refresh:** the upsert must not begin writing until both
  Challonge API calls (participants, matches) have succeeded — a partial
  failure must never leave one cache table refreshed and the other stale in a
  misleading combination (PRD-adjacent, RFC-007 §"Edge cases").
- **`state` is a strict enum** (`pending`/`open`/`complete`) enforced by a DB
  `check` constraint. An unrecognized value from a future Challonge API change
  must fail the upsert loudly (error/log), never silently store an unknown
  value. This is deliberate — do not loosen the constraint to "make an error
  go away."
- **Name-sync between Challonge and Supabase is an organizer responsibility,
  not a code problem.** No reconciliation/fuzzy-matching is in scope — a
  mismatch is a fail-soft outcome (§17, F33), not something the sync logic
  should try to "fix" (e.g. by fuzzy name matching).
- **Cache tables are disposable, not a backup of record.** Unlike
  `tournaments`/`players`, they can be fully re-derived from Challonge at any
  time via a re-trigger — do not add backup/retention logic for them.
- RLS: same deny-by-default posture as `tournaments`/`players` (§4 above,
  RFC-003 precedent) — enabled, no policies, service-key-only access from both
  the bot and the Edge Function.

---

## 15. The `/ots` command path — v3.0 opponent-resolution contract

*Amended by RFC-013 — see §26: the entry point is now the caller's bound
profile, not their typed input; the typed-name form survives only as
`/ots-organizer`.*

v3.0 **changes**, not extends, `/ots`'s argument meaning — this is an
intentional, confirmed one-time behavior break (PRD §17, §24 item 4), not a
regression to avoid. Do not add a flag/mode to preserve the old "look up any
name" behavior as a fallback.

1. **No-link hard-fail first:** if the active tournament's
   `challonge_tournament_id IS NULL`, fail immediately with a distinct French
   message (F34) — before any resolution logic runs. Never fall back to v2.0's
   arbitrary-lookup behavior for a tournament without a Challonge link.
2. **Resolution order** (F32): normalize the caller's own input (same
   `trim()`+`lower()` as v2.0) → resolve their `challonge_participant_id` via
   `challonge_participants_cache` → find the `state = 'open'` row in
   `challonge_matches_cache` where that id appears on either side → resolve
   the *other* side's id back to a name.
3. **Reuse v2.0's read path verbatim for the final step.** Opponent name →
   `players.team_text` lookup is the *same* query v2.0 already has — do not
   duplicate or reimplement it.
4. **More than one `open` match for the same participant** (malformed bracket,
   not schema-prevented): pick deterministically (e.g. highest `round`) as a
   defensive default — do not raise this to the player as an error.
5. Everything downstream of a resolved opponent (embed build, delivery,
   render-safety) is **unchanged from v2.0 §5** — do not touch that code path.

---

## 16. Security (v3.0 additions)

- **Challonge API key and the Edge Function trigger secret live only in the
  Edge Function's own Supabase environment config** — never in `bot.py`'s env
  vars, never committed, never logged. Same "worker/operator-only secret"
  posture as the existing Supabase service key (§6 above).
- **The trigger endpoint requires the shared secret**, not the public anon
  key — an invocation without it must be rejected. The documented `curl`
  command in the runbook uses a placeholder for the secret, never a real value
  committed to the repo.
- Secret rotation has no automated process in v3.0 scope — a manual procedure
  if ever needed; do not build rotation tooling speculatively.

---

## 17. Error handling & logging (v3.0 — expanded fail-soft)

`/ots` now has **(at least) seven** distinct fail-soft outcomes (PRD §18.3,
F33) — up from v2.0's three. Each needs its **own** clear French message:

1. No active tournament (unchanged from v2.0).
2. Active tournament has no Challonge link (`challonge_tournament_id IS NULL`).
3. Requester's username not found in the cached Challonge participants.
4. Requester found, but no `open` match involves them right now — **one**
   generic message covers bye / eliminated / round-not-started (a taken
   default, not separately confirmed — see §20 open items).
5. Opponent resolved, but no matching `players.team_text` row exists (a
   name-sync gap). **Must be distinguishable server-side (logged) from outcome
   3**, even though both may read similarly to a player.
6. Supabase read unavailable/timeout (unchanged from v2.0).
7. *(Operator-only, never player-facing)* cache older than 48h — logged as a
   server-side warning, never blocks the player.

- **No unhandled exception may reach the interaction response** — same rule as
  §7 above, now covering the Challonge-cache read paths too.
- **Staleness is a passive log check, not a gate.** Comparing
  `MAX(fetched_at)` against a 48h threshold happens inline on the existing
  read path — do not build a separate scheduled job for it.
- Fail-soft still must not mean fail-silent for the operator (§7's rule holds
  unchanged) — every new failure mode above needs a server-side log line with
  enough detail to diagnose.

---

## 18. Testing & quality gates (v3.0)

- **RFC-007's seed fixtures are the baseline test data** for RFC-008/009 —
  build and test the opponent-resolution query against them before requiring a
  live Challonge account. Do not skip this by hand-waving "test against
  production Challonge."
- **Pure-logic testing precedent from RFC-004 extends here:** if
  opponent-resolution logic (§15) can be factored into a small pure function
  (cache rows in → resolved name or fail-soft reason out), add lightweight
  `unittest` coverage the same way F14/F12 were tested. Do not build test
  infrastructure beyond what this needs.
- **E2E checklist expands to cover all seven fail-soft outcomes (§17) plus the
  happy path (F32)**, mirroring RFC-006's release-gate pattern (F37). This is
  the primary release gate for RFC-010, same as the v2.0 checklist was for
  RFC-006.
- **Edge Function verification is manual/operational**, not a Python test
  suite: confirm **2 Challonge API calls per invocation, plus a conditional
  3rd** when the completion check is armed (every cached match reads
  `complete`) — roughly once per event; a 7-round event goes from ~14 to ~15
  calls against the 500/month cap (F68, RFC-012). Also confirm re-runs upsert
  without duplicating rows, and confirm an invalid/missing
  `challonge_tournament_id` fails loudly.
- Accessibility/responsive design: still **N/A** (§8 above holds — Discord
  embed output only).

---

## 19. Implementation priorities (v3.0 MoSCoW & build order)

Strictly sequential — **007 → 008 → 009 → 010**, each depending on all
lower-numbered RFCs (including all of v2.0). No parallel work, same discipline
as v2.0 (RFCS.md).

- **Must:** Challonge link column + cache tables + RLS + seed data (F26–F29),
  the full-refresh Edge Function (F30), secret-protected invocation (F31), the
  opponent-resolution query (F32), expanded fail-soft (F33), the no-link
  hard-fail (F34), the runbook update (F35), and the E2E checklist/dry-run/
  release (F37).
- **Should:** the 48h staleness warning (F36) — desired but not release-
  blocking on its own; ship it, but don't let it hold up F26–F35/F37.
- **Could / Won't:** none newly introduced by v3.0 (FEATURES.md's v3.0 summary
  has 0 in both columns) — v3.0 doesn't reopen any v2.0 Won't-have except
  F25(e), which this addendum *is* the build-out of.

**Quality thresholds before RFC-010 release:** all 7 fail-soft outcomes
verified end-to-end; zero regression vs. the *new* `/ots` contract
(post-announcement — the old contract is intentionally superseded, not
preserved); `bot.py` has zero new runtime dependencies; Challonge credentials
and trigger secret never committed or logged; cache tables confirmed
idempotent under repeated triggers.

---

## 20. General working agreements (v3.0 additions)

- **The `/ots` behavior change is confirmed and intentional** — if asked to
  "also support looking up any name" as a fallback, treat that as a scope
  change back toward v2.0's rejected default (PRD §24 item 4) and stop to
  confirm before building it.
- **No automatic/scheduled Challonge polling, ever**, even as an
  "improvement" — the manual-trigger design is load-bearing for staying under
  the free-tier API cap (§19 above), not an MVP shortcut to later "fix."
- **Still-open items — do not silently resolve, flag instead:**
  - Bye/eliminated/not-started copy granularity (currently one generic
    message, PRD §24 item 7) — only split into distinct messages if
    explicitly requested.
  - No formal v3.0 release date is set (PRD §22) — don't assume one.
  - RFC-008/009/010 should each restate their own acceptance criteria rather
    than only pointing back to the PRD addendum (PRD §24 item 8).
- **This addendum is itself a flagged gap-fill:** RFC-007 noted that no formal
  PRD v3.0 section existed at the time it was drafted; `knowledge/PRD.md` §14–26
  now closes that gap. If future RFCs (008–010) reveal a decision this
  addendum doesn't cover, record it in `knowledge/PRD.md` or here — don't let
  code and docs drift, same rule as §10 above.
- **Won't-have bookkeeping:** once RFC-009 ships, update §9 above (v2.0's
  Won't-have list) to note that F25(e) ("real-time pairings... deferred") has
  been picked up by v3.0 — so §9 doesn't contradict what the bot actually does.
  Do not make this edit prematurely, before RFC-009 actually ships.

---

# v4.0 Addendum — Ranking System & `/ots` Identity Binding

Guardrails for RFC-011–014 (the ranking/identity series). Derived from
`knowledge/PRD.v4.final.md` and `knowledge/FEATURES.md`'s v4.0 section
(F38–F78). **Sections 1–20 above remain fully binding** — this addendum only
adds or narrowly amends what v4.0 changes. Same locked-decision posture: treat
these as binding unless the PRD v4.0 spec is formally changed.

> **v4.0 prime directive:** everything in this addendum lands in the existing
> `schema.sql` and (in later RFCs) `bot.py`. No new file, folder, module, or
> Python dependency is introduced by v4.0, and none is warranted — the same
> "tiny single-file bot" ethos from the top of this document still governs
> `bot.py`; only `schema.sql` (RFC-011) and the Edge Function (RFC-012's
> freeze) gain new surface, and both are documented exceptions already granted
> above, not new ones.

---

## 21. Durable data (v4.0)

`profiles` and `tournament_results` are the project's **first non-disposable**
data. Contrast this directly with §14 above: the Challonge cache tables can be
fully re-derived from Challonge at any time via a re-trigger, but a lost season
of standings, or a lost cross-tournament identity, cannot be reconstructed
from anywhere. Treat any future change touching these two tables with that
asymmetry in mind.

- **F48's `on delete restrict`** on `tournament_results.tournament_id` (and
  `.season_id`, and `tournaments.tier_id`) breaks `schema.sql`'s otherwise
  uniform `on delete cascade` pattern, on purpose. Do not soften it to make a
  test-tournament cleanup, a Studio "just delete it" impulse, or any other
  operational convenience easier — a roster typo is recoverable; a deleted
  season of frozen results is not. If a delete needs to succeed, the results
  must be purged first, deliberately, by someone who has read what that means
  (RUNBOOK §9, RFC-014).
- **`profiles.discord_user_id` is the first genuinely personal data** this
  project stores. The erasure path (F69, `on delete set null` on both
  `profile_id` FKs) must stay possible by construction — never add a
  cascading or restricting FK from `profiles` that would block a profile
  delete, and never make erasure require anything beyond `delete from
  profiles where id = ...`.

---

## 22. Frozen history

- **Snapshot the resolved value, never the lookup key.**
  `tournament_results.multiplier` stores the *resolved numeric* tier
  multiplier at freeze time, never `tier_id`. Tiers are shared, mutable rows —
  repricing "Majeur" from 3.0 to 2.5 must never silently restate every Majeur
  result ever frozen. Any future frozen-result column that derives from a
  shared lookup table must follow this same snapshot rule.
- **Standings sum over `tournament_results.season_id`, never over a join to
  `tournaments.season_id`.** Editing a tournament's season assignment after a
  freeze must never relocate a frozen result into a different season's
  standings. The frozen row's own `season_id` is the only source of truth for
  which season it counts toward.
- **Corrections are deliberate only, never a side effect of a routine sync.**
  `frozen_at` / `freeze_count` (F50) exist so a re-freeze (F72) is an explicit,
  logged, auditable act — not something that happens quietly because someone
  re-ran the Edge Function. Do not wire any routine/scheduled path to rewrite
  `tournament_results`.
- **Two opposing write semantics now live in one Edge Function (RFC-012).**
  `challonge_participants_cache` / `challonge_matches_cache` refresh by upsert
  and are designed to be re-run constantly; `tournament_results` is
  write-once by default and must not be. Keep the freeze (`runFreeze()` in
  `challonge-sync/index.ts`) textually separate from the cache-sync code, and
  never share a helper that "just upserts" across both without the caller
  stating which semantics it wants — `upsertRows` stays a mechanical POST
  helper whose write-once guarantee, where it applies, is the caller's job to
  enforce, not the helper's.

---

## 23. Security posture extended to views

RLS deny-by-default (§6 above) now extends to **views**, which need an extra
step views don't get for free:

- Every new view over RLS-protected data declares `with (security_invoker =
  on)` **and** is explicitly `revoke`d from `anon`/`authenticated`. Both halves
  are required — the revoke alone would not survive a future re-grant, and
  `security_invoker` alone leaves the view *readable* (but empty) to `anon`.
- **The failure mode this guards against:** a view owned by a superuser role,
  without `security_invoker`, happily serves `anon` exactly the rows RLS
  denies on the base table — silently reopening the hole RFC-003 closed. This
  is the single easiest mistake to make in any RFC that adds a view.
- **Verification must go through PostgREST with the anon key, never the SQL
  editor.** The SQL editor runs as a superuser role and is unaffected by RLS
  either way — a check that "passes" there proves nothing. A local container
  test must simulate this with `set role anon` after granting the PostgREST
  roles select on the object, not just check for "permission denied" from a
  missing grant.
- A `404`/`PGRST205` from PostgREST on a brand-new table or view is a **stale
  schema cache**, not a passing RLS result — reload it
  (`notify pgrst, 'reload schema';`) before concluding anything.

---

## 24. Auto-link rules

The forward auto-link trigger (F60) that binds a new `players` roster row to
an existing `profiles` row by normalized name follows two opposite-sounding
rules on purpose — do not "fix" either one into matching the other:

- **Fail-CLOSED on ambiguity.** If a normalized name matches more than one
  distinct bound profile, the trigger leaves `profile_id` null and logs a
  `WARNING` — it never guesses. Binding is an **authorization boundary** (a
  bound profile is who receives that team's `/ots` result), so a wrong guess
  here is a real access mistake, not a cosmetic one.
- **Fail-OPEN on the F40 slot conflict.** If the resolved profile already
  holds a roster slot in that tournament, the trigger leaves `profile_id` null
  and logs a `WARNING`, but the organizer's Studio **insert still succeeds**.
  Rejecting the insert instead would cost the whole roster row over a linking
  detail; a null link only costs one follow-up `/link-organizer`. Do not
  invert this into a hard rejection.
- **`before insert` only, never `or update`.** Renaming an existing roster row
  must never silently re-point it at a different person's profile — that is
  exactly the "silently moves team-sheet access" hazard this feature's
  logging exists to catch. Re-pointing is `/link-organizer`'s job (RFC-013),
  a deliberate act, not a side effect of an edit.
- **Trigger-name ordering is load-bearing.** Postgres fires same-event
  triggers in name order, so `players_autolink_profile` runs before
  `players_trim_ingame_name`. That the resolver still gets the right answer
  despite seeing an untrimmed `NEW.ingame_name` is only true because the
  resolver applies `btrim`/`lower` itself — do not rename either trigger
  without re-checking the relative order and re-running the untrimmed-name
  verification check.
- **The schema now depends on the organizer's own name discipline and cannot
  enforce it.** Auto-link keys on the normalized `ingame_name`, so "keep
  Challonge and Supabase names identical" (PRD §36) now also governs *who
  receives whose team sheet*, not just opponent resolution. This is an
  accepted trust argument, not a gap to code around.


## 25. Schema delivery: migrations, not a hand-applied file

**This section reopens and replaces a locked decision.** §2's "no new
folders/packages" and the repo-wide "`schema.sql` is idempotent and applied by
hand in the Studio SQL editor" contract were deliberately overturned on
**2026-08-16**, with explicit approval, immediately after RFC-011 was verified
and before it reached production. The earlier rule is superseded, not bent —
treat any surviving reference to hand-applying `schema.sql` (in older RFCs,
plans, agent definitions or the RUNBOOK) as historical.

- **The schema lives in `supabase/migrations/`.** Add a new timestamped file
  for every change. Never edit a migration that has been applied anywhere, and
  never re-create the root `schema.sql` — it is a redirect stub now.
- **`supabase/` remains the one folder exception to §2.** It already was
  (v3.0 Addendum §12, for the Edge Function); `migrations/`, `seed.sql` and
  `verification.sql` are subfolders of that same exception, not a new one.
- **Keep every migration individually idempotent** regardless of the ledger.
  That property is what allowed production to be baselined with
  `migration repair --status applied` instead of re-running v2.0/v3.0 DDL
  against a live database.
- **Test fixtures never go in a migration.** They live in `supabase/seed.sql`,
  which `db reset` applies locally and `db push` never ships. Reference data —
  data the DDL itself depends on, such as `tournament_tiers` backing the
  not-null `tournaments.tier_id` — stays in its migration.

  *Why this is a rule and not a preference:* fixtures inside the applied schema
  meant every production apply replayed seed inserts against data that had
  moved on since they were written. On 2026-08-16 the RFC-007 participant seed
  collided with real synced Challonge rows on `lower(ingame_name)` and aborted
  the apply under `ON_ERROR_STOP=1` **before a single v4.0 object was created**.
  A container seeded only from the schema file can never reproduce that, which
  is why it survived three separate verification passes.

- **Never rely on platform-default privileges.** Grant explicitly. A current
  Supabase CLI provisions `public` with no default `SELECT` for the PostgREST
  roles, so a schema that assumes the old implicit grants rebuilds into a
  database where the bot gets HTTP 403 while RLS and the service key are both
  correct. `service_role` gets DML and sequence usage; `anon` and
  `authenticated` get **nothing**, explicitly. This strengthens §6 rather than
  relaxing it: deny-by-default is now enforced instead of inherited.
- **RLS and grants are independent.** Enabling RLS does not grant anything, and
  granting does not weaken RLS. Both are required; reason about them separately.

## 26. Write path, authorization and the amended `/ots` entry point (RFC-013)

`bot.py` gains its **first write path** in RFC-013. This section amends §2 and
§15 rather than leaving them describing a bot that only ever reads.

- **§2's read-only seam gains one write twin, `_supabase_write(session,
  method, path, params, json_body, prefer)`.** Not a repository/service
  layer — one function, mirroring the existing `_fetch_*` helpers' shape.
  Every `POST`/`PATCH`/`DELETE` `bot.py` makes goes through it; nothing calls
  `session.post`/`patch`/`delete` directly.
- **The freeze still belongs in TypeScript.** This write seam does not reopen
  §22's decision. `bot.py`'s only writes are one `profiles` row and
  `profile_id` on `players`/`tournament_results` — attribution, never
  `awarded_points`, `final_rank`, `multiplier`, or `season_id`. Those stay
  Edge-Function-only, computed once at freeze time.
- **§15's entry point is amended: "normalize the caller's own input" becomes
  "resolve the caller's bound profile."** `/ots` takes no argument and infers
  the caller via `fetch_opponent_for_profile(str(interaction.user.id))`;
  §15.1's no-Challonge-link-first ordering and §15.3–5's resolution chain
  (dual-id handling, embed, DM delivery with ephemeral fallback) are
  unchanged. The typed-name form is **not deleted** — it survives only as
  `/ots-organizer` (F78), a separate organizer-gated command, never an
  optional argument on `/ots` under any justification (§20 still holds, now
  doubly).
- **Seven fail-soft statuses become nine.** `not_linked` and
  `not_in_tournament` join `fetch_opponent_for_profile`'s vocabulary;
  `fetch_current_opponent`'s original seven are unchanged and still serve
  `/ots-organizer`. Four commands (`/ots`, `/ots-organizer`,
  `/link-organizer`, `/unlink`) are now under the never-raise rule (§7/§17).
- **F77's two gates, and `ORGANIZER_DISCORD_ID` is not a secret.** Both
  `@app_commands.default_permissions(manage_guild=True)` (Discord-side
  hiding) and an explicit `is_organizer(interaction)` check (application-side
  refusal, compared as **text** — snowflakes exceed 2^53) are required on
  both organizer commands; neither alone is sufficient. `ORGANIZER_DISCORD_ID`
  is a new required env var, validated at boot (F19), but it is a public
  Discord id, not a secret — it may be logged, unlike every other var in
  `.env`.
- **Backfill's mitigation is three-part and non-negotiable:** bounded to the
  current season, filtered on `profile_id=is.null` (a backfill can never steal
  a row already attributed to someone else), and `_escape_ilike`'d on every
  name filter — which now guards a **write** that grants team-sheet access,
  not just a read (§4's original concern). Every propagation is logged
  server-side (profile id, normalized name, season id, per-table row counts,
  tournament ids) — this is F60's mandatory audit trail, not optional polish.
- **No self-service claim command, ever.** Binding is organizer-established
  only (`/link-organizer`); `/unlink` is the only player-initiated identity
  command, and it only ever removes a binding, never creates one.
- **F25(b) ("cross-tournament identities"), a v2.0 Won't-have, is deliberately
  reopened by this release.** Do not read §9 above as still current on that
  one point.

*(§2's data-access bullet and §15's heading above each carry a one-line
pointer to this section.)*
