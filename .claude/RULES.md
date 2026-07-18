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
  identities, custom web app/auth/roles, self-submission, pairings /
  hidden-until-reveal, pokepaste scraping, content validation, caching,
  multi-guild, non-French localization (F25). If asked to build one of these,
  stop and confirm it's a scope change.

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
