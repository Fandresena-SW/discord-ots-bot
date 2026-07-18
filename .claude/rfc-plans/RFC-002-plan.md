# RFC-002 Implementation Plan — Organizer Runbook (Supabase Studio Workflows)

> **Stack note:** This project is a single-file **Python Discord bot** with a
> **Supabase (Postgres + PostgREST)** backend — it is **not** a Flutter/Dart app.
> The standard plan template's Flutter sections (Dart Models, Riverpod Providers,
> Screens & Widgets, Routing, Edge Functions) are **Not Applicable** and are marked
> as such below. RFC-002 is a **documentation-only** deliverable: one new Markdown
> file, `knowledge/RUNBOOK.md`, plus (at most) a cross-reference tweak. **No Python,
> no SQL, no schema changes.** It consumes the RFC-001 schema (`schema.sql`) as-is.

---

## 1. SCOPE SUMMARY

RFC-002 delivers the organizer operating manual, `knowledge/RUNBOOK.md`: a
self-contained, numbered set of Supabase Studio procedures that let a non-developer
organizer run the whole backoffice with **zero code changes or redeploys** (PRD G1).
It documents first-time project bootstrap (create project + apply `schema.sql` +
capture `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`), creating and activating a
tournament (F7), the deliberate two-step activation switch with the exact expected
constraint-error text (F8), full player CRUD add/edit/delete taking effect on the
next `/ots` (F9), and a copy-paste fast-setup recipe for ~20 players (F10). Every
procedure is written to match the real DB behavior derivable from `schema.sql`
(exact object names, trigger behavior, `23505` error message), and the file reserves
clearly-marked placeholders for the two sections RFC-006 will append (pre-event
pre-flight, contingency / break-glass).

**Explicitly out of scope:** any bot code or SQL change; the timed 20-player < 5-min
dry-run and the pre-flight/contingency sections themselves (both deferred to RFC-006,
Day 6); RLS policies; and interactive click-through validation that requires a human
in Studio (see §9 Risk Areas).

---

## 2. DATABASE MIGRATIONS

**N/A — none.** RFC-002 makes no schema change and creates no migration. It consumes
RFC-001's `schema.sql` verbatim. The runbook must **describe** applying that existing
file via the Studio SQL editor, but the coder must **not** modify `schema.sql`, add a
`migrations/` folder, or alter any DDL (RULES §2; RFC-002 §4 "None").

The facts the runbook documents about the DB (must be transcribed exactly, no
paraphrase of identifiers) come from `schema.sql` (repo root):

| Object | Exact name / behavior to cite in the runbook |
|--------|----------------------------------------------|
| Tables | `tournaments`, `players` |
| Single-active index | `tournaments_one_active_idx` — partial unique on `is_active` where `is_active = true` |
| Name-uniqueness index | `players_tournament_name_idx` — unique on `(tournament_id, lower(ingame_name))` |
| Trim trigger | `players_trim_ingame_name` (BEFORE INSERT OR UPDATE) → `trim_ingame_name()`; `btrim()` only; empty-after-trim raises `ingame_name must not be empty after trimming` |
| FK | `players.tournament_id → tournaments(id) on delete cascade` (deleting a tournament cascades its players) |
| Seed | tournament `RFC-001 Test Tournament` (`is_active = true`); players `giovlacouture`, `zou` (both with pokepaste URLs), `koloina` (`pokepaste_url = NULL`); `team_text` = `[SEED PLACEHOLDER] …` |

**Exact F8 constraint-error text to document** (the organizer must recognize it as
expected, not a bug — RULES §4, PRD §11.1). A one-step activation attempt (setting a
second row `is_active = true` while one is already active) raises Postgres SQLSTATE
`23505`:

```
duplicate key value violates unique constraint "tournaments_one_active_idx"
```

Studio surfaces this as a red error toast/panel wrapping the PostgREST error body
(`code: "23505"`, the message above, and typically `details: Key (is_active)=(true)
already exists.`). Document all three fragments so the organizer recognizes any form
Studio renders. State plainly: **this is correct, protective behavior — never "fix"
it by dropping the index; do the two-step switch instead.**

---

## 3. DART MODELS

**N/A.** No Dart/Flutter. No models, no `build_runner`, no `@freezed`. RFC-002 touches
no Python either.

---

## 4. PROVIDERS

**N/A.** No Riverpod / Flutter. The read path the runbook's F9 "visible on next
`/ots`" promise depends on is owned by RFC-003/005, not RFC-002. The runbook only
asserts the *observable* behavior (edits are live on the next lookup), not any query
shape.

---

## 5. SCREENS & WIDGETS

**N/A — no web/mobile UI.** The only admin surface is **Supabase Studio**, described
in prose (RFC-002 §7: "describe Studio table-editor interactions in words; no web UI
to build"). There is no loading/error/empty/data state matrix to design.

The one UI-adjacent artifact the runbook must reference is the **F5 column ordering**
already documented in `schema.sql` comments (lines 37–42): in the `players` table
editor, order columns `ingame_name`, `team_text`, `pokepaste_url` first, then
`tournament_id`, then system columns (`id`, `created_at`) last. The fast-setup recipe
(F10) builds on this so a valid row needs only name + team text (+ optional URL). Do
not restate it as enforceable DDL — it is a Studio UI setting only.

---

## 6. ROUTING

**N/A.** No routing framework. (The player-facing `/ots` Discord command is untouched
by RFC-002.)

---

## 7. EDGE FUNCTIONS

**None.** No `supabase/functions/` directory, no pg_cron, no edge functions. All
workflows are manual Studio clicks and hand-run SQL, documented in Markdown.

---

## 8. IMPLEMENTATION ORDER

Migrations → models → providers → UI collapses here to **"write one Markdown file."**
Ordered steps for the coder:

1. **Create `knowledge/RUNBOOK.md`** (per RULES §2 — docs live in `knowledge/`). Use
   the repo's Markdown conventions: H1
   `# RFC-002 — Organizer Runbook (Supabase Studio Workflows)`; `## N.` H2 sections;
   `### N.M` subsections; `§N` section refs; pipe tables; fenced code blocks with a
   language tag; numbered procedures with sub-bullets; explicit locked-decision
   callouts (RULES §4, PRD §11.1); F-number coverage callouts (F7–F10). Keep all
   organizer-facing prose in **French** where it is copy the organizer reads
   in-context, matching the existing docs' tone (RULES §3, §5) — but keep DB
   identifiers, object names, and error strings in English/verbatim exactly as they
   appear in Postgres/`schema.sql` (RULES §3). Mirror the language mix already used in
   `.env.example` (French comments, English identifiers).

2. **Write the sections in this order** (RFC-002 §3.1 / §7):

   1. **Header block** — Status, Features covered (F7–F10), builds upon RFC-001,
      built upon by RFC-006; one-paragraph summary of purpose (G1 zero-redeploy).

   2. **§0 First-time Supabase setup (one-time bootstrap):**
      - Create a Supabase project (supabase.com → New project): org, name, region,
        DB password → store the password in a password manager, **never in the repo**.
      - Studio → SQL Editor → New query → paste the entire `schema.sql` (repo root) →
        Run. Note it is **idempotent** — safe to re-run; a second run is a no-op
        (`NOTICE: ... already exists, skipping`).
      - Confirm objects: Table Editor shows `tournaments` + `players`; seed = 1 active
        tournament + 3 players (one, `koloina`, with `pokepaste_url = NULL`).
        Optionally run the commented verification queries at the bottom of `schema.sql`.
      - Capture the two `.env` values (consumed by RFC-003): **Project Settings → API
        → Project URL** = `SUPABASE_URL`; **Project Settings → API Keys → the secret
        key** (`sb_secret_…`; legacy `service_role` JWT on unmigrated projects) =
        `SUPABASE_SERVICE_KEY`. Warn: **not** the publishable/anon key (respects RLS,
        reads nothing once RLS is deny-by-default); the secret key **bypasses RLS**,
        is **worker-only**, never committed or exposed client-side (RULES §3/§6, PRD
        §11.2). Cross-reference `.env.example` for the exact variable names.

   3. **§1 Create & activate a tournament (F7):** new `tournaments` row, set `name`,
      leave `is_active = false`; then set `is_active = true` (only when no other
      tournament is active); confirm `/ots <known player>` now resolves against it.

   4. **§2 Two-step activation switch (F8):** Step 1 set current active
      `is_active = false`; Step 2 set new `is_active = true`. Include the **exact**
      expected error (§2 of this plan) with the "expected, not a bug" callout (RULES
      §4, PRD §11.1) and the reassurance that the constraint protects data integrity.

   5. **§3 Player CRUD without redeploy (F9):** Add (new `players` row: set
      `tournament_id` to the **active** tournament, paste `ingame_name` + `team_text`,
      optional `pokepaste_url`); Edit `team_text` (Journey B) — live on the **next**
      `/ots`, no redeploy; Delete row — no longer resolvable. Note the trim trigger
      (F4): pasted names with stray leading/trailing spaces store clean; a
      name empty after trim is rejected with `ingame_name must not be empty after
      trimming`. Warn (edge case, RFC-002 §8): filter/scope edits to the **active**
      `tournament_id` so you don't edit the wrong tournament's players.

   6. **§4 20-player fast setup (F10):** the copy-paste recipe using F5 column
      ordering; document notes-app → Studio grid paste (spreadsheet/tab-separated bulk
      paste vs. one-row-at-a-time) and any transform needed; leave a spot to record
      observed setup time. State clearly the **timed < 5-min proof is the RFC-006
      Day-6 dry-run**, not this pass.

   7. **§5 (placeholders) reserved for RFC-006** — two clearly-labeled empty sections:
      **"Pre-event pre-flight"** and **"Contingency / break-glass."** Mark them as
      *"Reserved — added in RFC-006"* so they are not mistaken for missing content
      (RFC-002 §7). These are the *only* permitted placeholders (RULES §10 forbids
      stray TODOs; these are explicit, RFC-sanctioned deferrals).

3. **Add F-coverage + cross-references:** callouts to F7/F8/F9/F10, links to
   `knowledge/PRD.md` (§5.2, §7 Journeys A & B), `knowledge/FEATURES.md`,
   `.claude/RULES.md` (§2, §4, §5, §10), and `schema.sql`. Keep the note that RFC-006
   extends this same file.

4. **Optional (low priority) cross-link:** if trivial, add a one-line pointer to
   `knowledge/RUNBOOK.md` from `CLAUDE.md`'s "Docs & knowledge base" list for
   discoverability. **Do not** edit `schema.sql`, `.env.example` content, or any
   Python. Skip if it risks scope creep — the RFC only requires the new file.

5. **Self-review against acceptance criteria** (RFC-002 §6): bootstrap produces the
   two tables + trigger + indexes + seed on a fresh project; F7 activate flow; F8
   documented with exact error as expected; F9 add/edit/delete live on next `/ots`
   incl. mid-event `team_text` edit; F10 recipe present with the < 5-min proof
   deferred; file is self-contained; seed fixture noted as the data RFC-003/005 rely
   on.

---

## 9. RISK AREAS

The exploration report found **no code/schema conflicts** (documentation-only). The
residual risks are validation-fidelity and drift, resolved as follows:

1. **Un-validated live DB / no interactive Studio access (the key gap).** The RFC's
   acceptance criteria want procedures *validated by performing them*, but the coder
   cannot click through Studio's web UI or confirm `schema.sql` was applied to the
   live project in `.env`. **Resolution:** write every procedure to the **exact
   factual accuracy derivable from `schema.sql`** — real object names
   (`tournaments_one_active_idx`, `players_tournament_name_idx`,
   `players_trim_ingame_name`), real trigger behavior (`btrim`, empty-name raise), and
   the real Postgres `23505` message for F8. Explicitly flag the remaining
   **manual-only validation** — real click-through, Studio screenshots/exact toast
   wording, and the timed 20-player run — as **out of scope for the coder pass**,
   deferred to the human organizer and the RFC-006 Day-6 dry-run. Do not fabricate
   screenshots or invent UI wording not derivable from the schema.

2. **F8 error-text accuracy.** Getting the message subtly wrong defeats the section's
   purpose (organizer must recognize it). **Resolution:** transcribe verbatim from
   §2 of this plan (`duplicate key value violates unique constraint
   "tournaments_one_active_idx"`, SQLSTATE `23505`, `Key (is_active)=(true) already
   exists.`), and note Studio may wrap it in a PostgREST JSON body.

3. **Language mix drift.** French organizer copy vs. English DB identifiers can get
   muddled. **Resolution:** organizer-facing narrative in French (RULES §5); table
   names, column names, index names, and error strings stay verbatim English exactly
   as Postgres emits them (RULES §3) — never translate an identifier.

4. **Doc drift vs. `schema.sql` / `.env.example`.** The runbook restates schema facts
   and env var names; if it paraphrases loosely it can drift from the source of truth.
   **Resolution:** reference the exact variable names from `.env.example`
   (`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`) and the exact object names from
   `schema.sql`; keep the runbook pointing *at* those files rather than duplicating
   their contents (RULES §10 keep docs in sync).

5. **Placeholder discipline.** RFC-006's two sections must exist as labeled reservations
   without tripping the "no stubs/TODOs" rule. **Resolution:** mark them explicitly
   as *"Reserved — added in RFC-006"*, which is an RFC-sanctioned deferral, not a
   silent half-implementation (RULES §10; RFC-002 §7).

6. **Scope creep into RFC-006 / RFC-003.** Tempting to write the pre-flight, the
   resume-paused-project ritual, or the timed dry-run now. **Resolution:** stop at the
   labeled placeholders; the timed proof and contingency belong to RFC-006 (RFC-002
   §6, §10; scope-limitation clause of the implementation prompt).

---

## Rules compliance checklist (for the coder)

- New doc lives in `knowledge/RUNBOOK.md`; no new code, no new folders (RULES §2;
  RFC-002 §4/§9).
- Organizer-facing copy French; DB identifiers/error strings verbatim English
  (RULES §3, §5).
- Two-step-activation constraint documented as **expected**, never "fixed"
  (RULES §4, PRD §11.1).
- Secret key described as worker-only, RLS-bypassing, never committed; no real
  secrets in the doc (RULES §6).
- Only RFC-006 placeholders are the two explicitly-reserved sections; no stray TODOs
  (RULES §10).
- `schema.sql`, `.env.example` content, and all Python untouched (RFC-002 §4).
