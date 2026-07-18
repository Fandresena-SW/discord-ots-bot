# RFC-006 — Reliability, Contingency & Release — Implementation Plan

> **Architect's note on the template.** This repo is a single-file Python
> `discord.py` bot with a Supabase/PostgREST backend, not a Flutter app. The
> standard plan sections for DB migrations / Dart models / Riverpod providers /
> screens / routing / edge functions **do not apply** and are marked N/A below
> with justification. RFC-006 is a **documentation + verification + release**
> RFC — no application code is expected. The real substance is in sections 2A
> (Runbook additions), 2B (E2E checklist artifact), and 8–9 (order + risks).

---

## 1. SCOPE SUMMARY

RFC-006 closes out the v2.0 release by hardening the **live-event reliability**
story that the Supabase backend swap made necessary (Supabase is now a single
point of failure). It adds three operational procedures to the organizer
runbook — a **pre-event pre-flight ritual** (F20), a **break-glass /
graceful-degradation** contingency (F22), and **roster backup-of-record**
guidance (F24-backup); authors and executes the **E2E in-guild checklist** (the
primary release gate); runs the **timed 20-player Studio dry-run** (G2); and
**verifies the already-live production deployment** on the OCI systemd worker
plus monitors first live use. The optional keep-alive ping (F21, Could) is
**explicitly deferred, not built**, per RULES §1/§2 (external-scheduler-first).

**Out of scope:** any change to `bot.py` or `schema.sql`, and any new
dependency, folder, or module. This RFC is docs + verification only.

---

## 2. DATABASE MIGRATIONS

**N/A.** RFC-006 §4 states "Data models / schema changes: None." The schema is
static in `schema.sql` (root; no migrations folder — this project applies DDL
idempotently in Studio, it does not use numbered `.sql` migrations). No table,
column, RLS policy, index, trigger, or function is created or altered. The
existing objects the release depends on (`tournaments_one_active_idx`,
`players_tournament_name_idx`, `trim_ingame_name()` trigger) are **verified**
during the dry-run, not modified.

---

## 3. DART MODELS

**N/A.** No models of any kind. Discord embeds are built inline in `bot.py`
(RULES §2, single-file, no abstractions). No `build_runner`, no Dart.

---

## 4. PROVIDERS

**N/A.** No Riverpod. The data-access seam already exists from RFC-003/005
(`fetch_active_player()` and its `_fetch_active_tournament_id` /
`_fetch_player_in_tournament` helpers) and is **not touched** by this RFC. It is
only exercised (read-only) during the E2E checklist and dry-run.

---

## 5. SCREENS & WIDGETS

**N/A.** No UI code. The only user-facing surface is the Discord embed produced
by the existing `/ots` command, which is verified (not modified) by the E2E
checklist's four-state equivalents:
- **Happy / data:** embed with `team_text` code block (with and without title URL).
- **Empty / not-found:** friendly French "introuvable" message scoped to the
  active tournament (F16).
- **Error:** two distinct French messages — no active tournament (F15b) and
  Supabase unreachable/timeout (F15c), the latter with an operator-side log.
- **Loading:** the immediate ephemeral `defer` before network I/O (F18).

---

## 2A. RUNBOOK ADDITIONS (the primary deliverable) — `knowledge/RUNBOOK.md`

**File:** `/Volumes/Data/Perso/discord-ots-bot/knowledge/RUNBOOK.md`
**Action:** Replace the reserved placeholder `## §5 — Réservé (ajouté par
RFC-006)` block (currently lines ~219–227) with three fully-authored
subsections. Also update the document header (lines 3–8) to mark RFC-006
sections complete and update the "Complété par" note. Keep all user-facing prose
**in French** (RULES §3); internal identifiers and git references stay English.

### §5 — Pré-vol avant événement (F20)

A numbered checklist the organizer ticks through **before every event**:

1. Ouvrir Supabase Studio ; confirmer que le projet est **actif (non mis en
   pause)**. Le free tier se met en pause après ~7 jours d'inactivité — si
   pausé, cliquer **Resume**/**Restore** et attendre que le projet redémarre.
2. Confirmer qu'**exactement un** tournoi, le bon, a `is_active = true`
   (Table Editor → `tournaments`). Renvoyer vers §2 (switch en deux temps) si
   un changement est nécessaire.
3. Lancer un `/ots <joueur connu>` de test dans le serveur Discord et confirmer
   un embed correct (cite un joueur du seed ou du roster réel comme exemple).
4. Cocher chaque item ; ne pas ouvrir l'événement tant que les trois ne
   passent pas.

Include an explicit **paused-project scenario** with the resume step (acceptance
criterion F20 requires it).

### §6 — Contingence / procédure de secours ("break-glass") (F22)

Two parts:

**(a) Dégradation gracieuse (déjà implémentée, RFC-003/005) — à vérifier.**
Document that during a Supabase outage the bot already fails soft in French and
logs server-side; the organizer's job is to **confirm the operator log appears**
(`journalctl -u discord-ots-bot -f`, per DEPLOYMENT.md §10) and that no crash /
stack trace reaches the player. Cross-reference RULES §7 (loud-to-operator).

**(b) Break-glass : redéployer le bot v1 (carte codée en dur) pour un seul
événement** if Supabase is down and cannot be resumed in time. Document, with
exact git references:
- The v1 `USERNAME_URLS` + `fetch_pokepaste` path was **deleted in commit
  `a79bdfb` (RFC-005)** and lives only in history.
- **Last commit where the full v1 path is present: `184216b` (RFC-004)** —
  `USERNAME_URLS` at `bot.py:72`, `fetch_pokepaste()` at `bot.py:129`.
- Recovery steps (documented, not executed): from the production VM, on a
  throwaway branch, `git checkout 184216b -- bot.py`; populate `USERNAME_URLS`
  from the backup roster (see §7 below); commit locally; restart the systemd
  service (`sudo systemctl restart discord-ots-bot`, or a manual variant of
  `deploy.sh` that skips `git pull`). Note this is a **temporary single-event
  measure**; revert to the Supabase path (`git checkout main -- bot.py` +
  redeploy) once Supabase is back.
- Warn that v1 has no Supabase env dependency but **requires the roster to be
  re-entered by hand** into the dict — hence the backup-of-record in §7 must be
  current.

### §7 — Sauvegarde du roster de référence (F24-backup)

Document that the roster lives **only in Supabase**, so the backup-of-record is:
- The organizer's **source notes** (the notes-app list used for the §4 bulk
  entry), and/or
- A **Studio CSV export** of the `players` table (Table Editor → `players` →
  Export → CSV).
- **Refresh timing:** after the roster is finalized and again immediately before
  each event; this backup is what feeds the §6(b) break-glass dict if needed.

### Header + references maintenance
- Update lines 3–8 status/features/"Complété par" to reflect §5–§7 now authored.
- Add `knowledge/DEPLOYMENT.md` and `knowledge/E2E-CHECKLIST.md` to the
  **Références** block.

---

## 2B. E2E CHECKLIST ARTIFACT — `knowledge/E2E-CHECKLIST.md` (create)

**File:** `/Volumes/Data/Perso/discord-ots-bot/knowledge/E2E-CHECKLIST.md`
**Decision (architect):** author the checklist as a **separate file**, not
inside RUNBOOK.md. Rationale: RUNBOOK.md is the organizer's evergreen operating
manual; the E2E checklist is a **release-gate evidence artifact** with recorded
pass/fail results tied to a specific ship date. RFC-006 §3.3 explicitly permits
either; separation keeps the runbook clean and the release evidence auditable.
RULES §2 (docs in `knowledge/`) is satisfied.

Contents — the **8 mandated scenarios** (RFC-006 §3.3 / RULES §8), each a row
with columns: Scenario | Steps | Expected | Result (pass/fail) | Notes:
1. Happy path — player **with** `pokepaste_url` → embed title links.
2. Happy path — player **without** URL → renders, no link (use seed player
   `koloina`, whose `pokepaste_url` is NULL).
3. **Not found** → French, scoped-to-current-tournament copy (F16).
4. **No active tournament** → French message (F15b).
5. **Supabase down / timeout** → French unavailable message **and operator log
   present** (F15c/F22) — verify via `journalctl`.
6. **DMs-closed fallback** → ephemeral in-channel embed (`discord.Forbidden`).
7. **Oversized `team_text`** → truncated valid embed with French marker (F14).
8. **Backtick-containing `team_text`** → renders inside code block, no
   break-out (F14).
9. Case/whitespace variants of a name resolve to the same player (F12).

(That is 8 mandated scenarios plus the normalization check = 9 rows; keep all.)

Include a header noting: **all items must pass before deploy** (RULES §9), a
sign-off line (date + organizer), and a reference to the pre-deploy unit-test
sanity run (`python -m unittest test_bot`).

---

## 6. ROUTING

**N/A.** No `app_router.dart`. The only command route, `/ots`, already exists
(RFC-005) and is unchanged.

---

## 7. EDGE FUNCTIONS

**N/A / explicitly deferred.** F21 (keep-alive ping) is a *Could* and is **not
built** this RFC. Per RFC-006 §3.2 and RULES §1/§2, if a keep-alive ever proves
necessary the preferred implementation is an **external scheduler** (hosting
platform cron / external pinger hitting a trivial PostgREST read within the
~7-day window) requiring **zero repo/`bot.py` change** — no `supabase/functions`
directory, no in-process scheduler, no new dependency. The plan records this as
deferred; the coder must **document it as off-by-default in RUNBOOK §5/§6**, not
implement it. If pre-flight (F20) later proves insufficient in practice, that is
a follow-up decision requiring explicit PRD justification (RULES §10).

---

## 8. IMPLEMENTATION ORDER

No migrations/models/providers/UI here, so the standard ordering collapses to a
**docs → verification → release-verification** sequence:

1. **Author RUNBOOK §5–§7** (pre-flight F20, break-glass F22, roster backup
   F24) — replace the reserved placeholder; use the confirmed git references
   (`184216b` for v1 code, `a79bdfb` as the deletion commit). Update the
   RUNBOOK header + Références.
2. **Create `knowledge/E2E-CHECKLIST.md`** — the 9-row release-gate artifact.
3. **Record F21 deferral** in RUNBOOK (off-by-default, external-first) — no code.
4. **Pre-deploy sanity:** run `python -m unittest test_bot` from repo root;
   confirm all RFC-004 render-safety / normalization tests pass. (No new tests
   — RFC-004 already covers `normalize_name` / `render_team_text`.)
5. **Execute the E2E checklist** in the guild; record pass/fail for every row.
   All must pass (RULES §9) before proceeding.
6. **Timed 20-player dry-run** in Studio (G2/F10): target < 5 min from the
   notes app; rehearse the two-step activation switch (§2) and the §5 pre-flight
   + §6 resume/contingency. Record the actual time back into RUNBOOK §4's
   "Temps observé" line. If over 5 min, apply the F5/F10 column-ordering / paste
   recipe fixes and re-time.
7. **Verify the existing production deployment** (do NOT plan a fresh deploy —
   it already happened 2026-07-18, documented in `knowledge/DEPLOYMENT.md` with
   `deploy.sh`):
   - Confirm the OCI systemd service `discord-ots-bot` is `active (running)`
     (`sudo systemctl status`).
   - Confirm `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` are set on the VM
     (`.env`, worker-only, not committed) and startup env validation
     (`validate_config`) passes on boot.
   - Confirm heartbeat + Supabase error logs appear as expected
     (`journalctl -u discord-ots-bot`).
   - If a code change *were* needed, `deploy.sh` is the redeploy path — but
     none is expected for this RFC.
8. **Monitor first live use** toward the 2026-07-25 target; keep buffer for fixes.

Steps 5–8 are operational/manual (require the live guild + Studio + VM); the
coder authors the artifacts (1–3) and runs the sanity test (4). Where the coder
cannot execute a live step, it must leave the E2E rows / dry-run time as
explicitly **pending execution** (not fabricated results) and flag them for the
organizer, per RULES §10 (no silent half-implementation).

---

## 9. RISK AREAS

The exploration report identified **no code conflicts** (RFCs 001–005 are
complete and committed; RFC-006 touches only docs). Residual risks to manage:

1. **Break-glass git reference accuracy.** The recovery procedure is worthless
   if the commit hash is wrong. **Confirmed by inspection:** `184216b` (RFC-004)
   is the last commit containing the full v1 path (`USERNAME_URLS` at `bot.py:72`,
   `fetch_pokepaste()` at `bot.py:129`); the deletion is in `a79bdfb` (RFC-005).
   The coder must cite these exact hashes — do not paraphrase or re-derive.

2. **Deployment is already live — do not re-plan it.** DEPLOYMENT.md documents
   the real target as an **OCI systemd service**, not the `Procfile` worker named
   in RFC-006 §3.5 / CLAUDE.md. Strategy: RFC-006's "deploy" step becomes a
   **verify-existing** step against DEPLOYMENT.md (systemd status, env vars,
   logs); the `Procfile` remains a portable declaration only. Note this
   RFC-text-vs-reality discrepancy in the checklist rather than "fixing" either.

3. **Fabricated verification results.** The E2E pass/fail and the dry-run
   time require live execution. Risk: the coder marks them "pass" without
   running them. Strategy: any row the coder cannot actually execute must be left
   **pending** and flagged for the organizer — RULES §9 makes these a hard
   release gate, so a fabricated pass is worse than an honest pending.

4. **F21 scope creep.** Temptation to "just add" an in-process keep-alive.
   Strategy: explicitly deferred (section 7); external-scheduler-first; no
   `bot.py` / dependency change without PRD justification (RULES §1/§10).

5. **Roster-backup staleness (F24).** The break-glass dict is only as good as
   the backup. Strategy: RUNBOOK §7 must state the **refresh timing** (after
   roster finalized, before each event) explicitly, not just the export
   mechanism.

6. **French-only prose drift.** All RUNBOOK/E2E user-facing prose must stay
   French (RULES §3), while git hashes, object names, and CLI commands stay
   English. Strategy: mirror the existing RUNBOOK bilingual convention (French
   narrative, English identifiers in code fences).
