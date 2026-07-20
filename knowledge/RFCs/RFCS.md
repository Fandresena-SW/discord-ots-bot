# RFCS — OTS Bot Backoffice v2.0 (implementation roadmap)

Master index for the RFC set that delivers the Supabase-backed backoffice
(`knowledge/PRD.md` v2, `knowledge/FEATURES.md`, `.claude/RULES.md`).

> **Implementation is strictly sequential.** Each RFC is fully implementable only
> after **all** lower-numbered RFCs are complete. There is no parallel work. Follow
> the `implementation-prompt-RFC-00N.md` two-phase prompt for each (plan → approval →
> implement).

---

## RFCs in implementation order

| # | RFC | Features | Complexity | PRD §9 day |
|---|-----|----------|-----------|-----------|
| **001** ✅ | [Supabase Schema, Constraints, Indexes & Trigger](RFC-001-Supabase-Schema.md) | F1, F2, F3, F4, F5, F6 | Medium | Day 1 |
| **002** ✅ | [Organizer Runbook (Studio Workflows)](RFC-002-Organizer-Runbook.md) | F7, F8, F9, F10 | Low–Med | Day 2 |
| **003** ✅ | [Configuration & PostgREST Data-Access Seam](RFC-003-Config-And-Data-Access.md) | F19, F23, F17(mech) | Medium | Day 2 |
| **004** ✅ | [Pure Logic: Normalization & Render-Safety](RFC-004-Pure-Logic-Normalization-Render-Safety.md) | F12(logic), F14 | High | Day 3–4 |
| **005** ✅ | [`/ots` Command Refactor: Live Read & Fail-Soft](RFC-005-OTS-Command-Refactor.md) | F11, F13, F15, F16, F17(route), F18, F22(code), F24(code) | High | Day 3–4 |
| **006** ✅ | [Reliability, Contingency & Release](RFC-006-Reliability-And-Release.md) | F20, F21, F22(docs), F24(backup), E2E, dry-run, deploy | Medium | Day 5–7 |

All six RFCs are now ✅ complete — the v2.0 Supabase-backed backoffice release
is shipped. See RFC-006's Completion record for the live E2E checklist,
dry-run, and deploy-verification sign-off.

**Won't-have (F25 a–g)** — not covered by any RFC by design (RULES §9): multiple
active tournaments, cross-tournament identities, custom web app/auth/roles, player
self-submission, pairings / hidden-until-reveal, pokepaste scraping, content
validation, caching, multi-guild, non-French localization.

---

## v3.0 — Challonge Integration (RFC-007–010)

Picks up **F25(e)** (real-time pairings, previously deferred) via a Supabase-cached
read of an organizer-managed Challonge bracket. Full context: `FEATURES.md`
§"v3.0 — Challonge Integration". Strictly sequential, same as v2.0 — each RFC
depends on all lower-numbered RFCs (v2.0's included).

| # | RFC | Features | Complexity | Status |
|---|-----|----------|-----------|--------|
| **007** ✅ | [Challonge Schema & Cache Tables](RFC-007-Challonge-Schema.md) | F26–F29 | Low–Medium | ✅ Complete |
| **008** | [Challonge Sync Edge Function (manual trigger)](RFC-008-Challonge-Sync-Edge-Function.md) | F30–F31 | Medium | 📝 Drafted |
| **009** | [`/ots` Opponent-Resolution Refactor](RFC-009-OTS-Opponent-Resolution.md) | F32–F34 | High | 📝 Drafted |
| **010** | [Runbook, Staleness Backstop & Release](RFC-010-Runbook-Staleness-Release.md) | F35–F37 | Medium | 📝 Drafted |

### Key v3.0 decisions locked (see FEATURES.md for full rationale)
- Sync job is a **Supabase Edge Function** (TypeScript/Deno), not `pg_cron`/`pg_net`
  — correctness/debuggability of JSON handling outweighs the minimal-runtime ethos
  here; still Supabase-native infra, not a "custom web app" (F25c stays Won't-have).
- Refresh is **organizer-triggered** (manual `curl`, secret-protected), not polled —
  eliminates the Challonge free-tier (500 req/month) cadence-tuning problem entirely.
- `bot.py` still never talks to Challonge directly — only Supabase, unchanged from
  the v2.0 locked decision (PRD §11.5).
- No fallback to v2.0's arbitrary-lookup `/ots` behavior when a tournament has no
  Challonge link — `/ots` hard-fails distinctly instead (F34).

### Dependency table (v3.0 additions)

| RFC | Depends on | Enables |
|-----|-----------|---------|
| 007 | 001–006 | 008, 009 |
| 008 | 007 | 009 |
| 009 | 007, 008 | 010 |
| 010 | 007–009 | — (release) |

### Dependency graph (textual, v3.0)

```
007 (challonge_tournament_id, cache tables, RLS, seed data)
 └─► 008 (Edge Function: manual-trigger full-refresh sync, writes the cache)
       └─► 009 (/ots: own-name -> opponent resolution via the cache;
                 reuses fetch_active_player verbatim for the final read)
             └─► 010 (runbook + 48h staleness log + deploy docs + E2E release)
```

### Feature → RFC coverage map (v3.0)

| Feature | RFC | Feature | RFC |
|---------|-----|---------|-----|
| F26 `challonge_tournament_id` link | 007 | F32 opponent-resolution query | 009 |
| F27 `challonge_participants_cache` | 007 | F33 expanded fail-soft (6+1 outcomes) | 009 |
| F28 `challonge_matches_cache` | 007 | F34 no-link hard-fail | 009 |
| F29 RLS + seed/test fixtures | 007 | F35 runbook: linking + trigger | 010 |
| F30 full-refresh Edge Function | 008 | F36 48h staleness warning | 010 |
| F31 secret-protected invocation | 008 | F37 E2E checklist, release | 010 |

### Roadmap notes (v3.0)

- **Critical path:** 007 → 008 → 009 is the backbone (cache schema → writer →
  reader), same shape as v2.0's 001 → 003 → 005. 010 is the closing
  documentation/verification/release RFC, mirroring 006's role exactly.
- **Highest technical risk:** **F32** (RFC-009's multi-step resolution chain —
  tournament → link → participant → match → opponent → team_text) is the
  deepest read path this project has built, and the sole High-complexity
  v3.0 feature. **F30**'s all-or-nothing write ordering (RFC-008) is the
  second-highest risk — a bug there silently corrupts the data RFC-009 reads.
- **RFC-007 seed fixtures de-risk RFC-009 the same way RFC-002's seed data
  de-risked RFC-005:** giovlacouture ↔ zou (happy path) and koloina
  (no-current-match) are available before any live Challonge account is
  needed, so RFC-009 can be built and tested against known-good/known-bad
  inputs in isolation.
- **Locked decisions honored throughout:** Edge Function over `pg_cron`/`pg_net`;
  manual trigger over polling; `bot.py` never calls Challonge directly; no
  fallback to v2.0's arbitrary-lookup `/ots` behavior; staleness is a log,
  never a gate. (PRD §24 / RULES v3.0 Addendum.)

---

## Dependency table

| RFC | Depends on (predecessors) | Enables (successors) |
|-----|---------------------------|----------------------|
| 001 | — | 002, 003, 005 |
| 002 | 001 | 003 (seed data), 006 (runbook base) |
| 003 | 001, 002 | 005 |
| 004 | 001 (contract) | 005 |
| 005 | 003, 004 | 006 |
| 006 | 001–005 | — (release) |

### Dependency graph (textual)

```
001 (DB schema/constraints/indexes/trigger)
 ├─► 002 (Studio runbook + seeded test data)
 │     └─► 003 (config + PostgREST read helper) ◄─┐
 ├─────────────────────────────────────────────────┘
 └─► 004 (pure logic: normalize + render-safety)   (mirrors 001's normalization contract)
                   │                │
       003 ────────┴──────► 005 (/ots atomic swap: live read, embed, fail-soft, cleanup)
       004 ───────────────►  │
                             └─► 006 (reliability docs, E2E gate, dry-run, deploy)
```

---

## Feature → RFC coverage map

| Feature | RFC(s) | Feature | RFC(s) |
|---------|--------|---------|--------|
| F1 tournaments table | 001 | F13 embed build | 005 |
| F2 players table | 001 | F14 render-safety | 004 (logic) → 005 (use) |
| F3 single-active index | 001 | F15 fail-soft (3 French) | 005 |
| F4 name trim+CI-unique | 001 | F16 improved not-found copy | 005 |
| F5 Studio defaults/order | 001 | F17 bounded timeout | 003 (mech) → 005 (route) |
| F6 indexed read path | 001 | F18 mandatory deferral | 005 |
| F7 create/activate | 002 | F19 env config + validation | 003 |
| F8 two-step switch | 002 | F20 pre-event pre-flight | 006 |
| F9 player CRUD | 002 | F21 keep-alive (optional) | 006 |
| F10 20-player fast setup | 002 (recipe) → 006 (timed) | F22 break-glass + degradation | 003/005 (code) → 006 (docs) |
| F11 live Supabase read | 005 | F23 PostgREST over aiohttp | 003 |
| F12 trimmed CI lookup | 004 (logic) → 005 (integrate) | F24 migration/cleanup | 005 (code) → 006 (backup docs) |
| | | F25 out-of-scope (a–g) | — (not built) |

---

## Roadmap notes

- **Critical path:** 001 → 003 → 005 is the backbone (data → access → command). 002
  and 004 are prerequisites that slot in without extending the critical path (002
  supplies test data; 004 supplies the pure functions 005 wires in).
- **Highest technical risk:** **F11** (RFC-005, the sole command-path refactor) and
  **F14** (RFC-004, char-accounting + fence escaping). RFC-004 deliberately precedes
  RFC-005 to de-risk F14 in isolation with unit tests.
- **Release gates (RULES §8/§9):** the RFC-004 `unittest` suite must be green, and the
  RFC-006 E2E in-guild checklist + timed 20-player dry-run must pass, before the
  RFC-006 deploy. Zero player-facing regression vs. v1 is non-negotiable (PRD §6/G3).
- **Locked decisions honored throughout:** DB-level single-active + CI-unique;
  service key worker-only; raw PostgREST over `aiohttp` (no `supabase-py`); team text
  trusted-as-is but render-hardened; improved not-found copy. (PRD §11 / RULES.)

## Tracked follow-ups

- **RLS enablement on `tournaments` / `players` — owner: RFC-003. ✅ Resolved
  2026-07-18.** RFC-001 creates the tables but deliberately scopes RLS *out* (the
  worker's service key bypasses RLS anyway). However, Supabase grants the `anon`
  role default SELECT on public-schema tables unless RLS is enabled, and PRD §6
  states tables must not be exposed via a public anon endpoint without RLS. Assigned
  to **RFC-003** (the config/data-access seam) and closed there: `schema.sql` now
  enables RLS on both tables with a deny-by-default posture (no policies — only the
  service key needs access), added during RFC-003's round 2 fix after its own
  reviewer flagged the gap as blocking. *(Surfaced during RFC-001 review, Round 1;
  fixed during RFC-003 review, Round 2 — see RFC-003 § Completion record.)*

- **`.claude/agents/{coder,planner,reviewer,explorer,tester}.md` and the
  `/rfc` skill are templated for an unrelated Flutter/Supabase project
  ("Atelier Hub") — owner: unassigned, flagged during RFC-007.** They
  reference `flutter analyze`, `ccc search`, Dart/`freezed`/Riverpod
  conventions, `.claude/CLAUDE.md`, `.claude/rules/`, and `knowledge/PRD.v4.md`
  — none of which exist in this repo. RFC-007 was implemented directly
  (no orchestration) to avoid the mismatch; RFC-008–010 will hit the same
  issue unless these agent definitions are rewritten for this repo's actual
  stack (Python/discord.py/Supabase SQL, `CLAUDE.md`, `.claude/RULES.md`,
  `knowledge/PRD.md`) or the `/rfc` flow is skipped in favor of direct
  implementation. *(Surfaced during RFC-007, 2026-07-20 — not yet resolved.)*

## Structural decisions (low-risk defaults, flagged in the RFCs)

- **`schema.sql` at repo root** (operational DDL asset, not a `knowledge/` doc; no new
  Python folder — RULES §2). *(RFC-001)*
- **Tests in a single root-level `test_bot.py` using stdlib `unittest`** — no new
  folder, no new dependency (RULES §1/§2/§8). *(RFC-004)*
- **`if __name__ == "__main__":` guard** added so `import bot` is side-effect-free for
  testing. *(RFC-004, used by RFC-005)*

Each is a minimal, reversible choice; if the maintainer prefers otherwise it's a
trivial move noted in the relevant RFC.
